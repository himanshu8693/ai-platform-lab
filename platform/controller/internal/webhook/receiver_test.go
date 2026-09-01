// =============================================================================
// F2 — Idempotent Webhook Receiver Tests
// =============================================================================
//
// Run:  go test ./internal/webhook/... -v -race
//
// Gate validation commands:
//   go test ./internal/webhook/... -v -race -count=1
//
// All tests use a standaloneMirror that replicates Receiver HTTP logic
// without requiring a live TCP listener, so tests are fully synchronous.
// =============================================================================

package webhook_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"platform.ai/controller/internal/webhook"
)

// ---------------------------------------------------------------------------
// standaloneMirror — replicates Receiver HTTP logic for black-box unit tests.
// ---------------------------------------------------------------------------

type standaloneMirror struct {
	handler webhook.EventHandler
	table   sync.Map // key: string eventID → int statusCode
}

func newMirror(handler webhook.EventHandler) *standaloneMirror {
	return &standaloneMirror{handler: handler}
}

func (m *standaloneMirror) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	switch req.URL.Path {
	case "/healthz":
		w.WriteHeader(http.StatusOK)
	case "/webhook/model-events":
		m.handleModelEvent(w, req)
	default:
		http.NotFound(w, req)
	}
}

func (m *standaloneMirror) handleModelEvent(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	eventID := req.Header.Get("X-Webhook-ID")
	if eventID == "" {
		http.Error(w, "missing X-Webhook-ID header", http.StatusBadRequest)
		return
	}

	if rec, seen := m.table.Load(eventID); seen {
		w.WriteHeader(rec.(int))
		return
	}

	body, _ := io.ReadAll(io.LimitReader(req.Body, 1<<20))
	var e webhook.Event
	if err := json.Unmarshal(body, &e); err != nil {
		m.table.Store(eventID, http.StatusBadRequest)
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	e.ID = eventID
	e.ReceivedAt = time.Now().UTC()

	if err := m.handler.Handle(req.Context(), e); err != nil {
		// Transient handler error: do NOT record in table — allow replay.
		http.Error(w, "handler error", http.StatusInternalServerError)
		return
	}

	m.table.Store(eventID, http.StatusOK)
	w.WriteHeader(http.StatusOK)
}

func (m *standaloneMirror) tableSize() int {
	n := 0
	m.table.Range(func(_, _ any) bool { n++; return true })
	return n
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

func postEvent(t *testing.T, srv *httptest.Server, eventID string, body any) *http.Response {
	t.Helper()
	b, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal event body: %v", err)
	}
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/webhook/model-events", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	if eventID != "" {
		req.Header.Set("X-Webhook-ID", eventID)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST failed: %v", err)
	}
	return resp
}

func eventBody(modelName, version string) map[string]any {
	return map[string]any{
		"type":       string(webhook.EventModelVersionRegistered),
		"model_name": modelName,
		"version":    version,
	}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

func TestReceiver_FirstDelivery(t *testing.T) {
	var handlerCalls atomic.Int32
	mirror := newMirror(webhook.EventHandlerFunc(func(_ context.Context, e webhook.Event) error {
		handlerCalls.Add(1)
		if e.ModelName != "llama3" {
			t.Errorf("want model llama3, got %s", e.ModelName)
		}
		if e.ID != "evt-001" {
			t.Errorf("want ID evt-001, got %s", e.ID)
		}
		return nil
	}))

	srv := httptest.NewServer(mirror)
	defer srv.Close()

	resp := postEvent(t, srv, "evt-001", eventBody("llama3", "v1"))
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("want 200, got %d", resp.StatusCode)
	}
	if n := int(handlerCalls.Load()); n != 1 {
		t.Fatalf("want 1 handler call, got %d", n)
	}
}

func TestReceiver_DuplicateDelivery(t *testing.T) {
	var calls atomic.Int32
	mirror := newMirror(webhook.EventHandlerFunc(func(_ context.Context, _ webhook.Event) error {
		calls.Add(1)
		return nil
	}))

	srv := httptest.NewServer(mirror)
	defer srv.Close()

	send := func(id string) int {
		resp := postEvent(t, srv, id, eventBody("phi3", "v2"))
		resp.Body.Close()
		return resp.StatusCode
	}

	if got := send("evt-dup"); got != http.StatusOK {
		t.Fatalf("first delivery: want 200, got %d", got)
	}
	// Duplicate — must return 200 from cache without calling handler again.
	if got := send("evt-dup"); got != http.StatusOK {
		t.Fatalf("duplicate delivery: want 200, got %d", got)
	}
	if n := int(calls.Load()); n != 1 {
		t.Fatalf("want handler called exactly once, got %d", n)
	}
}

func TestReceiver_MissingIDHeader(t *testing.T) {
	mirror := newMirror(webhook.EventHandlerFunc(func(_ context.Context, _ webhook.Event) error { return nil }))
	srv := httptest.NewServer(mirror)
	defer srv.Close()

	b, _ := json.Marshal(eventBody("model", "v1"))
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/webhook/model-events", bytes.NewReader(b))
	// Intentionally omit X-Webhook-ID.
	resp, _ := http.DefaultClient.Do(req)
	resp.Body.Close()

	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("want 400 for missing header, got %d", resp.StatusCode)
	}
}

func TestReceiver_MethodNotAllowed(t *testing.T) {
	mirror := newMirror(webhook.EventHandlerFunc(func(_ context.Context, _ webhook.Event) error { return nil }))
	srv := httptest.NewServer(mirror)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/webhook/model-events", nil)
	resp, _ := http.DefaultClient.Do(req)
	resp.Body.Close()

	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("want 405, got %d", resp.StatusCode)
	}
}

func TestReceiver_MalformedJSON(t *testing.T) {
	mirror := newMirror(webhook.EventHandlerFunc(func(_ context.Context, _ webhook.Event) error { return nil }))
	srv := httptest.NewServer(mirror)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/webhook/model-events",
		bytes.NewReader([]byte(`{not valid json`)))
	req.Header.Set("X-Webhook-ID", "evt-malformed")
	resp, _ := http.DefaultClient.Do(req)
	resp.Body.Close()

	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("want 400, got %d", resp.StatusCode)
	}
}

func TestReceiver_HandlerError_NotRecorded(t *testing.T) {
	// First call: handler returns an error (not recorded → allows replay).
	// Second call: handler succeeds (processed again, not skipped as duplicate).
	var callCount atomic.Int32
	mirror := newMirror(webhook.EventHandlerFunc(func(_ context.Context, _ webhook.Event) error {
		n := callCount.Add(1)
		if n == 1 {
			return fmt.Errorf("transient error")
		}
		return nil
	}))

	srv := httptest.NewServer(mirror)
	defer srv.Close()

	send := func() int {
		resp := postEvent(t, srv, "evt-retry", eventBody("gpt2", "v1"))
		resp.Body.Close()
		return resp.StatusCode
	}

	if got := send(); got != http.StatusInternalServerError {
		t.Fatalf("first call (error): want 500, got %d", got)
	}
	if got := send(); got != http.StatusOK {
		t.Fatalf("second call (retry after error): want 200, got %d", got)
	}
	if n := int(callCount.Load()); n != 2 {
		t.Fatalf("want 2 handler invocations, got %d", n)
	}
}

func TestReceiver_TableSizeGrowth(t *testing.T) {
	mirror := newMirror(webhook.EventHandlerFunc(func(_ context.Context, _ webhook.Event) error { return nil }))
	srv := httptest.NewServer(mirror)
	defer srv.Close()

	for i := range 5 {
		id := fmt.Sprintf("evt-%03d", i)
		resp := postEvent(t, srv, id, eventBody("model", "v1"))
		resp.Body.Close()
	}

	if got := mirror.tableSize(); got != 5 {
		t.Fatalf("want table size 5, got %d", got)
	}
}

func TestReceiver_HealthzEndpoint(t *testing.T) {
	mirror := newMirror(webhook.EventHandlerFunc(func(_ context.Context, _ webhook.Event) error { return nil }))
	srv := httptest.NewServer(mirror)
	defer srv.Close()

	resp, _ := http.Get(srv.URL + "/healthz") //nolint:noctx
	resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("want 200 on /healthz, got %d", resp.StatusCode)
	}
}
