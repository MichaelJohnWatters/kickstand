// Package ledger implements the manual money tracking the plan describes:
// charges (money a student incurred) and payments (money received), with a
// derived balance per student. No card processing — Stripe is phase-2 and
// will plug in as another payment method, not a model change.
//
// Money is always INTEGER pence. Never floats — accountants and floating
// point don't mix.
//
// Permissions live in the HTTP layer, not the engine. The engine takes a
// recording user id and trusts the caller has already enforced role rules
// (admin-only for void; instructor-can-record gated by school setting).
// This keeps the engine pure and testable without weaving role checks
// through every function.
package ledger

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// ----- Charges -----

type RecordChargeRequest struct {
	StudentID   domain.UserID
	BookingID   domain.BookingID // optional — empty if not tied to a booking
	AmountPence domain.Money
	Description string
	IncurredAt  time.Time
	CreatedBy   domain.UserID
}

var (
	ErrStudentNotFound = errors.New("ledger: student not found in this school")
	ErrChargeNotFound  = errors.New("ledger: charge not found in this school")
	ErrPaymentNotFound = errors.New("ledger: payment not found in this school")
	ErrAlreadyVoided   = errors.New("ledger: already voided")
	ErrAmountInvalid   = errors.New("ledger: amount must be a positive integer")
)

func RecordCharge(ctx context.Context, scope *tenant.Scope, req RecordChargeRequest) (*domain.Charge, error) {
	return recordChargeAt(ctx, scope, req, time.Now)
}

func recordChargeAt(ctx context.Context, scope *tenant.Scope, req RecordChargeRequest, nowFn func() time.Time) (*domain.Charge, error) {
	if req.AmountPence <= 0 {
		return nil, ErrAmountInvalid
	}
	if req.Description == "" {
		return nil, fmt.Errorf("ledger: description required")
	}
	if err := requireStudent(ctx, scope, req.StudentID); err != nil {
		return nil, err
	}

	now := nowFn().UTC()
	c := domain.Charge{
		ID:          domain.ChargeID(domain.NewID()),
		SchoolID:    scope.SchoolID(),
		StudentID:   req.StudentID,
		BookingID:   req.BookingID,
		AmountPence: req.AmountPence,
		Description: req.Description,
		IncurredAt:  req.IncurredAt.UTC(),
		CreatedAt:   now,
		CreatedBy:   req.CreatedBy,
	}
	var bookingArg any
	if req.BookingID != "" {
		bookingArg = string(req.BookingID)
	}
	_, err := scope.Conn().ExecContext(ctx, `
		INSERT INTO charges (id, school_id, student_id, booking_id, amount_pence,
		    description, incurred_at, created_at, created_by)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, string(c.ID), string(c.SchoolID), string(c.StudentID), bookingArg,
		int64(c.AmountPence), c.Description,
		c.IncurredAt.Format(time.RFC3339),
		c.CreatedAt.Format(time.RFC3339),
		string(c.CreatedBy),
	)
	if err != nil {
		return nil, fmt.Errorf("insert charge: %w", err)
	}
	return &c, nil
}

type VoidChargeRequest struct {
	ChargeID domain.ChargeID
	VoidedBy domain.UserID
	Reason   string
}

func VoidCharge(ctx context.Context, scope *tenant.Scope, req VoidChargeRequest) error {
	return voidChargeAt(ctx, scope, req, time.Now)
}

func voidChargeAt(ctx context.Context, scope *tenant.Scope, req VoidChargeRequest, nowFn func() time.Time) error {
	res, err := scope.Conn().ExecContext(ctx, `
		UPDATE charges
		   SET voided_at = ?, voided_by = ?, void_reason = ?
		 WHERE id = ? AND school_id = ? AND voided_at IS NULL
	`, nowFn().UTC().Format(time.RFC3339), string(req.VoidedBy), req.Reason,
		string(req.ChargeID), string(scope.SchoolID()))
	if err != nil {
		return fmt.Errorf("void charge: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		// Either doesn't exist or already voided. Tell them which.
		var voidedAt sql.NullString
		err := scope.Conn().QueryRowContext(ctx,
			`SELECT voided_at FROM charges WHERE id = ? AND school_id = ?`,
			string(req.ChargeID), string(scope.SchoolID())).Scan(&voidedAt)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrChargeNotFound
		}
		if err != nil {
			return err
		}
		return ErrAlreadyVoided
	}
	return nil
}

// ----- Payments -----

type RecordPaymentRequest struct {
	StudentID   domain.UserID
	AmountPence domain.Money
	Method      domain.PaymentMethod
	ReceivedAt  time.Time
	RecordedBy  domain.UserID
	Notes       string
}

type RecordPaymentResult struct {
	Payment    domain.Payment
	NewBalance domain.Money
}

func RecordPayment(ctx context.Context, scope *tenant.Scope, req RecordPaymentRequest) (*RecordPaymentResult, error) {
	return recordPaymentAt(ctx, scope, req, time.Now)
}

func recordPaymentAt(ctx context.Context, scope *tenant.Scope, req RecordPaymentRequest, nowFn func() time.Time) (*RecordPaymentResult, error) {
	if req.AmountPence <= 0 {
		return nil, ErrAmountInvalid
	}
	if err := validateMethod(req.Method); err != nil {
		return nil, err
	}
	if err := requireStudent(ctx, scope, req.StudentID); err != nil {
		return nil, err
	}

	_ = nowFn // reserved for audit-trail timestamp; payments are dated by received_at
	p := domain.Payment{
		ID:          domain.PaymentID(domain.NewID()),
		SchoolID:    scope.SchoolID(),
		StudentID:   req.StudentID,
		AmountPence: req.AmountPence,
		Method:      req.Method,
		ReceivedAt:  req.ReceivedAt.UTC(),
		RecordedBy:  req.RecordedBy,
		Notes:       req.Notes,
	}
	var newBalance domain.Money
	err := scope.WithTx(ctx, func(tx *tenant.Scope) error {
		_, err := tx.Conn().ExecContext(ctx, `
			INSERT INTO payments (id, school_id, student_id, amount_pence, method,
			    received_at, recorded_by, notes)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		`, string(p.ID), string(p.SchoolID), string(p.StudentID),
			int64(p.AmountPence), string(p.Method),
			p.ReceivedAt.Format(time.RFC3339),
			string(p.RecordedBy), p.Notes,
		)
		if err != nil {
			return fmt.Errorf("insert payment: %w", err)
		}
		b, err := computeBalance(ctx, tx, req.StudentID)
		if err != nil {
			return err
		}
		newBalance = b
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &RecordPaymentResult{Payment: p, NewBalance: newBalance}, nil
}

type VoidPaymentRequest struct {
	PaymentID domain.PaymentID
	VoidedBy  domain.UserID
	Reason    string
}

func VoidPayment(ctx context.Context, scope *tenant.Scope, req VoidPaymentRequest) error {
	return voidPaymentAt(ctx, scope, req, time.Now)
}

func voidPaymentAt(ctx context.Context, scope *tenant.Scope, req VoidPaymentRequest, nowFn func() time.Time) error {
	res, err := scope.Conn().ExecContext(ctx, `
		UPDATE payments
		   SET voided_at = ?, voided_by = ?, void_reason = ?
		 WHERE id = ? AND school_id = ? AND voided_at IS NULL
	`, nowFn().UTC().Format(time.RFC3339), string(req.VoidedBy), req.Reason,
		string(req.PaymentID), string(scope.SchoolID()))
	if err != nil {
		return fmt.Errorf("void payment: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		var voidedAt sql.NullString
		err := scope.Conn().QueryRowContext(ctx,
			`SELECT voided_at FROM payments WHERE id = ? AND school_id = ?`,
			string(req.PaymentID), string(scope.SchoolID())).Scan(&voidedAt)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrPaymentNotFound
		}
		if err != nil {
			return err
		}
		return ErrAlreadyVoided
	}
	return nil
}

// ----- Balance & history -----

// StudentBalance is what a manager screen displays at the top: how much in,
// how much out, and the difference. Voided rows are excluded from totals.
type StudentBalance struct {
	StudentID    domain.UserID
	TotalCharged domain.Money
	TotalPaid    domain.Money
	Balance      domain.Money // positive = owes; negative = credit on account
}

func GetStudentBalance(ctx context.Context, scope *tenant.Scope, studentID domain.UserID) (StudentBalance, error) {
	var charged, paid sql.NullInt64
	err := scope.Conn().QueryRowContext(ctx, `
		SELECT
		    (SELECT COALESCE(SUM(amount_pence), 0) FROM charges
		      WHERE school_id = ? AND student_id = ? AND voided_at IS NULL),
		    (SELECT COALESCE(SUM(amount_pence), 0) FROM payments
		      WHERE school_id = ? AND student_id = ? AND voided_at IS NULL)
	`, string(scope.SchoolID()), string(studentID),
		string(scope.SchoolID()), string(studentID),
	).Scan(&charged, &paid)
	if err != nil {
		return StudentBalance{}, fmt.Errorf("balance: %w", err)
	}
	return StudentBalance{
		StudentID:    studentID,
		TotalCharged: domain.Money(charged.Int64),
		TotalPaid:    domain.Money(paid.Int64),
		Balance:      domain.Money(charged.Int64 - paid.Int64),
	}, nil
}

// LedgerEntry is one timeline item in the per-student ledger view. Charges
// and payments are interleaved by their dated date (incurred_at /
// received_at) so the UI can render a single chronological list.
type LedgerEntry struct {
	Kind        string // 'charge' | 'payment'
	ID          string
	AmountPence domain.Money // always positive; Kind tells direction
	Description string       // charge desc OR payment method label
	Method      string       // payments only
	At          time.Time    // incurred_at / received_at
	RecordedBy  domain.UserID
	Voided      bool
}

func GetStudentLedger(ctx context.Context, scope *tenant.Scope, studentID domain.UserID) ([]LedgerEntry, error) {
	const q = `
		SELECT 'charge' AS kind, id, amount_pence, description, '' AS method,
		       incurred_at AS at, created_by AS recorded_by,
		       (voided_at IS NOT NULL) AS voided
		FROM charges
		WHERE school_id = ? AND student_id = ?
		UNION ALL
		SELECT 'payment' AS kind, id, amount_pence,
		       COALESCE(notes, '') AS description, method,
		       received_at AS at, recorded_by,
		       (voided_at IS NOT NULL) AS voided
		FROM payments
		WHERE school_id = ? AND student_id = ?
		ORDER BY at DESC
	`
	rows, err := scope.Conn().QueryContext(ctx, q,
		string(scope.SchoolID()), string(studentID),
		string(scope.SchoolID()), string(studentID),
	)
	if err != nil {
		return nil, fmt.Errorf("ledger query: %w", err)
	}
	defer rows.Close()

	var out []LedgerEntry
	for rows.Next() {
		var (
			e         LedgerEntry
			atStr     string
			voidedInt int
		)
		if err := rows.Scan(&e.Kind, &e.ID, &e.AmountPence, &e.Description,
			&e.Method, &atStr, &e.RecordedBy, &voidedInt); err != nil {
			return nil, err
		}
		t, err := time.Parse(time.RFC3339, atStr)
		if err != nil {
			// Tolerate the SQLite alt format in case seed data uses it.
			t, err = time.Parse("2006-01-02 15:04:05", atStr)
			if err != nil {
				return nil, fmt.Errorf("parse ledger date %q: %w", atStr, err)
			}
		}
		e.At = t.UTC()
		e.Voided = voidedInt == 1
		out = append(out, e)
	}
	return out, rows.Err()
}

// ----- helpers -----

func computeBalance(ctx context.Context, scope *tenant.Scope, studentID domain.UserID) (domain.Money, error) {
	b, err := GetStudentBalance(ctx, scope, studentID)
	if err != nil {
		return 0, err
	}
	return b.Balance, nil
}

func requireStudent(ctx context.Context, scope *tenant.Scope, studentID domain.UserID) error {
	var n int
	err := scope.Conn().QueryRowContext(ctx,
		`SELECT 1 FROM users WHERE id = ? AND school_id = ? AND role = 'student'`,
		string(studentID), string(scope.SchoolID()),
	).Scan(&n)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrStudentNotFound
	}
	return err
}

func validateMethod(m domain.PaymentMethod) error {
	switch m {
	case domain.PayCash, domain.PayBankTransfer, domain.PayCardInPerson, domain.PayOther:
		return nil
	default:
		return fmt.Errorf("ledger: invalid payment method %q", m)
	}
}
