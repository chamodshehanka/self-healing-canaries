// Package telemetry wires OpenTelemetry traces, metrics and logs for the demo services.
//
// Note what is NOT here: no build_id, no git SHA, no image tag. The app does not know
// which build it is. Identity is attached by the platform, outside the app:
//   - Prometheus relabels the pod's rollouts-pod-template-hash label onto every series.
//   - The OTel Collector's k8sattributes processor stamps it onto every log and span.
//
// One ReplicaSet = one pod-template-hash = one image. That is the only identity
// dimension, and it disappears when the ReplicaSet is scaled away.
package telemetry

import (
	"context"
	"log/slog"
	"os"
	"time"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/exporters/prometheus"
	"go.opentelemetry.io/otel/propagation"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// Init configures global OTel providers and returns a logger that writes to both
// stdout (for kubectl logs) and OTLP (for Loki), plus a shutdown func.
func Init(ctx context.Context, service string) (*slog.Logger, func()) {
	endpoint := Env("OTEL_EXPORTER_OTLP_ENDPOINT", "otel-collector.observability:4317")

	res, _ := resource.Merge(resource.Default(), resource.NewWithAttributes(
		semconv.SchemaURL,
		semconv.ServiceName(service),
	))

	traceExp, err := otlptracegrpc.New(ctx, otlptracegrpc.WithEndpoint(endpoint), otlptracegrpc.WithInsecure())
	if err != nil {
		slog.Error("trace exporter", "err", err)
		os.Exit(1)
	}
	tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(traceExp), sdktrace.WithResource(res))
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{}))

	// Metrics are pulled by Prometheus from /metrics. The scrape config adds pod,
	// namespace and rollouts_pod_template_hash labels; the app adds none.
	promExp, err := prometheus.New(prometheus.WithoutScopeInfo())
	if err != nil {
		slog.Error("prometheus exporter", "err", err)
		os.Exit(1)
	}
	mp := sdkmetric.NewMeterProvider(sdkmetric.WithReader(promExp), sdkmetric.WithResource(res))
	otel.SetMeterProvider(mp)

	logExp, err := otlploggrpc.New(ctx, otlploggrpc.WithEndpoint(endpoint), otlploggrpc.WithInsecure())
	if err != nil {
		slog.Error("log exporter", "err", err)
		os.Exit(1)
	}
	lp := sdklog.NewLoggerProvider(sdklog.WithProcessor(sdklog.NewBatchProcessor(logExp)), sdklog.WithResource(res))

	logger := slog.New(fanout{
		slog.NewJSONHandler(os.Stdout, nil),
		otelslog.NewHandler(service, otelslog.WithLoggerProvider(lp)),
	})

	return logger, func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = tp.Shutdown(ctx)
		_ = mp.Shutdown(ctx)
		_ = lp.Shutdown(ctx)
	}
}

// Env returns the value of key, or fallback if unset.
func Env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// fanout sends each record to every handler.
type fanout []slog.Handler

func (f fanout) Enabled(ctx context.Context, l slog.Level) bool {
	for _, h := range f {
		if h.Enabled(ctx, l) {
			return true
		}
	}
	return false
}

func (f fanout) Handle(ctx context.Context, r slog.Record) error {
	for _, h := range f {
		if h.Enabled(ctx, r.Level) {
			_ = h.Handle(ctx, r.Clone())
		}
	}
	return nil
}

func (f fanout) WithAttrs(attrs []slog.Attr) slog.Handler {
	out := make(fanout, len(f))
	for i, h := range f {
		out[i] = h.WithAttrs(attrs)
	}
	return out
}

func (f fanout) WithGroup(name string) slog.Handler {
	out := make(fanout, len(f))
	for i, h := range f {
		out[i] = h.WithGroup(name)
	}
	return out
}
