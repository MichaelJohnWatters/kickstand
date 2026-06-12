package admin

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

// SessionAssignment is the engine-level shape for a one-off session.
// Instructors is 0..N — managers can scaffold a session shell now and
// assign people later via SetSessionInstructors.
type CreateSessionRequest struct {
	CourseTypeID domain.CourseTypeID
	LocationID   domain.LocationID
	StartsAt     time.Time
	EndsAt       time.Time
	Capacity     int
	InstructorIDs []domain.UserID // optional; first becomes primary if provided
	Notes        string
	CreatedBy    domain.UserID
}

// RatioWarning describes a soft violation of the course's max_ratio
// (students-per-instructor) recommendation. We surface it on the
// CreateSession response so the UI can show "1:6 booked but 1:2
// recommended", but the create call itself always succeeds — the
// manager can break the rule and live with the consequences.
type RatioWarning struct {
	Message            string
	StudentsPerInstructor int
	RecommendedMax     int
}

type CreateSessionResult struct {
	SessionID domain.SessionID
	Warnings  []RatioWarning
}

// CreateSession inserts one ad-hoc session + its session_instructors
// rows in the same transaction. Doesn't refuse on ratio violation —
// that's the manager's call.
func CreateSession(ctx context.Context, scope *tenant.Scope, req CreateSessionRequest) (*CreateSessionResult, error) {
	if req.CourseTypeID == "" {
		return nil, fmt.Errorf("%w: courseTypeId required", ErrInvalidInput)
	}
	if req.LocationID == "" {
		return nil, fmt.Errorf("%w: locationId required", ErrInvalidInput)
	}
	if req.Capacity <= 0 {
		return nil, fmt.Errorf("%w: capacity must be > 0", ErrInvalidInput)
	}
	if !req.StartsAt.Before(req.EndsAt) {
		return nil, fmt.Errorf("%w: startsAt must be before endsAt", ErrInvalidInput)
	}
	if err := requireLocation(ctx, scope, req.LocationID); err != nil {
		return nil, err
	}

	// Fetch the course's recommended max_ratio so we can compute the
	// warning. Also confirms the course exists.
	var maxRatio int
	if err := scope.Conn().QueryRowContext(ctx,
		`SELECT COALESCE(max_ratio, 0) FROM course_types WHERE id = ? AND school_id = ?`,
		string(req.CourseTypeID), string(scope.SchoolID()),
	).Scan(&maxRatio); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, fmt.Errorf("%w: courseTypeId not found", ErrInvalidInput)
		}
		return nil, err
	}

	sessionID := domain.SessionID(domain.NewID())
	out := &CreateSessionResult{SessionID: sessionID}

	// Soft ratio check. recommendedMax is total students supportable
	// by the given instructor count (one instructor handles max_ratio
	// students). 0 instructors = "needs someone" — different surface
	// in the UI but no warning here.
	if maxRatio > 0 && len(req.InstructorIDs) > 0 {
		supported := maxRatio * len(req.InstructorIDs)
		if req.Capacity > supported {
			out.Warnings = append(out.Warnings, RatioWarning{
				Message: fmt.Sprintf(
					"Capacity %d exceeds the recommended %d (%d instructor%s × %d student per instructor).",
					req.Capacity, supported,
					len(req.InstructorIDs),
					pluralS(len(req.InstructorIDs)),
					maxRatio),
				StudentsPerInstructor: req.Capacity / max1(len(req.InstructorIDs)),
				RecommendedMax:        maxRatio,
			})
		}
	}

	primary := domain.UserID("")
	if len(req.InstructorIDs) > 0 {
		primary = req.InstructorIDs[0]
	}

	at := time.Now().UTC().Format(time.RFC3339)
	err := scope.WithTx(ctx, func(tx *tenant.Scope) error {
		var instructorArg any
		if primary != "" {
			instructorArg = string(primary)
		}
		if _, err := tx.Conn().ExecContext(ctx, `
			INSERT INTO sessions
			    (id, school_id, course_type_id, instructor_id, location_id,
			     starts_at, ends_at, capacity, status, notes, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'scheduled', ?, ?)
		`, string(sessionID), string(scope.SchoolID()),
			string(req.CourseTypeID), instructorArg, string(req.LocationID),
			req.StartsAt.UTC().Format(time.RFC3339),
			req.EndsAt.UTC().Format(time.RFC3339),
			req.Capacity, nullStr(req.Notes), at); err != nil {
			return fmt.Errorf("insert session: %w", err)
		}
		for i, iid := range req.InstructorIDs {
			isPrimary := 0
			if i == 0 {
				isPrimary = 1
			}
			if _, err := tx.Conn().ExecContext(ctx, `
				INSERT INTO session_instructors
				    (id, school_id, session_id, instructor_id, is_primary, assigned_at, assigned_by)
				VALUES (?, ?, ?, ?, ?, ?, ?)
			`, domain.NewID(), string(scope.SchoolID()), string(sessionID),
				string(iid), isPrimary, at, string(req.CreatedBy)); err != nil {
				return fmt.Errorf("insert session_instructors: %w", err)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// UpdateSessionRequest carries the optional patches managers can apply
// to an existing session: a new (startsAt, endsAt) window, capacity, or
// both. Nil fields mean "don't touch". Course type, location and
// instructor assignment have their own dedicated endpoints (those mutate
// bookings + denormalised joins, so they get their own validated paths).
type UpdateSessionRequest struct {
	StartsAt *time.Time
	EndsAt   *time.Time
	Capacity *int
}

// UpdateSession applies a partial patch to a session. Both
// drag-and-drop on the master calendar (time only) and the edit sheet
// (time + capacity) route through this. Course, instructor and
// bookings are untouched.
//
// Conflict detection is intentionally not done here — managers can
// double-book if they really mean to, and the calendar will surface
// the overlap visually.
func UpdateSession(ctx context.Context, scope *tenant.Scope, sessionID domain.SessionID, req UpdateSessionRequest) error {
	if req.StartsAt != nil && req.EndsAt != nil && !req.StartsAt.Before(*req.EndsAt) {
		return fmt.Errorf("%w: startsAt must be before endsAt", ErrInvalidInput)
	}
	if (req.StartsAt != nil) != (req.EndsAt != nil) {
		return fmt.Errorf("%w: startsAt and endsAt must be supplied together", ErrInvalidInput)
	}
	if req.Capacity != nil && *req.Capacity <= 0 {
		return fmt.Errorf("%w: capacity must be positive", ErrInvalidInput)
	}
	parts := []string{}
	args := []any{}
	if req.StartsAt != nil {
		parts = append(parts, "starts_at = ?", "ends_at = ?")
		args = append(args,
			req.StartsAt.UTC().Format(time.RFC3339),
			req.EndsAt.UTC().Format(time.RFC3339))
	}
	if req.Capacity != nil {
		parts = append(parts, "capacity = ?")
		args = append(args, *req.Capacity)
	}
	if len(parts) == 0 {
		return nil // no-op
	}
	args = append(args, string(sessionID), string(scope.SchoolID()))
	res, err := scope.Conn().ExecContext(ctx,
		`UPDATE sessions SET `+strings.Join(parts, ", ")+
			` WHERE id = ? AND school_id = ?`,
		args...)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// UpdateSessionTime is a back-compat shim around UpdateSession kept so
// the drag-to-move handler doesn't have to know about the wider
// patch shape.
func UpdateSessionTime(ctx context.Context, scope *tenant.Scope, sessionID domain.SessionID, startsAt, endsAt time.Time) error {
	return UpdateSession(ctx, scope, sessionID, UpdateSessionRequest{
		StartsAt: &startsAt,
		EndsAt:   &endsAt,
	})
}

// SetSessionInstructors replaces the instructor assignment for a
// session. The first id in `instructorIDs` becomes the primary
// (mirrored to sessions.instructor_id for fast calendar reads).
// Empty list is allowed — that's how a manager clears a session and
// marks it as "needs instructor".
func SetSessionInstructors(ctx context.Context, scope *tenant.Scope, sessionID domain.SessionID, instructorIDs []domain.UserID, assignedBy domain.UserID) error {
	// Confirm the session exists in this school.
	var n int
	if err := scope.Conn().QueryRowContext(ctx,
		`SELECT 1 FROM sessions WHERE id = ? AND school_id = ?`,
		string(sessionID), string(scope.SchoolID()),
	).Scan(&n); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	at := time.Now().UTC().Format(time.RFC3339)
	return scope.WithTx(ctx, func(tx *tenant.Scope) error {
		if _, err := tx.Conn().ExecContext(ctx,
			`DELETE FROM session_instructors WHERE session_id = ? AND school_id = ?`,
			string(sessionID), string(scope.SchoolID())); err != nil {
			return err
		}
		var primary any
		for i, iid := range instructorIDs {
			isPrimary := 0
			if i == 0 {
				isPrimary = 1
				primary = string(iid)
			}
			if _, err := tx.Conn().ExecContext(ctx, `
				INSERT INTO session_instructors
				    (id, school_id, session_id, instructor_id, is_primary, assigned_at, assigned_by)
				VALUES (?, ?, ?, ?, ?, ?, ?)
			`, domain.NewID(), string(scope.SchoolID()), string(sessionID),
				string(iid), isPrimary, at, string(assignedBy)); err != nil {
				return err
			}
		}
		// Sync the denormalised primary on the sessions row.
		if _, err := tx.Conn().ExecContext(ctx,
			`UPDATE sessions SET instructor_id = ? WHERE id = ? AND school_id = ?`,
			primary, string(sessionID), string(scope.SchoolID())); err != nil {
			return err
		}
		return nil
	})
}

// ListSessionInstructors returns the assignment for one session,
// primary first.
func ListSessionInstructors(ctx context.Context, scope *tenant.Scope, sessionID domain.SessionID) ([]SessionInstructor, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT si.instructor_id, COALESCE(u.name, ''), si.is_primary
		FROM session_instructors si
		LEFT JOIN users u ON u.id = si.instructor_id AND u.school_id = si.school_id
		WHERE si.school_id = ? AND si.session_id = ?
		ORDER BY si.is_primary DESC, si.assigned_at ASC
	`, string(scope.SchoolID()), string(sessionID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SessionInstructor
	for rows.Next() {
		var r SessionInstructor
		var isPrimary int
		if err := rows.Scan(&r.InstructorID, &r.Name, &isPrimary); err != nil {
			return nil, err
		}
		r.IsPrimary = isPrimary == 1
		out = append(out, r)
	}
	return out, rows.Err()
}

type SessionInstructor struct {
	InstructorID domain.UserID
	Name         string
	IsPrimary    bool
}

// ----- helpers -----

func nullStr(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func pluralS(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}

func max1(n int) int {
	if n < 1 {
		return 1
	}
	return n
}
