package httpapi

import (
	"net/http"
	"sync"
	"time"
)

// ipRateLimiter is a per-client-IP token bucket. It's an application-layer
// defence-in-depth against flooding the abuse-prone public endpoints (chiefly
// self-signup) — Firebase already throttles account creation per IP, this adds
// a backend cap on top. In-memory and per-process, which matches the current
// single-instance SQLite deployment; a multi-replica deploy would want a
// shared store (Redis) instead.
//
// Keyed on clientIP(), which honours X-Forwarded-For — behind an untrusted
// proxy that header is spoofable, so treat this as a naive-flood cap rather
// than a hard security boundary.
type ipRateLimiter struct {
	mu      sync.Mutex
	buckets map[string]*tokenBucket
	rate    float64 // tokens refilled per second
	burst   float64 // bucket capacity
	ttl     time.Duration
	now     func() time.Time // injectable for tests
}

type tokenBucket struct {
	tokens float64
	last   time.Time
}

// EnableSignupRateLimit configures per-IP rate limiting on the public signup
// route. ratePerMin <= 0 disables it. Call before Routes().
func (s *Server) EnableSignupRateLimit(ratePerMin, burst int) {
	if ratePerMin <= 0 {
		s.SignupRateLimiter = nil
		return
	}
	if burst < 1 {
		burst = 1
	}
	s.SignupRateLimiter = newIPRateLimiter(ratePerMin, burst)
}

// newIPRateLimiter builds a limiter allowing `ratePerMinute` requests per IP
// in steady state, with a `burst` capacity for short spikes.
func newIPRateLimiter(ratePerMinute, burst int) *ipRateLimiter {
	return &ipRateLimiter{
		buckets: make(map[string]*tokenBucket),
		rate:    float64(ratePerMinute) / 60.0,
		burst:   float64(burst),
		ttl:     10 * time.Minute,
		now:     time.Now,
	}
}

// allow reports whether a request from ip may proceed, consuming one token.
func (l *ipRateLimiter) allow(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()

	b := l.buckets[ip]
	if b == nil {
		// Opportunistic sweep of stale buckets so the map can't grow without
		// bound under IP churn (no background goroutine to manage).
		if len(l.buckets) > 10_000 {
			for k, v := range l.buckets {
				if now.Sub(v.last) > l.ttl {
					delete(l.buckets, k)
				}
			}
		}
		l.buckets[ip] = &tokenBucket{tokens: l.burst - 1, last: now}
		return true
	}

	b.tokens = min(l.burst, b.tokens+now.Sub(b.last).Seconds()*l.rate)
	b.last = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// middleware wraps a handler, rejecting requests over the per-IP limit with a
// 429 + Retry-After.
func (l *ipRateLimiter) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !l.allow(clientIP(r)) {
			w.Header().Set("Retry-After", "60")
			writeError(w, http.StatusTooManyRequests, "rate_limited",
				"too many requests from your address; please wait and try again")
			return
		}
		next.ServeHTTP(w, r)
	})
}
