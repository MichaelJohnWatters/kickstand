// Package audit is the durable record of who-did-what.
//
// Owned by httpapi: the audit middleware writes one row per mutating
// request after the handler returns. Engine packages don't reach in
// here directly — the seam stays at the HTTP boundary so the schema
// can evolve without rippling through every engine call site.
//
// What lands in the table is shaped by the migration in
// migrations/0011_audit_log.up.sql; the doc comment there owns the
// rationale (denormalised actor, pattern not URL, no diffs yet).
package audit

import (
	"context"
	"database/sql"
	"fmt"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

type Entry struct {
	At           string // RFC3339 UTC
	SchoolID     domain.SchoolID
	ActorUserID  domain.UserID // empty when unauthenticated (we still log these)
	ActorRole    string
	ActorName    string
	Method       string
	PathPattern  string // route template, not concrete URL
	TargetEntity string // best-effort, derived from the path
	TargetID     string
	StatusCode   int
	ErrorCode    string // empty on success
	// Summary is the one-sentence human description set by the handler
	// via Describe(ctx, …). Empty when the handler didn't bother — the
	// audit viewer falls back to its verb-mapping in that case.
	Summary string
}

// Write inserts one audit row. Failures are returned but the caller
// (the middleware) treats them as best-effort — a failed audit insert
// must never fail the user's request.
func Write(ctx context.Context, db *sql.DB, e Entry) error {
	_, err := db.ExecContext(ctx, `
		INSERT INTO audit_log
		    (id, school_id, at, actor_user_id, actor_role, actor_name,
		     method, path_pattern, target_entity, target_id,
		     status_code, error_code, summary)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, domain.NewID(), string(e.SchoolID), e.At,
		nullableString(string(e.ActorUserID)),
		e.ActorRole, e.ActorName,
		e.Method, e.PathPattern,
		e.TargetEntity, e.TargetID,
		e.StatusCode, e.ErrorCode, e.Summary)
	if err != nil {
		return fmt.Errorf("audit write: %w", err)
	}
	return nil
}

// ----- Handler-side enrichment seam -----

// requestAudit is the mutable per-request bag handlers write into via
// Describe. The middleware allocates it before dispatch and reads it
// out after the handler returns to populate the audit row.
type requestAudit struct {
	summary string
}

type ctxKey struct{}

// WithRequest stores a fresh per-request bag in the context. Called
// by the httpapi middleware on every request — handlers don't need
// to do this themselves. Returns the new context.
func WithRequest(ctx context.Context) context.Context {
	return context.WithValue(ctx, ctxKey{}, &requestAudit{})
}

// Describe attaches a one-sentence human summary to the in-flight
// audit row. Safe to call multiple times — the last call wins. A
// no-op when no audit bag is in context (e.g. background workers
// that never went through the HTTP middleware), so it's always safe
// to call from engine code.
//
// Example:
//
//	audit.Describe(ctx, "Took bike %s offline (reason: %s)", bike.Nickname, reason)
func Describe(ctx context.Context, format string, args ...any) {
	a, _ := ctx.Value(ctxKey{}).(*requestAudit)
	if a == nil {
		return
	}
	a.summary = fmt.Sprintf(format, args...)
}

// SummaryFrom is read by the httpapi middleware when it builds the
// audit Entry. Empty when Describe was never called.
func SummaryFrom(ctx context.Context) string {
	a, _ := ctx.Value(ctxKey{}).(*requestAudit)
	if a == nil {
		return ""
	}
	return a.summary
}

// nullableString turns "" into a SQL NULL so the actor_user_id column
// reads back as NULL for unauthenticated rows rather than empty string.
func nullableString(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// ----- Read side: powering /audit -----

// Row is the wire-friendly read shape — same fields as Entry plus the
// row id (so the UI can stable-key paginated lists) and a server-
// resolved `TargetLabel` (e.g. a bike's nickname, a student's name) so
// the human-readable view doesn't have to expose raw IDs.
type Row struct {
	ID           string
	At           string
	ActorUserID  string
	ActorRole    string
	ActorName    string
	Method       string
	PathPattern  string
	TargetEntity string
	TargetID     string
	TargetLabel  string // resolved at read time; empty when the entity is gone
	Summary      string // handler-set; empty when the route never enriched
	StatusCode   int
	ErrorCode    string
}

// Filter shapes the WHERE clause for List. Empty strings mean "any".
type Filter struct {
	ActorUserID  domain.UserID
	TargetEntity string
	TargetID     string
	From         string // RFC3339 lower bound (inclusive)
	To           string // RFC3339 upper bound (exclusive)
	Limit        int
	Offset       int
}

// List returns audit rows for the school in `at DESC` order, plus the
// total count for the same filter (so the UI can render pagination).
// School scope comes from the *sql.DB-scoped query — we don't reuse
// tenant.Scope here because audit reads are admin-gated, not the same
// surface as engine reads.
func List(ctx context.Context, db *sql.DB, schoolID domain.SchoolID, f Filter) ([]Row, int, error) {
	where := "a.school_id = ?"
	args := []any{string(schoolID)}
	if f.ActorUserID != "" {
		where += " AND a.actor_user_id = ?"
		args = append(args, string(f.ActorUserID))
	}
	if f.TargetEntity != "" {
		where += " AND a.target_entity = ?"
		args = append(args, f.TargetEntity)
	}
	if f.TargetID != "" {
		where += " AND a.target_id = ?"
		args = append(args, f.TargetID)
	}
	if f.From != "" {
		where += " AND a.at >= ?"
		args = append(args, f.From)
	}
	if f.To != "" {
		where += " AND a.at < ?"
		args = append(args, f.To)
	}

	// Count first — same args, no LIMIT, no joins (count doesn't care
	// about target labels).
	var total int
	if err := db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM audit_log a WHERE `+where, args...,
	).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("audit count: %w", err)
	}

	limit := f.Limit
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	// Each LEFT JOIN matches only rows where target_entity points at
	// the joined table, so the planner can prune efficiently. The
	// COALESCE-CASE picks the first non-NULL label that's relevant
	// for this row's entity type. Resolves to '' when the underlying
	// entity has been deleted (audit rows outlive their targets).
	q := `SELECT
	        a.id, a.at, COALESCE(a.actor_user_id, ''), a.actor_role, a.actor_name,
	        a.method, a.path_pattern, a.target_entity, a.target_id,
	        a.summary,
	        COALESCE(
	          CASE WHEN a.target_entity = 'bikes'
	               THEN COALESCE(NULLIF(b.nickname, ''), TRIM(COALESCE(b.make,'') || ' ' || COALESCE(b.model,''))) END,
	          CASE WHEN a.target_entity IN ('students','instructors','auth','signups','users')
	               THEN u.name END,
	          CASE WHEN a.target_entity = 'locations' THEN l.name END,
	          CASE WHEN a.target_entity = 'course-types' THEN ct.code END,
	          CASE WHEN a.target_entity = 'sessions'
	               THEN sct.code || ' · ' || substr(s.starts_at, 1, 10) END,
	          CASE WHEN a.target_entity = 'bookings'
	               THEN bct.code || ' · ' || substr(bs.starts_at, 1, 10) END,
	          CASE WHEN a.target_entity = 'session-templates'
	               THEN tct.code || ' · ' ||
	                    CASE t.weekday
	                      WHEN 0 THEN 'Sun' WHEN 1 THEN 'Mon' WHEN 2 THEN 'Tue'
	                      WHEN 3 THEN 'Wed' WHEN 4 THEN 'Thu' WHEN 5 THEN 'Fri'
	                      WHEN 6 THEN 'Sat' END ||
	                    ' ' || t.starts_at_time END,
	          CASE WHEN a.target_entity = 'disruptions'
	               THEN COALESCE(NULLIF(db.nickname, ''), TRIM(COALESCE(db.make,'') || ' ' || COALESCE(db.model,''))) END,
	          ''
	        ) AS target_label,
	        a.status_code, a.error_code
	      FROM audit_log a
	      LEFT JOIN bikes b
	        ON b.id = a.target_id AND b.school_id = a.school_id
	        AND a.target_entity = 'bikes'
	      LEFT JOIN users u
	        ON u.id = a.target_id AND u.school_id = a.school_id
	        AND a.target_entity IN ('students','instructors','auth','signups','users')
	      LEFT JOIN locations l
	        ON l.id = a.target_id AND l.school_id = a.school_id
	        AND a.target_entity = 'locations'
	      LEFT JOIN course_types ct
	        ON ct.id = a.target_id AND ct.school_id = a.school_id
	        AND a.target_entity = 'course-types'
	      LEFT JOIN sessions s
	        ON s.id = a.target_id AND s.school_id = a.school_id
	        AND a.target_entity = 'sessions'
	      LEFT JOIN course_types sct
	        ON sct.id = s.course_type_id AND sct.school_id = s.school_id
	      LEFT JOIN bookings bk
	        ON bk.id = a.target_id AND bk.school_id = a.school_id
	        AND a.target_entity = 'bookings'
	      LEFT JOIN sessions bs
	        ON bs.id = bk.session_id AND bs.school_id = bk.school_id
	      LEFT JOIN course_types bct
	        ON bct.id = bs.course_type_id AND bct.school_id = bs.school_id
	      LEFT JOIN session_templates t
	        ON t.id = a.target_id AND t.school_id = a.school_id
	        AND a.target_entity = 'session-templates'
	      LEFT JOIN course_types tct
	        ON tct.id = t.course_type_id AND tct.school_id = t.school_id
	      LEFT JOIN disruptions d
	        ON d.id = a.target_id AND d.school_id = a.school_id
	        AND a.target_entity = 'disruptions'
	      LEFT JOIN bikes db
	        ON db.id = d.bike_id AND db.school_id = d.school_id
	      WHERE ` + where + `
	      ORDER BY a.at DESC, a.rowid DESC
	      LIMIT ? OFFSET ?`
	args = append(args, limit, f.Offset)
	rows, err := db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, 0, fmt.Errorf("audit list: %w", err)
	}
	defer rows.Close()
	out := make([]Row, 0, limit)
	for rows.Next() {
		var r Row
		if err := rows.Scan(&r.ID, &r.At, &r.ActorUserID, &r.ActorRole, &r.ActorName,
			&r.Method, &r.PathPattern, &r.TargetEntity, &r.TargetID,
			&r.Summary,
			&r.TargetLabel,
			&r.StatusCode, &r.ErrorCode); err != nil {
			return nil, 0, err
		}
		out = append(out, r)
	}
	return out, total, rows.Err()
}
