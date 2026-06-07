// Package records handles staff-only student records: incidents,
// safety/accommodation flags, progress notes, and external test history.
//
// Per plan §3:
//   - **Notes and flags are staff-visible only**, enforced at the data layer
//     not just hidden in the UI. The HTTP layer must never return these to
//     a student. (Engine functions don't check role — the HTTP layer does.)
//   - **Incidents** are distinct from bike_unavailability. A bike going
//     offline because of damage might or might not link to an incident; an
//     incident records the *event* (who was riding, what happened) and may
//     optionally trigger an unavailability.
//   - Treat note bodies as **UK GDPR personal data** — professional,
//     factual, defensible against a Subject Access Request. The engine
//     doesn't enforce phrasing; the UI nudges.
package records

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

var (
	ErrNotFound     = errors.New("records: not found in this school")
	ErrInvalidInput = errors.New("records: invalid input")
	ErrInvalidKind  = errors.New("records: kind must be 'safety_flag' or 'progress_note'")
)

// ----- Incidents -----

type Incident struct {
	ID               domain.IncidentID
	BikeID           domain.BikeID
	StudentID        domain.UserID
	BookingID        domain.BookingID
	OccurredAt       time.Time
	Description      string
	TookBikeOffline  bool
	CreatedAt        time.Time
	CreatedBy        domain.UserID
}

type LogIncidentRequest struct {
	BikeID          domain.BikeID
	StudentID       domain.UserID
	BookingID       domain.BookingID
	OccurredAt      time.Time
	Description     string
	TakeBikeOffline bool
	OfflineReason   string // used only if TakeBikeOffline is true
	CreatedBy       domain.UserID
}

// LogIncident records the event and optionally takes the bike offline in
// the same transaction (consistent with the design mock's "log incident
// (with 'take bike offline' option)" modal).
func LogIncident(ctx context.Context, scope *tenant.Scope, req LogIncidentRequest) (*Incident, error) {
	if strings.TrimSpace(req.Description) == "" {
		return nil, fmt.Errorf("%w: description required", ErrInvalidInput)
	}
	if req.OccurredAt.IsZero() {
		req.OccurredAt = time.Now().UTC()
	}
	if req.TakeBikeOffline && req.BikeID == "" {
		return nil, fmt.Errorf("%w: takeBikeOffline requires bikeId", ErrInvalidInput)
	}

	inc := &Incident{
		ID:              domain.IncidentID(domain.NewID()),
		BikeID:          req.BikeID,
		StudentID:       req.StudentID,
		BookingID:       req.BookingID,
		OccurredAt:      req.OccurredAt.UTC(),
		Description:     req.Description,
		TookBikeOffline: req.TakeBikeOffline,
		CreatedAt:       time.Now().UTC(),
		CreatedBy:       req.CreatedBy,
	}

	err := scope.WithTx(ctx, func(tx *tenant.Scope) error {
		var bikeArg, stuArg, bkArg any
		if inc.BikeID != "" {
			bikeArg = string(inc.BikeID)
		}
		if inc.StudentID != "" {
			stuArg = string(inc.StudentID)
		}
		if inc.BookingID != "" {
			bkArg = string(inc.BookingID)
		}
		_, err := tx.Conn().ExecContext(ctx, `
			INSERT INTO incidents (id, school_id, bike_id, student_id, booking_id,
			    occurred_at, description, took_bike_offline, created_at, created_by)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		`, string(inc.ID), string(scope.SchoolID()), bikeArg, stuArg, bkArg,
			inc.OccurredAt.Format(time.RFC3339), inc.Description,
			boolInt(inc.TookBikeOffline),
			inc.CreatedAt.Format(time.RFC3339), string(inc.CreatedBy))
		if err != nil {
			return fmt.Errorf("insert incident: %w", err)
		}
		if req.TakeBikeOffline {
			// Flip status to offline + add an open-ended unavailability.
			if _, err := tx.Conn().ExecContext(ctx,
				`UPDATE bikes SET status = 'offline' WHERE id = ? AND school_id = ?`,
				string(req.BikeID), string(scope.SchoolID()),
			); err != nil {
				return fmt.Errorf("mark bike offline: %w", err)
			}
			reason := req.OfflineReason
			if reason == "" {
				reason = "damaged"
			}
			if _, err := tx.Conn().ExecContext(ctx, `
				INSERT INTO bike_unavailability (id, school_id, bike_id, reason,
				    starts_at, ends_at, notes, created_at, created_by)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
			`, domain.NewID(), string(scope.SchoolID()), string(req.BikeID),
				reason,
				inc.OccurredAt.Format(time.RFC3339),
				inc.OccurredAt.AddDate(1, 0, 0).Format(time.RFC3339), // ~indefinite
				"From incident "+string(inc.ID),
				inc.CreatedAt.Format(time.RFC3339), string(inc.CreatedBy),
			); err != nil {
				return fmt.Errorf("insert unavailability: %w", err)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return inc, nil
}

func ListIncidents(ctx context.Context, scope *tenant.Scope, studentID domain.UserID) ([]Incident, error) {
	// If studentID is "" the call returns all incidents in the school.
	var (
		q    string
		args []any
	)
	if studentID == "" {
		q = `SELECT id, COALESCE(bike_id,''), COALESCE(student_id,''),
		            COALESCE(booking_id,''), occurred_at, description,
		            took_bike_offline, created_at, created_by
		     FROM incidents WHERE school_id = ?
		     ORDER BY occurred_at DESC`
		args = []any{string(scope.SchoolID())}
	} else {
		q = `SELECT id, COALESCE(bike_id,''), COALESCE(student_id,''),
		            COALESCE(booking_id,''), occurred_at, description,
		            took_bike_offline, created_at, created_by
		     FROM incidents WHERE school_id = ? AND student_id = ?
		     ORDER BY occurred_at DESC`
		args = []any{string(scope.SchoolID()), string(studentID)}
	}
	rows, err := scope.Conn().QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Incident
	for rows.Next() {
		var (
			inc            Incident
			occStr, crStr  string
			tookOfflineInt int
		)
		if err := rows.Scan(&inc.ID, &inc.BikeID, &inc.StudentID, &inc.BookingID,
			&occStr, &inc.Description, &tookOfflineInt, &crStr, &inc.CreatedBy); err != nil {
			return nil, err
		}
		inc.OccurredAt, _ = time.Parse(time.RFC3339, occStr)
		inc.CreatedAt, _ = time.Parse(time.RFC3339, crStr)
		inc.TookBikeOffline = tookOfflineInt == 1
		out = append(out, inc)
	}
	return out, rows.Err()
}

// ----- Student notes (staff-only) -----

const (
	NoteSafetyFlag   = "safety_flag"
	NoteProgressNote = "progress_note"
)

type StudentNote struct {
	ID        domain.StudentNoteID
	StudentID domain.UserID
	Kind      string
	Body      string
	IsActive  bool
	CreatedAt time.Time
	CreatedBy domain.UserID
}

type AddNoteRequest struct {
	StudentID domain.UserID
	Kind      string // 'safety_flag' or 'progress_note'
	Body      string
	CreatedBy domain.UserID
}

func AddNote(ctx context.Context, scope *tenant.Scope, req AddNoteRequest) (*StudentNote, error) {
	if req.Kind != NoteSafetyFlag && req.Kind != NoteProgressNote {
		return nil, ErrInvalidKind
	}
	if strings.TrimSpace(req.Body) == "" {
		return nil, fmt.Errorf("%w: body required", ErrInvalidInput)
	}
	if err := requireStudent(ctx, scope, req.StudentID); err != nil {
		return nil, err
	}
	n := &StudentNote{
		ID:        domain.StudentNoteID(domain.NewID()),
		StudentID: req.StudentID,
		Kind:      req.Kind,
		Body:      req.Body,
		IsActive:  true,
		CreatedAt: time.Now().UTC(),
		CreatedBy: req.CreatedBy,
	}
	_, err := scope.Conn().ExecContext(ctx, `
		INSERT INTO student_notes (id, school_id, student_id, kind, body, is_active, created_at, created_by)
		VALUES (?, ?, ?, ?, ?, 1, ?, ?)
	`, string(n.ID), string(scope.SchoolID()), string(n.StudentID), n.Kind, n.Body,
		n.CreatedAt.Format(time.RFC3339), string(n.CreatedBy))
	if err != nil {
		return nil, fmt.Errorf("insert note: %w", err)
	}
	return n, nil
}

// ListNotes returns notes for one student, optionally filtered by kind.
// Pass an empty kind to return both safety_flag and progress_note.
func ListNotes(ctx context.Context, scope *tenant.Scope, studentID domain.UserID, kind string) ([]StudentNote, error) {
	var (
		q    string
		args []any
	)
	base := `SELECT id, student_id, kind, body, is_active, created_at, created_by
	         FROM student_notes WHERE school_id = ? AND student_id = ?`
	if kind == "" {
		q = base + ` ORDER BY created_at DESC`
		args = []any{string(scope.SchoolID()), string(studentID)}
	} else {
		q = base + ` AND kind = ? ORDER BY created_at DESC`
		args = []any{string(scope.SchoolID()), string(studentID), kind}
	}
	rows, err := scope.Conn().QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []StudentNote
	for rows.Next() {
		var (
			n          StudentNote
			activeInt  int
			createdStr string
		)
		if err := rows.Scan(&n.ID, &n.StudentID, &n.Kind, &n.Body, &activeInt, &createdStr, &n.CreatedBy); err != nil {
			return nil, err
		}
		n.IsActive = activeInt == 1
		n.CreatedAt, _ = time.Parse(time.RFC3339, createdStr)
		out = append(out, n)
	}
	return out, rows.Err()
}

// DeactivateNote sets is_active=0. We don't hard-delete — notes are part of
// the audit record. Safety flags that no longer apply are deactivated, not
// removed.
func DeactivateNote(ctx context.Context, scope *tenant.Scope, noteID domain.StudentNoteID) error {
	res, err := scope.Conn().ExecContext(ctx,
		`UPDATE student_notes SET is_active = 0 WHERE id = ? AND school_id = ?`,
		string(noteID), string(scope.SchoolID()))
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// ----- helpers -----

func requireStudent(ctx context.Context, scope *tenant.Scope, id domain.UserID) error {
	var n int
	err := scope.Conn().QueryRowContext(ctx,
		`SELECT 1 FROM users WHERE id = ? AND school_id = ? AND role = 'student'`,
		string(id), string(scope.SchoolID()),
	).Scan(&n)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	return err
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
