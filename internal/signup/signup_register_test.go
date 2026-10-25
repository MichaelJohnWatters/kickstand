package signup_test

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/signup"
)

func newSignupDB(t *testing.T) (*sql.DB, domain.SchoolID) {
	t.Helper()
	ctx := context.Background()
	d, err := db.Open(t.TempDir() + "/s.db")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	const school = domain.SchoolID("sch1")
	if _, err := d.ExecContext(ctx,
		`INSERT INTO schools (id, name, region, test_body_label, onboarding_mode, created_at)
		 VALUES (?, 'Test', 'NI', 'DVA', 'open', ?)`,
		string(school), time.Now().UTC().Format(time.RFC3339)); err != nil {
		t.Fatalf("insert school: %v", err)
	}
	return d, school
}

// Omitting the optional, CHECK-constrained profile fields must store NULL and
// succeed — not fail the student_profiles INSERT with a CHECK violation.
func TestRegister_OmittedEnumsStoreNull(t *testing.T) {
	ctx := context.Background()
	d, school := newSignupDB(t)

	id, err := signup.Register(ctx, d, signup.SignupRequest{
		SchoolID: school,
		Name:     "Sam Rider",
		Email:    "sam@test.co",
		Password: "a-good-password",
		// TransmissionPreference / LicenceCategoryPursued intentionally omitted.
	})
	if err != nil {
		t.Fatalf("register with omitted enums should succeed, got: %v", err)
	}
	if id == nil {
		t.Fatal("nil identity")
	}
	var transNull, licNull, dobNull sql.NullString
	if err := d.QueryRowContext(ctx,
		`SELECT transmission_preference, licence_category_pursued, rider_date_of_birth
		 FROM student_profiles WHERE user_id = ?`, string(id.UserID)).
		Scan(&transNull, &licNull, &dobNull); err != nil {
		t.Fatalf("read profile: %v", err)
	}
	if transNull.Valid || licNull.Valid || dobNull.Valid {
		t.Errorf("expected NULL for omitted fields, got trans=%v lic=%v dob=%v", transNull, licNull, dobNull)
	}
}

// A non-empty but invalid enum value is rejected up front with ErrInvalidField.
func TestRegister_InvalidEnumRejected(t *testing.T) {
	ctx := context.Background()
	d, school := newSignupDB(t)

	_, err := signup.Register(ctx, d, signup.SignupRequest{
		SchoolID:               school,
		Name:                   "Bad Enum",
		Email:                  "bad@test.co",
		Password:               "a-good-password",
		TransmissionPreference: domain.Transmission("automatic"), // not manual/auto
	})
	if !errors.Is(err, signup.ErrInvalidField) {
		t.Fatalf("expected ErrInvalidField, got %v", err)
	}
}

// A valid enum value still works and is persisted.
func TestRegister_ValidEnumPersisted(t *testing.T) {
	ctx := context.Background()
	d, school := newSignupDB(t)

	id, err := signup.Register(ctx, d, signup.SignupRequest{
		SchoolID:               school,
		Name:                   "Good Enum",
		Email:                  "good@test.co",
		Password:               "a-good-password",
		TransmissionPreference: domain.Transmission("auto"),
		LicenceCategoryPursued: domain.LicenceCategory("A2"),
	})
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	var trans, lic string
	if err := d.QueryRowContext(ctx,
		`SELECT transmission_preference, licence_category_pursued FROM student_profiles WHERE user_id = ?`,
		string(id.UserID)).Scan(&trans, &lic); err != nil {
		t.Fatalf("read profile: %v", err)
	}
	if trans != "auto" || lic != "A2" {
		t.Errorf("got trans=%q lic=%q, want auto/A2", trans, lic)
	}
}

// A too-short password is rejected before any DB write.
func TestRegister_ShortPasswordRejected(t *testing.T) {
	ctx := context.Background()
	d, school := newSignupDB(t)

	_, err := signup.Register(ctx, d, signup.SignupRequest{
		SchoolID: school,
		Name:     "Shorty",
		Email:    "short@test.co",
		Password: "short",
	})
	if !errors.Is(err, auth.ErrPasswordTooShort) {
		t.Fatalf("expected ErrPasswordTooShort, got %v", err)
	}
}
