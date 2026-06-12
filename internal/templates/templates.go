// Package templates manages recurring session schedules.
//
// A `Template` is the manager's recipe ("every Saturday 09:00 CBT-125 at
// Belfast with Dave, capacity 4"). The engine materialises concrete
// sessions from it over an explicit window — typically the next N weeks
// — so the calendar reads stay simple (sessions remain the source of
// truth for what's bookable).
//
// Idempotent by design: re-running Materialise over the same window is
// a no-op thanks to the unique (school, template, starts_at) index.
package templates

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

var (
	ErrNotFound     = errors.New("templates: not found")
	ErrInvalidInput = errors.New("templates: invalid input")
	// Returned by UndoMaterialisation when one or more sessions in the
	// pass already have student bookings. We refuse rather than
	// cascade-delete bookings — that's a destructive call the manager
	// should make session-by-session.
	ErrUndoHasBookings  = errors.New("templates: cannot undo — sessions have bookings")
	ErrAlreadyUndone    = errors.New("templates: materialisation already undone")
)

type Template struct {
	ID              string
	CourseTypeID    domain.CourseTypeID
	CourseCode      string
	CourseName      string
	InstructorID    domain.UserID
	InstructorName  string
	LocationID      domain.LocationID
	LocationName    string
	Weekday         int    // 0=Sunday … 6=Saturday
	StartsAtTime    string // HH:MM
	DurationMinutes int
	Capacity        int
	StartsOn        string // YYYY-MM-DD or empty
	EndsOn          string // YYYY-MM-DD or empty
	Notes           string
	CreatedAt       string
	CreatedBy       domain.UserID
}

type CreateRequest struct {
	CourseTypeID    domain.CourseTypeID
	InstructorID    domain.UserID
	LocationID      domain.LocationID
	Weekday         int
	StartsAtTime    string
	DurationMinutes int
	Capacity        int
	StartsOn        string
	EndsOn          string
	Notes           string
	CreatedBy       domain.UserID
}

func Create(ctx context.Context, scope *tenant.Scope, req CreateRequest) (*Template, error) {
	if err := validate(req); err != nil {
		return nil, err
	}
	id := domain.NewID()
	at := time.Now().UTC().Format(time.RFC3339)
	_, err := scope.Conn().ExecContext(ctx, `
		INSERT INTO session_templates
		    (id, school_id, course_type_id, instructor_id, location_id,
		     weekday, starts_at_time, duration_minutes, capacity,
		     starts_on, ends_on, notes, created_at, created_by)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, id, string(scope.SchoolID()),
		string(req.CourseTypeID), nullableString(string(req.InstructorID)), string(req.LocationID),
		req.Weekday, req.StartsAtTime, req.DurationMinutes, req.Capacity,
		nullableDate(req.StartsOn), nullableDate(req.EndsOn),
		req.Notes, at, string(req.CreatedBy))
	if err != nil {
		return nil, fmt.Errorf("insert template: %w", err)
	}
	return Get(ctx, scope, id)
}

func Delete(ctx context.Context, scope *tenant.Scope, id string) error {
	res, err := scope.Conn().ExecContext(ctx,
		`DELETE FROM session_templates WHERE id = ? AND school_id = ?`,
		id, string(scope.SchoolID()))
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

func Get(ctx context.Context, scope *tenant.Scope, id string) (*Template, error) {
	const q = baseSelect + ` WHERE t.id = ? AND t.school_id = ?`
	row := scope.Conn().QueryRowContext(ctx, q, id, string(scope.SchoolID()))
	t, err := scanTemplate(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return t, err
}

func List(ctx context.Context, scope *tenant.Scope) ([]Template, error) {
	const q = baseSelect + ` WHERE t.school_id = ? ORDER BY t.weekday, t.starts_at_time, ct.name`
	rows, err := scope.Conn().QueryContext(ctx, q, string(scope.SchoolID()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Template
	for rows.Next() {
		t, err := scanTemplate(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *t)
	}
	return out, rows.Err()
}

// MaterialiseResult is what Materialise returns to the HTTP layer.
// Pass-level metadata lets the UI offer "Undo just this one" right
// after generation without re-fetching the history list.
type MaterialiseResult struct {
	MaterialisationID string // empty when CreatedCount == 0 (no row written)
	CreatedCount      int
}

// Materialise generates concrete sessions for every matching weekday in
// [from, to). Idempotent — the unique index on
// (school_id, source_template_id, starts_at) catches the dedupe case.
// Records a `template_materialisations` row when at least one session
// was created so the UI can list passes + offer undo.
func Materialise(ctx context.Context, scope *tenant.Scope, from, to time.Time, performedBy domain.UserID) (*MaterialiseResult, error) {
	tmpls, err := List(ctx, scope)
	if err != nil {
		return nil, err
	}
	return materialiseList(ctx, scope, tmpls, from, to, performedBy)
}

// MaterialiseOne generates concrete sessions for a single template
// over [from, to). Same idempotency + audit-trail behaviour as the
// all-templates variant; the manager picks just one row off the
// templates page when they want to roll it out without touching the
// rest.
func MaterialiseOne(ctx context.Context, scope *tenant.Scope, id string, from, to time.Time, performedBy domain.UserID) (*MaterialiseResult, error) {
	t, err := Get(ctx, scope, id)
	if err != nil {
		return nil, err
	}
	return materialiseList(ctx, scope, []Template{*t}, from, to, performedBy)
}

func materialiseList(ctx context.Context, scope *tenant.Scope, tmpls []Template, from, to time.Time, performedBy domain.UserID) (*MaterialiseResult, error) {
	if len(tmpls) == 0 {
		return &MaterialiseResult{}, nil
	}
	out := &MaterialiseResult{MaterialisationID: domain.NewID()}
	weeks := int(to.Sub(from).Hours() / 24 / 7)
	if weeks < 1 {
		weeks = 1
	}
	err := scope.WithTx(ctx, func(tx *tenant.Scope) error {
		// Insert the pass row first so the sessions' FK on
		// source_materialisation_id resolves at row-insert time. We'll
		// either backfill the count or roll the row away if the pass
		// ended up empty.
		if _, err := tx.Conn().ExecContext(ctx, `
			INSERT INTO template_materialisations
			    (id, school_id, at, performed_by, weeks,
			     window_from, window_to, created_count)
			VALUES (?, ?, ?, ?, ?, ?, ?, 0)
		`, out.MaterialisationID, string(tx.SchoolID()),
			time.Now().UTC().Format(time.RFC3339), string(performedBy),
			weeks,
			from.Format("2006-01-02"), to.Format("2006-01-02")); err != nil {
			return err
		}
		for _, t := range tmpls {
			n, err := materialiseOne(ctx, tx, t, from, to, out.MaterialisationID)
			if err != nil {
				return err
			}
			out.CreatedCount += n
		}
		// Don't pollute the history with empty passes — those are
		// almost always idempotent re-runs over the same window.
		if out.CreatedCount == 0 {
			_, err := tx.Conn().ExecContext(ctx,
				`DELETE FROM template_materialisations WHERE id = ?`,
				out.MaterialisationID)
			return err
		}
		_, err := tx.Conn().ExecContext(ctx, `
			UPDATE template_materialisations SET created_count = ?
			WHERE id = ?
		`, out.CreatedCount, out.MaterialisationID)
		return err
	})
	if err != nil {
		return nil, err
	}
	if out.CreatedCount == 0 {
		out.MaterialisationID = ""
	}
	return out, nil
}

func materialiseOne(ctx context.Context, tx *tenant.Scope, t Template, from, to time.Time, materialisationID string) (int, error) {
	// Clamp window by the template's own bounds.
	if t.StartsOn != "" {
		s, err := time.Parse("2006-01-02", t.StartsOn)
		if err == nil && s.After(from) {
			from = s
		}
	}
	if t.EndsOn != "" {
		e, err := time.Parse("2006-01-02", t.EndsOn)
		if err == nil && e.Before(to) {
			to = e
		}
	}
	if !from.Before(to) {
		return 0, nil
	}

	// Parse HH:MM.
	if len(t.StartsAtTime) < 5 {
		return 0, fmt.Errorf("%w: starts_at_time bad", ErrInvalidInput)
	}
	hr, mn, err := parseHHMM(t.StartsAtTime)
	if err != nil {
		return 0, err
	}

	// Walk each day in [from, to) UTC. The Kickstand tenant region is
	// NI/GB — both effectively share UTC for now. When we introduce
	// real per-school timezones, swap UTC for the school's zone here.
	created := 0
	cursor := time.Date(from.Year(), from.Month(), from.Day(), 0, 0, 0, 0, time.UTC)
	end := time.Date(to.Year(), to.Month(), to.Day(), 0, 0, 0, 0, time.UTC)
	// Pre-load the list of closure ranges once per pass so we don't
	// round-trip per candidate day. Cheap to inline since the closure
	// table is tiny (handful of rows per school).
	closures, err := loadClosureDates(ctx, tx)
	if err != nil {
		return 0, err
	}
	for ; cursor.Before(end); cursor = cursor.AddDate(0, 0, 1) {
		if int(cursor.Weekday()) != t.Weekday {
			continue
		}
		dateStr := cursor.Format("2006-01-02")
		if closures[dateStr] {
			continue // school's closed; skip silently
		}
		startsAt := time.Date(cursor.Year(), cursor.Month(), cursor.Day(),
			hr, mn, 0, 0, time.UTC)
		endsAt := startsAt.Add(time.Duration(t.DurationMinutes) * time.Minute)

		// Try the insert; ignore unique-violation so the call is idempotent.
		// source_materialisation_id ties every NEW row to this pass so
		// the undo path can scope cleanly to "just what this pass made".
		sessionID := domain.NewID()
		now := time.Now().UTC().Format(time.RFC3339)
		res, err := tx.Conn().ExecContext(ctx, `
			INSERT INTO sessions
			    (id, school_id, course_type_id, instructor_id, location_id,
			     starts_at, ends_at, capacity, created_at,
			     source_template_id, source_materialisation_id)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(school_id, source_template_id, starts_at) DO NOTHING
		`, sessionID, string(tx.SchoolID()),
			string(t.CourseTypeID), nullableString(string(t.InstructorID)), string(t.LocationID),
			startsAt.Format(time.RFC3339), endsAt.Format(time.RFC3339),
			t.Capacity, now, t.ID, materialisationID)
		if err != nil {
			return created, fmt.Errorf("insert session from template: %w", err)
		}
		rowsAffected, _ := res.RowsAffected()
		if rowsAffected == 0 {
			continue // session already existed; idempotent skip
		}
		created++
		// Mirror the template's instructor into the join table so the
		// booking engine's "at least one qualified instructor" check
		// passes. Templates with a nullable instructor (a follow-up
		// task) will skip this insert when InstructorID is "".
		if t.InstructorID != "" {
			if _, err := tx.Conn().ExecContext(ctx, `
				INSERT INTO session_instructors
				    (id, school_id, session_id, instructor_id, is_primary, assigned_at, assigned_by)
				VALUES (?, ?, ?, ?, 1, ?, ?)
			`, domain.NewID(), string(tx.SchoolID()), sessionID,
				string(t.InstructorID), now, string(t.InstructorID)); err != nil {
				return created, fmt.Errorf("insert session_instructors from template: %w", err)
			}
		}
	}
	return created, nil
}

// Materialisation is one row of the materialisation history. Used for
// both the listing surface and as the undo target.
type Materialisation struct {
	ID            string
	At            time.Time
	PerformedBy   domain.UserID
	PerformerName string
	Weeks         int
	WindowFrom    string // YYYY-MM-DD
	WindowTo      string // YYYY-MM-DD
	CreatedCount  int
	UndoneAt      time.Time // zero == not undone
	UndoneBy      domain.UserID
}

// ListMaterialisations returns the school's pass history newest first.
// Capped at 100 — older entries can fall off; this is operational
// history, not audit (that's the audit_log).
func ListMaterialisations(ctx context.Context, scope *tenant.Scope) ([]Materialisation, error) {
	const q = `
		SELECT m.id, m.at, m.performed_by, COALESCE(u.name, ''),
		       m.weeks, m.window_from, m.window_to, m.created_count,
		       COALESCE(m.undone_at, ''), COALESCE(m.undone_by, '')
		FROM template_materialisations m
		LEFT JOIN users u ON u.id = m.performed_by AND u.school_id = m.school_id
		WHERE m.school_id = ?
		ORDER BY m.at DESC, m.id DESC
		LIMIT 100
	`
	rows, err := scope.Conn().QueryContext(ctx, q, string(scope.SchoolID()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Materialisation
	for rows.Next() {
		var m Materialisation
		var atStr, undoneAtStr string
		var performedBy, undoneBy string
		if err := rows.Scan(&m.ID, &atStr, &performedBy, &m.PerformerName,
			&m.Weeks, &m.WindowFrom, &m.WindowTo, &m.CreatedCount,
			&undoneAtStr, &undoneBy); err != nil {
			return nil, err
		}
		m.PerformedBy = domain.UserID(performedBy)
		m.UndoneBy = domain.UserID(undoneBy)
		m.At, _ = time.Parse(time.RFC3339, atStr)
		if undoneAtStr != "" {
			m.UndoneAt, _ = time.Parse(time.RFC3339, undoneAtStr)
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// UndoMaterialisation deletes every session generated by one pass
// (provided no student has booked into any of them) and marks the
// pass undone. Atomic; either all sessions go or none.
//
// Refuses with ErrUndoHasBookings if any session has a non-cancelled
// booking — the manager has to resolve those by hand. We don't
// cancel-cascade because that's a per-student communication call.
func UndoMaterialisation(ctx context.Context, scope *tenant.Scope, id string, undoneBy domain.UserID) (int, error) {
	var deleted int
	err := scope.WithTx(ctx, func(tx *tenant.Scope) error {
		var undoneAt sql.NullString
		err := tx.Conn().QueryRowContext(ctx, `
			SELECT undone_at FROM template_materialisations
			WHERE id = ? AND school_id = ?
		`, id, string(tx.SchoolID())).Scan(&undoneAt)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if undoneAt.Valid && undoneAt.String != "" {
			return ErrAlreadyUndone
		}

		// Refuse if any session has bookings (any status — even cancelled
		// bookings carry historical reference value the manager may want
		// preserved against an audit complaint).
		var bookingCount int
		if err := tx.Conn().QueryRowContext(ctx, `
			SELECT COUNT(*) FROM bookings b
			JOIN sessions s ON s.id = b.session_id AND s.school_id = b.school_id
			WHERE s.school_id = ? AND s.source_materialisation_id = ?
		`, string(tx.SchoolID()), id).Scan(&bookingCount); err != nil {
			return err
		}
		if bookingCount > 0 {
			return ErrUndoHasBookings
		}

		// FK dance: session_instructors references sessions(id), so
		// we have to clear those rows before the parent sessions go.
		if _, err := tx.Conn().ExecContext(ctx, `
			DELETE FROM session_instructors
			WHERE school_id = ? AND session_id IN (
				SELECT id FROM sessions
				WHERE school_id = ? AND source_materialisation_id = ?
			)
		`, string(tx.SchoolID()), string(tx.SchoolID()), id); err != nil {
			return err
		}
		res, err := tx.Conn().ExecContext(ctx, `
			DELETE FROM sessions
			WHERE school_id = ? AND source_materialisation_id = ?
		`, string(tx.SchoolID()), id)
		if err != nil {
			return err
		}
		n, _ := res.RowsAffected()
		deleted = int(n)

		_, err = tx.Conn().ExecContext(ctx, `
			UPDATE template_materialisations
			   SET undone_at = ?, undone_by = ?
			 WHERE id = ? AND school_id = ?
		`, time.Now().UTC().Format(time.RFC3339), string(undoneBy),
			id, string(tx.SchoolID()))
		return err
	})
	return deleted, err
}

// Preview returns the count of NEW sessions Materialise would create
// over [from, to) without actually inserting anything. Lets the UI
// show "this template would generate N sessions" before commit.
func Preview(ctx context.Context, scope *tenant.Scope, id string, from, to time.Time) (int, error) {
	t, err := Get(ctx, scope, id)
	if err != nil {
		return 0, err
	}
	// Clamp by template bounds.
	if t.StartsOn != "" {
		if s, err := time.Parse("2006-01-02", t.StartsOn); err == nil && s.After(from) {
			from = s
		}
	}
	if t.EndsOn != "" {
		if e, err := time.Parse("2006-01-02", t.EndsOn); err == nil && e.Before(to) {
			to = e
		}
	}
	if !from.Before(to) {
		return 0, nil
	}
	hr, mn, err := parseHHMM(t.StartsAtTime)
	if err != nil {
		return 0, err
	}

	// Count already-materialised occurrences in the window — Preview's
	// number is "NEW", not "total".
	var existing int
	if err := scope.Conn().QueryRowContext(ctx, `
		SELECT COUNT(*) FROM sessions
		WHERE school_id = ? AND source_template_id = ?
		  AND starts_at >= ? AND starts_at < ?
	`, string(scope.SchoolID()), t.ID,
		from.Format(time.RFC3339), to.Format(time.RFC3339),
	).Scan(&existing); err != nil {
		return 0, err
	}

	total := 0
	cursor := time.Date(from.Year(), from.Month(), from.Day(), hr, mn, 0, 0, time.UTC)
	endCursor := time.Date(to.Year(), to.Month(), to.Day(), 0, 0, 0, 0, time.UTC)
	for ; cursor.Before(endCursor); cursor = cursor.AddDate(0, 0, 1) {
		if int(cursor.Weekday()) == t.Weekday {
			total++
		}
	}
	if total < existing {
		return 0, nil
	}
	return total - existing, nil
}

// ----- helpers -----

const baseSelect = `
	SELECT t.id, t.course_type_id, COALESCE(ct.code,''), COALESCE(ct.name,''),
	       COALESCE(t.instructor_id, ''), COALESCE(u.name,''),
	       t.location_id, COALESCE(l.name,''),
	       t.weekday, t.starts_at_time, t.duration_minutes, t.capacity,
	       COALESCE(t.starts_on, ''), COALESCE(t.ends_on, ''),
	       COALESCE(t.notes, ''), t.created_at, t.created_by
	FROM session_templates t
	LEFT JOIN course_types ct ON ct.id = t.course_type_id AND ct.school_id = t.school_id
	LEFT JOIN users u         ON u.id = t.instructor_id   AND u.school_id  = t.school_id
	LEFT JOIN locations l     ON l.id = t.location_id     AND l.school_id  = t.school_id
`

func scanTemplate(s interface {
	Scan(dest ...any) error
}) (*Template, error) {
	var t Template
	if err := s.Scan(
		&t.ID, &t.CourseTypeID, &t.CourseCode, &t.CourseName,
		&t.InstructorID, &t.InstructorName,
		&t.LocationID, &t.LocationName,
		&t.Weekday, &t.StartsAtTime, &t.DurationMinutes, &t.Capacity,
		&t.StartsOn, &t.EndsOn,
		&t.Notes, &t.CreatedAt, &t.CreatedBy,
	); err != nil {
		return nil, err
	}
	return &t, nil
}

func validate(r CreateRequest) error {
	// Instructor is optional — managers can scaffold the weekly grid
	// first, assign instructors per generated session afterwards.
	if r.CourseTypeID == "" || r.LocationID == "" {
		return fmt.Errorf("%w: courseType, location required", ErrInvalidInput)
	}
	if r.Weekday < 0 || r.Weekday > 6 {
		return fmt.Errorf("%w: weekday must be 0..6", ErrInvalidInput)
	}
	if _, _, err := parseHHMM(r.StartsAtTime); err != nil {
		return fmt.Errorf("%w: starts_at_time must be HH:MM", ErrInvalidInput)
	}
	if r.DurationMinutes <= 0 {
		return fmt.Errorf("%w: duration_minutes must be > 0", ErrInvalidInput)
	}
	if r.Capacity <= 0 {
		return fmt.Errorf("%w: capacity must be > 0", ErrInvalidInput)
	}
	if r.StartsOn != "" {
		if _, err := time.Parse("2006-01-02", r.StartsOn); err != nil {
			return fmt.Errorf("%w: startsOn must be YYYY-MM-DD", ErrInvalidInput)
		}
	}
	if r.EndsOn != "" {
		if _, err := time.Parse("2006-01-02", r.EndsOn); err != nil {
			return fmt.Errorf("%w: endsOn must be YYYY-MM-DD", ErrInvalidInput)
		}
	}
	return nil
}

func parseHHMM(s string) (int, int, error) {
	if len(s) != 5 || s[2] != ':' {
		return 0, 0, fmt.Errorf("%w: starts_at_time must be HH:MM", ErrInvalidInput)
	}
	var hr, mn int
	if _, err := fmt.Sscanf(s, "%d:%d", &hr, &mn); err != nil {
		return 0, 0, fmt.Errorf("%w: %v", ErrInvalidInput, err)
	}
	if hr < 0 || hr > 23 || mn < 0 || mn > 59 {
		return 0, 0, fmt.Errorf("%w: HH:MM out of range", ErrInvalidInput)
	}
	return hr, mn, nil
}

func nullableString(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func nullableDate(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// loadClosureDates returns a set of YYYY-MM-DD strings covered by any
// school closure. Computed once per materialise pass so the per-day
// check inside materialiseOne stays O(1). Expanded by date so a
// multi-day closure (from 2026-12-24 to 2026-12-26) appears as three
// separate keys.
func loadClosureDates(ctx context.Context, scope *tenant.Scope) (map[string]bool, error) {
	rows, err := scope.Conn().QueryContext(ctx,
		`SELECT from_date, to_date FROM school_closures WHERE school_id = ?`,
		string(scope.SchoolID()))
	if err != nil {
		return nil, fmt.Errorf("load closures: %w", err)
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var fromStr, toStr string
		if err := rows.Scan(&fromStr, &toStr); err != nil {
			return nil, err
		}
		from, err1 := time.Parse("2006-01-02", fromStr)
		to, err2 := time.Parse("2006-01-02", toStr)
		if err1 != nil || err2 != nil {
			continue
		}
		for d := from; !d.After(to); d = d.AddDate(0, 0, 1) {
			out[d.Format("2006-01-02")] = true
		}
	}
	return out, rows.Err()
}
