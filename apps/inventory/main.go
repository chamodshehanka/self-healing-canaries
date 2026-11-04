// inventory serves stock levels. It already runs the v2 schema in every environment.
//
//	GET /v1/stock/{sku}  {"sku":"sku-7","available":45}                    (aggregated server-side)
//	GET /v2/stock/{sku}  {"sku":"sku-1","available":42}                    (single warehouse)
//	                     {"sku":"sku-7","warehouses":[{"id":"sin-1","available":20}, ...]}
//
// In v2, multi-warehouse SKUs return per-warehouse stock and omit top-level "available".
package main

import (
	"context"
	"encoding/json"
	"errors"
	"math/rand/v2"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

	"github.com/chamodshehanka/self-healing-canaries/apps/internal/telemetry"
)

type warehouse struct {
	ID        string `json:"id"`
	Available int    `json:"available"`
}

// catalog: sku-7, sku-8, sku-9 are stocked in several warehouses (30% of SKUs).
var catalog = map[string][]warehouse{
	"sku-0": {{"sin-1", 40}}, "sku-1": {{"sin-1", 42}}, "sku-2": {{"sin-1", 18}},
	"sku-3": {{"sin-1", 77}}, "sku-4": {{"sin-1", 63}}, "sku-5": {{"sin-1", 25}},
	"sku-6": {{"sin-1", 90}},
	"sku-7": {{"sin-1", 20}, {"nrt-1", 25}},
	"sku-8": {{"sin-1", 12}, {"iad-1", 30}},
	"sku-9": {{"sin-1", 5}, {"nrt-1", 8}, {"iad-1", 40}},
}

func total(ws []warehouse) int {
	n := 0
	for _, w := range ws {
		n += w.Available
	}
	return n
}

func jitter() { time.Sleep(time.Duration(3+rand.IntN(8)) * time.Millisecond) }

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	logger, shutdown := telemetry.Init(ctx, "inventory")
	defer shutdown()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/stock/{sku}", func(w http.ResponseWriter, r *http.Request) {
		jitter()
		ws, ok := catalog[r.PathValue("sku")]
		if !ok {
			http.NotFound(w, r)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"sku": r.PathValue("sku"), "available": total(ws)})
	})
	mux.HandleFunc("GET /v2/stock/{sku}", func(w http.ResponseWriter, r *http.Request) {
		jitter()
		ws, ok := catalog[r.PathValue("sku")]
		if !ok {
			http.NotFound(w, r)
			return
		}
		if len(ws) == 1 {
			_ = json.NewEncoder(w).Encode(map[string]any{"sku": r.PathValue("sku"), "available": ws[0].Available})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"sku": r.PathValue("sku"), "warehouses": ws})
	})
	mux.Handle("GET /metrics", promhttp.Handler())
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })

	srv := &http.Server{Addr: telemetry.Env("ADDR", ":8080"), Handler: otelhttp.NewHandler(mux, "inventory",
		otelhttp.WithFilter(func(r *http.Request) bool { return r.URL.Path != "/metrics" && r.URL.Path != "/healthz" })),
		ReadHeaderTimeout: 5 * time.Second}
	go func() {
		<-ctx.Done()
		_ = srv.Shutdown(context.Background())
	}()
	logger.Info("inventory starting", "addr", srv.Addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("server", "err", err)
		os.Exit(1)
	}
}
