package availability_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/availability"
	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

const (
	testSchool = domain.SchoolID("sch1")
	instA      = domain.UserID("insA")
	instB      = domain.UserID("insB")
)

// newTestScope opens a fresh migrated SQLite DB with one school and two
// instructors, returning a tenant scope for that school.
func newTestScope(t *testing.T) *tenant.Scope {
	t.Helper()
	ctx := context.Background()
	d, err := db.Open(t.TempDir() + "/test.db")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	now := time.Now().UTC().Format(time.RFC3339)
	if _, err := d.ExecContext(ctx,
		`INSERT INTO schools (id, name, region, test_body_label, created_at) VALUES (?, 'Test', 'NI', 'DVA', ?)`,
		string(testSchool), now); err != nil {
		t.Fatalf("insert school: %v", err)
	}
	for _, u := range []domain.UserID{instA, instB} {
		if _, err := d.ExecContext(ctx,
			`INSERT INTO users (id, school_id, email, password_hash, name, role, created_at)
			 VALUES (?, ?, ?, '', ?, 'instructor', ?)`,
			string(u), string(testSchool), string(u)+"@test", string(u), now); err != nil {
			t.Fatalf("insert user %s: %v", u, err)
		}
	}
	return tenant.NewScope(d, testSchool)
}

func mkSlot(t *testing.T, scope *tenant.Scope, owner domain.UserID) domain.AvailabilityID {
	t.Helper()
	slot, err := availability.CreateRecurringSlot(context.Background(), scope, availability.CreateRecurringRequest{
		InstructorID: owner, Weekday: 1, StartsAtLocal: "09:00", EndsAtLocal: "12:00",
	})
	if err != nil {
		t.Fatalf("create slot: %v", err)
	}
	return slot.ID
}

func slotExists(t *testing.T, scope *tenant.Scope, owner domain.UserID, id domain.AvailabilityID) bool {
	t.Helper()
	slots, err := availability.ListRecurringSlots(context.Background(), scope, owner)
	if err != nil {
		t.Fatalf("list slots: %v", err)
	}
	for _, s := range slots {
		if s.ID == id {
			return true
		}
	}
	return false
}

func TestDeleteRecurringSlot_OwnershipGuard(t *testing.T) {
	ctx := context.Background()
	scope := newTestScope(t)
	slotA := mkSlot(t, scope, instA)

	// Another instructor must NOT be able to delete A's slot — and the
	// mismatch is reported as not-found, never confirming the row exists.
	if err := availability.DeleteRecurringSlot(ctx, scope, slotA, instB); !errors.Is(err, availability.ErrNotFound) {
		t.Fatalf("cross-instructor delete: got %v, want ErrNotFound", err)
	}
	if !slotExists(t, scope, instA, slotA) {
		t.Fatal("slot A was deleted by a non-owning instructor")
	}

	// The owning instructor can delete it.
	if err := availability.DeleteRecurringSlot(ctx, scope, slotA, instA); err != nil {
		t.Fatalf("owner delete: %v", err)
	}
	if slotExists(t, scope, instA, slotA) {
		t.Fatal("slot A survived owner delete")
	}

	// Admin/owner (empty guard) can delete any instructor's slot.
	slotB := mkSlot(t, scope, instB)
	if err := availability.DeleteRecurringSlot(ctx, scope, slotB, ""); err != nil {
		t.Fatalf("admin delete: %v", err)
	}
	if slotExists(t, scope, instB, slotB) {
		t.Fatal("slot B survived admin delete")
	}
}

func TestDeleteTimeOff_OwnershipGuard(t *testing.T) {
	ctx := context.Background()
	scope := newTestScope(t)
	start := time.Now().UTC().Add(24 * time.Hour)
	mk := func(owner domain.UserID) domain.TimeOffID {
		to, err := availability.AddTimeOff(ctx, scope, availability.AddTimeOffRequest{
			InstructorID: owner, StartsAt: start, EndsAt: start.Add(time.Hour), Reason: "x",
		})
		if err != nil {
			t.Fatalf("add time off: %v", err)
		}
		return to.ID
	}
	exists := func(owner domain.UserID, id domain.TimeOffID) bool {
		rows, err := availability.ListTimeOff(ctx, scope, owner)
		if err != nil {
			t.Fatalf("list time off: %v", err)
		}
		for _, r := range rows {
			if r.ID == id {
				return true
			}
		}
		return false
	}

	toA := mk(instA)
	if err := availability.DeleteTimeOff(ctx, scope, toA, instB); !errors.Is(err, availability.ErrNotFound) {
		t.Fatalf("cross-instructor delete: got %v, want ErrNotFound", err)
	}
	if !exists(instA, toA) {
		t.Fatal("time-off A deleted by non-owner")
	}
	if err := availability.DeleteTimeOff(ctx, scope, toA, instA); err != nil {
		t.Fatalf("owner delete: %v", err)
	}
	if exists(instA, toA) {
		t.Fatal("time-off A survived owner delete")
	}
	toB := mk(instB)
	if err := availability.DeleteTimeOff(ctx, scope, toB, ""); err != nil {
		t.Fatalf("admin delete: %v", err)
	}
	if exists(instB, toB) {
		t.Fatal("time-off B survived admin delete")
	}
}
