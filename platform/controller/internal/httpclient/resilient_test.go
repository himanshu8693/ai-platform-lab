// =============================================================================
// F1 — Resilient HTTP Client Tests
// =============================================================================
//
// Run:  go test ./internal/httpclient/... -v -race
//
// Coverage targets:
//   TestResilientClient_Success              — 200 on first attempt
//   TestResilientClient_RetryOnce            — 503 then 200
//   TestResilientClient_ExhaustAttempts      — all attempts return 503
//   TestResilientClient_ContextCancelled     — context cancelled mid-retry
//   TestResilientClient_RetryAfterHeader     — 429 with Retry-After honoured
//   TestResilientClient_NonRetryable         — 400 not retried
//   TestPaginator_SinglePage                 — one page, no next_cursor
//   TestPaginator_MultiPage                  — two pages, cursor threading
//   TestPaginator_ErrorOnFetch              — network error on page 2
// =============================================================================

package httpclient_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"platform.ai/controller/internal/httpclient"
)

// -------------------------------------------------------------------------
// helpers
// -------------------------------------------------------------------------

func newServer(handler http.HandlerFunc) (*httptest.Server, func()) {
	srv := httptest.NewServer(handler)
	return srv, srv.Close
}

func fastOpts(maxAttempts int) httpclient.Options {
	return httpclient.Options{
		MaxAttempts: maxAttempts,
		BaseDelay:   1 * time.Millisecond,
		MaxDelay:    5 * time.Millisecond,
	}
}

// -------------------------------------------------------------------------
// ResilientClient tests
// -------------------------------------------------------------------------

func TestResilientClient_Success(t *testing.T) {
	srv, close := newServer(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	defer close()

	c := httpclient.New(fastOpts(3))
	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)

	resp, err := c.Do(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("want 200, got %d", resp.StatusCode)
	}
}

func TestResilientClient_RetryOnce(t *testing.T) {
	var calls atomic.Int32
	srv, close := newServer(func(w http.ResponseWriter, _ *http.Request) {
		n := calls.Add(1)
		if n == 1 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	defer close()

	c := httpclient.New(fastOpts(3))
	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)

	resp, err := c.Do(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	defer resp.Body.Close()

	if got := int(calls.Load()); got != 2 {
		t.Fatalf("want 2 calls, got %d", got)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("want 200, got %d", resp.StatusCode)
	}
}

func TestResilientClient_ExhaustAttempts(t *testing.T) {
	var calls atomic.Int32
	srv, close := newServer(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusServiceUnavailable)
	})
	defer close()

	const maxAttempts = 3
	c := httpclient.New(fastOpts(maxAttempts))
	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)

	_, err := c.Do(context.Background(), req)
	if err == nil {
		t.Fatal("expected error after exhausted attempts")
	}
	if got := int(calls.Load()); got != maxAttempts {
		t.Fatalf("want %d calls, got %d", maxAttempts, got)
	}
}

func TestResilientClient_ContextCancelled(t *testing.T) {
	srv, close := newServer(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable) // always retryable
	})
	defer close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()

	c := httpclient.New(httpclient.Options{
		MaxAttempts: 10,
		BaseDelay:   50 * time.Millisecond, // longer than context deadline
		MaxDelay:    200 * time.Millisecond,
	})
	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)

	_, err := c.Do(ctx, req)
	if err == nil {
		t.Fatal("expected context cancellation error")
	}
}

func TestResilientClient_RetryAfterHeader(t *testing.T) {
	var calls atomic.Int32
	srv, close := newServer(func(w http.ResponseWriter, _ *http.Request) {
		n := calls.Add(1)
		if n == 1 {
			w.Header().Set("Retry-After", "0") // 0 seconds → no additional wait
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	defer close()

	c := httpclient.New(fastOpts(3))
	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)

	resp, err := c.Do(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	defer resp.Body.Close()

	if got := int(calls.Load()); got != 2 {
		t.Fatalf("want 2 calls, got %d", got)
	}
}

func TestResilientClient_NonRetryable(t *testing.T) {
	var calls atomic.Int32
	srv, close := newServer(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusBadRequest)
	})
	defer close()

	c := httpclient.New(fastOpts(3))
	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)

	resp, err := c.Do(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	defer resp.Body.Close()

	// Must not retry a 400.
	if got := int(calls.Load()); got != 1 {
		t.Fatalf("want 1 call (no retry), got %d", got)
	}
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("want 400, got %d", resp.StatusCode)
	}
}

// -------------------------------------------------------------------------
// Paginator tests
// -------------------------------------------------------------------------

type testItem struct {
	ID string `json:"id"`
}

func TestPaginator_SinglePage(t *testing.T) {
	srv, close := newServer(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(httpclient.PagedResponse[testItem]{
			Data: []testItem{{ID: "a"}, {ID: "b"}},
			// no next_cursor → single page
		})
	})
	defer close()

	client := httpclient.New(fastOpts(3))
	p := httpclient.NewPaginator[testItem](client, func(cursor string) *http.Request {
		req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
		return req
	})

	var items []testItem
	for p.Next(context.Background()) {
		items = append(items, p.Page()...)
	}
	if err := p.Err(); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(items) != 2 {
		t.Fatalf("want 2 items, got %d", len(items))
	}
}

func TestPaginator_MultiPage(t *testing.T) {
	var pageNum atomic.Int32
	srv, close := newServer(func(w http.ResponseWriter, r *http.Request) {
		n := pageNum.Add(1)
		w.Header().Set("Content-Type", "application/json")
		if n == 1 {
			_ = json.NewEncoder(w).Encode(httpclient.PagedResponse[testItem]{
				Data:       []testItem{{ID: "p1-a"}},
				NextCursor: "page2",
				HasMore:    true,
			})
		} else {
			_ = json.NewEncoder(w).Encode(httpclient.PagedResponse[testItem]{
				Data: []testItem{{ID: "p2-a"}, {ID: "p2-b"}},
				// no next_cursor
			})
		}
	})
	defer close()

	client := httpclient.New(fastOpts(3))
	p := httpclient.NewPaginator[testItem](client, func(cursor string) *http.Request {
		u := srv.URL
		if cursor != "" {
			u += "?after=" + cursor
		}
		req, _ := http.NewRequest(http.MethodGet, u, nil)
		return req
	})

	var items []testItem
	for p.Next(context.Background()) {
		items = append(items, p.Page()...)
	}
	if err := p.Err(); err != nil {
		t.Fatalf("unexpected paginator error: %v", err)
	}
	if len(items) != 3 {
		t.Fatalf("want 3 items across 2 pages, got %d", len(items))
	}
}

func TestPaginator_ErrorOnFetch(t *testing.T) {
	var pageNum atomic.Int32
	srv, close := newServer(func(w http.ResponseWriter, _ *http.Request) {
		n := pageNum.Add(1)
		w.Header().Set("Content-Type", "application/json")
		if n == 1 {
			_ = json.NewEncoder(w).Encode(httpclient.PagedResponse[testItem]{
				Data:       []testItem{{ID: "p1-a"}},
				NextCursor: "page2",
				HasMore:    true,
			})
		} else {
			w.WriteHeader(http.StatusServiceUnavailable)
		}
	})
	defer close()

	// MaxAttempts=1 so the paginator immediately fails on the 503 without retry.
	client := httpclient.New(httpclient.Options{
		MaxAttempts: 1,
		BaseDelay:   1 * time.Millisecond,
	})
	p := httpclient.NewPaginator[testItem](client, func(cursor string) *http.Request {
		u := srv.URL
		if cursor != "" {
			u += "?after=" + cursor
		}
		req, _ := http.NewRequest(http.MethodGet, u, nil)
		return req
	})

	pageCount := 0
	for p.Next(context.Background()) {
		pageCount++
	}
	if p.Err() == nil {
		t.Fatal("expected error after 503 on page 2")
	}
	if pageCount != 1 {
		t.Fatalf("want 1 successful page before error, got %d", pageCount)
	}
}
