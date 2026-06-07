package ledger_test

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/ledger"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

type fixture struct {
	t       *testing.T
	db      *sql.DB
	scope   *tenant.Scope
	now     time.Time
	school  domain.SchoolID
	admin   domain.UserID
	student domain.UserID
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	d, err := db.Open(t.TempDir() + "/ledger.db")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	if err := db.Migrate(context.Background(), d); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	f := &fixture{
		t:       t,
		db:      d,
		now:     time.Date(2026, 6, 6, 9, 0, 0, 0, time.UTC),
		school:  "school_t",
		admin:   "user_admin",
		student: "user_student",
	}
	f.scope = tenant.NewScope(d, f.school)
	f.seed()
	return f
}

func (f *fixture) seed() {
	f.t.Helper()
	at := f.now.Format(time.RFC3339)
	exec := func(q string, args ...any) {
		f.t.Helper()
		if _, err := f.db.Exec(q, args...); err != nil {
			f.t.Fatalf("seed %q: %v", q, err)
		}
	}
	exec(`INSERT INTO schools (id, name, region, test_body_label, created_at)
	      VALUES (?, ?, 'NI', 'DVA', ?)`, f.school, "Test", at)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, created_at)
	      VALUES (?, ?, ?, '', ?, 'admin', ?)`, f.admin, f.school, "admin@t", "Admin", at)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	      VALUES (?, ?, ?, '', ?, 'student', 'active', ?)`, f.student, f.school, "stu@t", "Stu", at)
}

// ----- Tests -----

func TestRecordCharge_HappyPath(t *testing.T) {
	f := newFixture(t)
	c, err := ledger.RecordCharge(context.Background(), f.scope, ledger.RecordChargeRequest{
		StudentID:   f.student,
		AmountPence: 13000,
		Description: "CBT 125 day",
		IncurredAt:  f.now,
		CreatedBy:   f.admin,
	})
	if err != nil {
		t.Fatalf("record: %v", err)
	}
	if c.AmountPence != 13000 {
		t.Errorf("amount: %d", c.AmountPence)
	}

	bal, err := ledger.GetStudentBalance(context.Background(), f.scope, f.student)
	if err != nil {
		t.Fatalf("balance: %v", err)
	}
	if bal.Balance != 13000 {
		t.Errorf("expected balance 13000, got %d", bal.Balance)
	}
}

func TestRecordCharge_RejectsZeroOrNegative(t *testing.T) {
	f := newFixture(t)
	for _, amt := range []domain.Money{0, -1, -100} {
		_, err := ledger.RecordCharge(context.Background(), f.scope, ledger.RecordChargeRequest{
			StudentID:   f.student,
			AmountPence: amt,
			Description: "x",
			IncurredAt:  f.now,
			CreatedBy:   f.admin,
		})
		if !errors.Is(err, ledger.ErrAmountInvalid) {
			t.Errorf("amount %d: expected ErrAmountInvalid, got %v", amt, err)
		}
	}
}

func TestRecordCharge_RequiresStudent(t *testing.T) {
	f := newFixture(t)
	_, err := ledger.RecordCharge(context.Background(), f.scope, ledger.RecordChargeRequest{
		StudentID:   "nobody",
		AmountPence: 100,
		Description: "x",
		IncurredAt:  f.now,
		CreatedBy:   f.admin,
	})
	if !errors.Is(err, ledger.ErrStudentNotFound) {
		t.Errorf("expected ErrStudentNotFound, got %v", err)
	}
}

func TestRecordPayment_ReducesBalance(t *testing.T) {
	f := newFixture(t)
	if _, err := ledger.RecordCharge(context.Background(), f.scope, ledger.RecordChargeRequest{
		StudentID:   f.student,
		AmountPence: 13000,
		Description: "CBT",
		IncurredAt:  f.now,
		CreatedBy:   f.admin,
	}); err != nil {
		t.Fatal(err)
	}
	res, err := ledger.RecordPayment(context.Background(), f.scope, ledger.RecordPaymentRequest{
		StudentID:   f.student,
		AmountPence: 5000,
		Method:      domain.PayCash,
		ReceivedAt:  f.now,
		RecordedBy:  f.admin,
	})
	if err != nil {
		t.Fatalf("payment: %v", err)
	}
	if res.NewBalance != 8000 {
		t.Errorf("expected new balance 8000, got %d", res.NewBalance)
	}
}

func TestRecordPayment_InvalidMethod(t *testing.T) {
	f := newFixture(t)
	_, err := ledger.RecordPayment(context.Background(), f.scope, ledger.RecordPaymentRequest{
		StudentID:   f.student,
		AmountPence: 100,
		Method:      domain.PaymentMethod("crypto"),
		ReceivedAt:  f.now,
		RecordedBy:  f.admin,
	})
	if err == nil {
		t.Fatalf("expected error for invalid method")
	}
}

func TestVoidCharge_RemovedFromBalance(t *testing.T) {
	f := newFixture(t)
	c, err := ledger.RecordCharge(context.Background(), f.scope, ledger.RecordChargeRequest{
		StudentID:   f.student,
		AmountPence: 5000,
		Description: "oops",
		IncurredAt:  f.now,
		CreatedBy:   f.admin,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := ledger.VoidCharge(context.Background(), f.scope, ledger.VoidChargeRequest{
		ChargeID: c.ID, VoidedBy: f.admin, Reason: "duplicate",
	}); err != nil {
		t.Fatalf("void: %v", err)
	}
	bal, _ := ledger.GetStudentBalance(context.Background(), f.scope, f.student)
	if bal.Balance != 0 {
		t.Errorf("expected 0 balance after void, got %d", bal.Balance)
	}
}

func TestVoidCharge_DoubleVoidRejected(t *testing.T) {
	f := newFixture(t)
	c, _ := ledger.RecordCharge(context.Background(), f.scope, ledger.RecordChargeRequest{
		StudentID:   f.student,
		AmountPence: 100,
		Description: "x",
		IncurredAt:  f.now,
		CreatedBy:   f.admin,
	})
	req := ledger.VoidChargeRequest{ChargeID: c.ID, VoidedBy: f.admin, Reason: "x"}
	if err := ledger.VoidCharge(context.Background(), f.scope, req); err != nil {
		t.Fatal(err)
	}
	err := ledger.VoidCharge(context.Background(), f.scope, req)
	if !errors.Is(err, ledger.ErrAlreadyVoided) {
		t.Fatalf("expected ErrAlreadyVoided, got %v", err)
	}
}

func TestVoidCharge_NotFound(t *testing.T) {
	f := newFixture(t)
	err := ledger.VoidCharge(context.Background(), f.scope, ledger.VoidChargeRequest{
		ChargeID: "nope", VoidedBy: f.admin,
	})
	if !errors.Is(err, ledger.ErrChargeNotFound) {
		t.Fatalf("expected ErrChargeNotFound, got %v", err)
	}
}

func TestVoidPayment_RemovedFromBalance(t *testing.T) {
	f := newFixture(t)
	if _, err := ledger.RecordCharge(context.Background(), f.scope, ledger.RecordChargeRequest{
		StudentID: f.student, AmountPence: 10000, Description: "CBT",
		IncurredAt: f.now, CreatedBy: f.admin,
	}); err != nil {
		t.Fatal(err)
	}
	p, err := ledger.RecordPayment(context.Background(), f.scope, ledger.RecordPaymentRequest{
		StudentID: f.student, AmountPence: 4000, Method: domain.PayCash,
		ReceivedAt: f.now, RecordedBy: f.admin,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := ledger.VoidPayment(context.Background(), f.scope, ledger.VoidPaymentRequest{
		PaymentID: p.Payment.ID, VoidedBy: f.admin, Reason: "mistaken deposit",
	}); err != nil {
		t.Fatalf("void payment: %v", err)
	}
	bal, _ := ledger.GetStudentBalance(context.Background(), f.scope, f.student)
	if bal.Balance != 10000 {
		t.Errorf("expected balance back to 10000 after voiding payment, got %d", bal.Balance)
	}
}

func TestGetStudentLedger_OrderedReverseChronological(t *testing.T) {
	f := newFixture(t)
	t1 := f.now
	t2 := f.now.Add(time.Hour)
	t3 := f.now.Add(2 * time.Hour)

	if _, err := ledger.RecordCharge(context.Background(), f.scope, ledger.RecordChargeRequest{
		StudentID: f.student, AmountPence: 10000, Description: "old charge",
		IncurredAt: t1, CreatedBy: f.admin,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := ledger.RecordPayment(context.Background(), f.scope, ledger.RecordPaymentRequest{
		StudentID: f.student, AmountPence: 5000, Method: domain.PayCash,
		ReceivedAt: t2, RecordedBy: f.admin,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := ledger.RecordCharge(context.Background(), f.scope, ledger.RecordChargeRequest{
		StudentID: f.student, AmountPence: 2000, Description: "newer charge",
		IncurredAt: t3, CreatedBy: f.admin,
	}); err != nil {
		t.Fatal(err)
	}

	entries, err := ledger.GetStudentLedger(context.Background(), f.scope, f.student)
	if err != nil {
		t.Fatalf("ledger: %v", err)
	}
	if len(entries) != 3 {
		t.Fatalf("expected 3 entries, got %d", len(entries))
	}
	if entries[0].Description != "newer charge" {
		t.Errorf("expected newest first, got %q", entries[0].Description)
	}
	if entries[2].Description != "old charge" {
		t.Errorf("expected oldest last, got %q", entries[2].Description)
	}
}

func TestGetStudentLedger_VoidedFlagSurfaced(t *testing.T) {
	f := newFixture(t)
	c, _ := ledger.RecordCharge(context.Background(), f.scope, ledger.RecordChargeRequest{
		StudentID: f.student, AmountPence: 1000, Description: "x",
		IncurredAt: f.now, CreatedBy: f.admin,
	})
	if err := ledger.VoidCharge(context.Background(), f.scope, ledger.VoidChargeRequest{
		ChargeID: c.ID, VoidedBy: f.admin,
	}); err != nil {
		t.Fatal(err)
	}
	entries, _ := ledger.GetStudentLedger(context.Background(), f.scope, f.student)
	if len(entries) != 1 {
		t.Fatalf("expected 1 entry (voided still shown), got %d", len(entries))
	}
	if !entries[0].Voided {
		t.Errorf("expected Voided=true")
	}
}

func TestLedger_TenantIsolation(t *testing.T) {
	f := newFixture(t)
	if _, err := ledger.RecordCharge(context.Background(), f.scope, ledger.RecordChargeRequest{
		StudentID: f.student, AmountPence: 5000, Description: "CBT",
		IncurredAt: f.now, CreatedBy: f.admin,
	}); err != nil {
		t.Fatal(err)
	}
	other := tenant.NewScope(f.db, domain.SchoolID("school_other"))
	bal, err := ledger.GetStudentBalance(context.Background(), other, f.student)
	if err != nil {
		t.Fatalf("balance: %v", err)
	}
	if bal.Balance != 0 {
		t.Errorf("expected isolated balance 0, got %d", bal.Balance)
	}
}
