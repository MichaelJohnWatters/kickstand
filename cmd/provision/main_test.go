package main

import (
	"context"
	"database/sql"
	"testing"

	"github.com/michaeljohnwatters/kickstand/internal/db"
)

func newDB(t *testing.T) *sql.DB {
	t.Helper()
	d, err := db.Open(t.TempDir() + "/prov.db")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	if err := db.Migrate(context.Background(), d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return d
}

func validInput() provisionInput {
	return provisionInput{
		SchoolID:    "sch-1",
		OwnerID:     "owner-1",
		Name:        "Belfast Rider Co",
		Region:      "GB",
		Onboarding:  "approval",
		OwnerEmail:  "jo@belfastrider.co.uk",
		OwnerName:   "Jo Rider",
		FirebaseUID: "owner-1",
	}
}

func TestProvisionSchool_CreatesSchoolAndOwner(t *testing.T) {
	ctx := context.Background()
	d := newDB(t)
	if err := provisionSchool(ctx, d, validInput()); err != nil {
		t.Fatalf("provision: %v", err)
	}

	var name, region, testBody, onboarding string
	if err := d.QueryRow(
		`SELECT name, region, test_body_label, onboarding_mode FROM schools WHERE id = 'sch-1'`).
		Scan(&name, &region, &testBody, &onboarding); err != nil {
		t.Fatalf("read school: %v", err)
	}
	if name != "Belfast Rider Co" || region != "GB" || testBody != "DVSA" || onboarding != "approval" {
		t.Errorf("school = %q/%q/%q/%q, want Belfast Rider Co/GB/DVSA/approval", name, region, testBody, onboarding)
	}

	var email, role, status, fbUID string
	if err := d.QueryRow(
		`SELECT email, role, account_status, COALESCE(firebase_uid,'') FROM users WHERE id = 'owner-1'`).
		Scan(&email, &role, &status, &fbUID); err != nil {
		t.Fatalf("read owner: %v", err)
	}
	if role != "owner" || status != "active" || email != "jo@belfastrider.co.uk" || fbUID != "owner-1" {
		t.Errorf("owner = %q/%q/%q/fb=%q, want owner/active/email/owner-1", role, status, email, fbUID)
	}
}

func TestProvisionSchool_NIMapsToDVA(t *testing.T) {
	d := newDB(t)
	in := validInput()
	in.Region = "NI"
	if err := provisionSchool(context.Background(), d, in); err != nil {
		t.Fatalf("provision: %v", err)
	}
	var testBody string
	d.QueryRow(`SELECT test_body_label FROM schools WHERE id = 'sch-1'`).Scan(&testBody)
	if testBody != "DVA" {
		t.Errorf("NI test body = %q, want DVA", testBody)
	}
}

func TestProvisionSchool_NoFirebaseLeavesUIDNull(t *testing.T) {
	d := newDB(t)
	in := validInput()
	in.FirebaseUID = nil // -no-firebase
	if err := provisionSchool(context.Background(), d, in); err != nil {
		t.Fatalf("provision: %v", err)
	}
	var fbUID sql.NullString
	d.QueryRow(`SELECT firebase_uid FROM users WHERE id = 'owner-1'`).Scan(&fbUID)
	if fbUID.Valid {
		t.Errorf("firebase_uid = %q, want NULL", fbUID.String)
	}
}

func TestProvisionSchool_RefusesDuplicateSchoolID(t *testing.T) {
	ctx := context.Background()
	d := newDB(t)
	if err := provisionSchool(ctx, d, validInput()); err != nil {
		t.Fatalf("first provision: %v", err)
	}
	// Same school id, different owner id — must refuse, not clobber.
	in := validInput()
	in.OwnerID = "owner-2"
	in.FirebaseUID = "owner-2"
	in.OwnerEmail = "other@x.co"
	if err := provisionSchool(ctx, d, in); err == nil {
		t.Fatal("expected duplicate school id to be refused")
	}
	// The original owner is untouched; no second owner leaked in.
	var owners int
	d.QueryRow(`SELECT COUNT(*) FROM users WHERE school_id = 'sch-1'`).Scan(&owners)
	if owners != 1 {
		t.Errorf("owners for sch-1 = %d, want 1", owners)
	}
}

func TestProvisionInput_Validation(t *testing.T) {
	cases := []struct {
		name    string
		mut     func(*provisionInput)
		wantErr bool
	}{
		{"valid", func(_ *provisionInput) {}, false},
		{"missing name", func(in *provisionInput) { in.Name = "" }, true},
		{"missing owner email", func(in *provisionInput) { in.OwnerEmail = "" }, true},
		{"missing owner name", func(in *provisionInput) { in.OwnerName = "" }, true},
		{"bad region", func(in *provisionInput) { in.Region = "EU" }, true},
		{"bad onboarding", func(in *provisionInput) { in.Onboarding = "whenever" }, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			in := validInput()
			tc.mut(&in)
			err := in.validate()
			if (err != nil) != tc.wantErr {
				t.Errorf("validate() err = %v, wantErr %v", err, tc.wantErr)
			}
		})
	}
}
