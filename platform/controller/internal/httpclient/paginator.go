// =============================================================================
// F1 — Cursor Paginator  (platform/controller/internal/httpclient)
// =============================================================================
//
// Generic cursor-based paginator for REST APIs that follow the pattern:
//
//   GET /v1/models?limit=100&after=<cursor>
//   Response: { "data": [...], "next_cursor": "tok_xyz" }
//
// Usage:
//
//   p := httpclient.NewPaginator[ModelRecord](client, func(cursor string) *http.Request {
//       u := "https://api.example.com/v1/models?limit=100"
//       if cursor != "" { u += "&after=" + cursor }
//       req, _ := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
//       return req
//   })
//
//   for p.Next(ctx) {
//       page := p.Page()   // []ModelRecord
//       for _, m := range page { process(m) }
//   }
//   if err := p.Err(); err != nil { ... }
//
// The paginator integrates with ResilientClient.Do() so every page fetch
// benefits from the same exponential-back-off / Retry-After handling.
// =============================================================================

package httpclient

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
)

// PagedResponse is the expected JSON envelope from paginated endpoints.
// T is the item type contained in the "data" array.
type PagedResponse[T any] struct {
	Data       []T    `json:"data"`
	NextCursor string `json:"next_cursor,omitempty"`

	// Alternate cursor field names used by some APIs.
	// Only one of the three is required to be non-empty.
	After   string `json:"after,omitempty"`
	Cursor  string `json:"cursor,omitempty"`
	HasMore bool   `json:"has_more,omitempty"`
}

// cursor returns the first non-empty cursor from the three possible fields.
func (pr PagedResponse[T]) cursor() string {
	if pr.NextCursor != "" {
		return pr.NextCursor
	}
	if pr.After != "" {
		return pr.After
	}
	return pr.Cursor
}

// RequestFactory builds an *http.Request for the given cursor value.
// An empty cursor string means "first page".
type RequestFactory[T any] func(cursor string) *http.Request

// Paginator iterates over all pages of a cursor-based REST endpoint.
type Paginator[T any] struct {
	client  *ResilientClient
	factory RequestFactory[T]
	cursor  string
	page    []T
	done    bool
	err     error
}

// NewPaginator constructs a Paginator. The factory is called once per page.
func NewPaginator[T any](client *ResilientClient, factory RequestFactory[T]) *Paginator[T] {
	return &Paginator[T]{
		client:  client,
		factory: factory,
	}
}

// Next fetches the next page. Returns false when there are no more pages or an
// error occurred. Call Err() after a false return to distinguish EOF from error.
func (p *Paginator[T]) Next(ctx context.Context) bool {
	if p.done {
		return false
	}

	req := p.factory(p.cursor)
	if req == nil {
		p.done = true
		return false
	}

	resp, err := p.client.Do(ctx, req)
	if err != nil {
		p.err = fmt.Errorf("paginator: fetch page (cursor=%q): %w", p.cursor, err)
		p.done = true
		return false
	}
	defer resp.Body.Close() //nolint:errcheck

	if resp.StatusCode != http.StatusOK {
		p.err = fmt.Errorf("paginator: unexpected status %d (cursor=%q)", resp.StatusCode, p.cursor)
		p.done = true
		return false
	}

	var envelope PagedResponse[T]
	if decErr := json.NewDecoder(resp.Body).Decode(&envelope); decErr != nil {
		p.err = fmt.Errorf("paginator: decode page: %w", decErr)
		p.done = true
		return false
	}

	p.page = envelope.Data

	nextCursor := envelope.cursor()
	if nextCursor == "" || !envelope.HasMore {
		// No further pages: return this page but signal termination on the next call.
		p.done = true
	} else {
		p.cursor = nextCursor
	}

	// An empty data slice on a non-error response is a terminal condition.
	if len(p.page) == 0 {
		p.done = true
		return false
	}

	return true
}

// Page returns the items fetched on the most recent successful call to Next.
// The slice is owned by the Paginator; copy elements if you need to retain them
// beyond the next Next() call.
func (p *Paginator[T]) Page() []T {
	return p.page
}

// Err returns any error that caused Next to return false.
// A nil error after Next() returns false means the full result set was consumed.
func (p *Paginator[T]) Err() error {
	return p.err
}
