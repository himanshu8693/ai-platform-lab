#!/usr/bin/env python3
"""
F1 — Resilient HTTP Client (Python companion)
scripts/examples/resilient_client.py

Python counterpart to the Go httpclient package. Demonstrates the same
decorrelated-jitter back-off pattern using only stdlib (urllib.request)
so there are zero external dependencies.

Usage:
    python3 scripts/examples/resilient_client.py

The script hits httpbin.org/status/503 three times to force retries, then
succeeds on a 200 endpoint to show the pattern end-to-end.

Pattern reference:
    https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
"""

from __future__ import annotations

import json
import logging
import os
import random
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Callable, Iterator, Optional

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Retry configuration
# ---------------------------------------------------------------------------

RETRYABLE_STATUSES: frozenset[int] = frozenset({429, 502, 503, 504})

@dataclass
class RetryOptions:
    max_attempts: int = 4
    base_delay: float = 0.2       # seconds
    max_delay: float = 30.0       # seconds
    retryable_statuses: frozenset[int] = field(default_factory=lambda: RETRYABLE_STATUSES)


# ---------------------------------------------------------------------------
# Decorrelated jitter helper
# ---------------------------------------------------------------------------

def _jitter(prev: float, opts: RetryOptions) -> float:
    """
    Decorrelated jitter: sleep = clamp(random(base, prev*3), base, max)
    This avoids thundering-herd more effectively than pure exponential back-off.
    """
    lo = opts.base_delay
    hi = min(opts.max_delay, prev * 3)
    hi = max(hi, lo)
    return random.uniform(lo, hi)  # noqa: S311 — not crypto


# ---------------------------------------------------------------------------
# Resilient request wrapper
# ---------------------------------------------------------------------------

class ResilientClient:
    """
    Wraps urllib.request with exponential-jitter back-off and Retry-After support.

    Example::

        client = ResilientClient(RetryOptions(max_attempts=5))
        with client.get("https://api.example.com/v1/models") as resp:
            data = json.load(resp)
    """

    def __init__(self, opts: Optional[RetryOptions] = None) -> None:
        self.opts = opts or RetryOptions()

    def request(
        self,
        url: str,
        method: str = "GET",
        headers: Optional[dict[str, str]] = None,
        data: Optional[bytes] = None,
    ):
        """
        Execute an HTTP request with retry logic.
        Returns the urllib response object (context manager, call .read()/.close()).
        Raises urllib.error.HTTPError if all attempts are exhausted.
        """
        opts = self.opts
        prev = opts.base_delay

        req = urllib.request.Request(url, method=method, data=data, headers=headers or {})

        last_exc: Exception | None = None

        for attempt in range(1, opts.max_attempts + 1):
            try:
                resp = urllib.request.urlopen(req, timeout=30)  # noqa: S310
                return resp  # success — caller owns this resource

            except urllib.error.HTTPError as exc:
                if exc.code not in opts.retryable_statuses:
                    raise  # non-retryable: propagate immediately

                log.warning(
                    "httpclient: retryable status %d (attempt %d/%d)",
                    exc.code, attempt, opts.max_attempts,
                )
                last_exc = exc

                if attempt == opts.max_attempts:
                    break

                # Honour Retry-After header.
                sleep = _jitter(prev, opts)
                retry_after = exc.headers.get("Retry-After")
                if retry_after:
                    try:
                        sleep = max(sleep, float(retry_after))
                    except ValueError:
                        pass

                log.info("httpclient: backing off %.2fs", sleep)
                time.sleep(sleep)
                prev = sleep

            except (urllib.error.URLError, OSError) as exc:
                log.warning("httpclient: network error (attempt %d/%d): %s", attempt, opts.max_attempts, exc)
                last_exc = exc

                if attempt == opts.max_attempts:
                    break

                sleep = _jitter(prev, opts)
                log.info("httpclient: backing off %.2fs", sleep)
                time.sleep(sleep)
                prev = sleep

        raise RuntimeError(
            f"httpclient: exhausted {opts.max_attempts} attempts"
        ) from last_exc

    def get(self, url: str, headers: Optional[dict[str, str]] = None):
        return self.request(url, method="GET", headers=headers)


# ---------------------------------------------------------------------------
# Cursor paginator
# ---------------------------------------------------------------------------

def paginate(
    client: ResilientClient,
    url_factory: Callable[[str], str],
    page_key: str = "data",
    cursor_key: str = "next_cursor",
) -> Iterator[list]:
    """
    Yields successive pages from a cursor-based REST endpoint.

    :param client:       ResilientClient instance.
    :param url_factory:  Called with (cursor: str) → URL string. cursor is "" for the first page.
    :param page_key:     JSON key containing the list of items (default: "data").
    :param cursor_key:   JSON key for the next-page cursor (default: "next_cursor").

    Example::

        for page in paginate(client, lambda c: f"https://api.example.com/v1/models?after={c}"):
            for item in page:
                print(item["id"])
    """
    cursor = ""
    while True:
        url = url_factory(cursor)
        with client.get(url) as resp:
            body = json.loads(resp.read().decode())

        items = body.get(page_key, [])
        if not items:
            return

        yield items

        # Advance cursor.
        cursor = body.get(cursor_key) or body.get("after") or body.get("cursor") or ""
        has_more = body.get("has_more", bool(cursor))
        if not has_more or not cursor:
            return


# ---------------------------------------------------------------------------
# Demo / smoke-test
# ---------------------------------------------------------------------------

def main() -> None:
    log.info("=== F1 Resilient HTTP Client Demo ===")

    # Use a short retry window for the demo.
    opts = RetryOptions(max_attempts=3, base_delay=0.05, max_delay=0.5)
    client = ResilientClient(opts)

    # 1. Basic successful request.
    log.info("--- Test 1: successful GET ---")
    with client.get("https://httpbin.org/get") as resp:
        data = json.loads(resp.read().decode())
        log.info("origin: %s", data.get("origin", "unknown"))

    # 2. Simulated retry via /status/503 (will exhaust attempts).
    log.info("--- Test 2: retryable 503 (expects failure after %d attempts) ---", opts.max_attempts)
    try:
        with client.get("https://httpbin.org/status/503"):
            pass
    except RuntimeError as exc:
        log.info("correctly raised: %s", exc)

    # 3. Paginator demo against httpbin's JSON endpoint (single-page).
    log.info("--- Test 3: paginator (single page, httpbin/json) ---")
    for page in paginate(
        client,
        url_factory=lambda _: "https://httpbin.org/json",
        page_key="slideshow",   # httpbin returns {"slideshow": {...}}
        cursor_key="next_cursor",
    ):
        log.info("page item count: %d", len(page) if isinstance(page, list) else 1)
        break  # httpbin/json isn't a real paginated API — just confirm no crash

    log.info("=== Demo complete ===")


if __name__ == "__main__":
    # Allow REGISTRY_TOKEN override for live testing against a real registry.
    token = os.getenv("REGISTRY_TOKEN")
    if token:
        log.info("REGISTRY_TOKEN set — would attach Authorization header in real usage")
    main()
