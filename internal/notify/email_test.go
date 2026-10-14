package notify

import (
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/email"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// captureSender records every message instead of sending — the test double
// for the email.Sender seam.
type captureSender struct {
	msgs    []email.Message
	failAll bool
}

func (c *captureSender) Send(_ context.Context, m email.Message) error {
	if c.failAll {
		return errFail
	}
	c.msgs = append(c.msgs, m)
	return nil
}

var errFail = &sendErr{}

type sendErr struct{}

func (*sendErr) Error() string { return "smtp down" }

func emailFixture(t *testing.T) (*sql.DB, *tenant.Scope) {
	t.Helper()
	ctx := context.Background()
	d, err := db.Open(t.TempDir() + "/n.db")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	now := time.Now().UTC().Format(time.RFC3339)
	exec := func(q string, args ...any) {
		if _, err := d.ExecContext(ctx, q, args...); err != nil {
			t.Fatalf("seed %q: %v", q, err)
		}
	}
	exec(`INSERT INTO schools (id, name, region, test_body_label, created_at) VALUES ('sch1','Lagan Valley','NI','DVA',?)`, now)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	      VALUES ('u1','sch1','sam@rider.test','','Sam Rider','student','active',?)`, now)
	exec(`INSERT INTO events (id, school_id, kind, subject_id, payload, created_at)
	      VALUES ('ev1','sch1',?, 'bk1', ?, ?)`, EventBookingCreated,
		`{"courseName":"CBT 125","startsAt":"2026-07-01T09:00:00Z"}`, now)
	return d, tenant.NewScope(d, "sch1")
}

func pendingEmailCount(t *testing.T, d *sql.DB) int {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM notifications WHERE channel='email' AND status='pending'`).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	return n
}

func TestQueueEmail_RespectsPref(t *testing.T) {
	ctx := context.Background()
	d, scope := emailFixture(t)

	// Default prefs: email on → a pending email row is queued.
	if err := QueueEmail(ctx, scope, "ev1", "u1", CategoryBooking); err != nil {
		t.Fatalf("queue: %v", err)
	}
	if got := pendingEmailCount(t, d); got != 1 {
		t.Fatalf("pending email rows = %d, want 1", got)
	}

	// Turn the email pref off for this category → nothing queued.
	if _, err := d.ExecContext(ctx, `
		INSERT INTO notification_prefs (school_id, user_id, category, in_app, email, push, sms, updated_at)
		VALUES ('sch1','u1',?,1,0,1,0,?)`, CategoryBooking, time.Now().UTC().Format(time.RFC3339)); err != nil {
		t.Fatalf("prefs: %v", err)
	}
	if err := QueueEmail(ctx, scope, "ev1", "u1", CategoryBooking); err != nil {
		t.Fatalf("queue (off): %v", err)
	}
	if got := pendingEmailCount(t, d); got != 1 {
		t.Errorf("pending email rows = %d, want still 1 (email pref off should not queue)", got)
	}
}

func TestDispatchEmails_SendsMarksAndIsIdempotent(t *testing.T) {
	ctx := context.Background()
	d, scope := emailFixture(t)
	if err := QueueEmail(ctx, scope, "ev1", "u1", CategoryBooking); err != nil {
		t.Fatalf("queue: %v", err)
	}

	cap := &captureSender{}
	n, err := DispatchEmails(ctx, d, cap, time.Now(), 0)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if n != 1 || len(cap.msgs) != 1 {
		t.Fatalf("sent=%d captured=%d, want 1/1", n, len(cap.msgs))
	}
	m := cap.msgs[0]
	if m.To != "sam@rider.test" {
		t.Errorf("To = %q", m.To)
	}
	if !strings.Contains(m.Subject, "Booking confirmed") || !strings.Contains(m.Body, "CBT 125") {
		t.Errorf("render: subject=%q body=%q", m.Subject, m.Body)
	}

	// Row is now 'sent' — a second drain sends nothing (idempotent).
	if got := pendingEmailCount(t, d); got != 0 {
		t.Errorf("pending after send = %d, want 0", got)
	}
	n2, _ := DispatchEmails(ctx, d, cap, time.Now(), 0)
	if n2 != 0 || len(cap.msgs) != 1 {
		t.Errorf("second drain sent=%d captured=%d, want 0/1", n2, len(cap.msgs))
	}
}

func TestDispatchEmails_MarksFailedOnSenderError(t *testing.T) {
	ctx := context.Background()
	d, scope := emailFixture(t)
	if err := QueueEmail(ctx, scope, "ev1", "u1", CategoryBooking); err != nil {
		t.Fatalf("queue: %v", err)
	}
	n, err := DispatchEmails(ctx, d, &captureSender{failAll: true}, time.Now(), 0)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if n != 0 {
		t.Errorf("sent=%d, want 0 on failure", n)
	}
	var status, reason string
	if err := d.QueryRow(`SELECT status, COALESCE(failure_reason,'') FROM notifications WHERE channel='email'`).
		Scan(&status, &reason); err != nil {
		t.Fatalf("read: %v", err)
	}
	if status != "failed" || !strings.Contains(reason, "smtp down") {
		t.Errorf("status=%q reason=%q, want failed / smtp down (no infinite retry)", status, reason)
	}
}

func TestRenderEmail_KnownAndUnknownKinds(t *testing.T) {
	subj, body := renderEmail("session.reminder_24h",
		`{"courseName":"CBT 125","startsAt":"2026-07-01T09:00:00Z"}`, "Sam Rider", "Lagan Valley")
	if !strings.Contains(subj, "tomorrow") || !strings.Contains(body, "Hi Sam,") || !strings.Contains(body, "Lagan Valley") {
		t.Errorf("reminder render: subj=%q body=%q", subj, body)
	}
	// Unknown kind must not panic and should produce a generic nudge.
	subj2, body2 := renderEmail("something.new", "", "", "Lagan Valley")
	if subj2 == "" || !strings.Contains(body2, "Hi there,") {
		t.Errorf("fallback render: subj=%q body=%q", subj2, body2)
	}
}
