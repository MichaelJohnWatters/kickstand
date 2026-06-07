// Package availability is the CRUD seam for instructor availability —
// recurring weekly slots plus one-off time-off windows.
//
// The booking engine doesn't read this table directly; sessions are
// already-committed instantiations of an instructor's offered time. This
// package is what the admin/instructor UI uses to MANAGE what time gets
// offered. Plan §3 ("availability — when an instructor offers time
// (recurring or one-off blocks); also covers instructor time off").
package availability

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
	ErrNotFound     = errors.New("availability: not found in this school")
	ErrInvalidInput = errors.New("availability: invalid input")
)

// ----- Recurring weekly slots -----

type RecurringSlot struct {
	ID            domain.AvailabilityID
	InstructorID  domain.UserID
	Weekday       int    // 0 = Sunday … 6 = Saturday
	StartsAtLocal string // 'HH:MM'
	EndsAtLocal   string // 'HH:MM'
	LocationID    domain.LocationID
}

type CreateRecurringRequest struct {
	InstructorID  domain.UserID
	Weekday       int
	StartsAtLocal string
	EndsAtLocal   string
	LocationID    domain.LocationID
}

func CreateRecurringSlot(ctx context.Context, scope *tenant.Scope, req CreateRecurringRequest) (*RecurringSlot, error) {
	if req.Weekday < 0 || req.Weekday > 6 {
		return nil, fmt.Errorf("%w: weekday must be 0..6", ErrInvalidInput)
	}
	if !isHHMM(req.StartsAtLocal) || !isHHMM(req.EndsAtLocal) {
		return nil, fmt.Errorf("%w: startsAtLocal and endsAtLocal must be 'HH:MM'", ErrInvalidInput)
	}
	if req.StartsAtLocal >= req.EndsAtLocal {
		return nil, fmt.Errorf("%w: endsAtLocal must be after startsAtLocal", ErrInvalidInput)
	}
	if err := requireInstructor(ctx, scope, req.InstructorID); err != nil {
		return nil, err
	}
	slot := &RecurringSlot{
		ID:            domain.AvailabilityID(domain.NewID()),
		InstructorID:  req.InstructorID,
		Weekday:       req.Weekday,
		StartsAtLocal: req.StartsAtLocal,
		EndsAtLocal:   req.EndsAtLocal,
		LocationID:    req.LocationID,
	}
	var locArg any
	if slot.LocationID != "" {
		locArg = string(slot.LocationID)
	}
	_, err := scope.Conn().ExecContext(ctx, `
		INSERT INTO instructor_recurring_availability
		    (id, school_id, instructor_id, weekday, starts_at_local, ends_at_local, location_id)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	`, string(slot.ID), string(scope.SchoolID()), string(slot.InstructorID),
		slot.Weekday, slot.StartsAtLocal, slot.EndsAtLocal, locArg)
	if err != nil {
		return nil, fmt.Errorf("insert recurring slot: %w", err)
	}
	return slot, nil
}

func ListRecurringSlots(ctx context.Context, scope *tenant.Scope, instructorID domain.UserID) ([]RecurringSlot, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT id, instructor_id, weekday, starts_at_local, ends_at_local, COALESCE(location_id, '')
		FROM instructor_recurring_availability
		WHERE school_id = ? AND instructor_id = ?
		ORDER BY weekday ASC, starts_at_local ASC
	`, string(scope.SchoolID()), string(instructorID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []RecurringSlot
	for rows.Next() {
		var s RecurringSlot
		if err := rows.Scan(&s.ID, &s.InstructorID, &s.Weekday,
			&s.StartsAtLocal, &s.EndsAtLocal, &s.LocationID); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func DeleteRecurringSlot(ctx context.Context, scope *tenant.Scope, id domain.AvailabilityID) error {
	res, err := scope.Conn().ExecContext(ctx,
		`DELETE FROM instructor_recurring_availability WHERE id = ? AND school_id = ?`,
		string(id), string(scope.SchoolID()))
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// ----- Time off -----

type TimeOff struct {
	ID           domain.TimeOffID
	InstructorID domain.UserID
	StartsAt     time.Time
	EndsAt       time.Time
	Reason       string
}

type AddTimeOffRequest struct {
	InstructorID domain.UserID
	StartsAt     time.Time
	EndsAt       time.Time
	Reason       string
}

func AddTimeOff(ctx context.Context, scope *tenant.Scope, req AddTimeOffRequest) (*TimeOff, error) {
	if !req.EndsAt.After(req.StartsAt) {
		return nil, fmt.Errorf("%w: endsAt must be after startsAt", ErrInvalidInput)
	}
	if err := requireInstructor(ctx, scope, req.InstructorID); err != nil {
		return nil, err
	}
	t := &TimeOff{
		ID:           domain.TimeOffID(domain.NewID()),
		InstructorID: req.InstructorID,
		StartsAt:     req.StartsAt.UTC(),
		EndsAt:       req.EndsAt.UTC(),
		Reason:       req.Reason,
	}
	_, err := scope.Conn().ExecContext(ctx, `
		INSERT INTO instructor_time_off (id, school_id, instructor_id, starts_at, ends_at, reason)
		VALUES (?, ?, ?, ?, ?, ?)
	`, string(t.ID), string(scope.SchoolID()), string(t.InstructorID),
		t.StartsAt.Format(time.RFC3339), t.EndsAt.Format(time.RFC3339), t.Reason)
	if err != nil {
		return nil, fmt.Errorf("insert time off: %w", err)
	}
	return t, nil
}

func ListTimeOff(ctx context.Context, scope *tenant.Scope, instructorID domain.UserID) ([]TimeOff, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT id, instructor_id, starts_at, ends_at, COALESCE(reason, '')
		FROM instructor_time_off
		WHERE school_id = ? AND instructor_id = ?
		ORDER BY starts_at ASC
	`, string(scope.SchoolID()), string(instructorID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TimeOff
	for rows.Next() {
		var (
			t                  TimeOff
			startsStr, endsStr string
		)
		if err := rows.Scan(&t.ID, &t.InstructorID, &startsStr, &endsStr, &t.Reason); err != nil {
			return nil, err
		}
		t.StartsAt, _ = time.Parse(time.RFC3339, startsStr)
		t.EndsAt, _ = time.Parse(time.RFC3339, endsStr)
		out = append(out, t)
	}
	return out, rows.Err()
}

func DeleteTimeOff(ctx context.Context, scope *tenant.Scope, id domain.TimeOffID) error {
	res, err := scope.Conn().ExecContext(ctx,
		`DELETE FROM instructor_time_off WHERE id = ? AND school_id = ?`,
		string(id), string(scope.SchoolID()))
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

func requireInstructor(ctx context.Context, scope *tenant.Scope, id domain.UserID) error {
	var n int
	err := scope.Conn().QueryRowContext(ctx,
		`SELECT 1 FROM users WHERE id = ? AND school_id = ? AND role = 'instructor'`,
		string(id), string(scope.SchoolID()),
	).Scan(&n)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	return err
}

// isHHMM checks that a string matches HH:MM with hours 00-23 and minutes 00-59.
func isHHMM(s string) bool {
	if len(s) != 5 || s[2] != ':' {
		return false
	}
	hh, mm := s[:2], s[3:]
	for _, c := range hh + mm {
		if c < '0' || c > '9' {
			return false
		}
	}
	h := (int(hh[0]-'0'))*10 + int(hh[1]-'0')
	m := (int(mm[0]-'0'))*10 + int(mm[1]-'0')
	return h <= 23 && m <= 59
}

// strings import is used elsewhere; keeping for future validation tweaks.
var _ = strings.TrimSpace
