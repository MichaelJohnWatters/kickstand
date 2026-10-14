package httpapi

import (
	"context"
	"fmt"
	"net/http"
	"sync/atomic"
	"time"
)

// Observability surface, all dependency-free:
//   - GET /healthz — liveness (process is up).
//   - GET /readyz  — readiness (can serve traffic: DB reachable).
//   - GET /metrics — minimal Prometheus-text request counters.
//   - ErrorReporter — optional panic-alert hook (wired from ERROR_WEBHOOK).

// httpMetrics holds process-wide request counters. Atomic so the metrics
// middleware can update them without locking.
var httpMetrics struct {
	total  atomic.Int64
	r2xx   atomic.Int64
	r3xx   atomic.Int64
	r4xx   atomic.Int64
	r5xx   atomic.Int64
	panics atomic.Int64
}

// ErrorReporter, when set, is invoked (best-effort, async) with a short
// description whenever a handler panics. Lets a deployment wire a crash alert
// (Slack/Discord/collector) without a hard Sentry dependency. Set in main from
// ERROR_WEBHOOK; nil = no-op.
var ErrorReporter func(detail string)

// withMetrics counts responses by status class for /metrics. Uses its own
// statusRecorder so it sees the final status regardless of the inner chain.
func withMetrics(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(rec, r)
		httpMetrics.total.Add(1)
		switch {
		case rec.status >= 500:
			httpMetrics.r5xx.Add(1)
		case rec.status >= 400:
			httpMetrics.r4xx.Add(1)
		case rec.status >= 300:
			httpMetrics.r3xx.Add(1)
		default:
			httpMetrics.r2xx.Add(1)
		}
	})
}

// handleReadyz reports whether the server can actually serve traffic — i.e.
// the database answers. Liveness (/healthz) says "the process is up"; a load
// balancer or uptime check should gate on /readyz.
func (s *Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if s.DB == nil || s.DB.PingContext(ctx) != nil {
		writeError(w, http.StatusServiceUnavailable, "not_ready", "database unreachable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ready": true})
}

// handleMetrics emits a tiny Prometheus-text exposition — no client library.
// Aggregate counts only (no PII); firewall it off if you don't want request
// volume public.
func handleMetrics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	fmt.Fprintf(w, "# HELP kickstand_http_requests_total Total HTTP requests handled.\n")
	fmt.Fprintf(w, "# TYPE kickstand_http_requests_total counter\n")
	fmt.Fprintf(w, "kickstand_http_requests_total %d\n", httpMetrics.total.Load())
	fmt.Fprintf(w, "# HELP kickstand_http_responses_total HTTP responses by status class.\n")
	fmt.Fprintf(w, "# TYPE kickstand_http_responses_total counter\n")
	fmt.Fprintf(w, "kickstand_http_responses_total{class=\"2xx\"} %d\n", httpMetrics.r2xx.Load())
	fmt.Fprintf(w, "kickstand_http_responses_total{class=\"3xx\"} %d\n", httpMetrics.r3xx.Load())
	fmt.Fprintf(w, "kickstand_http_responses_total{class=\"4xx\"} %d\n", httpMetrics.r4xx.Load())
	fmt.Fprintf(w, "kickstand_http_responses_total{class=\"5xx\"} %d\n", httpMetrics.r5xx.Load())
	fmt.Fprintf(w, "# HELP kickstand_handler_panics_total Handler panics recovered.\n")
	fmt.Fprintf(w, "# TYPE kickstand_handler_panics_total counter\n")
	fmt.Fprintf(w, "kickstand_handler_panics_total %d\n", httpMetrics.panics.Load())
}
