// Package compliance is the read-only aggregator behind the manager's
// compliance dashboard.
//
// Pulls every expiry-bearing record that costs money or breaks the law
// when it lapses: bike MOT + tax, instructor accreditation, school
// insurance. Computes severity buckets so the dashboard can render
// rows by colour without re-computing on the client.
//
// Thresholds: bikes use the school's configured MOT/tax windows;
// accreditation + insurance use the package-local defaults below
// (annual, so we don't yet bother giving the manager per-window
// knobs — easy to add later if needed).
package compliance

import (
	"context"
	"fmt"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/admin"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// Annual-cycle defaults — used for accreditation + insurance as a
// safety net when a school's settings haven't been populated (e.g. test
// fixtures that bypass the migration's DEFAULT). Real production reads
// the per-school columns added in migration 0015.
const (
	AccreditationWarnDays   = 90
	AccreditationUrgentDays = 30
	InsuranceWarnDays       = 60
	InsuranceUrgentDays     = 14
)

type BikeRow struct {
	ID           domain.BikeID
	Nickname     string
	Registration string
	MOTExpiresOn string
	MOTStatus    admin.WarningStatus
	TaxExpiresOn string
	TaxStatus    admin.WarningStatus
	WorstStatus  admin.WarningStatus // for sorting / bucket counts
}

// AccreditationRow is one (course, expiry, status) entry under an
// instructor — there is one of these per course the instructor is
// accredited to teach.
type AccreditationRow struct {
	CourseTypeID domain.CourseTypeID
	CourseCode   string
	CourseName   string
	ExpiresOn    string
	Status       admin.WarningStatus
}

type InstructorRow struct {
	UserID         domain.UserID
	Name           string
	Accreditations []AccreditationRow
	// WorstStatus is the worst severity across the instructor's
	// accreditations — what the dashboard hero counts and what the row
	// pill renders. Empty accreditation lists report `unknown`.
	WorstStatus admin.WarningStatus
}

type SchoolRow struct {
	InsuranceExpiresOn string
	InsuranceStatus    admin.WarningStatus
}

type Report struct {
	Bikes       []BikeRow
	Instructors []InstructorRow
	School      SchoolRow
	// Severity tallies across the whole report — what the dashboard
	// shows in the hero. Keys: "expired", "urgent", "warn", "unknown".
	Counts map[string]int
}

// Load fetches everything in three small queries and bucketises in
// memory. Returns one combined Report; cheap for a single school (~5
// bikes, ~5 instructors).
func Load(ctx context.Context, scope *tenant.Scope) (*Report, error) {
	settings, err := admin.GetSchoolSettings(ctx, scope)
	if err != nil {
		return nil, fmt.Errorf("settings: %w", err)
	}
	motWarn := nonZero(settings.MOTWarnDays, admin.DefaultMOTWarnDays)
	motUrg := nonZero(settings.MOTUrgentDays, admin.DefaultMOTUrgentDays)
	taxWarn := nonZero(settings.TaxWarnDays, admin.DefaultTaxWarnDays)
	taxUrg := nonZero(settings.TaxUrgentDays, admin.DefaultTaxUrgentDays)
	accWarn := nonZero(settings.AccreditationWarnDays, AccreditationWarnDays)
	accUrg := nonZero(settings.AccreditationUrgentDays, AccreditationUrgentDays)
	insWarn := nonZero(settings.InsuranceWarnDays, InsuranceWarnDays)
	insUrg := nonZero(settings.InsuranceUrgentDays, InsuranceUrgentDays)
	today := time.Now().UTC()

	r := &Report{Counts: map[string]int{
		"expired": 0, "urgent": 0, "warn": 0, "unknown": 0,
	}}

	// --- Bikes ---
	bikes, err := admin.ListBikes(ctx, scope)
	if err != nil {
		return nil, fmt.Errorf("bikes: %w", err)
	}
	for _, b := range bikes {
		mot, motSet, _ := admin.ParseExpiry(b.MOTExpiresOn)
		tax, taxSet, _ := admin.ParseExpiry(b.TaxExpiresOn)
		motStatus := admin.ComputeWarning(today, mot, motSet, motWarn, motUrg)
		taxStatus := admin.ComputeWarning(today, tax, taxSet, taxWarn, taxUrg)
		worst := worstOf(motStatus, taxStatus)
		r.Bikes = append(r.Bikes, BikeRow{
			ID:           b.ID,
			Nickname:     fallbackName(b.Nickname, b.Make, b.Model),
			Registration: b.Registration,
			MOTExpiresOn: b.MOTExpiresOn,
			MOTStatus:    motStatus,
			TaxExpiresOn: b.TaxExpiresOn,
			TaxStatus:    taxStatus,
			WorstStatus:  worst,
		})
		tally(r.Counts, worst)
	}

	// --- Instructors ---
	// One row per (instructor, accreditation). LEFT JOIN so an
	// instructor with no accreditations on file still appears once with
	// status `unknown`. Joining course_types lets us return the code +
	// name so the UI doesn't have to denormalise client-side.
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT u.id, u.name,
		       COALESCE(ia.course_type_id, ''),
		       COALESCE(ct.code, ''), COALESCE(ct.name, ''),
		       COALESCE(ia.expires_on, '')
		  FROM users u
		  LEFT JOIN instructor_accreditations ia
		    ON ia.school_id = u.school_id AND ia.instructor_id = u.id
		  LEFT JOIN course_types ct
		    ON ct.id = ia.course_type_id AND ct.school_id = ia.school_id
		 WHERE u.school_id = ? AND u.role = 'instructor'
		 ORDER BY u.name ASC, ct.code ASC
	`, string(scope.SchoolID()))
	if err != nil {
		return nil, fmt.Errorf("instructors: %w", err)
	}
	defer rows.Close()
	byUser := map[string]*InstructorRow{}
	order := []string{} // preserve user-name ordering
	for rows.Next() {
		var uid, name, ctID, ctCode, ctName, accDate string
		if err := rows.Scan(&uid, &name, &ctID, &ctCode, &ctName, &accDate); err != nil {
			return nil, err
		}
		row, ok := byUser[uid]
		if !ok {
			row = &InstructorRow{
				UserID:      domain.UserID(uid),
				Name:        name,
				WorstStatus: admin.WarnUnknown,
			}
			byUser[uid] = row
			order = append(order, uid)
		}
		if ctID == "" {
			continue // instructor with zero accreditations — leave WorstStatus=unknown
		}
		t, set, _ := admin.ParseExpiry(accDate)
		status := admin.ComputeWarning(today, t, set, accWarn, accUrg)
		row.Accreditations = append(row.Accreditations, AccreditationRow{
			CourseTypeID: domain.CourseTypeID(ctID),
			CourseCode:   ctCode,
			CourseName:   ctName,
			ExpiresOn:    accDate,
			Status:       status,
		})
		row.WorstStatus = worstOf(row.WorstStatus, status)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for _, uid := range order {
		row := byUser[uid]
		r.Instructors = append(r.Instructors, *row)
		tally(r.Counts, row.WorstStatus)
	}

	// --- School insurance ---
	var insDate string
	if err := scope.Conn().QueryRowContext(ctx,
		`SELECT COALESCE(insurance_expires_on, '') FROM schools WHERE id = ?`,
		string(scope.SchoolID()),
	).Scan(&insDate); err != nil {
		return nil, fmt.Errorf("school insurance: %w", err)
	}
	t, ok, _ := admin.ParseExpiry(insDate)
	r.School = SchoolRow{
		InsuranceExpiresOn: insDate,
		InsuranceStatus:    admin.ComputeWarning(today, t, ok, insWarn, insUrg),
	}
	tally(r.Counts, r.School.InsuranceStatus)

	return r, nil
}

// SetInsurance updates the school's insurance expiry. Empty string clears.
func SetInsurance(ctx context.Context, scope *tenant.Scope, date string) error {
	if date != "" {
		if _, _, err := admin.ParseExpiry(date); err != nil {
			return fmt.Errorf("invalid date: %w", err)
		}
	}
	_, err := scope.Conn().ExecContext(ctx, `
		UPDATE schools SET insurance_expires_on = NULLIF(?, '') WHERE id = ?
	`, date, string(scope.SchoolID()))
	return err
}

// ----- helpers -----

func worstOf(a, b admin.WarningStatus) admin.WarningStatus {
	order := map[admin.WarningStatus]int{
		admin.WarnUnknown:   0,
		admin.WarnOK:        1,
		admin.WarnDueSoon:   2,
		admin.WarnDueUrgent: 3,
		admin.WarnExpired:   4,
	}
	if order[a] >= order[b] {
		return a
	}
	return b
}

func tally(m map[string]int, s admin.WarningStatus) {
	switch s {
	case admin.WarnExpired:
		m["expired"]++
	case admin.WarnDueUrgent:
		m["urgent"]++
	case admin.WarnDueSoon:
		m["warn"]++
	case admin.WarnUnknown:
		m["unknown"]++
	}
}

func nonZero(v, fallback int) int {
	if v <= 0 {
		return fallback
	}
	return v
}

func fallbackName(nick, make, model string) string {
	if nick != "" {
		return nick
	}
	if make != "" || model != "" {
		return make + " " + model
	}
	return ""
}
