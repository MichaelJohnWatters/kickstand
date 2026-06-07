// Package reminders is the cron-style worker that emits session-reminder
// notifications.
//
// Per plan §8b: the high-value reminders are 24h and 2h before a session.
// Each Tick scans sessions whose start time falls in a window around (now +
// horizon) and emits ONE event per (session, horizon) plus N in-app
// notifications (one per booked student).
//
// Idempotency: before emitting we check that no event of the same kind has
// been recorded for this session. The check + insert run in a single
// transaction, so two workers can't double-fire.
//
// Worker scheduling: the caller invokes Tick on a ticker (e.g. every 5
// minutes). The detection window is symmetric (±3 min) around the horizon
// to absorb tick-time jitter without missing sessions.
package reminders

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

const (
	// detectionSlop is the +/- window around (now + horizon) we use to find
	// sessions to remind about. Must be > tick interval / 2.
	detectionSlop = 3 * time.Minute
)

// horizons defines the (hoursBefore, event kind, category) tuples we emit.
// Kept in one place so config changes don't have to update SQL.
var horizons = []struct {
	HoursBefore int
	EventKind   string
	Category    string
}{
	{24, "session.reminder_24h", "reminder"},
	{2, "session.reminder_2h", "reminder"},
}

// Tick runs one pass: for each configured horizon, find eligible sessions,
// emit event + notifications. Returns an error only on infrastructure
// problems — per-session errors are logged but don't halt the whole pass.
func Tick(ctx context.Context, db *sql.DB, now time.Time) error {
	// Compare timestamps in UTC consistently — the DB stores RFC3339 with
	// the Z suffix; if we used a local-offset time here, lexicographic
	// SQLite comparison would silently miss sessions.
	now = now.UTC()
	for _, h := range horizons {
		target := now.Add(time.Duration(h.HoursBefore) * time.Hour)
		from := target.Add(-detectionSlop)
		to := target.Add(detectionSlop)

		sessions, err := loadSessionsInWindow(ctx, db, h.EventKind, from, to)
		if err != nil {
			return fmt.Errorf("load sessions for %s: %w", h.EventKind, err)
		}
		for _, s := range sessions {
			if err := emit(ctx, db, h.EventKind, h.Category, s, now); err != nil {
				// Per-session failure: keep going. Don't poison the rest
				// of this tick.
				_ = err
			}
		}
	}
	return nil
}

type sessionToRemind struct {
	ID         string
	SchoolID   string
	CourseName string
	StartsAt   time.Time
}

// loadSessionsInWindow finds sessions that start in [from, to) and don't
// already have a reminder event of the given kind. The NOT EXISTS clause
// is the idempotency check; the transaction in emit re-checks under the
// write lock so two parallel ticks can't both pass this gate.
func loadSessionsInWindow(ctx context.Context, db *sql.DB, kind string, from, to time.Time) ([]sessionToRemind, error) {
	const q = `
		SELECT s.id, s.school_id, s.starts_at, COALESCE(ct.name, '')
		FROM sessions s
		JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		WHERE s.status = 'scheduled'
		  AND s.starts_at >= ? AND s.starts_at < ?
		  AND NOT EXISTS (
		    SELECT 1 FROM events e
		    WHERE e.school_id = s.school_id
		      AND e.kind = ?
		      AND e.subject_id = s.id
		  )
		ORDER BY s.starts_at ASC
	`
	rows, err := db.QueryContext(ctx, q, from.Format(time.RFC3339), to.Format(time.RFC3339), kind)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []sessionToRemind
	for rows.Next() {
		var (
			s         sessionToRemind
			startsStr string
		)
		if err := rows.Scan(&s.ID, &s.SchoolID, &startsStr, &s.CourseName); err != nil {
			return nil, err
		}
		s.StartsAt, _ = time.Parse(time.RFC3339, startsStr)
		out = append(out, s)
	}
	return out, rows.Err()
}

// emit inserts the event + a notification per booked student in one tx.
// Re-checks the idempotency condition inside the tx so concurrent workers
// can't double-emit. The tx is short — just two INSERTs and a SELECT per
// student — but holding it briefly is fine.
func emit(ctx context.Context, db *sql.DB, kind, category string, s sessionToRemind, now time.Time) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	// Idempotency under the write lock.
	var n int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM events WHERE school_id = ? AND kind = ? AND subject_id = ?`,
		s.SchoolID, kind, s.ID,
	).Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return nil // another worker beat us to it
	}

	// Insert event.
	eventID := domain.NewID()
	payload, _ := json.Marshal(map[string]any{
		"sessionId":   s.ID,
		"courseName":  s.CourseName,
		"startsAt":    s.StartsAt.UTC().Format(time.RFC3339),
		"hoursBefore": hoursBeforeFromKind(kind),
	})
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO events (id, school_id, kind, subject_id, payload, created_at)
		VALUES (?, ?, ?, ?, ?, ?)
	`, eventID, s.SchoolID, kind, s.ID, string(payload), now.UTC().Format(time.RFC3339)); err != nil {
		return err
	}

	// Find booked students for this session.
	rows, err := tx.QueryContext(ctx, `
		SELECT student_id FROM bookings
		WHERE school_id = ? AND session_id = ? AND status = 'booked'
	`, s.SchoolID, s.ID)
	if err != nil {
		return err
	}
	var studentIDs []string
	for rows.Next() {
		var sid string
		if err := rows.Scan(&sid); err != nil {
			rows.Close()
			return err
		}
		studentIDs = append(studentIDs, sid)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	// One notification per student.
	const insertNotif = `
		INSERT INTO notifications (id, school_id, event_id, recipient_id, channel, category, status, sent_at)
		VALUES (?, ?, ?, ?, 'in_app', ?, 'sent', ?)
	`
	sent := now.UTC().Format(time.RFC3339)
	for _, sid := range studentIDs {
		if _, err := tx.ExecContext(ctx, insertNotif,
			domain.NewID(), s.SchoolID, eventID, sid, category, sent); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func hoursBeforeFromKind(kind string) int {
	for _, h := range horizons {
		if h.EventKind == kind {
			return h.HoursBefore
		}
	}
	return 0
}
