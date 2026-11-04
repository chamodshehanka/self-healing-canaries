// payment is the checkout API the canary is about.
//
//	POST /pay {"sku":"sku-3","qty":1,"amount":12.5,"currency":"USD"}
//
// The edge (Envoy Gateway) sets X-Region. Region and currency are business
// attributes on logs and spans only — never metric labels.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"

	"github.com/chamodshehanka/self-healing-canaries/apps/internal/telemetry"
)

type payRequest struct {
	SKU      string  `json:"sku"`
	Qty      int     `json:"qty"`
	Amount   float64 `json:"amount"`
	Currency string  `json:"currency"`
}

type server struct {
	log *slog.Logger
	inv *inventoryClient
}

func (s *server) pay(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	span := trace.SpanFromContext(ctx)

	var req payRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.SKU == "" || req.Qty <= 0 {
		http.Error(w, `{"error":"bad request"}`, http.StatusBadRequest)
		return
	}
	region := r.Header.Get("X-Region")
	span.SetAttributes(
		attribute.String("checkout.region", region),
		attribute.String("checkout.currency", req.Currency),
		attribute.String("checkout.sku", req.SKU),
	)

	available, err := s.inv.Available(ctx, req.SKU)
	if err != nil {
		s.fail(ctx, w, "inventory_lookup_failed", err, req, region)
		return
	}
	if available < req.Qty {
		http.Error(w, `{"error":"out of stock"}`, http.StatusConflict)
		return
	}

	charge, err := charge(ctx, req.Amount, req.Currency)
	if err != nil {
		s.fail(ctx, w, "charge_failed", err, req, region)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"status": "approved", "charge": charge})
}

// fail records the error on the span and as a structured log, then returns 500.
func (s *server) fail(ctx context.Context, w http.ResponseWriter, kind string, err error, req payRequest, region string) {
	span := trace.SpanFromContext(ctx)
	span.RecordError(err)
	span.SetStatus(codes.Error, err.Error())
	s.log.ErrorContext(ctx, err.Error(),
		"error.type", kind,
		"checkout.region", region,
		"checkout.currency", req.Currency,
		"checkout.sku", req.SKU,
		"checkout.amount", req.Amount,
	)
	http.Error(w, `{"error":"`+kind+`"}`, http.StatusInternalServerError)
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	logger, shutdown := telemetry.Init(ctx, "payment")
	defer shutdown()

	s := &server{
		log: logger,
		inv: newInventoryClient(telemetry.Env("INVENTORY_URL", "http://inventory:8080")),
	}

	mux := http.NewServeMux()
	mux.Handle("POST /pay", otelhttp.WithRouteTag("/pay", http.HandlerFunc(s.pay)))
	mux.Handle("GET /metrics", promhttp.Handler())
	// Liveness/readiness: "is the process up?" — green through every gray failure in this demo.
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })

	srv := &http.Server{
		Addr: telemetry.Env("ADDR", ":8080"),
		Handler: otelhttp.NewHandler(mux, "payment",
			otelhttp.WithFilter(func(r *http.Request) bool { return r.URL.Path == "/pay" })),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(sctx)
	}()

	logger.Info("payment starting", "addr", srv.Addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("server", "err", err)
		os.Exit(1)
	}
}
