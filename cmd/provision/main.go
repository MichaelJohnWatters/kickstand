// Command provision creates a new training school (tenant) and its first
// owner account. It is the production path for onboarding a real customer —
// separate from `cmd/seed`, which fabricates the Lagan Valley demo tenant.
//
// It works for both deployment models:
//   - Shared multi-tenant: run against the shared DB to add a school.
//   - Dedicated single-tenant: run against a fresh DB to bootstrap the one
//     school that instance will serve, then set
//     KS_SINGLE_TENANT_SCHOOL_ID=<printed id> on that deployment.
//
// Auth is hand-rolled email/password: the owner's password (supplied via
// -owner-password) is bcrypt-hashed into the users row, and the owner signs
// in with that email + password through /auth/login.
//
// Example:
//
//	FIREBASE_PROJECT_ID=kickstand-prod GOOGLE_APPLICATION_CREDENTIALS=sa.json \
//	  bin/provision -dsn kickstand.db -name "Belfast Rider Co" -region NI \
//	  -owner-email owner@belfastrider.co.uk -owner-name "Jo Rider" \
//	  -owner-password 'change-me-now'
package main

import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/logging"
)

func main() {
	dsn := flag.String("dsn", "kickstand.db", "SQLite database path")
	name := flag.String("name", "", "School name (required)")
	region := flag.String("region", "NI", "Region: NI (DVA) | GB (DVSA)")
	onboarding := flag.String("onboarding-mode", "open", "Signup mode: open | approval")
	ownerEmail := flag.String("owner-email", "", "Owner account email (required)")
	ownerName := flag.String("owner-name", "", "Owner full name (required)")
	ownerPassword := flag.String("owner-password", "", "Owner's initial password (required)")
	schoolIDFlag := flag.String("school-id", "", "Explicit school id (default: generated)")
	flag.Parse()

	logging.Setup(slog.LevelInfo)
	log := slog.Default()
	ctx := context.Background()

	fatal := func(format string, args ...any) {
		log.Error("provision failed", slog.String("err", fmt.Sprintf(format, args...)))
		os.Exit(1)
	}

	in := provisionInput{
		SchoolID:   strings.TrimSpace(*schoolIDFlag),
		OwnerID:    domain.NewID(),
		Name:       strings.TrimSpace(*name),
		Region:     *region,
		Onboarding: *onboarding,
		OwnerEmail: strings.ToLower(strings.TrimSpace(*ownerEmail)),
		OwnerName:  strings.TrimSpace(*ownerName),
	}
	if in.SchoolID == "" {
		in.SchoolID = domain.NewID()
	}
	// Validate inputs up front (cheap, no I/O) before touching the DB.
	if err := in.validate(); err != nil {
		fatal("%v", err)
	}
	if *ownerPassword == "" {
		fatal("-owner-password is required")
	}
	hash, err := auth.HashPassword(*ownerPassword)
	if err != nil {
		fatal("password: %v", err)
	}
	in.PasswordHash = hash

	d, err := db.Open(*dsn)
	if err != nil {
		fatal("open db: %v", err)
	}
	defer d.Close()
	if err := db.Migrate(ctx, d); err != nil {
		fatal("migrate: %v", err)
	}

	if err := provisionSchool(ctx, d, in); err != nil {
		fatal("%v", err)
	}

	testBody, _ := testBodyForRegion(in.Region)
	fmt.Println("✓ Provisioned school")
	fmt.Printf("  school id   : %s\n", in.SchoolID)
	fmt.Printf("  name        : %s\n", in.Name)
	fmt.Printf("  region      : %s (%s)\n", in.Region, testBody)
	fmt.Printf("  onboarding  : %s\n", in.Onboarding)
	fmt.Printf("  owner       : %s <%s>  (role=owner, user id=%s)\n", in.OwnerName, in.OwnerEmail, in.OwnerID)
	fmt.Printf("  auth        : password set. Owner signs in with the email + the password you supplied.\n")
	fmt.Println()
	fmt.Println("For a DEDICATED single-tenant instance, pin this deployment to the school:")
	fmt.Printf("  KS_SINGLE_TENANT_SCHOOL_ID=%s\n", in.SchoolID)
}

// provisionInput is the fully-resolved request: ids already generated, email
// normalised, password already hashed. Kept separate from flag parsing so the
// DB logic is unit-testable.
type provisionInput struct {
	SchoolID     string
	OwnerID      string
	Name         string
	Region       string // "NI" | "GB"
	Onboarding   string // "open" | "approval"
	OwnerEmail   string
	OwnerName    string
	PasswordHash string // bcrypt hash written to the owner's users row
}

func (in provisionInput) validate() error {
	if in.Name == "" {
		return errors.New("-name is required")
	}
	if in.OwnerEmail == "" || in.OwnerName == "" {
		return errors.New("-owner-email and -owner-name are required")
	}
	if _, ok := testBodyForRegion(in.Region); !ok {
		return fmt.Errorf("-region must be NI or GB, got %q", in.Region)
	}
	if in.Onboarding != "open" && in.Onboarding != "approval" {
		return fmt.Errorf("-onboarding-mode must be open or approval, got %q", in.Onboarding)
	}
	return nil
}

// testBodyForRegion maps a region to its driving-test body label. NI schools
// test through the DVA; GB through the DVSA.
func testBodyForRegion(region string) (string, bool) {
	switch domain.Region(region) {
	case domain.RegionNI:
		return "DVA", true
	case domain.RegionGB:
		return "DVSA", true
	default:
		return "", false
	}
}

// provisionSchool validates the input, refuses to clobber an existing school
// id, and writes the school + owner rows in one transaction.
func provisionSchool(ctx context.Context, d *sql.DB, in provisionInput) error {
	if err := in.validate(); err != nil {
		return err
	}
	testBody, _ := testBodyForRegion(in.Region)

	exists, err := schoolExists(ctx, d, in.SchoolID)
	if err != nil {
		return fmt.Errorf("check school id: %w", err)
	}
	if exists {
		return fmt.Errorf("school id %q already exists — refusing to overwrite", in.SchoolID)
	}

	createdAt := time.Now().UTC().Format(time.RFC3339)
	tx, err := d.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO schools (id, name, region, test_body_label, onboarding_mode, created_at)
		VALUES (?, ?, ?, ?, ?, ?)
	`, in.SchoolID, in.Name, in.Region, testBody, in.Onboarding, createdAt); err != nil {
		return fmt.Errorf("insert school: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
		VALUES (?, ?, ?, ?, ?, 'owner', 'active', ?)
	`, in.OwnerID, in.SchoolID, in.OwnerEmail, in.PasswordHash, in.OwnerName, createdAt); err != nil {
		return fmt.Errorf("insert owner: %w", err)
	}
	return tx.Commit()
}

func schoolExists(ctx context.Context, d *sql.DB, id string) (bool, error) {
	var one int
	err := d.QueryRowContext(ctx, `SELECT 1 FROM schools WHERE id = ?`, id).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}
