package httpapi

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestIPRateLimiter_BurstThenRefill(t *testing.T) {
	now := time.Unix(0, 0)
	l := newIPRateLimiter(60, 2) // 60/min = 1 token/sec, burst 2
	l.now = func() time.Time { return now }

	// Burst of 2 allowed, 3rd denied (same IP).
	if !l.allow("1.2.3.4") || !l.allow("1.2.3.4") {
		t.Fatal("first two requests should be allowed (burst=2)")
	}
	if l.allow("1.2.3.4") {
		t.Fatal("third request should be denied (burst exhausted)")
	}

	// A different IP has its own bucket.
	if !l.allow("5.6.7.8") {
		t.Fatal("a different IP should not be throttled by the first IP")
	}

	// After 1 second, one token refills (rate 1/sec).
	now = now.Add(time.Second)
	if !l.allow("1.2.3.4") {
		t.Fatal("after 1s one token should have refilled")
	}
	if l.allow("1.2.3.4") {
		t.Fatal("only one token should have refilled, not two")
	}
}

func TestIPRateLimiter_Middleware429(t *testing.T) {
	l := newIPRateLimiter(60, 1) // burst 1
	var reached int
	h := l.middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reached++
		w.WriteHeader(http.StatusOK)
	}))

	call := func() *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/auth/firebase-signup", nil)
		req.RemoteAddr = "9.9.9.9:1234"
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec
	}

	if rec := call(); rec.Code != http.StatusOK {
		t.Fatalf("first request status = %d, want 200", rec.Code)
	}
	rec := call()
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("second request status = %d, want 429", rec.Code)
	}
	if rec.Header().Get("Retry-After") == "" {
		t.Error("expected a Retry-After header on 429")
	}
	if reached != 1 {
		t.Errorf("handler reached %d times, want 1 (second request blocked)", reached)
	}
}

// With no limiter configured, the signup route must not be throttled (the
// default for tests and dev).
func TestEnableSignupRateLimit_DisabledWhenZero(t *testing.T) {
	s := &Server{}
	s.EnableSignupRateLimit(0, 5)
	if s.SignupRateLimiter != nil {
		t.Fatal("rate <= 0 should leave the limiter disabled")
	}
	s.EnableSignupRateLimit(10, 5)
	if s.SignupRateLimiter == nil {
		t.Fatal("positive rate should enable the limiter")
	}
}
