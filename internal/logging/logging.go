// Package logging wires the rest of the codebase onto log/slog with a few
// project-level conventions:
//
//   - One slog.Default() logger configured at startup (Setup).
//   - A per-request logger stashed on context via WithLogger / FromContext.
//     The HTTP request middleware pre-fills it with rid, method, path, ip
//     etc., so downstream packages just call FromContext(ctx).Info(...)
//     and the line carries the request context automatically.
//   - One structured line per request emitted by the middleware on the way
//     out (after the handler returns) with status, duration, bytes,
//     identity, and any query string.
//
// Why slog and not zerolog/zap: stdlib since Go 1.21, no extra dep, plenty
// fast for our scale, easy to swap text → JSON via a flag if we ever want
// log shipping.
package logging

import (
	"context"
	"io"
	"log/slog"
	"os"
)

type ctxKey struct{}

// Setup wires slog.Default() to a text handler on stdout. Level controls
// whether Debug lines are emitted; everything Info and above always goes
// through. Returns the logger so the caller can keep a reference if needed.
func Setup(level slog.Level) *slog.Logger {
	return SetupTo(os.Stdout, level)
}

// SetupTo is Setup with an explicit writer — handy in tests.
func SetupTo(w io.Writer, level slog.Level) *slog.Logger {
	h := slog.NewTextHandler(w, &slog.HandlerOptions{Level: level})
	l := slog.New(h)
	slog.SetDefault(l)
	return l
}

// WithLogger attaches a logger to ctx. Use when you're about to call into
// downstream code that should inherit the same set of fields (rid, user…).
func WithLogger(ctx context.Context, l *slog.Logger) context.Context {
	return context.WithValue(ctx, ctxKey{}, l)
}

// FromContext returns the per-request logger if one was attached, or the
// default logger otherwise. Always safe — never returns nil.
func FromContext(ctx context.Context) *slog.Logger {
	if l, ok := ctx.Value(ctxKey{}).(*slog.Logger); ok && l != nil {
		return l
	}
	return slog.Default()
}
