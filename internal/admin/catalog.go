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

// ----- Course types -----

type CourseTypeRow struct {
	ID                      domain.CourseTypeID
	Code                    string
	Name                    string
	Region                  domain.Region
	RequiredBikeCategory    domain.LicenceCategory
	DurationMinutes         int
	MaxRatio                int
	PricePence              domain.Money
	NonTeaching             bool
	CancellationCutoffHours int
	AccentColour            string
	Icon                    string
	Prerequisites           []string // 'cbt_held', 'theory_passed'
}

type CreateCourseTypeRequest struct {
	Code                    string
	Name                    string
	Region                  domain.Region
	RequiredBikeCategory    domain.LicenceCategory
	DurationMinutes         int
	MaxRatio                int
	PricePence              domain.Money
	NonTeaching             bool
	CancellationCutoffHours int
	AccentColour            string
	Icon                    string
	Prerequisites           []string
}

func CreateCourseType(ctx context.Context, scope *tenant.Scope, req CreateCourseTypeRequest) (*CourseTypeRow, error) {
	if err := validateCourseType(req); err != nil {
		return nil, err
	}
	id := domain.CourseTypeID(domain.NewID())
	at := time.Now().UTC().Format(time.RFC3339)

	err := scope.WithTx(ctx, func(tx *tenant.Scope) error {
		_, err := tx.Conn().ExecContext(ctx, `
			INSERT INTO course_types
			    (id, school_id, code, name, region, required_bike_category,
			     duration_minutes, max_ratio, price_pence, non_teaching,
			     cancellation_cutoff_hours, accent_colour, icon, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		`, string(id), string(scope.SchoolID()), strings.ToUpper(req.Code), req.Name, string(req.Region),
			string(req.RequiredBikeCategory),
			req.DurationMinutes, req.MaxRatio, int64(req.PricePence),
			boolInt(req.NonTeaching), req.CancellationCutoffHours,
			req.AccentColour, req.Icon, at)
		if err != nil {
			if isUniqueViolation(err) {
				return fmt.Errorf("%w: code already exists", ErrConflict)
			}
			return fmt.Errorf("insert course type: %w", err)
		}
		return insertPrereqs(ctx, tx, id, req.Prerequisites)
	})
	if err != nil {
		return nil, err
	}
	return GetCourseType(ctx, scope, id)
}

type UpdateCourseTypeRequest = CreateCourseTypeRequest

func UpdateCourseType(ctx context.Context, scope *tenant.Scope, id domain.CourseTypeID, req UpdateCourseTypeRequest) error {
	if err := validateCourseType(req); err != nil {
		return err
	}
	return scope.WithTx(ctx, func(tx *tenant.Scope) error {
		res, err := tx.Conn().ExecContext(ctx, `
			UPDATE course_types SET
			    code = ?, name = ?, region = ?, required_bike_category = ?,
			    duration_minutes = ?, max_ratio = ?, price_pence = ?,
			    non_teaching = ?, cancellation_cutoff_hours = ?,
			    accent_colour = ?, icon = ?
			WHERE id = ? AND school_id = ?
		`, strings.ToUpper(req.Code), req.Name, string(req.Region), string(req.RequiredBikeCategory),
			req.DurationMinutes, req.MaxRatio, int64(req.PricePence),
			boolInt(req.NonTeaching), req.CancellationCutoffHours,
			req.AccentColour, req.Icon, string(id), string(scope.SchoolID()))
		if err != nil {
			if isUniqueViolation(err) {
				return fmt.Errorf("%w: code already exists", ErrConflict)
			}
			return err
		}
		n, _ := res.RowsAffected()
		if n == 0 {
			return ErrNotFound
		}
		// Replace prerequisites.
		if _, err := tx.Conn().ExecContext(ctx,
			`DELETE FROM course_prerequisites WHERE school_id = ? AND course_type_id = ?`,
			string(scope.SchoolID()), string(id)); err != nil {
			return err
		}
		return insertPrereqs(ctx, tx, id, req.Prerequisites)
	})
}

func GetCourseType(ctx context.Context, scope *tenant.Scope, id domain.CourseTypeID) (*CourseTypeRow, error) {
	var c CourseTypeRow
	var nonTeachingInt, cancelCutoff int
	err := scope.Conn().QueryRowContext(ctx, `
		SELECT id, code, name, region, COALESCE(required_bike_category,''),
		       duration_minutes, max_ratio, price_pence, non_teaching,
		       COALESCE(cancellation_cutoff_hours, 0),
		       COALESCE(accent_colour,''), COALESCE(icon,'')
		FROM course_types WHERE id = ? AND school_id = ?
	`, string(id), string(scope.SchoolID())).Scan(
		&c.ID, &c.Code, &c.Name, &c.Region, &c.RequiredBikeCategory,
		&c.DurationMinutes, &c.MaxRatio, &c.PricePence, &nonTeachingInt, &cancelCutoff,
		&c.AccentColour, &c.Icon,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	c.NonTeaching = nonTeachingInt == 1
	c.CancellationCutoffHours = cancelCutoff
	c.Prerequisites, err = getPrereqs(ctx, scope, c.ID)
	if err != nil {
		return nil, err
	}
	return &c, nil
}

func ListCourseTypes(ctx context.Context, scope *tenant.Scope) ([]CourseTypeRow, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT id, code, name, region, COALESCE(required_bike_category,''),
		       duration_minutes, max_ratio, price_pence, non_teaching,
		       COALESCE(cancellation_cutoff_hours, 0),
		       COALESCE(accent_colour,''), COALESCE(icon,'')
		FROM course_types WHERE school_id = ? ORDER BY name ASC
	`, string(scope.SchoolID()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []CourseTypeRow
	for rows.Next() {
		var c CourseTypeRow
		var nonTeachingInt, cancelCutoff int
		if err := rows.Scan(
			&c.ID, &c.Code, &c.Name, &c.Region, &c.RequiredBikeCategory,
			&c.DurationMinutes, &c.MaxRatio, &c.PricePence, &nonTeachingInt, &cancelCutoff,
			&c.AccentColour, &c.Icon,
		); err != nil {
			return nil, err
		}
		c.NonTeaching = nonTeachingInt == 1
		c.CancellationCutoffHours = cancelCutoff
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// Load prereqs in a second pass to keep the row scan simple.
	for i := range out {
		p, err := getPrereqs(ctx, scope, out[i].ID)
		if err != nil {
			return nil, err
		}
		out[i].Prerequisites = p
	}
	return out, nil
}

// DeleteCourseType refuses if there are sessions or competencies referencing
// it. Tells the admin to remove or reassign first — keeps the audit trail.
func DeleteCourseType(ctx context.Context, scope *tenant.Scope, id domain.CourseTypeID) error {
	used, err := courseTypeInUse(ctx, scope, id)
	if err != nil {
		return err
	}
	if used {
		return ErrCannotDeleteUsed
	}
	return scope.WithTx(ctx, func(tx *tenant.Scope) error {
		if _, err := tx.Conn().ExecContext(ctx,
			`DELETE FROM course_prerequisites WHERE school_id = ? AND course_type_id = ?`,
			string(scope.SchoolID()), string(id)); err != nil {
			return err
		}
		res, err := tx.Conn().ExecContext(ctx,
			`DELETE FROM course_types WHERE id = ? AND school_id = ?`,
			string(id), string(scope.SchoolID()))
		if err != nil {
			return err
		}
		n, _ := res.RowsAffected()
		if n == 0 {
			return ErrNotFound
		}
		return nil
	})
}

func courseTypeInUse(ctx context.Context, scope *tenant.Scope, id domain.CourseTypeID) (bool, error) {
	var n int
	err := scope.Conn().QueryRowContext(ctx, `
		SELECT
		    (SELECT COUNT(*) FROM sessions WHERE school_id = ? AND course_type_id = ?) +
		    (SELECT COUNT(*) FROM competencies WHERE school_id = ? AND course_type_id = ?) +
		    (SELECT COUNT(*) FROM instructor_qualifications WHERE school_id = ? AND course_type_id = ?)
	`, string(scope.SchoolID()), string(id),
		string(scope.SchoolID()), string(id),
		string(scope.SchoolID()), string(id)).Scan(&n)
	return n > 0, err
}

func validateCourseType(r CreateCourseTypeRequest) error {
	if strings.TrimSpace(r.Code) == "" || strings.TrimSpace(r.Name) == "" {
		return fmt.Errorf("%w: code and name required", ErrInvalidInput)
	}
	if r.Region != domain.RegionNI && r.Region != domain.RegionGB {
		return fmt.Errorf("%w: region must be NI or GB", ErrInvalidInput)
	}
	if r.DurationMinutes <= 0 {
		return fmt.Errorf("%w: durationMinutes must be positive", ErrInvalidInput)
	}
	if r.MaxRatio <= 0 {
		return fmt.Errorf("%w: maxRatio must be positive", ErrInvalidInput)
	}
	for _, p := range r.Prerequisites {
		if p != "cbt_held" && p != "theory_passed" {
			return fmt.Errorf("%w: unknown prerequisite %q", ErrInvalidInput, p)
		}
	}
	return nil
}

func insertPrereqs(ctx context.Context, tx *tenant.Scope, id domain.CourseTypeID, prereqs []string) error {
	for _, p := range prereqs {
		if _, err := tx.Conn().ExecContext(ctx, `
			INSERT INTO course_prerequisites (school_id, course_type_id, prereq_kind)
			VALUES (?, ?, ?)
			ON CONFLICT DO NOTHING
		`, string(tx.SchoolID()), string(id), p); err != nil {
			return fmt.Errorf("insert prereq %q: %w", p, err)
		}
	}
	return nil
}

func getPrereqs(ctx context.Context, scope *tenant.Scope, id domain.CourseTypeID) ([]string, error) {
	rows, err := scope.Conn().QueryContext(ctx,
		`SELECT prereq_kind FROM course_prerequisites WHERE school_id = ? AND course_type_id = ? ORDER BY prereq_kind`,
		string(scope.SchoolID()), string(id))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// ----- Competencies -----

type CompetencyRow struct {
	ID           domain.CompetencyID
	CourseTypeID domain.CourseTypeID
	Label        string
	SortOrder    int
}

type CreateCompetencyRequest struct {
	CourseTypeID domain.CourseTypeID
	Label        string
	SortOrder    int
}

func CreateCompetency(ctx context.Context, scope *tenant.Scope, req CreateCompetencyRequest) (*CompetencyRow, error) {
	if strings.TrimSpace(req.Label) == "" {
		return nil, fmt.Errorf("%w: label required", ErrInvalidInput)
	}
	id := domain.CompetencyID(domain.NewID())
	_, err := scope.Conn().ExecContext(ctx, `
		INSERT INTO competencies (id, school_id, course_type_id, label, sort_order)
		VALUES (?, ?, ?, ?, ?)
	`, string(id), string(scope.SchoolID()), string(req.CourseTypeID), req.Label, req.SortOrder)
	if err != nil {
		return nil, fmt.Errorf("insert competency: %w", err)
	}
	return &CompetencyRow{ID: id, CourseTypeID: req.CourseTypeID, Label: req.Label, SortOrder: req.SortOrder}, nil
}

func ListCompetencies(ctx context.Context, scope *tenant.Scope, courseTypeID domain.CourseTypeID) ([]CompetencyRow, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT id, course_type_id, label, sort_order
		FROM competencies WHERE school_id = ? AND course_type_id = ?
		ORDER BY sort_order ASC, label ASC
	`, string(scope.SchoolID()), string(courseTypeID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []CompetencyRow
	for rows.Next() {
		var c CompetencyRow
		if err := rows.Scan(&c.ID, &c.CourseTypeID, &c.Label, &c.SortOrder); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func DeleteCompetency(ctx context.Context, scope *tenant.Scope, id domain.CompetencyID) error {
	// Refuse if there's any progress_records tied.
	var n int
	if err := scope.Conn().QueryRowContext(ctx,
		`SELECT COUNT(*) FROM progress_records WHERE school_id = ? AND competency_id = ?`,
		string(scope.SchoolID()), string(id)).Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return ErrCannotDeleteUsed
	}
	res, err := scope.Conn().ExecContext(ctx,
		`DELETE FROM competencies WHERE id = ? AND school_id = ?`,
		string(id), string(scope.SchoolID()))
	if err != nil {
		return err
	}
	rows, _ := res.RowsAffected()
	if rows == 0 {
		return ErrNotFound
	}
	return nil
}

// ----- helpers -----

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "UNIQUE constraint failed") ||
		strings.Contains(msg, "constraint failed: UNIQUE")
}
