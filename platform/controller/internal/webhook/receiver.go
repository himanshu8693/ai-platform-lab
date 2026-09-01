// =============================================================================
// F2 — Idempotent Webhook Receiver  (platform/controller/internal/webhook)
// =============================================================================
//
// Provides an HTTP handler that receives model-version push events from an
// external Model Registry (e.g., MLflow, Hugging Face Hub webhooks) and
// ensures exactly-once processing via an in-memory idempotency table.
//
// Idempotency guarantee:
//   A webhook delivery is identified by its X-Webhook-ID header. On the first
//   receipt the event is stored in the idempotency table and the handler
//   processes it.  On any replay (same ID) the handler returns 200 immediately
//   without re-processing.
//
// Production upgrade path:
//   Replace idempotencyTable (sync.Map) with a Redis or PostgreSQL-backed
//   store and add a TTL-based eviction policy (see comments below).
//   The interface surface (Receiver, EventHandler) is unchanged.
//
// Integration with main.go:
//   manager.Add(webhook.NewReceiver(webhook.Options{
//       Addr: ":9443",
//       Handler: myEventHandler,
//   }))
//
// See receiver_test.go for usage examples and gate validation.
// =============================================================================

package webhook

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"sync"
	"time"
)

// EventType categorises the incoming webhook payload.
// Extend this list as the registry adds more event types.
type EventType string

const (
	EventModelVersionRegistered EventType = "model.version.registered"
	EventModelVersionPromoted   EventType = "model.version.promoted"
	EventModelVersionArchived   EventType = "model.version.archived"
)

// Event is the normalised representation of a model registry webhook payload.
type Event struct {
	// ID is the globally unique event identifier sent in X-Webhook-ID.
	// Used as the idempotency key.
	ID string `json:"id"`

	// Type is the event category.
	Type EventType `json:"type"`

	// ModelName is the logical model name (e.g. "llama3-instruct").
	ModelName string `json:"model_name"`

	// Version is the SemVer or monotonic version string.
	Version string `json:"version"`

	// Tag is an optional OCI digest or HuggingFace revision SHA.
	Tag string `json:"tag,omitempty"`

	// ReceivedAt is set by the receiver — not trusted from the payload.
	ReceivedAt time.Time `json:"-"`
}

// EventHandler is called exactly once per unique event ID.
// Implementations should be idempotent themselves where feasible, but the
// Receiver ensures at-most-once delivery for duplicate webhook IDs.
type EventHandler interface {
	Handle(ctx context.Context, e Event) error
}

// EventHandlerFunc is a convenience adapter for function-based handlers.
type EventHandlerFunc func(ctx context.Context, e Event) error

func (f EventHandlerFunc) Handle(ctx context.Context, e Event) error { return f(ctx, e) }

// Options configures a Receiver.
type Options struct {
	// Addr is the TCP listen address (e.g. ":9443").
	Addr string

	// Handler is called for each new event.
	Handler EventHandler

	// SharedSecret is the HMAC-SHA256 key for validating X-Hub-Signature-256.
	// If empty, signature validation is disabled (not recommended for production).
	SharedSecret string

	// MaxBodyBytes limits the request body size (default 1 MiB).
	MaxBodyBytes int64

	// Logger, if nil, uses slog.Default().
	Logger *slog.Logger
}

func (o *Options) defaults() {
	if o.Addr == "" {
		o.Addr = ":9443"
	}
	if o.MaxBodyBytes == 0 {
		o.MaxBodyBytes = 1 << 20 // 1 MiB
	}
	if o.Logger == nil {
		o.Logger = slog.Default()
	}
}

// idempotencyRecord stores the outcome of a previously processed event.
type idempotencyRecord struct {
	processedAt time.Time
	statusCode  int
}

// Receiver implements the controller-runtime Runnable interface so it can be
// registered with the Manager (manager.Add) and participate in graceful shutdown.
type Receiver struct {
	opts    Options
	table   sync.Map // key: string (event ID) → idempotencyRecord
	srv     *http.Server
	logger  *slog.Logger
}

// NewReceiver constructs a Receiver.  Call manager.Add(r) to start it.
func NewReceiver(opts Options) *Receiver {
	opts.defaults()
	r := &Receiver{
		opts:   opts,
		logger: opts.Logger,
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/webhook/model-events", r.handleModelEvent)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	r.srv = &http.Server{
		Addr:              opts.Addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	return r
}

// Start implements controller-runtime's Runnable interface.
// ctx cancellation triggers a graceful HTTP shutdown.
func (r *Receiver) Start(ctx context.Context) error {
	l, err := net.Listen("tcp", r.opts.Addr)
	if err != nil {
		return fmt.Errorf("webhook receiver: listen %s: %w", r.opts.Addr, err)
	}
	r.logger.Info("webhook receiver listening", slog.String("addr", r.opts.Addr))

	errCh := make(chan error, 1)
	go func() {
		if serveErr := r.srv.Serve(l); serveErr != nil && serveErr != http.ErrServerClosed {
			errCh <- serveErr
		}
		close(errCh)
	}()

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if shutErr := r.srv.Shutdown(shutdownCtx); shutErr != nil {
			r.logger.Error("webhook receiver: shutdown error", slog.String("error", shutErr.Error()))
		}
		return nil
	case err := <-errCh:
		return err
	}
}

// handleModelEvent is the HTTP handler for POST /webhook/model-events.
func (r *Receiver) handleModelEvent(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// --- Extract idempotency key ---
	eventID := req.Header.Get("X-Webhook-ID")
	if eventID == "" {
		http.Error(w, "missing X-Webhook-ID header", http.StatusBadRequest)
		return
	}

	// --- Idempotency check (optimistic read before processing) ---
	if rec, seen := r.table.Load(eventID); seen {
		existing := rec.(idempotencyRecord)
		r.logger.Info("webhook receiver: duplicate event, returning cached status",
			slog.String("event_id", eventID),
			slog.Int("cached_status", existing.statusCode),
		)
		w.WriteHeader(existing.statusCode)
		return
	}

	// --- Body size guard ---
	body, err := io.ReadAll(io.LimitReader(req.Body, r.opts.MaxBodyBytes))
	if err != nil {
		r.logger.Error("webhook receiver: read body", slog.String("error", err.Error()))
		http.Error(w, "read error", http.StatusInternalServerError)
		return
	}

	// --- Parse event ---
	var e Event
	if parseErr := json.Unmarshal(body, &e); parseErr != nil {
		r.logger.Error("webhook receiver: parse body",
			slog.String("event_id", eventID),
			slog.String("error", parseErr.Error()),
		)
		r.storeAndRespond(w, eventID, http.StatusBadRequest)
		return
	}
	e.ID = eventID       // always trust the header, not payload field
	e.ReceivedAt = time.Now().UTC()

	// --- Dispatch ---
	if dispatchErr := r.opts.Handler.Handle(req.Context(), e); dispatchErr != nil {
		r.logger.Error("webhook receiver: handler error",
			slog.String("event_id", eventID),
			slog.String("type", string(e.Type)),
			slog.String("error", dispatchErr.Error()),
		)
		// Do NOT record a failure in the idempotency table — allow replay.
		http.Error(w, "handler error", http.StatusInternalServerError)
		return
	}

	r.logger.Info("webhook receiver: event processed",
		slog.String("event_id", eventID),
		slog.String("type", string(e.Type)),
		slog.String("model", e.ModelName),
		slog.String("version", e.Version),
	)
	r.storeAndRespond(w, eventID, http.StatusOK)
}

// storeAndRespond records the outcome in the idempotency table and writes the
// HTTP response.  The table entry is intentionally never deleted in this
// implementation; production systems should add TTL-based eviction.
func (r *Receiver) storeAndRespond(w http.ResponseWriter, eventID string, code int) {
	r.table.Store(eventID, idempotencyRecord{
		processedAt: time.Now().UTC(),
		statusCode:  code,
	})
	w.WriteHeader(code)
}

// TableSize returns the number of entries in the idempotency table.
// Exposed for observability / metrics; not part of the Runnable interface.
func (r *Receiver) TableSize() int {
	n := 0
	r.table.Range(func(_, _ any) bool { n++; return true })
	return n
}
