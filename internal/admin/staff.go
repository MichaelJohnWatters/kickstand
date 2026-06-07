package admin

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// ----- Instructors -----

type InstructorRow struct {
	UserID            domain.UserID
	Name              string
	Email             string
	Phone             string
	HomeLocationID    domain.LocationID
	HomeLocationName  string
	AccountStatus     domain.AccountStatus
	QualifiedCourseIDs []domain.CourseTypeID
}

type InviteInstructorRequest struct {
	Name           string
	Email          string
	Phone          string
	Password       string // for MVP we set an initial password
	HomeLocationID domain.LocationID
	QualifiedCourseIDs []domain.CourseTypeID
}

// InviteInstructor creates an instructor user + profile + qualifications.
// "Invite" is aspirational — MVP just creates the account with a password.
// Phase 2: real email invitation flow.
func InviteInstructor(ctx context.Context, scope *tenant.Scope, req InviteInstructorRequest) (*InstructorRow, error) {
	if strings.TrimSpace(req.Name) == "" || strings.TrimSpace(req.Email) == "" {
		return nil, fmt.Errorf("%w: name and email required", ErrInvalidInput)
	}
	if len(req.Password) < 8 {
		return nil, fmt.Errorf("%w: password must be at least 8 chars", ErrInvalidInput)
	}
	if req.HomeLocationID != "" {
		if err := requireLocation(ctx, scope, req.HomeLocationID); err != nil {
			return nil, err
		}
	}
	hash, err := auth.HashPassword(req.Password)
	if err != nil {
		return nil, err
	}
	id := domain.UserID(domain.NewID())
	at := time.Now().UTC().Format(time.RFC3339)

	err = scope.WithTx(ctx, func(tx *tenant.Scope) error {
		_, err := tx.Conn().ExecContext(ctx, `
			INSERT INTO users (id, school_id, email, phone, password_hash, name, role, account_status, created_at)
			VALUES (?, ?, ?, ?, ?, ?, 'instructor', 'active', ?)
		`, string(id), string(scope.SchoolID()), strings.ToLower(strings.TrimSpace(req.Email)),
			req.Phone, hash, req.Name, at)
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
		`, string(id), string(scope.SchoolID()), homeArg)
		if err != nil {
			return fmt.Errorf("insert profile: %w", err)
		}
		for _, cid := range req.QualifiedCourseIDs {
			if _, err := tx.Conn().ExecContext(ctx, `
				INSERT INTO instructor_qualifications (school_id, instructor_id, course_type_id)
				VALUES (?, ?, ?)
				ON CONFLICT DO NOTHING
			`, string(scope.SchoolID()), string(id), string(cid)); err != nil {
				return fmt.Errorf("insert qualification: %w", err)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return GetInstructor(ctx, scope, id)
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
	r.QualifiedCourseIDs, err = loadQualifications(ctx, scope, id)
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
		q, err := loadQualifications(ctx, scope, out[i].UserID)
		if err != nil {
			return nil, err
		}
		out[i].QualifiedCourseIDs = q
	}
	return out, nil
}

type SetQualificationsRequest struct {
	CourseTypeIDs []domain.CourseTypeID
}

func SetQualifications(ctx context.Context, scope *tenant.Scope, instructorID domain.UserID, req SetQualificationsRequest) error {
	// Verify the instructor exists
	if _, err := GetInstructor(ctx, scope, instructorID); err != nil {
		return err
	}
	return scope.WithTx(ctx, func(tx *tenant.Scope) error {
		if _, err := tx.Conn().ExecContext(ctx,
			`DELETE FROM instructor_qualifications WHERE school_id = ? AND instructor_id = ?`,
			string(scope.SchoolID()), string(instructorID)); err != nil {
			return err
		}
		for _, cid := range req.CourseTypeIDs {
			if _, err := tx.Conn().ExecContext(ctx, `
				INSERT INTO instructor_qualifications (school_id, instructor_id, course_type_id)
				VALUES (?, ?, ?)
			`, string(scope.SchoolID()), string(instructorID), string(cid)); err != nil {
				return err
			}
		}
		return nil
	})
}

func loadQualifications(ctx context.Context, scope *tenant.Scope, id domain.UserID) ([]domain.CourseTypeID, error) {
	rows, err := scope.Conn().QueryContext(ctx,
		`SELECT course_type_id FROM instructor_qualifications WHERE school_id = ? AND instructor_id = ?`,
		string(scope.SchoolID()), string(id))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []domain.CourseTypeID
	for rows.Next() {
		var c domain.CourseTypeID
		if err := rows.Scan(&c); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// ----- School settings -----

type SchoolSettings struct {
	Name                           string
	Region                         domain.Region
	TestBodyLabel                  string
	OnboardingMode                 string // 'open' | 'approval'
	InstructorsCanRecordPayments   bool
	CancelCutoffHours              int
	TravelBufferMinutes            int
	CrossSiteNoticeHours           int
}

func GetSchoolSettings(ctx context.Context, scope *tenant.Scope) (*SchoolSettings, error) {
	var s SchoolSettings
	var canRecordInt int
	err := scope.Conn().QueryRowContext(ctx, `
		SELECT name, region, test_body_label, onboarding_mode,
		       instructors_can_record_payments, cancel_cutoff_hours,
		       travel_buffer_minutes, cross_site_notice_hours
		FROM schools WHERE id = ?
	`, string(scope.SchoolID())).Scan(
		&s.Name, &s.Region, &s.TestBodyLabel, &s.OnboardingMode,
		&canRecordInt, &s.CancelCutoffHours, &s.TravelBufferMinutes, &s.CrossSiteNoticeHours,
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
