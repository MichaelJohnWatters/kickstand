package admin

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// ----- Instructors -----

// Accreditation is one (course, expiry-date) pair held by an instructor.
// The expiry is stored as a YYYY-MM-DD string (empty means "on file but
// expiry unknown"). The combination of `(school_id, instructor_id,
// course_type_id)` is unique — at most one accreditation per course per
// instructor.
type Accreditation struct {
	CourseTypeID domain.CourseTypeID
	ExpiresOn    string // "YYYY-MM-DD" or ""
}

type InstructorRow struct {
	UserID           domain.UserID
	Name             string
	Email            string
	Phone            string
	HomeLocationID   domain.LocationID
	HomeLocationName string
	AccountStatus    domain.AccountStatus
	Accreditations   []Accreditation
}

// QualifiedCourseIDs returns the bare list of course IDs an instructor is
// accredited to teach — kept as a helper because booking only needs the
// IDs and doesn't care about expiry dates.
func (r InstructorRow) QualifiedCourseIDs() []domain.CourseTypeID {
	out := make([]domain.CourseTypeID, 0, len(r.Accreditations))
	for _, a := range r.Accreditations {
		out = append(out, a.CourseTypeID)
	}
	return out
}

type InviteInstructorRequest struct {
	// UserID + FirebaseUID are supplied by the HTTP layer, which creates
	// the Firebase identity before writing the local row (so a duplicate
	// email is rejected by Firebase before we touch the database).
	UserID         domain.UserID
	FirebaseUID    string
	Name           string
	Email          string
	Phone          string
	HomeLocationID domain.LocationID
	Accreditations []Accreditation
}

// InviteInstructor writes the user + instructor_profile + accreditation
// rows in one transaction. The auth identity is owned by Firebase — the
// caller is expected to have already created it and to be passing the
// resulting UID through FirebaseUID. If this function returns an error,
// the caller should delete the Firebase user it created so the email
// stays available for retry.
func InviteInstructor(ctx context.Context, scope *tenant.Scope, req InviteInstructorRequest) (*InstructorRow, error) {
	if strings.TrimSpace(req.Name) == "" || strings.TrimSpace(req.Email) == "" {
		return nil, fmt.Errorf("%w: name and email required", ErrInvalidInput)
	}
	if req.UserID == "" || req.FirebaseUID == "" {
		return nil, fmt.Errorf("%w: userID and firebaseUID required", ErrInvalidInput)
	}
	if req.HomeLocationID != "" {
		if err := requireLocation(ctx, scope, req.HomeLocationID); err != nil {
			return nil, err
		}
	}
	at := time.Now().UTC().Format(time.RFC3339)

	err := scope.WithTx(ctx, func(tx *tenant.Scope) error {
		// password_hash is a vestigial NOT NULL column from the pre-Firebase
		// era — we write empty string. A follow-up migration will drop it.
		_, err := tx.Conn().ExecContext(ctx, `
			INSERT INTO users (id, school_id, email, phone, password_hash, name, role, account_status, created_at, firebase_uid)
			VALUES (?, ?, ?, ?, '', ?, 'instructor', 'active', ?, ?)
		`, string(req.UserID), string(scope.SchoolID()), strings.ToLower(strings.TrimSpace(req.Email)),
			req.Phone, req.Name, at, req.FirebaseUID)
		if err != nil {
			if isUniqueViolation(err) {
				return fmt.Errorf("%w: email already in use", ErrConflict)
			}
			return fmt.Errorf("insert instructor user: %w", err)
		}
		var homeArg any
		if req.HomeLocationID != "" {
			homeArg = string(req.HomeLocationID)
		}
		_, err = tx.Conn().ExecContext(ctx, `
			INSERT INTO instructor_profiles (user_id, school_id, home_location_id)
			VALUES (?, ?, ?)
		`, string(req.UserID), string(scope.SchoolID()), homeArg)
		if err != nil {
			return fmt.Errorf("insert profile: %w", err)
		}
		for _, a := range req.Accreditations {
			if _, err := tx.Conn().ExecContext(ctx, `
				INSERT INTO instructor_accreditations (school_id, instructor_id, course_type_id, expires_on)
				VALUES (?, ?, ?, NULLIF(?, ''))
				ON CONFLICT DO NOTHING
			`, string(scope.SchoolID()), string(req.UserID), string(a.CourseTypeID), a.ExpiresOn); err != nil {
				return fmt.Errorf("insert accreditation: %w", err)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return GetInstructor(ctx, scope, req.UserID)
}

func GetInstructor(ctx context.Context, scope *tenant.Scope, id domain.UserID) (*InstructorRow, error) {
	const q = `
		SELECT u.id, u.name, u.email, COALESCE(u.phone,''),
		       COALESCE(ip.home_location_id,''), COALESCE(l.name, ''),
		       u.account_status
		FROM users u
		LEFT JOIN instructor_profiles ip ON ip.user_id = u.id AND ip.school_id = u.school_id
		LEFT JOIN locations l ON l.id = ip.home_location_id AND l.school_id = u.school_id
		WHERE u.id = ? AND u.school_id = ? AND u.role = 'instructor'
	`
	var r InstructorRow
	err := scope.Conn().QueryRowContext(ctx, q, string(id), string(scope.SchoolID())).Scan(
		&r.UserID, &r.Name, &r.Email, &r.Phone,
		&r.HomeLocationID, &r.HomeLocationName, &r.AccountStatus,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	r.Accreditations, err = loadAccreditations(ctx, scope, id)
	if err != nil {
		return nil, err
	}
	return &r, nil
}

func ListInstructors(ctx context.Context, scope *tenant.Scope) ([]InstructorRow, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT u.id, u.name, u.email, COALESCE(u.phone,''),
		       COALESCE(ip.home_location_id,''), COALESCE(l.name,''),
		       u.account_status
		FROM users u
		LEFT JOIN instructor_profiles ip ON ip.user_id = u.id AND ip.school_id = u.school_id
		LEFT JOIN locations l ON l.id = ip.home_location_id AND l.school_id = u.school_id
		WHERE u.school_id = ? AND u.role = 'instructor'
		ORDER BY u.name ASC
	`, string(scope.SchoolID()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []InstructorRow
	for rows.Next() {
		var r InstructorRow
		if err := rows.Scan(&r.UserID, &r.Name, &r.Email, &r.Phone,
			&r.HomeLocationID, &r.HomeLocationName, &r.AccountStatus); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i := range out {
		a, err := loadAccreditations(ctx, scope, out[i].UserID)
		if err != nil {
			return nil, err
		}
		out[i].Accreditations = a
	}
	return out, nil
}

type SetAccreditationsRequest struct {
	Accreditations []Accreditation
}

// SetAccreditations replaces the instructor's full accreditation list in
// one transaction. Missing entries are dropped; supplying an entry with
// an empty ExpiresOn keeps the course but clears the expiry date.
func SetAccreditations(ctx context.Context, scope *tenant.Scope, instructorID domain.UserID, req SetAccreditationsRequest) error {
	if _, err := GetInstructor(ctx, scope, instructorID); err != nil {
		return err
	}
	for _, a := range req.Accreditations {
		if a.ExpiresOn != "" {
			if _, _, err := ParseExpiry(a.ExpiresOn); err != nil {
				return fmt.Errorf("%w: bad expires_on for %s: %v", ErrInvalidInput, a.CourseTypeID, err)
			}
		}
	}
	return scope.WithTx(ctx, func(tx *tenant.Scope) error {
		if _, err := tx.Conn().ExecContext(ctx,
			`DELETE FROM instructor_accreditations WHERE school_id = ? AND instructor_id = ?`,
			string(scope.SchoolID()), string(instructorID)); err != nil {
			return err
		}
		for _, a := range req.Accreditations {
			if _, err := tx.Conn().ExecContext(ctx, `
				INSERT INTO instructor_accreditations (school_id, instructor_id, course_type_id, expires_on)
				VALUES (?, ?, ?, NULLIF(?, ''))
			`, string(scope.SchoolID()), string(instructorID), string(a.CourseTypeID), a.ExpiresOn); err != nil {
				return err
			}
		}
		return nil
	})
}

func loadAccreditations(ctx context.Context, scope *tenant.Scope, id domain.UserID) ([]Accreditation, error) {
	rows, err := scope.Conn().QueryContext(ctx,
		`SELECT course_type_id, COALESCE(expires_on, '')
		   FROM instructor_accreditations
		  WHERE school_id = ? AND instructor_id = ?
		  ORDER BY course_type_id`,
		string(scope.SchoolID()), string(id))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Accreditation
	for rows.Next() {
		var a Accreditation
		if err := rows.Scan(&a.CourseTypeID, &a.ExpiresOn); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// ----- School settings -----

type SchoolSettings struct {
	Name                         string
	Region                       domain.Region
	TestBodyLabel                string
	OnboardingMode               string // 'open' | 'approval'
	InstructorsCanRecordPayments bool
	CancelCutoffHours            int
	TravelBufferMinutes          int
	CrossSiteNoticeHours         int
	// Fleet warning windows — feed the bike card MOT/tax pill colours.
	// Defaults set by migration 0008 (90 / 14 / 30 / 7).
	MOTWarnDays   int
	MOTUrgentDays int
	TaxWarnDays   int
	TaxUrgentDays int
	// Compliance dashboard windows (annual cycles, defaults from 0015).
	AccreditationWarnDays   int
	AccreditationUrgentDays int
	InsuranceWarnDays       int
	InsuranceUrgentDays     int
}

func GetSchoolSettings(ctx context.Context, scope *tenant.Scope) (*SchoolSettings, error) {
	var s SchoolSettings
	var canRecordInt int
	err := scope.Conn().QueryRowContext(ctx, `
		SELECT name, region, test_body_label, onboarding_mode,
		       instructors_can_record_payments, cancel_cutoff_hours,
		       travel_buffer_minutes, cross_site_notice_hours,
		       mot_warn_days, mot_urgent_days, tax_warn_days, tax_urgent_days,
		       accreditation_warn_days, accreditation_urgent_days,
		       insurance_warn_days, insurance_urgent_days
		FROM schools WHERE id = ?
	`, string(scope.SchoolID())).Scan(
		&s.Name, &s.Region, &s.TestBodyLabel, &s.OnboardingMode,
		&canRecordInt, &s.CancelCutoffHours, &s.TravelBufferMinutes, &s.CrossSiteNoticeHours,
		&s.MOTWarnDays, &s.MOTUrgentDays, &s.TaxWarnDays, &s.TaxUrgentDays,
		&s.AccreditationWarnDays, &s.AccreditationUrgentDays,
		&s.InsuranceWarnDays, &s.InsuranceUrgentDays,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	s.InstructorsCanRecordPayments = canRecordInt == 1
	return &s, nil
}

type UpdateSchoolSettingsRequest struct {
	Name                         *string
	OnboardingMode               *string
	InstructorsCanRecordPayments *bool
	CancelCutoffHours            *int
	TravelBufferMinutes          *int
	CrossSiteNoticeHours         *int
	TestBodyLabel                *string
	MOTWarnDays                  *int
	MOTUrgentDays                *int
	TaxWarnDays                  *int
	TaxUrgentDays                *int
	AccreditationWarnDays        *int
	AccreditationUrgentDays      *int
	InsuranceWarnDays            *int
	InsuranceUrgentDays          *int
}

func UpdateSchoolSettings(ctx context.Context, scope *tenant.Scope, req UpdateSchoolSettingsRequest) error {
	// Build a dynamic SET clause from the non-nil fields. The pointer-fields
	// pattern lets us distinguish "not provided" from "explicitly set to
	// zero".
	parts := []string{}
	args := []any{}
	if req.Name != nil {
		parts = append(parts, "name = ?")
		args = append(args, *req.Name)
	}
	if req.OnboardingMode != nil {
		if *req.OnboardingMode != "open" && *req.OnboardingMode != "approval" {
			return fmt.Errorf("%w: onboardingMode must be 'open' or 'approval'", ErrInvalidInput)
		}
		parts = append(parts, "onboarding_mode = ?")
		args = append(args, *req.OnboardingMode)
	}
	if req.InstructorsCanRecordPayments != nil {
		parts = append(parts, "instructors_can_record_payments = ?")
		args = append(args, boolInt(*req.InstructorsCanRecordPayments))
	}
	if req.CancelCutoffHours != nil {
		parts = append(parts, "cancel_cutoff_hours = ?")
		args = append(args, *req.CancelCutoffHours)
	}
	if req.TravelBufferMinutes != nil {
		parts = append(parts, "travel_buffer_minutes = ?")
		args = append(args, *req.TravelBufferMinutes)
	}
	if req.CrossSiteNoticeHours != nil {
		parts = append(parts, "cross_site_notice_hours = ?")
		args = append(args, *req.CrossSiteNoticeHours)
	}
	if req.TestBodyLabel != nil {
		parts = append(parts, "test_body_label = ?")
		args = append(args, *req.TestBodyLabel)
	}
	// Warning thresholds — basic sanity bounds. Negative would invert
	// the buckets; 365+ is silly for an annual MOT.
	if req.MOTWarnDays != nil {
		if *req.MOTWarnDays < 1 || *req.MOTWarnDays > 365 {
			return fmt.Errorf("%w: motWarnDays must be 1..365", ErrInvalidInput)
		}
		parts = append(parts, "mot_warn_days = ?")
		args = append(args, *req.MOTWarnDays)
	}
	if req.MOTUrgentDays != nil {
		if *req.MOTUrgentDays < 1 || *req.MOTUrgentDays > 365 {
			return fmt.Errorf("%w: motUrgentDays must be 1..365", ErrInvalidInput)
		}
		parts = append(parts, "mot_urgent_days = ?")
		args = append(args, *req.MOTUrgentDays)
	}
	if req.TaxWarnDays != nil {
		if *req.TaxWarnDays < 1 || *req.TaxWarnDays > 365 {
			return fmt.Errorf("%w: taxWarnDays must be 1..365", ErrInvalidInput)
		}
		parts = append(parts, "tax_warn_days = ?")
		args = append(args, *req.TaxWarnDays)
	}
	if req.TaxUrgentDays != nil {
		if *req.TaxUrgentDays < 1 || *req.TaxUrgentDays > 365 {
			return fmt.Errorf("%w: taxUrgentDays must be 1..365", ErrInvalidInput)
		}
		parts = append(parts, "tax_urgent_days = ?")
		args = append(args, *req.TaxUrgentDays)
	}
	if req.AccreditationWarnDays != nil {
		if *req.AccreditationWarnDays < 1 || *req.AccreditationWarnDays > 365 {
			return fmt.Errorf("%w: accreditationWarnDays must be 1..365", ErrInvalidInput)
		}
		parts = append(parts, "accreditation_warn_days = ?")
		args = append(args, *req.AccreditationWarnDays)
	}
	if req.AccreditationUrgentDays != nil {
		if *req.AccreditationUrgentDays < 1 || *req.AccreditationUrgentDays > 365 {
			return fmt.Errorf("%w: accreditationUrgentDays must be 1..365", ErrInvalidInput)
		}
		parts = append(parts, "accreditation_urgent_days = ?")
		args = append(args, *req.AccreditationUrgentDays)
	}
	if req.InsuranceWarnDays != nil {
		if *req.InsuranceWarnDays < 1 || *req.InsuranceWarnDays > 365 {
			return fmt.Errorf("%w: insuranceWarnDays must be 1..365", ErrInvalidInput)
		}
		parts = append(parts, "insurance_warn_days = ?")
		args = append(args, *req.InsuranceWarnDays)
	}
	if req.InsuranceUrgentDays != nil {
		if *req.InsuranceUrgentDays < 1 || *req.InsuranceUrgentDays > 365 {
			return fmt.Errorf("%w: insuranceUrgentDays must be 1..365", ErrInvalidInput)
		}
		parts = append(parts, "insurance_urgent_days = ?")
		args = append(args, *req.InsuranceUrgentDays)
	}
	if len(parts) == 0 {
		return nil // nothing to update
	}
	args = append(args, string(scope.SchoolID()))
	q := fmt.Sprintf("UPDATE schools SET %s WHERE id = ?", strings.Join(parts, ", "))
	res, err := scope.Conn().ExecContext(ctx, q, args...)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}
