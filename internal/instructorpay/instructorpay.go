// Package instructorpay tracks what schools owe their instructors.
//
// Per plan §3 ("Instructor pay — parallel ledger"):
//
//   - This is **owed-tracking, NOT payroll**. No payslips, PAYE, NI, tax —
//     that's regulated and schools use accountants. This is just "we owe
//     Dave £340."
//   - The pay model is stored per instructor (schools mix freelancers on
//     percentage with employed salaried staff). Salaried = not tracked.
//   - MVP: earnings entered MANUALLY by admin (consistent with charges).
//     For percentage earnings, the row may reference source charges so
//     "how was this calculated?" remains answerable.
//   - Balance is derived: earnings − payments.
package instructorpay

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
	ErrInstructorNotFound = errors.New("instructorpay: instructor not found in this school")
	ErrEarningNotFound    = errors.New("instructorpay: earning not found")
	ErrAlreadyVoided      = errors.New("instructorpay: already voided")
	ErrAmountInvalid      = errors.New("instructorpay: amount must be a positive integer")
	ErrInvalidBasis       = errors.New("instructorpay: invalid pay_basis")
)

// ----- Pay model -----

type SetPayModelRequest struct {
	InstructorID domain.UserID
	PayBasis     domain.PayBasis
	RateValue    int64 // pence for flat; basis-points (10000 = 100%) for percentage
}

// SetPayModel inserts or replaces the per-instructor pay model. Per the
// plan, one model per instructor; an optional per-course override lives in
// the instructor_pay_overrides table (not exposed yet — admin UI add later).
func SetPayModel(ctx context.Context, scope *tenant.Scope, req SetPayModelRequest) error {
	return setPayModelAt(ctx, scope, req, time.Now)
}

func setPayModelAt(ctx context.Context, scope *tenant.Scope, req SetPayModelRequest, nowFn func() time.Time) error {
	if !validBasis(req.PayBasis) {
		return ErrInvalidBasis
	}
	if err := requireInstructor(ctx, scope, req.InstructorID); err != nil {
		return err
	}

	// Upsert via DELETE+INSERT (SQLite has ON CONFLICT but the UNIQUE is
	// on (school_id, instructor_id); a clean DELETE+INSERT is simpler).
	err := scope.WithTx(ctx, func(tx *tenant.Scope) error {
		if _, err := tx.Conn().ExecContext(ctx,
			`DELETE FROM instructor_pay_models WHERE school_id = ? AND instructor_id = ?`,
			string(scope.SchoolID()), string(req.InstructorID),
		); err != nil {
			return fmt.Errorf("delete existing model: %w", err)
		}
		_, err := tx.Conn().ExecContext(ctx, `
			INSERT INTO instructor_pay_models
			    (id, school_id, instructor_id, pay_basis, rate_value, created_at)
			VALUES (?, ?, ?, ?, ?, ?)
		`, domain.NewID(), string(scope.SchoolID()), string(req.InstructorID),
			string(req.PayBasis), req.RateValue,
			nowFn().UTC().Format(time.RFC3339),
		)
		return err
	})
	if err != nil {
		return fmt.Errorf("upsert pay model: %w", err)
	}
	return nil
}

type PayModel struct {
	InstructorID domain.UserID
	PayBasis     domain.PayBasis
	RateValue    int64
}

func GetPayModel(ctx context.Context, scope *tenant.Scope, instructorID domain.UserID) (*PayModel, error) {
	var m PayModel
	err := scope.Conn().QueryRowContext(ctx, `
		SELECT instructor_id, pay_basis, rate_value
		FROM instructor_pay_models
		WHERE school_id = ? AND instructor_id = ?
	`, string(scope.SchoolID()), string(instructorID)).Scan(&m.InstructorID, &m.PayBasis, &m.RateValue)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil // no model set; instructor isn't tracked here
	}
	if err != nil {
		return nil, err
	}
	return &m, nil
}

// ----- Earnings -----

type RecordEarningRequest struct {
	InstructorID domain.UserID
	SessionID    domain.SessionID // optional but recommended
	AmountPence  domain.Money
	Basis        domain.PayBasis // snapshot (the model could change later)
	Notes        string
	CreatedBy    domain.UserID
	// SourceChargeIDs — only meaningful for percentage earnings.
	// Per plan: "reference the session and the charges it derived from,
	// not just a bare number — so the later automation is clean."
	SourceChargeIDs []domain.ChargeID
}

type Earning struct {
	ID           domain.EarningID
	SchoolID     domain.SchoolID
	InstructorID domain.UserID
	SessionID    domain.SessionID
	AmountPence  domain.Money
	Basis        domain.PayBasis
	Notes        string
	CreatedAt    time.Time
	CreatedBy    domain.UserID
}

func RecordEarning(ctx context.Context, scope *tenant.Scope, req RecordEarningRequest) (*Earning, error) {
	return recordEarningAt(ctx, scope, req, time.Now)
}

func recordEarningAt(ctx context.Context, scope *tenant.Scope, req RecordEarningRequest, nowFn func() time.Time) (*Earning, error) {
	if req.AmountPence <= 0 {
		return nil, ErrAmountInvalid
	}
	if !validBasis(req.Basis) {
		return nil, ErrInvalidBasis
	}
	if err := requireInstructor(ctx, scope, req.InstructorID); err != nil {
		return nil, err
	}

	e := &Earning{
		ID:           domain.EarningID(domain.NewID()),
		SchoolID:     scope.SchoolID(),
		InstructorID: req.InstructorID,
		SessionID:    req.SessionID,
		AmountPence:  req.AmountPence,
		Basis:        req.Basis,
		Notes:        req.Notes,
		CreatedAt:    nowFn().UTC(),
		CreatedBy:    req.CreatedBy,
	}

	err := scope.WithTx(ctx, func(tx *tenant.Scope) error {
		var sessionArg any
		if e.SessionID != "" {
			sessionArg = string(e.SessionID)
		}
		_, err := tx.Conn().ExecContext(ctx, `
			INSERT INTO instructor_earnings
			    (id, school_id, instructor_id, session_id, amount_pence, basis, notes, created_at, created_by)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		`, string(e.ID), string(e.SchoolID), string(e.InstructorID), sessionArg,
			int64(e.AmountPence), string(e.Basis), e.Notes,
			e.CreatedAt.Format(time.RFC3339), string(e.CreatedBy),
		)
		if err != nil {
			return fmt.Errorf("insert earning: %w", err)
		}
		for _, cid := range req.SourceChargeIDs {
			if _, err := tx.Conn().ExecContext(ctx, `
				INSERT INTO instructor_earning_sources (school_id, earning_id, charge_id)
				VALUES (?, ?, ?)
			`, string(scope.SchoolID()), string(e.ID), string(cid)); err != nil {
				return fmt.Errorf("insert earning source: %w", err)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return e, nil
}

type VoidEarningRequest struct {
	EarningID domain.EarningID
	VoidedBy  domain.UserID
	Reason    string
}

func VoidEarning(ctx context.Context, scope *tenant.Scope, req VoidEarningRequest) error {
	return voidEarningAt(ctx, scope, req, time.Now)
}

func voidEarningAt(ctx context.Context, scope *tenant.Scope, req VoidEarningRequest, nowFn func() time.Time) error {
	res, err := scope.Conn().ExecContext(ctx, `
		UPDATE instructor_earnings
		   SET voided_at = ?, voided_by = ?
		 WHERE id = ? AND school_id = ? AND voided_at IS NULL
	`, nowFn().UTC().Format(time.RFC3339), string(req.VoidedBy),
		string(req.EarningID), string(scope.SchoolID()))
	if err != nil {
		return fmt.Errorf("void earning: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		var voidedAt sql.NullString
		err := scope.Conn().QueryRowContext(ctx,
			`SELECT voided_at FROM instructor_earnings WHERE id = ? AND school_id = ?`,
			string(req.EarningID), string(scope.SchoolID())).Scan(&voidedAt)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrEarningNotFound
		}
		if err != nil {
			return err
		}
		return ErrAlreadyVoided
	}
	return nil
}

// ----- Payments out -----

type RecordPaymentRequest struct {
	InstructorID domain.UserID
	AmountPence  domain.Money
	Method       domain.PaymentMethod
	PaidAt       time.Time
	RecordedBy   domain.UserID
	Notes        string
}

type Payment struct {
	ID           domain.InstructorPayID
	SchoolID     domain.SchoolID
	InstructorID domain.UserID
	AmountPence  domain.Money
	Method       domain.PaymentMethod
	PaidAt       time.Time
	RecordedBy   domain.UserID
	Notes        string
}

func RecordPayment(ctx context.Context, scope *tenant.Scope, req RecordPaymentRequest) (*Payment, error) {
	if req.AmountPence <= 0 {
		return nil, ErrAmountInvalid
	}
	if err := validateMethod(req.Method); err != nil {
		return nil, err
	}
	if err := requireInstructor(ctx, scope, req.InstructorID); err != nil {
		return nil, err
	}

	p := &Payment{
		ID:           domain.InstructorPayID(domain.NewID()),
		SchoolID:     scope.SchoolID(),
		InstructorID: req.InstructorID,
		AmountPence:  req.AmountPence,
		Method:       req.Method,
		PaidAt:       req.PaidAt.UTC(),
		RecordedBy:   req.RecordedBy,
		Notes:        req.Notes,
	}
	_, err := scope.Conn().ExecContext(ctx, `
		INSERT INTO instructor_payments
		    (id, school_id, instructor_id, amount_pence, method, paid_at, recorded_by, notes)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	`, string(p.ID), string(p.SchoolID), string(p.InstructorID),
		int64(p.AmountPence), string(p.Method),
		p.PaidAt.Format(time.RFC3339), string(p.RecordedBy), p.Notes,
	)
	if err != nil {
		return nil, fmt.Errorf("insert payment: %w", err)
	}
	return p, nil
}

// ----- Balance & history -----

// InstructorBalance is the "we owe Dave £340" tile at the top of the
// instructor-pay screen.
type InstructorBalance struct {
	InstructorID  domain.UserID
	TotalEarned   domain.Money
	TotalPaid     domain.Money
	Outstanding   domain.Money // earned − paid (positive = school owes them)
}

func GetInstructorBalance(ctx context.Context, scope *tenant.Scope, instructorID domain.UserID) (InstructorBalance, error) {
	var earned, paid sql.NullInt64
	err := scope.Conn().QueryRowContext(ctx, `
		SELECT
		    (SELECT COALESCE(SUM(amount_pence), 0) FROM instructor_earnings
		      WHERE school_id = ? AND instructor_id = ? AND voided_at IS NULL),
		    (SELECT COALESCE(SUM(amount_pence), 0) FROM instructor_payments
		      WHERE school_id = ? AND instructor_id = ?)
	`, string(scope.SchoolID()), string(instructorID),
		string(scope.SchoolID()), string(instructorID),
	).Scan(&earned, &paid)
	if err != nil {
		return InstructorBalance{}, err
	}
	return InstructorBalance{
		InstructorID: instructorID,
		TotalEarned:  domain.Money(earned.Int64),
		TotalPaid:    domain.Money(paid.Int64),
		Outstanding:  domain.Money(earned.Int64 - paid.Int64),
	}, nil
}

// AllOutstanding returns one row per instructor with non-zero (or any)
// activity. Used to drive the "what we owe" screen — a manager view of the
// whole school.
type Outstanding struct {
	InstructorID   domain.UserID
	InstructorName string
	TotalEarned    domain.Money
	TotalPaid      domain.Money
	Balance        domain.Money
}

func AllOutstanding(ctx context.Context, scope *tenant.Scope) ([]Outstanding, error) {
	const q = `
		SELECT u.id, u.name,
		       COALESCE((SELECT SUM(amount_pence) FROM instructor_earnings ie
		                 WHERE ie.instructor_id = u.id AND ie.school_id = u.school_id AND ie.voided_at IS NULL), 0),
		       COALESCE((SELECT SUM(amount_pence) FROM instructor_payments ip
		                 WHERE ip.instructor_id = u.id AND ip.school_id = u.school_id), 0)
		FROM users u
		WHERE u.school_id = ? AND u.role = 'instructor'
		ORDER BY u.name ASC
	`
	rows, err := scope.Conn().QueryContext(ctx, q, string(scope.SchoolID()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Outstanding
	for rows.Next() {
		var o Outstanding
		var earned, paid int64
		if err := rows.Scan(&o.InstructorID, &o.InstructorName, &earned, &paid); err != nil {
			return nil, err
		}
		o.TotalEarned = domain.Money(earned)
		o.TotalPaid = domain.Money(paid)
		o.Balance = domain.Money(earned - paid)
		out = append(out, o)
	}
	return out, rows.Err()
}

// ----- helpers -----

func requireInstructor(ctx context.Context, scope *tenant.Scope, id domain.UserID) error {
	var n int
	err := scope.Conn().QueryRowContext(ctx,
		`SELECT 1 FROM users WHERE id = ? AND school_id = ? AND role = 'instructor'`,
		string(id), string(scope.SchoolID()),
	).Scan(&n)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrInstructorNotFound
	}
	return err
}

func validBasis(b domain.PayBasis) bool {
	switch b {
	case domain.BasisPercentage, domain.BasisPerDay, domain.BasisPerSession,
		domain.BasisPerHour, domain.BasisPerStudent, domain.BasisSalary:
		return true
	}
	return false
}

func validateMethod(m domain.PaymentMethod) error {
	switch m {
	case domain.PayCash, domain.PayBankTransfer, domain.PayCardInPerson, domain.PayOther:
		return nil
	default:
		return fmt.Errorf("instructorpay: invalid payment method %q", m)
	}
}
