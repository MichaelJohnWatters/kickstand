package progress_test

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/progress"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

type fixture struct {
	t              *testing.T
	db             *sql.DB
	scope          *tenant.Scope
	now            time.Time
	school         domain.SchoolID
	location       domain.LocationID
	instructor     domain.UserID
	student        domain.UserID
	courseCBT      domain.CourseTypeID
	courseTestDay  domain.CourseTypeID
	bike           domain.BikeID
	session        domain.SessionID
	sessionTestDay domain.SessionID
	booking        domain.BookingID
	bookingTestDay domain.BookingID
	compUturn      domain.CompetencyID
	compStop       domain.CompetencyID
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	d, err := db.Open(t.TempDir() + "/p.db")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	if err := db.Migrate(context.Background(), d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	f := &fixture{
		t:              t,
		db:             d,
		now:            time.Date(2026, 6, 6, 9, 0, 0, 0, time.UTC),
		school:         "school_t",
		location:       "loc_t",
		instructor:     "user_inst",
		student:        "user_stu",
		courseCBT:      "ct_cbt",
		courseTestDay:  "ct_test",
		bike:           "bike_t",
		session:        "sess_t",
		sessionTestDay: "sess_test",
		booking:        "booking_t",
		bookingTestDay: "booking_test",
		compUturn:      "comp_uturn",
		compStop:       "comp_stop",
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
	      VALUES (?, ?, 'NI', 'DVA', ?)`, f.school, "T", at)
	exec(`INSERT INTO locations (id, school_id, name, created_at) VALUES (?, ?, ?, ?)`,
		f.location, f.school, "Belfast", at)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, created_at)
	      VALUES (?, ?, ?, '', ?, 'instructor', ?)`, f.instructor, f.school, "i@t", "Dave", at)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	      VALUES (?, ?, ?, '', ?, 'student', 'active', ?)`, f.student, f.school, "s@t", "Sam", at)
	exec(`INSERT INTO student_profiles (user_id, school_id, transmission_preference, cbt_certificate_held, theory_passed)
	      VALUES (?, ?, 'manual', 0, 0)`, f.student, f.school)
	exec(`INSERT INTO course_types (id, school_id, code, name, region, required_bike_category,
	          duration_minutes, max_ratio, price_pence, non_teaching, created_at)
	      VALUES (?, ?, 'CBT-125', 'CBT 125', 'NI', 'A1', 240, 4, 13000, 0, ?)`, f.courseCBT, f.school, at)
	exec(`INSERT INTO course_types (id, school_id, code, name, region, required_bike_category,
	          duration_minutes, max_ratio, price_pence, non_teaching, created_at)
	      VALUES (?, ?, 'TEST-PRAC', 'Practical test day', 'NI', 'A2', 90, 1, 6000, 1, ?)`,
		f.courseTestDay, f.school, at)
	exec(`INSERT INTO instructor_qualifications (school_id, instructor_id, course_type_id)
	      VALUES (?, ?, ?), (?, ?, ?)`,
		f.school, f.instructor, f.courseCBT, f.school, f.instructor, f.courseTestDay)
	exec(`INSERT INTO bikes (id, school_id, category, transmission, status, home_location_id, current_location_id, created_at)
	      VALUES (?, ?, 'A1', 'manual', 'ready', ?, ?, ?)`, f.bike, f.school, f.location, f.location, at)
	exec(`INSERT INTO competencies (id, school_id, course_type_id, label, sort_order)
	      VALUES (?, ?, ?, 'U-turn', 1), (?, ?, ?, 'Emergency stop', 2)`,
		f.compUturn, f.school, f.courseCBT, f.compStop, f.school, f.courseCBT)
	exec(`INSERT INTO sessions (id, school_id, course_type_id, instructor_id, location_id,
	          starts_at, ends_at, capacity, created_at)
	      VALUES (?, ?, ?, ?, ?, ?, ?, 2, ?)`,
		f.session, f.school, f.courseCBT, f.instructor, f.location,
		f.now.Add(24*time.Hour).Format(time.RFC3339), f.now.Add(28*time.Hour).Format(time.RFC3339), at)
	exec(`INSERT INTO sessions (id, school_id, course_type_id, instructor_id, location_id,
	          starts_at, ends_at, capacity, created_at)
	      VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)`,
		f.sessionTestDay, f.school, f.courseTestDay, f.instructor, f.location,
		f.now.Add(48*time.Hour).Format(time.RFC3339), f.now.Add(50*time.Hour).Format(time.RFC3339), at)
	exec(`INSERT INTO bookings (id, school_id, session_id, student_id, bike_id, status, created_at)
	      VALUES (?, ?, ?, ?, ?, 'booked', ?)`,
		f.booking, f.school, f.session, f.student, f.bike, at)
	exec(`INSERT INTO bookings (id, school_id, session_id, student_id, bike_id, status, created_at)
	      VALUES (?, ?, ?, ?, ?, 'booked', ?)`,
		f.bookingTestDay, f.school, f.sessionTestDay, f.student, f.bike, at)
}

// ----- Tests -----

func TestMarkAttendance_HappyPath(t *testing.T) {
	f := newFixture(t)
	if err := progress.MarkAttendance(context.Background(), f.scope, progress.MarkAttendanceRequest{
		BookingID: f.booking, Status: domain.BookingCompleted,
	}); err != nil {
		t.Fatalf("attendance: %v", err)
	}
	var status string
	f.db.QueryRow(`SELECT status FROM bookings WHERE id = ?`, f.booking).Scan(&status)
	if status != "completed" {
		t.Errorf("expected completed, got %s", status)
	}
}

func TestMarkAttendance_NoShow(t *testing.T) {
	f := newFixture(t)
	if err := progress.MarkAttendance(context.Background(), f.scope, progress.MarkAttendanceRequest{
		BookingID: f.booking, Status: domain.BookingNoShow,
	}); err != nil {
		t.Fatalf("no-show: %v", err)
	}
}

func TestMarkAttendance_InvalidStatus(t *testing.T) {
	f := newFixture(t)
	err := progress.MarkAttendance(context.Background(), f.scope, progress.MarkAttendanceRequest{
		BookingID: f.booking, Status: domain.BookingCancelled,
	})
	if !errors.Is(err, progress.ErrInvalidAttendance) {
		t.Errorf("expected ErrInvalidAttendance, got %v", err)
	}
}

func TestMarkAttendance_CancelledBookingRejected(t *testing.T) {
	f := newFixture(t)
	f.db.Exec(`UPDATE bookings SET status = 'cancelled' WHERE id = ?`, f.booking)
	err := progress.MarkAttendance(context.Background(), f.scope, progress.MarkAttendanceRequest{
		BookingID: f.booking, Status: domain.BookingCompleted,
	})
	if !errors.Is(err, progress.ErrBookingNotInProgress) {
		t.Errorf("expected ErrBookingNotInProgress, got %v", err)
	}
}

func TestAssessCompetency_HappyPath(t *testing.T) {
	f := newFixture(t)
	rec, err := progress.AssessCompetency(context.Background(), f.scope, progress.AssessCompetencyRequest{
		BookingID:    f.booking,
		CompetencyID: f.compUturn,
		Status:       progress.StatusCompetent,
		RecordedBy:   f.instructor,
	})
	if err != nil {
		t.Fatalf("assess: %v", err)
	}
	if rec.Status != progress.StatusCompetent {
		t.Errorf("expected competent, got %s", rec.Status)
	}
}

func TestAssessCompetency_UpsertReplaces(t *testing.T) {
	f := newFixture(t)
	if _, err := progress.AssessCompetency(context.Background(), f.scope, progress.AssessCompetencyRequest{
		BookingID: f.booking, CompetencyID: f.compUturn, Status: progress.StatusNeedsWork, RecordedBy: f.instructor,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := progress.AssessCompetency(context.Background(), f.scope, progress.AssessCompetencyRequest{
		BookingID: f.booking, CompetencyID: f.compUturn, Status: progress.StatusCompetent, RecordedBy: f.instructor,
	}); err != nil {
		t.Fatal(err)
	}
	// Only one row should exist.
	var n int
	f.db.QueryRow(`SELECT COUNT(*) FROM progress_records WHERE booking_id = ?`, f.booking).Scan(&n)
	if n != 1 {
		t.Errorf("expected 1 row after upsert, got %d", n)
	}
	var status string
	f.db.QueryRow(`SELECT status FROM progress_records WHERE booking_id = ?`, f.booking).Scan(&status)
	if status != "competent" {
		t.Errorf("expected competent after upsert, got %s", status)
	}
}

func TestAssessCompetency_NonTeachingRejected(t *testing.T) {
	f := newFixture(t)
	_, err := progress.AssessCompetency(context.Background(), f.scope, progress.AssessCompetencyRequest{
		BookingID: f.bookingTestDay, CompetencyID: f.compUturn,
		Status: progress.StatusCompetent, RecordedBy: f.instructor,
	})
	if !errors.Is(err, progress.ErrNonTeachingSession) {
		t.Errorf("expected ErrNonTeachingSession, got %v", err)
	}
}

func TestAssessCompetency_WrongCourseCompetencyRejected(t *testing.T) {
	f := newFixture(t)
	// Make a competency on a DIFFERENT course
	otherCourse := "ct_other"
	otherComp := "comp_other"
	if _, err := f.db.Exec(`INSERT INTO course_types (id, school_id, code, name, region, required_bike_category,
	          duration_minutes, max_ratio, price_pence, non_teaching, created_at)
	      VALUES (?, ?, 'X', 'Other', 'NI', 'A2', 60, 1, 5000, 0, ?)`,
		otherCourse, f.school, f.now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(`INSERT INTO competencies (id, school_id, course_type_id, label) VALUES (?, ?, ?, 'X')`,
		otherComp, f.school, otherCourse); err != nil {
		t.Fatal(err)
	}
	_, err := progress.AssessCompetency(context.Background(), f.scope, progress.AssessCompetencyRequest{
		BookingID: f.booking, CompetencyID: domain.CompetencyID(otherComp),
		Status: progress.StatusCompetent, RecordedBy: f.instructor,
	})
	if !errors.Is(err, progress.ErrCompetencyWrongCourse) {
		t.Errorf("expected ErrCompetencyWrongCourse, got %v", err)
	}
}

func TestAssessCompetency_UnknownCompetency(t *testing.T) {
	f := newFixture(t)
	_, err := progress.AssessCompetency(context.Background(), f.scope, progress.AssessCompetencyRequest{
		BookingID: f.booking, CompetencyID: "nope",
		Status: progress.StatusCompetent, RecordedBy: f.instructor,
	})
	if !errors.Is(err, progress.ErrCompetencyNotFound) {
		t.Errorf("expected ErrCompetencyNotFound, got %v", err)
	}
}

func TestAssessCompetency_InvalidStatus(t *testing.T) {
	f := newFixture(t)
	_, err := progress.AssessCompetency(context.Background(), f.scope, progress.AssessCompetencyRequest{
		BookingID: f.booking, CompetencyID: f.compUturn,
		Status: "amazing", RecordedBy: f.instructor,
	})
	if !errors.Is(err, progress.ErrInvalidStatus) {
		t.Errorf("expected ErrInvalidStatus, got %v", err)
	}
}

func TestSetBookingNotes(t *testing.T) {
	f := newFixture(t)
	if err := progress.SetBookingNotes(context.Background(), f.scope, progress.SetBookingNotesRequest{
		BookingID: f.booking, Notes: "Strong on slow control, needs roundabout practice.",
	}); err != nil {
		t.Fatal(err)
	}
	var notes string
	f.db.QueryRow(`SELECT notes FROM bookings WHERE id = ?`, f.booking).Scan(&notes)
	if notes != "Strong on slow control, needs roundabout practice." {
		t.Errorf("notes not saved, got %q", notes)
	}
}

func TestIsInstructorForBooking(t *testing.T) {
	f := newFixture(t)
	yes, err := progress.IsInstructorForBooking(context.Background(), f.scope, f.booking, f.instructor)
	if err != nil || !yes {
		t.Errorf("expected true for the assigned instructor, got %v, %v", yes, err)
	}
	no, err := progress.IsInstructorForBooking(context.Background(), f.scope, f.booking, "someone_else")
	if err != nil || no {
		t.Errorf("expected false for non-instructor, got %v, %v", no, err)
	}
}

func TestGetSessionDetail_BringsBookingsAndCompetencies(t *testing.T) {
	f := newFixture(t)
	// Add a safety flag for the student to verify it surfaces.
	if _, err := f.db.Exec(`INSERT INTO student_notes (id, school_id, student_id, kind, body, is_active, created_at, created_by)
	                       VALUES ('note1', ?, ?, 'safety_flag', 'Requires low seat', 1, ?, ?)`,
		f.school, f.student, f.now.Format(time.RFC3339), f.instructor); err != nil {
		t.Fatal(err)
	}
	// Add a charge so outstanding > 0
	if _, err := f.db.Exec(`INSERT INTO charges (id, school_id, student_id, amount_pence, description, incurred_at, created_at, created_by)
	                       VALUES ('c1', ?, ?, 13000, 'CBT', ?, ?, ?)`,
		f.school, f.student, f.now.Format(time.RFC3339), f.now.Format(time.RFC3339), f.instructor); err != nil {
		t.Fatal(err)
	}
	// Assess one competency
	if _, err := progress.AssessCompetency(context.Background(), f.scope, progress.AssessCompetencyRequest{
		BookingID: f.booking, CompetencyID: f.compUturn, Status: progress.StatusCompetent, RecordedBy: f.instructor,
	}); err != nil {
		t.Fatal(err)
	}

	sd, err := progress.GetSessionDetail(context.Background(), f.scope, f.session)
	if err != nil {
		t.Fatalf("detail: %v", err)
	}
	if len(sd.Bookings) != 1 {
		t.Fatalf("expected 1 booking, got %d", len(sd.Bookings))
	}
	bk := sd.Bookings[0]
	if len(bk.SafetyFlags) != 1 || bk.SafetyFlags[0].Body != "Requires low seat" {
		t.Errorf("safety flags: %+v", bk.SafetyFlags)
	}
	if bk.OutstandingPence != 13000 {
		t.Errorf("outstanding: got %d want 13000", bk.OutstandingPence)
	}
	if bk.Competencies[f.compUturn] != progress.StatusCompetent {
		t.Errorf("expected competent for U-turn, got %v", bk.Competencies)
	}
	if len(sd.CourseCompetencies) != 2 {
		t.Errorf("expected 2 course competencies, got %d", len(sd.CourseCompetencies))
	}
}

func TestGetSessionDetail_TestDaySkipsCompetencies(t *testing.T) {
	f := newFixture(t)
	sd, err := progress.GetSessionDetail(context.Background(), f.scope, f.sessionTestDay)
	if err != nil {
		t.Fatal(err)
	}
	if !sd.NonTeaching {
		t.Errorf("expected non-teaching flag")
	}
	if len(sd.CourseCompetencies) != 0 {
		t.Errorf("expected no competencies for test day, got %d", len(sd.CourseCompetencies))
	}
}

func TestGetSessionDetail_ExcludesCancelledBookings(t *testing.T) {
	f := newFixture(t)
	if _, err := f.db.Exec(`UPDATE bookings SET status = 'cancelled' WHERE id = ?`, f.booking); err != nil {
		t.Fatal(err)
	}
	sd, err := progress.GetSessionDetail(context.Background(), f.scope, f.session)
	if err != nil {
		t.Fatal(err)
	}
	if len(sd.Bookings) != 0 {
		t.Errorf("expected no bookings (only cancelled exists), got %d", len(sd.Bookings))
	}
}

func TestGetStudentProgress_AggregatesAcrossCourses(t *testing.T) {
	f := newFixture(t)
	if _, err := progress.AssessCompetency(context.Background(), f.scope, progress.AssessCompetencyRequest{
		BookingID: f.booking, CompetencyID: f.compUturn, Status: progress.StatusCompetent, RecordedBy: f.instructor,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := progress.AssessCompetency(context.Background(), f.scope, progress.AssessCompetencyRequest{
		BookingID: f.booking, CompetencyID: f.compStop, Status: progress.StatusNeedsWork, RecordedBy: f.instructor,
	}); err != nil {
		t.Fatal(err)
	}
	sp, err := progress.GetStudentProgress(context.Background(), f.scope, f.student)
	if err != nil {
		t.Fatal(err)
	}
	if len(sp.Courses) != 1 {
		t.Fatalf("expected 1 course (test day excluded), got %d", len(sp.Courses))
	}
	c := sp.Courses[0]
	if c.TotalCompetencies != 2 || c.CompetentCount != 1 || c.NeedsWorkCount != 1 {
		t.Errorf("counts: total=%d competent=%d needsWork=%d", c.TotalCompetencies, c.CompetentCount, c.NeedsWorkCount)
	}
}

func TestProgress_TenantIsolation(t *testing.T) {
	f := newFixture(t)
	otherScope := tenant.NewScope(f.db, domain.SchoolID("school_other"))
	err := progress.MarkAttendance(context.Background(), otherScope, progress.MarkAttendanceRequest{
		BookingID: f.booking, Status: domain.BookingCompleted,
	})
	if !errors.Is(err, progress.ErrBookingNotFound) {
		t.Errorf("expected ErrBookingNotFound (tenant-isolated), got %v", err)
	}
}
