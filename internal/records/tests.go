package records

import (
	"context"
	"fmt"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// External tests — DVA (NI) / DVSA (GB) test history per student.
//
// Per plan §3 ("external_tests") and §10c (region amendment):
//   - Test types are region-specific. NI = 'theory', 'practical'.
//     GB = 'theory', 'mod1', 'mod2'.
//   - Outcomes: 'booked', 'pass', 'fail', 'not_yet'.
//   - CBT itself is NOT modelled here — CBT is completion-based, lives on
//     student_profiles (cbt_certificate_held, cbt_expires_on, cbt_variant).
//   - Multiple rows per (student, test_type) = multiple attempts. The
//     attempt_number is denormalised; the UI shows "Mod 1 attempt 2 — pass".

type ExternalTest struct {
	ID            domain.ExternalTestID
	StudentID     domain.UserID
	TestType      string // 'theory' | 'practical' | 'mod1' | 'mod2'
	Region        domain.Region
	AttemptNumber int
	ScheduledAt   time.Time // zero if not scheduled
	Reference     string
	Outcome       string // 'booked' | 'pass' | 'fail' | 'not_yet'
	Notes         string
	CreatedAt     time.Time
}

type RecordExternalTestRequest struct {
	StudentID   domain.UserID
	TestType    string
	Region      domain.Region
	ScheduledAt time.Time
	Reference   string
	Outcome     string
	Notes       string
}

// RecordExternalTest inserts an attempt row. attempt_number is computed:
// existing-attempts-for-this-(student, test_type) + 1.
func RecordExternalTest(ctx context.Context, scope *tenant.Scope, req RecordExternalTestRequest) (*ExternalTest, error) {
	if err := validateTestType(req.TestType, req.Region); err != nil {
		return nil, err
	}
	if !validOutcome(req.Outcome) {
		return nil, fmt.Errorf("%w: invalid outcome %q", ErrInvalidInput, req.Outcome)
	}
	if err := requireStudent(ctx, scope, req.StudentID); err != nil {
		return nil, err
	}

	// Compute next attempt number — count existing for this (student, type).
	var prev int
	if err := scope.Conn().QueryRowContext(ctx,
		`SELECT COUNT(*) FROM external_tests
		 WHERE school_id = ? AND student_id = ? AND test_type = ?`,
		string(scope.SchoolID()), string(req.StudentID), req.TestType,
	).Scan(&prev); err != nil {
		return nil, err
	}

	t := &ExternalTest{
		ID:            domain.ExternalTestID(domain.NewID()),
		StudentID:     req.StudentID,
		TestType:      req.TestType,
		Region:        req.Region,
		AttemptNumber: prev + 1,
		ScheduledAt:   req.ScheduledAt.UTC(),
		Reference:     req.Reference,
		Outcome:       req.Outcome,
		Notes:         req.Notes,
		CreatedAt:     time.Now().UTC(),
	}
	var schedArg any
	if !req.ScheduledAt.IsZero() {
		schedArg = req.ScheduledAt.UTC().Format(time.RFC3339)
	}
	_, err := scope.Conn().ExecContext(ctx, `
		INSERT INTO external_tests (id, school_id, student_id, test_type, region,
		    attempt_number, scheduled_at, reference, outcome, notes, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, string(t.ID), string(scope.SchoolID()), string(t.StudentID),
		t.TestType, string(t.Region), t.AttemptNumber, schedArg,
		t.Reference, t.Outcome, t.Notes, t.CreatedAt.Format(time.RFC3339))
	if err != nil {
		return nil, fmt.Errorf("insert external test: %w", err)
	}
	return t, nil
}

// UpdateOutcome flips a 'booked' row to a final state (pass/fail/not_yet).
// The most common flow: book → record outcome later.
func UpdateOutcome(ctx context.Context, scope *tenant.Scope, id domain.ExternalTestID, outcome, notes string) error {
	if !validOutcome(outcome) {
		return fmt.Errorf("%w: invalid outcome %q", ErrInvalidInput, outcome)
	}
	res, err := scope.Conn().ExecContext(ctx,
		`UPDATE external_tests SET outcome = ?, notes = ? WHERE id = ? AND school_id = ?`,
		outcome, notes, string(id), string(scope.SchoolID()))
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

func ListExternalTests(ctx context.Context, scope *tenant.Scope, studentID domain.UserID) ([]ExternalTest, error) {
	const q = `
		SELECT id, student_id, test_type, region, attempt_number,
		       COALESCE(scheduled_at,''), COALESCE(reference,''), outcome,
		       COALESCE(notes,''), created_at
		FROM external_tests
		WHERE school_id = ? AND student_id = ?
		ORDER BY scheduled_at DESC, created_at DESC, attempt_number DESC
	`
	rows, err := scope.Conn().QueryContext(ctx, q, string(scope.SchoolID()), string(studentID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ExternalTest
	for rows.Next() {
		var (
			t        ExternalTest
			schedStr string
			createdStr string
		)
		if err := rows.Scan(&t.ID, &t.StudentID, &t.TestType, &t.Region,
			&t.AttemptNumber, &schedStr, &t.Reference, &t.Outcome,
			&t.Notes, &createdStr); err != nil {
			return nil, err
		}
		if schedStr != "" {
			t.ScheduledAt, _ = time.Parse(time.RFC3339, schedStr)
		}
		t.CreatedAt, _ = time.Parse(time.RFC3339, createdStr)
		out = append(out, t)
	}
	return out, rows.Err()
}

// ----- helpers -----

func validateTestType(t string, r domain.Region) error {
	switch r {
	case domain.RegionNI:
		switch t {
		case "theory", "practical":
			return nil
		}
	case domain.RegionGB:
		switch t {
		case "theory", "mod1", "mod2":
			return nil
		}
	default:
		return fmt.Errorf("%w: region must be NI or GB", ErrInvalidInput)
	}
	return fmt.Errorf("%w: test type %q not valid for region %s", ErrInvalidInput, t, r)
}

func validOutcome(o string) bool {
	switch o {
	case "booked", "pass", "fail", "not_yet":
		return true
	}
	return false
}

