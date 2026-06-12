package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net/http"
	"runtime/debug"
	"strings"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/audit"
	"github.com/michaeljohnwatters/kickstand/internal/auth"
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

// authMiddleware verifies the Bearer token via the Firebase Admin SDK
// and attaches the resolved Identity to the request context. Handlers
// then build a tenant.Scope from id.SchoolID — never from request
// headers.
//
// Server construction requires a non-nil Firebase client (see
// NewServer); if you somehow get here without one, every request 503s
// rather than silently letting anything through.
func (s *Server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.Firebase == nil {
			writeError(w, http.StatusServiceUnavailable, "firebase_disabled",
				"Firebase Auth is not configured on this server")
			return
		}
		token, ok := bearerToken(r)
		if !ok {
			writeError(w, http.StatusUnauthorized, "missing_token", "Authorization header missing or malformed")
			return
		}
		id, err := s.Firebase.VerifyAndLoad(r.Context(), s.DB, token)
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
func (s *Server) withLog(next http.Handler) http.Handler {
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
		// Seed an empty audit bag for handlers to enrich via
		// audit.Describe(ctx, …). The read at the end picks up whatever
		// was set (or "" if no handler bothered, in which case the
		// client falls back to its verb-mapping).
		ctx = audit.WithRequest(ctx)
		sw := &statusRecorder{ResponseWriter: w, status: 200}
		// Keep a handle on the request struct the mux actually dispatches
		// against — `r.WithContext` returns a shallow copy, and the mux
		// writes the matched pattern into THAT struct. Reading
		// `r.Pattern` on the outer request would always see "".
		inner := r.WithContext(ctx)
		next.ServeHTTP(sw, inner)

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

		// Audit log — mutating requests only, after the handler returns.
		// School scope comes from the resolved identity, so unauthenticated
		// mutations (which 401 before reaching a handler) are not recorded
		// here; they're already covered by the structured request log
		// above. Best-effort: a failed insert must not affect the caller.
		if isAuditableMethod(r.Method) && state.identity != nil && inner.Pattern != "" {
			id := state.identity
			entity, targetID := auditTargetFrom(inner)
			entry := audit.Entry{
				At:           started.UTC().Format(time.RFC3339),
				SchoolID:     id.SchoolID,
				ActorUserID:  id.UserID,
				ActorRole:    string(id.Role),
				ActorName:    id.Name,
				Method:       r.Method,
				PathPattern:  auditPathPattern(inner.Pattern),
				TargetEntity: entity,
				TargetID:     targetID,
				StatusCode:   sw.status,
				ErrorCode:    sw.errorCode(),
				Summary:      audit.SummaryFrom(inner.Context()),
			}
			if err := audit.Write(r.Context(), s.DB, entry); err != nil {
				reqLogger.LogAttrs(r.Context(), slog.LevelWarn, "audit write failed",
					slog.String("err", err.Error()))
			}
		}
	})
}

func isAuditableMethod(m string) bool {
	switch m {
	case http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete:
		return true
	}
	return false
}

// auditPathPattern strips the leading method from r.Pattern. Go's mux
// stores the matched pattern as e.g. "POST /bikes/{id}/restore"; the
// audit row only needs the path portion.
func auditPathPattern(pattern string) string {
	if i := strings.Index(pattern, " "); i >= 0 {
		return pattern[i+1:]
	}
	return pattern
}

// auditTargetFrom derives (entity, id) from the request. Entity is the
// first non-empty path segment ("bikes" for /bikes/{id}/restore). ID is
// the value of the first path parameter in the pattern. Both are
// best-effort — empty when not derivable.
func auditTargetFrom(r *http.Request) (entity, id string) {
	path := strings.TrimPrefix(r.URL.Path, "/")
	if i := strings.Index(path, "/"); i >= 0 {
		entity = path[:i]
	} else {
		entity = path
	}
	// First {name} in the pattern → that path value.
	pat := auditPathPattern(r.Pattern)
	if open := strings.Index(pat, "{"); open >= 0 {
		if close := strings.Index(pat[open:], "}"); close > 0 {
			name := pat[open+1 : open+close]
			// Path params may be declared `{name...}` for wildcard; strip
			// the suffix so PathValue resolves.
			name = strings.TrimSuffix(name, "...")
			id = r.PathValue(name)
		}
	}
	return entity, id
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
	// bodyHead buffers the first slice of the response body so the
	// audit middleware can lift `error_code` out of error envelopes
	// ({"error":"...","message":"..."}). Capped — the envelope is tiny
	// and we don't want to mirror full success payloads in memory.
	bodyHead [512]byte
	bodyN    int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	n, err := s.ResponseWriter.Write(b)
	s.bytes += n
	if s.bodyN < len(s.bodyHead) {
		room := len(s.bodyHead) - s.bodyN
		if len(b) < room {
			room = len(b)
		}
		copy(s.bodyHead[s.bodyN:], b[:room])
		s.bodyN += room
	}
	return n, err
}

// errorCode returns the `error` field from the JSON body when the
// response is a 4xx/5xx; empty otherwise. Cheap best-effort parse —
// non-JSON bodies (or unparseable ones) just yield "".
func (s *statusRecorder) errorCode() string {
	if s.status < 400 || s.bodyN == 0 {
		return ""
	}
	var env struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(s.bodyHead[:s.bodyN], &env); err != nil {
		return ""
	}
	return env.Error
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
