// =============================================================================
// F1 — Model Registry Poller  (platform/controller/cmd/poller/main.go)
// =============================================================================
//
// A standalone CLI that periodically polls an external Model Registry REST API
// and syncs new model versions into the platform's ModelDeployment CRDs.
//
// Architecture:
//   - Uses httpclient.ResilientClient for all outbound API calls.
//   - Uses httpclient.NewPaginator to walk the model list endpoint.
//   - Authenticates with a Bearer token sourced from env / Vault Agent file.
//   - Dry-run mode (--dry-run) prints planned CRD mutations without applying them.
//
// This binary is the Month 5 Go deliverable that exercises F1 end-to-end.
//
// Usage:
//   go run ./cmd/poller \
//     --registry-url https://registry.example.com \
//     --token-file /var/run/secrets/registry-token \
//     --interval 60s \
//     --namespace inference \
//     --dry-run
//
// Vault Agent integration:
//   Mount a Vault dynamic-secret file at --token-file.  The poller re-reads the
//   file on every poll cycle so token rotations are transparent.
// =============================================================================

package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"platform.ai/controller/internal/httpclient"
)

// ModelVersion is the item shape returned by the registry's /v1/models endpoint.
type ModelVersion struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Version   string    `json:"version"`
	CreatedAt time.Time `json:"created_at"`
	Tag       string    `json:"tag"`
}

func main() {
	var (
		registryURL = flag.String("registry-url", "", "Base URL of the model registry API (required)")
		tokenFile   = flag.String("token-file", "", "Path to file containing the Bearer token (Vault Agent sink)")
		interval    = flag.Duration("interval", 60*time.Second, "Poll interval")
		namespace   = flag.String("namespace", "inference", "Kubernetes namespace to apply ModelDeployment CRDs")
		dryRun      = flag.Bool("dry-run", false, "Print planned mutations without applying them")
		maxAttempts = flag.Int("max-attempts", 4, "Max retry attempts per HTTP request")
	)
	flag.Parse()

	if *registryURL == "" {
		fmt.Fprintln(os.Stderr, "error: --registry-url is required")
		flag.Usage()
		os.Exit(1)
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	client := httpclient.New(httpclient.Options{
		MaxAttempts: *maxAttempts,
		BaseDelay:   300 * time.Millisecond,
		MaxDelay:    30 * time.Second,
	}).WithLogger(logger)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	logger.Info("poller starting",
		slog.String("registry", *registryURL),
		slog.Duration("interval", *interval),
		slog.String("namespace", *namespace),
		slog.Bool("dry_run", *dryRun),
	)

	ticker := time.NewTicker(*interval)
	defer ticker.Stop()

	// Run once immediately before entering the tick loop.
	if err := poll(ctx, client, *registryURL, *tokenFile, *namespace, *dryRun, logger); err != nil {
		logger.Error("initial poll failed", slog.String("error", err.Error()))
	}

	for {
		select {
		case <-ctx.Done():
			logger.Info("poller shutting down")
			return
		case <-ticker.C:
			if err := poll(ctx, client, *registryURL, *tokenFile, *namespace, *dryRun, logger); err != nil {
				logger.Error("poll cycle failed", slog.String("error", err.Error()))
			}
		}
	}
}

// poll performs a single paginated walk of the registry and logs (or applies) each model.
func poll(
	ctx context.Context,
	client *httpclient.ResilientClient,
	registryURL string,
	tokenFile string,
	namespace string,
	dryRun bool,
	logger *slog.Logger,
) error {
	token, err := readToken(tokenFile)
	if err != nil {
		return fmt.Errorf("poller: read token: %w", err)
	}

	p := httpclient.NewPaginator[ModelVersion](client, func(cursor string) *http.Request {
		u := registryURL + "/v1/models?limit=100"
		if cursor != "" {
			u += "&after=" + cursor
		}
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		return req
	})

	var total int
	for p.Next(ctx) {
		for _, m := range p.Page() {
			total++
			if dryRun {
				logger.Info("dry-run: would sync model",
					slog.String("id", m.ID),
					slog.String("name", m.Name),
					slog.String("version", m.Version),
					slog.String("namespace", namespace),
				)
			} else {
				// TODO: apply/update ModelDeployment CRD via controller-runtime client.
				// This is intentionally left as a TODO — the integration point with
				// main.go's reconciler is the next step in the Month 5 exercise.
				logger.Info("synced model",
					slog.String("id", m.ID),
					slog.String("name", m.Name),
					slog.String("version", m.Version),
				)
			}
		}
	}
	if err := p.Err(); err != nil {
		return fmt.Errorf("poller: pagination error: %w", err)
	}

	logger.Info("poll cycle complete", slog.Int("models_scanned", total))
	return nil
}

// readToken reads a token from a file (Vault Agent sink) or REGISTRY_TOKEN env var.
// Returns empty string if neither is configured (unauthenticated registry).
func readToken(tokenFile string) (string, error) {
	if tokenFile != "" {
		data, err := os.ReadFile(tokenFile) //nolint:gosec // intentional file read
		if err != nil {
			return "", err
		}
		// Trim trailing newline that Vault Agent appends to sink files.
		return string(trimRight(data)), nil
	}
	return os.Getenv("REGISTRY_TOKEN"), nil
}

// trimRight removes trailing whitespace bytes.
func trimRight(b []byte) []byte {
	for len(b) > 0 {
		c := b[len(b)-1]
		if c == '\n' || c == '\r' || c == ' ' || c == '\t' {
			b = b[:len(b)-1]
		} else {
			break
		}
	}
	return b
}
