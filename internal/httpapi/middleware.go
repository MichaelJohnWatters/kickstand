package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"log/slog"
	"net/http"
	"runtime/debug"
	"strings"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/logging"
)

// identityCtxKey is package-private — only this file constructs an
// identity-bearing context. Handlers read it via identityFromContext.
type identityCtxKey struct{}

func contextWithIdentity(parent context.Context, id *auth.Identity) context.Context {
	return context.WithValue(parent, identityCtxKey{}, id)
}

func identityFromContext(ctx context.Context) (*auth.Identity, bool) {
	id, ok := ctx.Value(identityCtxKey{}).(*auth.Identity)
	return id, ok
}

// requestState is a small mutable bag shared between withLog and
// authMiddleware. Go contexts are immutable — values you attach inside a
// handler don't bubble back up to outer middleware. So withLog allocates
// this struct, drops a pointer in the context, and authMiddleware writes
// the identity into it once it's resolved. On the way back out, withLog
// reads from the same struct.
type requestState struct {
	identity *auth.Identity
}

type requestStateKey struct{}

func requestStateFrom(ctx context.Context) *requestState {
	s, _ := ctx.Value(requestStateKey{}).(*requestState)
	return s
}

// authMiddleware enforces a valid Bearer token on every wrapped route. On
// success it attaches the resolved Identity to the request context. Handlers
// then build a tenant.Scope from id.SchoolID — never from request headers.
func (s *Server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := bearerToken(r)
		if !ok {
			writeError(w, http.StatusUnauthorized, "missing_token", "Authorization header missing or malformed")
			return
		}
		id, err := auth.Authenticate(r.Context(), s.DB, domain.UserSessionToken(token))
		if err != nil {
			writeEngineError(w, err)
			return
		}
		// Publish identity to the outer request-log middleware via the
		// shared state (contexts can't propagate values back up the chain).
		if st := requestStateFrom(r.Context()); st != nil {
			st.identity = id
		}
		next.ServeHTTP(w, r.WithContext(contextWithIdentity(r.Context(), id)))
	})
}

func bearerToken(r *http.Request) (string, bool) {
	h := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if !strings.HasPrefix(h, prefix) {
		return "", false
	}
	tok := strings.TrimSpace(strings.TrimPrefix(h, prefix))
	if tok == "" {
		return "", false
	}
	return tok, true
}

// withLog emits one structured line per request, after the handler returns,
// carrying everything we'd want to grep on: method, path, query, status,
// duration, response bytes, request id, client IP, and the authenticated
// identity (user / school / role) when the route was authenticated.
//
// The per-request logger is also attached to r.Context() so downstream
// packages can `logging.FromContext(ctx).Info(...)` with the same rid +
// identity fields without re-deriving them.
func withLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		rid := newRequestID()
		ip := clientIP(r)

		reqLogger := slog.Default().With(
			slog.String("rid", rid),
			slog.String("method", r.Method),
			slog.String("path", r.URL.Path),
			slog.String("ip", ip),
		)

		w.Header().Set("X-Request-ID", rid)
		state := &requestState{}
		ctx := context.WithValue(r.Context(), requestStateKey{}, state)
		ctx = logging.WithLogger(ctx, reqLogger)
		sw := &statusRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(sw, r.WithContext(ctx))

		attrs := []any{
			slog.Int("status", sw.status),
			slog.Int64("dur_ms", time.Since(started).Milliseconds()),
			slog.Int("bytes", sw.bytes),
		}
		if q := r.URL.RawQuery; q != "" {
			attrs = append(attrs, slog.String("query", q))
		}
		if id := state.identity; id != nil {
			attrs = append(attrs,
				slog.String("user", string(id.UserID)),
				slog.String("school", string(id.SchoolID)),
				slog.String("role", string(id.Role)),
			)
		}
		reqLogger.LogAttrs(r.Context(), levelFor(sw.status), "request", toAttrs(attrs)...)
	})
}

// levelFor maps the response status to a slog level so 5xx jumps out in a
// noisy log file. Client errors still log at INFO — they're usually the
// app behaving correctly under bad input.
func levelFor(status int) slog.Level {
	switch {
	case status >= 500:
		return slog.LevelError
	case status >= 400:
		return slog.LevelWarn
	default:
		return slog.LevelInfo
	}
}

func toAttrs(in []any) []slog.Attr {
	out := make([]slog.Attr, 0, len(in))
	for _, v := range in {
		if a, ok := v.(slog.Attr); ok {
			out = append(out, a)
		}
	}
	return out
}

// withRecover turns panics into 500s instead of crashing the server. Logs
// via the request logger so the panic line carries rid + identity.
func withRecover(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				logging.FromContext(r.Context()).Error("panic in handler",
					slog.Any("recovered", v),
					slog.String("stack", string(debug.Stack())),
				)
				writeError(w, http.StatusInternalServerError, "internal_error", "an internal error occurred")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// withCORS allows the Flutter Web dev build to talk to the Go server from
// another origin. Permissive in dev (reflects any Origin); for production
// we'd want a real allowlist.
//
// The Authorization header is explicitly listed in Allow-Headers — browsers
// don't include it in the default safelist, so without this the bearer
// token never reaches us on cross-origin requests.
func withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Credentials", "true")
			w.Header().Set("Vary", "Origin")
		}
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		w.Header().Set("Access-Control-Max-Age", "86400")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
	bytes  int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	n, err := s.ResponseWriter.Write(b)
	s.bytes += n
	return n, err
}

func newRequestID() string {
	var b [6]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// clientIP returns the originating client address. Honours X-Forwarded-For
// when a proxy is in front; otherwise falls back to the direct connection's
// remote address.
func clientIP(r *http.Request) string {
	if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
		if i := strings.Index(fwd, ","); i > 0 {
			return strings.TrimSpace(fwd[:i])
		}
		return strings.TrimSpace(fwd)
	}
	return r.RemoteAddr
}
