package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/michaeljohnwatters/kickstand/internal/db"
)

func TestReadyz_ReflectsDBHealth(t *testing.T) {
	ctx := context.Background()
	d, err := db.Open(t.TempDir() + "/r.db")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	s := &Server{DB: d}

	rec := httptest.NewRecorder()
	s.handleReadyz(rec, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("ready DB: status = %d, want 200", rec.Code)
	}

	// With the DB closed, readiness must flip to 503 (liveness /healthz would
	// still be 200 — that's the point of the distinction).
	d.Close()
	rec = httptest.NewRecorder()
	s.handleReadyz(rec, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("down DB: status = %d, want 503", rec.Code)
	}
}

func TestMetrics_CountsAndRenders(t *testing.T) {
	before := httpMetrics.r4xx.Load()

	// withMetrics should count a 404 as a 4xx.
	h := withMetrics(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/x", nil))
	if got := httpMetrics.r4xx.Load(); got != before+1 {
		t.Errorf("4xx counter = %d, want %d", got, before+1)
	}

	// /metrics renders Prometheus text with the expected series.
	rec := httptest.NewRecorder()
	handleMetrics(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body := rec.Body.String()
	for _, want := range []string{
		"kickstand_http_requests_total",
		`kickstand_http_responses_total{class="4xx"}`,
		"kickstand_handler_panics_total",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("/metrics missing %q", want)
		}
	}
}
