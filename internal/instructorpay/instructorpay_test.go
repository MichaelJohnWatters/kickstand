package instructorpay_test

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/instructorpay"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

type fixture struct {
	t          *testing.T
	db         *sql.DB
	scope      *tenant.Scope
	now        time.Time
	school     domain.SchoolID
	admin      domain.UserID
	instructor domain.UserID
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	d, err := db.Open(t.TempDir() + "/ip.db")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	if err := db.Migrate(context.Background(), d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	f := &fixture{
		t:          t,
		db:         d,
		now:        time.Date(2026, 6, 6, 9, 0, 0, 0, time.UTC),
		school:     "school_t",
		admin:      "user_admin",
		instructor: "user_dave",
	}
	f.scope = tenant.NewScope(d, f.school)
	at := f.now.Format(time.RFC3339)
	exec := func(q string, args ...any) {
		f.t.Helper()
		if _, err := f.db.Exec(q, args...); err != nil {
			f.t.Fatalf("seed %q: %v", q, err)
		}
	}
	exec(`INSERT INTO schools (id, name, region, test_body_label, created_at)
	      VALUES (?, ?, 'NI', 'DVA', ?)`, f.school, "T", at)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, created_at)
	      VALUES (?, ?, ?, '', ?, 'admin', ?)`, f.admin, f.school, "admin@t", "Admin", at)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, created_at)
	      VALUES (?, ?, ?, '', ?, 'instructor', ?)`, f.instructor, f.school, "dave@t", "Dave", at)
	return f
}

// ----- Tests -----

func TestSetPayModel_HappyPath(t *testing.T) {
	f := newFixture(t)
	if err := instructorpay.SetPayModel(context.Background(), f.scope, instructorpay.SetPayModelRequest{
		InstructorID: f.instructor,
		PayBasis:     domain.BasisPercentage,
		RateValue:    6000, // 60%
	}); err != nil {
		t.Fatalf("set: %v", err)
	}
	m, err := instructorpay.GetPayModel(context.Background(), f.scope, f.instructor)
	if err != nil {
		t.Fatal(err)
	}
	if m == nil || m.PayBasis != domain.BasisPercentage || m.RateValue != 6000 {
		t.Errorf("unexpected model: %+v", m)
	}
}

func TestSetPayModel_Replaces(t *testing.T) {
	f := newFixture(t)
	if err := instructorpay.SetPayModel(context.Background(), f.scope, instructorpay.SetPayModelRequest{
		InstructorID: f.instructor, PayBasis: domain.BasisPerDay, RateValue: 12000,
	}); err != nil {
		t.Fatal(err)
	}
	if err := instructorpay.SetPayModel(context.Background(), f.scope, instructorpay.SetPayModelRequest{
		InstructorID: f.instructor, PayBasis: domain.BasisPerHour, RateValue: 2500,
	}); err != nil {
		t.Fatal(err)
	}
	m, _ := instructorpay.GetPayModel(context.Background(), f.scope, f.instructor)
	if m.PayBasis != domain.BasisPerHour || m.RateValue != 2500 {
		t.Errorf("expected replacement, got %+v", m)
	}
}

func TestSetPayModel_RejectsInvalidBasis(t *testing.T) {
	f := newFixture(t)
	err := instructorpay.SetPayModel(context.Background(), f.scope, instructorpay.SetPayModelRequest{
		InstructorID: f.instructor, PayBasis: domain.PayBasis("hopeful"), RateValue: 100,
	})
	if !errors.Is(err, instructorpay.ErrInvalidBasis) {
		t.Errorf("expected ErrInvalidBasis, got %v", err)
	}
}

func TestRecordEarning_AddsToBalance(t *testing.T) {
	f := newFixture(t)
	if _, err := instructorpay.RecordEarning(context.Background(), f.scope, instructorpay.RecordEarningRequest{
		InstructorID: f.instructor,
		AmountPence:  8000,
		Basis:        domain.BasisPerDay,
		CreatedBy:    f.admin,
	}); err != nil {
		t.Fatalf("earn: %v", err)
	}
	b, _ := instructorpay.GetInstructorBalance(context.Background(), f.scope, f.instructor)
	if b.Outstanding != 8000 || b.TotalEarned != 8000 {
		t.Errorf("balance: %+v", b)
	}
}

func TestRecordPayment_ReducesOutstanding(t *testing.T) {
	f := newFixture(t)
	if _, err := instructorpay.RecordEarning(context.Background(), f.scope, instructorpay.RecordEarningRequest{
		InstructorID: f.instructor, AmountPence: 10000, Basis: domain.BasisPerDay, CreatedBy: f.admin,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := instructorpay.RecordPayment(context.Background(), f.scope, instructorpay.RecordPaymentRequest{
		InstructorID: f.instructor, AmountPence: 7000, Method: domain.PayBankTransfer,
		PaidAt: f.now, RecordedBy: f.admin,
	}); err != nil {
		t.Fatal(err)
	}
	b, _ := instructorpay.GetInstructorBalance(context.Background(), f.scope, f.instructor)
	if b.Outstanding != 3000 {
		t.Errorf("expected 3000 outstanding, got %d", b.Outstanding)
	}
}

func TestVoidEarning_RemovesFromBalance(t *testing.T) {
	f := newFixture(t)
	e, _ := instructorpay.RecordEarning(context.Background(), f.scope, instructorpay.RecordEarningRequest{
		InstructorID: f.instructor, AmountPence: 5000, Basis: domain.BasisPerDay, CreatedBy: f.admin,
	})
	if err := instructorpay.VoidEarning(context.Background(), f.scope, instructorpay.VoidEarningRequest{
		EarningID: e.ID, VoidedBy: f.admin, Reason: "duplicate",
	}); err != nil {
		t.Fatal(err)
	}
	b, _ := instructorpay.GetInstructorBalance(context.Background(), f.scope, f.instructor)
	if b.Outstanding != 0 {
		t.Errorf("expected 0 outstanding after void, got %d", b.Outstanding)
	}
}

func TestRecordEarning_WithSourceCharges(t *testing.T) {
	// Percentage earnings should link to source charges so the audit trail
	// shows how the amount was calculated.
	f := newFixture(t)
	// Insert a fake charge (we don't go through the ledger package; just put
	// the row in directly for the test).
	if _, err := f.db.Exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	                       VALUES ('stu','school_t','s@t','','S','student','active',?)`, f.now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(`INSERT INTO charges (id, school_id, student_id, amount_pence, description, incurred_at, created_at, created_by)
	                       VALUES ('charge1','school_t','stu',13000,'CBT',?,?,?)`,
		f.now.Format(time.RFC3339), f.now.Format(time.RFC3339), f.admin); err != nil {
		t.Fatal(err)
	}
	e, err := instructorpay.RecordEarning(context.Background(), f.scope, instructorpay.RecordEarningRequest{
		InstructorID:    f.instructor,
		AmountPence:     7800, // 60% of 13000
		Basis:           domain.BasisPercentage,
		Notes:           "60% of CBT charge",
		CreatedBy:       f.admin,
		SourceChargeIDs: []domain.ChargeID{"charge1"},
	})
	if err != nil {
		t.Fatalf("earn: %v", err)
	}
	// Verify the link row exists.
	var n int
	if err := f.db.QueryRow(`SELECT COUNT(*) FROM instructor_earning_sources WHERE earning_id = ?`, e.ID).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("expected 1 source-charge link, got %d", n)
	}
}

func TestAllOutstanding_ListsInstructors(t *testing.T) {
	f := newFixture(t)
	// Add a second instructor with no earnings.
	if _, err := f.db.Exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, created_at)
	                       VALUES ('user_priya','school_t','priya@t','','Priya','instructor',?)`, f.now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	// Earnings for Dave only.
	if _, err := instructorpay.RecordEarning(context.Background(), f.scope, instructorpay.RecordEarningRequest{
		InstructorID: f.instructor, AmountPence: 4000, Basis: domain.BasisPerDay, CreatedBy: f.admin,
	}); err != nil {
		t.Fatal(err)
	}

	out, err := instructorpay.AllOutstanding(context.Background(), f.scope)
	if err != nil {
		t.Fatal(err)
	}
	if len(out) != 2 {
		t.Fatalf("expected 2 instructors, got %d", len(out))
	}
	var daveBal, priyaBal domain.Money
	for _, o := range out {
		if o.InstructorID == f.instructor {
			daveBal = o.Balance
		} else {
			priyaBal = o.Balance
		}
	}
	if daveBal != 4000 || priyaBal != 0 {
		t.Errorf("balances: dave=%d priya=%d (want 4000, 0)", daveBal, priyaBal)
	}
}

func TestRecordEarning_RequiresInstructor(t *testing.T) {
	f := newFixture(t)
	_, err := instructorpay.RecordEarning(context.Background(), f.scope, instructorpay.RecordEarningRequest{
		InstructorID: "nope", AmountPence: 100, Basis: domain.BasisPerDay, CreatedBy: f.admin,
	})
	if !errors.Is(err, instructorpay.ErrInstructorNotFound) {
		t.Errorf("expected ErrInstructorNotFound, got %v", err)
	}
}

func TestRecordEarning_RejectsZeroAmount(t *testing.T) {
	f := newFixture(t)
	_, err := instructorpay.RecordEarning(context.Background(), f.scope, instructorpay.RecordEarningRequest{
		InstructorID: f.instructor, AmountPence: 0, Basis: domain.BasisPerDay, CreatedBy: f.admin,
	})
	if !errors.Is(err, instructorpay.ErrAmountInvalid) {
		t.Errorf("expected ErrAmountInvalid, got %v", err)
	}
}
