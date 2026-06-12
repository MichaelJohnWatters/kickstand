// Event log for seed data.
//
// Today the seed inserts state directly with raw SQL. That's fast but
// it proves nothing about whether the engine would actually accept
// such transitions. This file is the start of a parallel structure:
// every state change worth proving is expressed as a typed Event with
// two ways to apply it —
//
//   - Direct: raw INSERT/UPDATE. What the seed binary calls. Keeps
//     `make backend` fast.
//   - Engine: real engine function calls (`booking.BookAt`, etc.) with
//     the event's timestamp wired into the engine's clock. Used by the
//     replay test to prove the same state is reachable through
//     legitimate API transitions.
//
// The replay test runs the same log through both and diffs the
// resulting DBs; any drift means the Direct path can produce a state
// the engine wouldn't.
//
// Scope today is just bookings + cancellations + attendance marks —
// enough to prove the pattern. The rest of the seed (schools, users,
// locations, bikes, sessions, etc.) stays as bootstrap-layer direct
// INSERTs, since none of it has an engine-managed lifecycle anyway.

package main

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/admin"
	"github.com/michaeljohnwatters/kickstand/internal/availability"
	"github.com/michaeljohnwatters/kickstand/internal/bikemaint"
	"github.com/michaeljohnwatters/kickstand/internal/booking"
	"github.com/michaeljohnwatters/kickstand/internal/closures"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/instructorpay"
	"github.com/michaeljohnwatters/kickstand/internal/ledger"
	"github.com/michaeljohnwatters/kickstand/internal/progress"
	"github.com/michaeljohnwatters/kickstand/internal/records"
	"github.com/michaeljohnwatters/kickstand/internal/templates"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// Event is one atomic, time-ordered demo state change. Concrete types
// (BookSession, CancelBooking, MarkAttendance) carry the data;
// Runner.applyDirect / applyEngine dispatch on the concrete type.
type Event interface {
	At() time.Time
	Description() string
}

// BookSession books a student onto a session with a specific bike.
// On the Engine path the event time is passed as the engine's clock,
// so the session is "future" relative to nowFn even if its real
// starts_at is in the past by the time the test runs.
type BookSession struct {
	Time       time.Time
	IntendedID string // deterministic ID for Direct; mapped to engine-generated ID for Engine
	SessionID  string
	StudentID  string
	BikeID     string // explicit so both paths pick the same bike
}

func (e BookSession) At() time.Time { return e.Time }
func (e BookSession) Description() string {
	return fmt.Sprintf("BookSession{%s on %s, bike=%s}", e.StudentID, e.SessionID, e.BikeID)
}

// CancelBooking targets a previously booked event by its IntendedID.
type CancelBooking struct {
	Time        time.Time
	IntendedID  string
	CancelledBy domain.CancelledBy
	Reason      string
}

func (e CancelBooking) At() time.Time { return e.Time }
func (e CancelBooking) Description() string {
	return fmt.Sprintf("CancelBooking{%s by %s}", e.IntendedID, e.CancelledBy)
}

// MarkAttendance flips a 'booked' or 'needs_reassignment' booking to
// 'completed' or 'no_show'. Real-world equivalent: the instructor
// taps Done / No-show in the Assess sheet.
type MarkAttendance struct {
	Time       time.Time
	IntendedID string
	Status     domain.BookingStatus // BookingCompleted or BookingNoShow
}

func (e MarkAttendance) At() time.Time { return e.Time }
func (e MarkAttendance) Description() string {
	return fmt.Sprintf("MarkAttendance{%s -> %s}", e.IntendedID, e.Status)
}

// TakeBikeOffline takes a bike out of service and opens a disruption
// record. Side effects (mirrored exactly by both paths):
//   - bike_unavailability row inserted with the supplied window
//   - bikes.status flips to 'offline'
//   - disruption row inserted
//   - every booked / needs_reassignment booking on the bike within the
//     window gets a disruption_affected_bookings row (pending) and is
//     flipped to needs_reassignment
//
// On the Engine path the engine's TakeBikeOffline does all of this.
// On the Direct path we do the same SQL inline so the resulting state
// matches; we keep the deterministic IntendedDisruptionID + IntendedUnavailID
// so re-running the seed remains idempotent.
type TakeBikeOffline struct {
	Time                 time.Time
	IntendedDisruptionID string // direct path uses as disruption.id
	IntendedUnavailID    string // direct path uses as bike_unavailability.id
	BikeID               string
	Reason               string
	StartsAt             time.Time
	EndsAt               time.Time
	Notes                string
	CreatedBy            string
}

func (e TakeBikeOffline) At() time.Time { return e.Time }
func (e TakeBikeOffline) Description() string {
	return fmt.Sprintf("TakeBikeOffline{%s, %s}", e.BikeID, e.Reason)
}

// ResolveAffectedBookingSwap resolves an affected booking by swapping
// to a different bike. The booking's bike_id moves to NewBikeID and
// status flips back to 'booked'. The disruption_affected_bookings row
// records the swap with resolved_at + new_bike_id.
type ResolveAffectedBookingSwap struct {
	Time                 time.Time
	IntendedDisruptionID string
	IntendedBookingID    string
	NewBikeID            string
	ApprovedBy           string
}

func (e ResolveAffectedBookingSwap) At() time.Time { return e.Time }
func (e ResolveAffectedBookingSwap) Description() string {
	return fmt.Sprintf("ResolveSwap{%s -> %s}", e.IntendedBookingID, e.NewBikeID)
}

// RestoreBike flips an offline bike back to 'ready'. Used to model
// the "bike came back in service" transition that closes out the
// physical side of a disruption — the affected_bookings link stays
// where it is (the demo for "stale needs cleanup" keeps it pending).
type RestoreBike struct {
	Time   time.Time
	BikeID string
}

func (e RestoreBike) At() time.Time { return e.Time }
func (e RestoreBike) Description() string {
	return fmt.Sprintf("RestoreBike{%s}", e.BikeID)
}

// RecordPayment records a payment from a student against their
// balance. Engine path calls ledger.RecordPayment; Direct path does
// the same INSERT (payments are stateless — no booking link, no
// auto-charge to void).
type RecordPayment struct {
	Time        time.Time
	IntendedID  string // direct path payment.id
	StudentID   string
	AmountPence int64
	Method      domain.PaymentMethod
	ReceivedAt  time.Time
	RecordedBy  string
	Notes       string
}

func (e RecordPayment) At() time.Time { return e.Time }
func (e RecordPayment) Description() string {
	return fmt.Sprintf("RecordPayment{%s £%.2f}", e.StudentID, float64(e.AmountPence)/100)
}

// JoinWaitlist puts a student on a fully-booked session's waitlist.
// The engine requires the session to still be future, scheduled, and
// at-or-over capacity — the event log respects this by sequencing
// after the BookSession that fills the session.
type JoinWaitlist struct {
	Time       time.Time
	IntendedID string // direct path waitlist_entries.id
	SessionID  string
	StudentID  string
}

func (e JoinWaitlist) At() time.Time { return e.Time }
func (e JoinWaitlist) Description() string {
	return fmt.Sprintf("JoinWaitlist{%s on %s}", e.StudentID, e.SessionID)
}

// AssessCompetency upserts a per-(booking,competency) progress
// record. Engine path uses progress.AssessCompetency which gates on
// session-must-be-teaching and competency-must-belong-to-course.
type AssessCompetency struct {
	Time              time.Time
	IntendedID        string // direct path progress_records.id
	IntendedBookingID string
	CompetencyID      string
	Status            string // not_assessed / developing / competent / needs_work
	RecordedBy        string
}

func (e AssessCompetency) At() time.Time { return e.Time }
func (e AssessCompetency) Description() string {
	return fmt.Sprintf("AssessCompetency{%s -> %s}", e.CompetencyID, e.Status)
}

// RecordBikeExpense logs a maintenance expense for a bike. Receipt
// bytes/thumb/key are prepared by the seed binary's pre-event step
// (the filestore upload is bound to the seed binary, not the event)
// and passed in here so both Direct and Engine paths use the same
// shape the engine's bikemaint.Record would accept.
type RecordBikeExpense struct {
	Time               time.Time
	IntendedID         string // direct path bike_expenses.id
	BikeID             string
	Category           string // service / parts / mot / tax / labour / other
	AmountPence        int
	OccurredAt         string // YYYY-MM-DD
	Vendor             string
	Notes              string
	ReceiptStorageKey  string
	ReceiptContentType string
	ReceiptSizeBytes   int
	ReceiptThumb       []byte
	RecordedBy         string
}

func (e RecordBikeExpense) At() time.Time { return e.Time }
func (e RecordBikeExpense) Description() string {
	return fmt.Sprintf("RecordBikeExpense{%s £%.2f %s}",
		e.BikeID, float64(e.AmountPence)/100, e.Category)
}

// SetInstructorPayModel writes (or replaces) an instructor's pay model.
type SetInstructorPayModel struct {
	Time         time.Time
	IntendedID   string // direct path instructor_pay_models.id
	InstructorID string
	PayBasis     domain.PayBasis
	RateValue    int64
}

func (e SetInstructorPayModel) At() time.Time { return e.Time }
func (e SetInstructorPayModel) Description() string {
	return fmt.Sprintf("SetInstructorPayModel{%s %s}", e.InstructorID, e.PayBasis)
}

// RecordInstructorEarning logs a per-session earning for an instructor.
// SessionID is optional. SourceBookingIDs resolves to charge ids via
// the same (booking -> live charge) lookup the seed uses elsewhere.
type RecordInstructorEarning struct {
	Time             time.Time
	IntendedID       string // direct path instructor_earnings.id
	InstructorID     string
	SessionID        string // optional
	AmountPence      int64
	Basis            domain.PayBasis
	Notes            string
	SourceBookingIDs []string // optional — looked up to charges
	CreatedBy        string
}

func (e RecordInstructorEarning) At() time.Time { return e.Time }
func (e RecordInstructorEarning) Description() string {
	return fmt.Sprintf("RecordInstructorEarning{%s £%.2f}",
		e.InstructorID, float64(e.AmountPence)/100)
}

// RecordInstructorPayment records a payout to an instructor.
type RecordInstructorPayment struct {
	Time         time.Time
	IntendedID   string // direct path instructor_payments.id
	InstructorID string
	AmountPence  int64
	Method       domain.PaymentMethod
	PaidAt       time.Time
	RecordedBy   string
	Notes        string
}

func (e RecordInstructorPayment) At() time.Time { return e.Time }
func (e RecordInstructorPayment) Description() string {
	return fmt.Sprintf("RecordInstructorPayment{%s £%.2f}",
		e.InstructorID, float64(e.AmountPence)/100)
}

// RecordExternalTest records a DVA/DVSA external test result (or a
// "booked" attempt) for a student. Engine path uses
// records.RecordExternalTest which auto-computes attempt_number; the
// Direct path takes it as a parameter for parity with the original
// seed data.
type RecordExternalTest struct {
	Time          time.Time
	IntendedID    string
	StudentID     string
	TestType      string
	Region        domain.Region
	AttemptNumber int
	ScheduledAt   time.Time
	Reference     string
	Outcome       string
	Notes         string
}

func (e RecordExternalTest) At() time.Time { return e.Time }
func (e RecordExternalTest) Description() string {
	return fmt.Sprintf("RecordExternalTest{%s %s %s}", e.StudentID, e.TestType, e.Outcome)
}

// AddSchoolClosure records a calendar closure for the school.
type AddSchoolClosure struct {
	Time       time.Time
	IntendedID string // direct path school_closures.id
	FromDate   string // YYYY-MM-DD
	ToDate     string // YYYY-MM-DD
	Label      string
	Reason     string
	CreatedBy  string
}

func (e AddSchoolClosure) At() time.Time { return e.Time }
func (e AddSchoolClosure) Description() string {
	return fmt.Sprintf("AddSchoolClosure{%s..%s %q}", e.FromDate, e.ToDate, e.Label)
}

// CreateRecurringAvailability declares an instructor's weekly slot.
type CreateRecurringAvailability struct {
	Time          time.Time
	IntendedID    string // direct path instructor_recurring_availability.id
	InstructorID  string
	Weekday       int
	StartsAtLocal string // HH:MM
	EndsAtLocal   string // HH:MM
	LocationID    string
}

func (e CreateRecurringAvailability) At() time.Time { return e.Time }
func (e CreateRecurringAvailability) Description() string {
	return fmt.Sprintf("CreateRecurringAvailability{%s w%d %s-%s}",
		e.InstructorID, e.Weekday, e.StartsAtLocal, e.EndsAtLocal)
}

// AddTimeOff blocks out a window in the instructor's calendar.
type AddTimeOff struct {
	Time         time.Time
	IntendedID   string // direct path instructor_time_off.id
	InstructorID string
	StartsAt     time.Time
	EndsAt       time.Time
	Reason       string
}

func (e AddTimeOff) At() time.Time { return e.Time }
func (e AddTimeOff) Description() string {
	return fmt.Sprintf("AddTimeOff{%s %s-%s}", e.InstructorID,
		e.StartsAt.Format(time.RFC3339), e.EndsAt.Format(time.RFC3339))
}

// CreateSessionTemplate defines a recurring session pattern.
type CreateSessionTemplate struct {
	Time            time.Time
	IntendedID      string // direct path session_templates.id
	CourseTypeID    string
	InstructorID    string
	LocationID      string
	Weekday         int
	StartsAtTime    string // HH:MM
	DurationMinutes int
	Capacity        int
	CreatedBy       string
}

func (e CreateSessionTemplate) At() time.Time { return e.Time }
func (e CreateSessionTemplate) Description() string {
	return fmt.Sprintf("CreateSessionTemplate{%s w%d %s}",
		e.CourseTypeID, e.Weekday, e.StartsAtTime)
}

// AddStudentNote writes a staff-visible note against a student.
// Engine path uses records.AddNote which validates the kind enum
// (safety_flag / progress_note) and requires a non-empty body.
type AddStudentNote struct {
	Time       time.Time
	IntendedID string // direct path student_notes.id
	StudentID  string
	Kind       string // safety_flag / progress_note
	Body       string
	CreatedBy  string
}

func (e AddStudentNote) At() time.Time { return e.Time }
func (e AddStudentNote) Description() string {
	return fmt.Sprintf("AddStudentNote{%s on %s}", e.Kind, e.StudentID)
}

// LogIncident records a bike incident. Engine path uses
// records.LogIncident which writes an incident row plus three
// standard follow-up tasks (mechanical_check, student_welfare,
// insurance_notify). Direct path mirrors that exactly.
//
// IntendedBookingID is optional — many demo incidents aren't tied
// to a specific booking (e.g. "near-miss noticed in the car park").
type LogIncident struct {
	Time              time.Time
	IntendedID        string // direct path incidents.id
	BikeID            string // optional
	StudentID         string // optional
	IntendedBookingID string // optional — looked up in Runner if non-empty
	Note              string // incident description
	CreatedBy         string
}

func (e LogIncident) At() time.Time { return e.Time }
func (e LogIncident) Description() string {
	return fmt.Sprintf("LogIncident{%s on %s}", e.IntendedID, e.BikeID)
}

// Runner applies a chronological event log via one of two paths and
// tracks the mapping from each event's intended id to the actual id
// the path produced (the engine generates UUIDs for booking +
// disruption rows; direct path uses the deterministic intended ids).
type Runner struct {
	SchoolID      string
	bookingIDs    map[string]string // intended booking ID -> actual booking ID
	disruptionIDs map[string]string // intended disruption ID -> actual disruption ID
}

func NewRunner(schoolID string) *Runner {
	return &Runner{
		SchoolID:      schoolID,
		bookingIDs:    map[string]string{},
		disruptionIDs: map[string]string{},
	}
}

// ActualBookingID returns the booking id the runner ended up using for
// the given intended id — useful for tests that need to look up the
// engine-generated UUID after a replay.
func (r *Runner) ActualBookingID(intendedID string) string {
	return r.bookingIDs[intendedID]
}

// ActualDisruptionID is the same for disruption rows.
func (r *Runner) ActualDisruptionID(intendedID string) string {
	return r.disruptionIDs[intendedID]
}

// ApplyDirect runs events through raw SQL, in chronological order.
func (r *Runner) ApplyDirect(ctx context.Context, d *sql.DB, events []Event) error {
	for _, e := range sortByTime(events) {
		if err := r.applyDirectOne(ctx, d, e); err != nil {
			return fmt.Errorf("direct %s: %w", e.Description(), err)
		}
	}
	return nil
}

// ApplyEngine runs events through real engine function calls, using
// each event's At() as the injected clock.
func (r *Runner) ApplyEngine(ctx context.Context, scope *tenant.Scope, events []Event) error {
	for _, e := range sortByTime(events) {
		if err := r.applyEngineOne(ctx, scope, e); err != nil {
			return fmt.Errorf("engine %s: %w", e.Description(), err)
		}
	}
	return nil
}

func sortByTime(events []Event) []Event {
	out := make([]Event, len(events))
	copy(out, events)
	sort.SliceStable(out, func(i, j int) bool { return out[i].At().Before(out[j].At()) })
	return out
}

func (r *Runner) applyDirectOne(ctx context.Context, d *sql.DB, e Event) error {
	ts := e.At().UTC().Format(time.RFC3339)
	switch ev := e.(type) {
	case BookSession:
		if _, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO bookings
			(id, school_id, session_id, student_id, bike_id, status, created_at)
			VALUES (?, ?, ?, ?, ?, 'booked', ?)`,
			ev.IntendedID, r.SchoolID, ev.SessionID, ev.StudentID,
			nullIfEmpty(ev.BikeID), ts); err != nil {
			return err
		}
		r.bookingIDs[ev.IntendedID] = ev.IntendedID
		// Mirror the engine's auto-charge: when the session's
		// course_type has a positive price_pence, INSERT a charge with
		// the same shape engine emits. Keeps DB_A and DB_B's charges
		// equivalent without us having to maintain a parallel
		// manual-charge layer in the seed.
		return r.autoChargeDirect(ctx, d, ev.IntendedID, ev.SessionID, ev.StudentID, ts)
	case CancelBooking:
		id, ok := r.bookingIDs[ev.IntendedID]
		if !ok {
			return fmt.Errorf("no prior BookSession for %s", ev.IntendedID)
		}
		// Match the engine's Cancel exactly — it leaves bike_id
		// alone. The booking's history of which bike was held is
		// preserved for the audit trail.
		if _, err := d.ExecContext(ctx, `UPDATE bookings
			   SET status = 'cancelled',
			       cancelled_by = ?,
			       cancellation_reason = ?,
			       cancelled_at = ?
			 WHERE id = ? AND school_id = ?`,
			string(ev.CancelledBy), nullIfEmpty(ev.Reason), ts, id, r.SchoolID); err != nil {
			return err
		}
		// Mirror the engine's void-auto-charge: any live charge
		// linked to this booking gets voided in the same step.
		var voider any
		if ev.CancelledBy == domain.CancelledByStudent {
			var studentID string
			if err := d.QueryRowContext(ctx,
				`SELECT student_id FROM bookings WHERE id = ? AND school_id = ?`,
				id, r.SchoolID).Scan(&studentID); err == nil {
				voider = studentID
			}
		}
		_, err := d.ExecContext(ctx, `UPDATE charges
			SET voided_at = ?, voided_by = ?, void_reason = 'booking_cancelled'
			WHERE school_id = ? AND booking_id = ? AND voided_at IS NULL`,
			ts, voider, r.SchoolID, id)
		return err
	case MarkAttendance:
		id, ok := r.bookingIDs[ev.IntendedID]
		if !ok {
			return fmt.Errorf("no prior BookSession for %s", ev.IntendedID)
		}
		_, err := d.ExecContext(ctx, `UPDATE bookings SET status = ?
			WHERE id = ? AND school_id = ?`,
			string(ev.Status), id, r.SchoolID)
		return err
	case TakeBikeOffline:
		return r.applyDirectTakeBikeOffline(ctx, d, ev, ts)
	case ResolveAffectedBookingSwap:
		return r.applyDirectResolveSwap(ctx, d, ev, ts)
	case RestoreBike:
		_, err := d.ExecContext(ctx,
			`UPDATE bikes SET status = 'ready' WHERE id = ? AND school_id = ?`,
			ev.BikeID, r.SchoolID)
		return err
	case RecordPayment:
		_, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO payments
			(id, school_id, student_id, amount_pence, method,
			 received_at, recorded_by, notes)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			ev.IntendedID, r.SchoolID, ev.StudentID, ev.AmountPence,
			string(ev.Method), ev.ReceivedAt.UTC().Format(time.RFC3339),
			ev.RecordedBy, nullIfEmpty(ev.Notes))
		return err
	case JoinWaitlist:
		_, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO waitlist_entries
			(id, school_id, session_id, student_id, joined_at)
			VALUES (?, ?, ?, ?, ?)`,
			ev.IntendedID, r.SchoolID, ev.SessionID, ev.StudentID, ts)
		return err
	case AssessCompetency:
		bookingID, ok := r.bookingIDs[ev.IntendedBookingID]
		if !ok {
			return fmt.Errorf("no prior BookSession for %s", ev.IntendedBookingID)
		}
		// Need student_id for the row — pull it from the booking.
		var studentID string
		if err := d.QueryRowContext(ctx,
			`SELECT student_id FROM bookings WHERE id = ? AND school_id = ?`,
			bookingID, r.SchoolID).Scan(&studentID); err != nil {
			return fmt.Errorf("lookup student for progress: %w", err)
		}
		_, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO progress_records
			(id, school_id, booking_id, student_id, competency_id,
			 status, recorded_at, recorded_by)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			ev.IntendedID, r.SchoolID, bookingID, studentID, ev.CompetencyID,
			ev.Status, ts, ev.RecordedBy)
		return err
	case LogIncident:
		return r.applyDirectLogIncident(ctx, d, ev, ts)
	case AddStudentNote:
		_, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO student_notes
			(id, school_id, student_id, kind, body, is_active, created_at, created_by)
			VALUES (?, ?, ?, ?, ?, 1, ?, ?)`,
			ev.IntendedID, r.SchoolID, ev.StudentID, ev.Kind, ev.Body, ts, ev.CreatedBy)
		return err
	case RecordExternalTest:
		var schedArg any
		if !ev.ScheduledAt.IsZero() {
			schedArg = ev.ScheduledAt.UTC().Format(time.RFC3339)
		}
		_, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO external_tests
			(id, school_id, student_id, test_type, region, attempt_number,
			 scheduled_at, reference, outcome, notes, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			ev.IntendedID, r.SchoolID, ev.StudentID, ev.TestType, string(ev.Region),
			ev.AttemptNumber, schedArg, ev.Reference, ev.Outcome, ev.Notes, ts)
		return err
	case AddSchoolClosure:
		_, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO school_closures
			(id, school_id, from_date, to_date, label, reason, created_at, created_by)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			ev.IntendedID, r.SchoolID, ev.FromDate, ev.ToDate,
			ev.Label, ev.Reason, ts, ev.CreatedBy)
		return err
	case CreateRecurringAvailability:
		_, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO instructor_recurring_availability
			(id, school_id, instructor_id, weekday, starts_at_local, ends_at_local, location_id)
			VALUES (?, ?, ?, ?, ?, ?, ?)`,
			ev.IntendedID, r.SchoolID, ev.InstructorID, ev.Weekday,
			ev.StartsAtLocal, ev.EndsAtLocal, ev.LocationID)
		return err
	case AddTimeOff:
		_, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO instructor_time_off
			(id, school_id, instructor_id, starts_at, ends_at, reason)
			VALUES (?, ?, ?, ?, ?, ?)`,
			ev.IntendedID, r.SchoolID, ev.InstructorID,
			ev.StartsAt.UTC().Format(time.RFC3339),
			ev.EndsAt.UTC().Format(time.RFC3339),
			ev.Reason)
		return err
	case CreateSessionTemplate:
		_, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO session_templates
			(id, school_id, course_type_id, instructor_id, location_id,
			 weekday, starts_at_time, duration_minutes, capacity,
			 created_at, created_by)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			ev.IntendedID, r.SchoolID, ev.CourseTypeID, ev.InstructorID, ev.LocationID,
			ev.Weekday, ev.StartsAtTime, ev.DurationMinutes, ev.Capacity,
			ts, ev.CreatedBy)
		return err
	case SetInstructorPayModel:
		_, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO instructor_pay_models
			(id, school_id, instructor_id, pay_basis, rate_value, created_at)
			VALUES (?, ?, ?, ?, ?, ?)`,
			ev.IntendedID, r.SchoolID, ev.InstructorID,
			string(ev.PayBasis), ev.RateValue, ts)
		return err
	case RecordInstructorEarning:
		var sessionArg any
		if ev.SessionID != "" {
			sessionArg = ev.SessionID
		}
		if _, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO instructor_earnings
			(id, school_id, instructor_id, session_id, amount_pence,
			 basis, notes, created_at, created_by)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			ev.IntendedID, r.SchoolID, ev.InstructorID, sessionArg,
			ev.AmountPence, string(ev.Basis), ev.Notes, ts, ev.CreatedBy); err != nil {
			return err
		}
		// Link to source charges via booking ids.
		for _, bookingIntendedID := range ev.SourceBookingIDs {
			bookingID, ok := r.bookingIDs[bookingIntendedID]
			if !ok {
				return fmt.Errorf("no prior BookSession for %s", bookingIntendedID)
			}
			var chargeID string
			if err := d.QueryRowContext(ctx, `
				SELECT id FROM charges
				WHERE school_id = ? AND booking_id = ? AND voided_at IS NULL
				ORDER BY created_at ASC LIMIT 1`,
				r.SchoolID, bookingID).Scan(&chargeID); err != nil {
				return fmt.Errorf("lookup source charge: %w", err)
			}
			if _, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO instructor_earning_sources
				(school_id, earning_id, charge_id)
				VALUES (?, ?, ?)`, r.SchoolID, ev.IntendedID, chargeID); err != nil {
				return err
			}
		}
		return nil
	case RecordInstructorPayment:
		_, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO instructor_payments
			(id, school_id, instructor_id, amount_pence, method, paid_at, recorded_by, notes)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			ev.IntendedID, r.SchoolID, ev.InstructorID, ev.AmountPence,
			string(ev.Method), ev.PaidAt.UTC().Format(time.RFC3339),
			ev.RecordedBy, nullIfEmpty(ev.Notes))
		return err
	case RecordBikeExpense:
		_, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO bike_expenses
			(id, school_id, bike_id, category, amount_pence,
			 occurred_at, vendor, notes,
			 receipt_storage_key, receipt_content_type, receipt_size_bytes,
			 receipt_thumb, recorded_by, recorded_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			ev.IntendedID, r.SchoolID, ev.BikeID, ev.Category, ev.AmountPence,
			ev.OccurredAt, ev.Vendor, ev.Notes,
			ev.ReceiptStorageKey, ev.ReceiptContentType, ev.ReceiptSizeBytes,
			ev.ReceiptThumb, ev.RecordedBy, ts)
		return err
	default:
		return fmt.Errorf("unknown event type %T", e)
	}
}

// applyDirectLogIncident mirrors records.LogIncident: writes the
// incident row plus three standard follow-up tasks. Skips the
// take-bike-offline branch (none of the demo incidents use it). The
// booking link, if present, is resolved through the runner's
// intended->actual id map.
func (r *Runner) applyDirectLogIncident(ctx context.Context, d *sql.DB, ev LogIncident, ts string) error {
	var bookingID any
	if ev.IntendedBookingID != "" {
		id, ok := r.bookingIDs[ev.IntendedBookingID]
		if !ok {
			return fmt.Errorf("no prior BookSession for %s", ev.IntendedBookingID)
		}
		bookingID = id
	}
	var bikeArg, studentArg any
	if ev.BikeID != "" {
		bikeArg = ev.BikeID
	}
	if ev.StudentID != "" {
		studentArg = ev.StudentID
	}
	if _, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO incidents
		(id, school_id, bike_id, student_id, booking_id, occurred_at,
		 description, took_bike_offline, created_at, created_by)
		VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)`,
		ev.IntendedID, r.SchoolID, bikeArg, studentArg, bookingID,
		ts, ev.Note, ts, ev.CreatedBy); err != nil {
		return fmt.Errorf("insert incident: %w", err)
	}
	// Three default followups — same shape and offsets the engine uses.
	occurredAt, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		return err
	}
	standard := []struct {
		kind, description string
		dueIn             time.Duration
	}{
		{"mechanical_check", "Inspect the bike and sign off road-worthy.", 24 * time.Hour},
		{"student_welfare", "Call the student to check they're OK.", 24 * time.Hour},
		{"insurance_notify", "Notify the insurer if severity warrants it.", 7 * 24 * time.Hour},
	}
	for _, s := range standard {
		due := occurredAt.Add(s.dueIn).Format("2006-01-02")
		if _, err := d.ExecContext(ctx, `INSERT INTO incident_followups
			(id, school_id, incident_id, kind, description, due_on, created_at, created_by)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			domain.NewID(), r.SchoolID, ev.IntendedID, s.kind, s.description,
			due, ts, ev.CreatedBy); err != nil {
			return fmt.Errorf("insert followup: %w", err)
		}
	}
	return nil
}

// autoChargeDirect mirrors booking.autoChargeForBooking: looks up the
// session's course price + label, and INSERTs a charge with the same
// shape the engine would have written. Skips silently when price is 0
// (i.e. the course opts out of standard pricing).
func (r *Runner) autoChargeDirect(ctx context.Context, d *sql.DB, bookingID, sessionID, studentID, ts string) error {
	var price int64
	var courseName, courseCode string
	if err := d.QueryRowContext(ctx, `
		SELECT COALESCE(ct.price_pence, 0), COALESCE(ct.name, ''), COALESCE(ct.code, '')
		FROM sessions s
		JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		WHERE s.id = ? AND s.school_id = ?
	`, sessionID, r.SchoolID).Scan(&price, &courseName, &courseCode); err != nil {
		return fmt.Errorf("lookup course price: %w", err)
	}
	if price <= 0 {
		return nil
	}
	desc := courseName
	if courseCode != "" {
		desc = fmt.Sprintf("%s · %s", courseCode, courseName)
	}
	_, err := d.ExecContext(ctx, `INSERT INTO charges
		(id, school_id, student_id, booking_id, amount_pence,
		 description, incurred_at, created_at, created_by)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		domain.NewID(), r.SchoolID, studentID, bookingID, price,
		desc, ts, ts, studentID)
	return err
}

// applyDirectTakeBikeOffline mirrors booking.TakeBikeOffline as raw
// SQL — same writes, same affected-booking flip, just no notify
// events (the diff only looks at the bookings table for now, so the
// notify divergence is invisible). The "now" passed in is the event's
// timestamp.
func (r *Runner) applyDirectTakeBikeOffline(ctx context.Context, d *sql.DB, ev TakeBikeOffline, ts string) error {
	startsStr := ev.StartsAt.UTC().Format(time.RFC3339)
	endsStr := ev.EndsAt.UTC().Format(time.RFC3339)
	if _, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO bike_unavailability
		(id, school_id, bike_id, reason, starts_at, ends_at, notes, created_at, created_by)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		ev.IntendedUnavailID, r.SchoolID, ev.BikeID, ev.Reason,
		startsStr, endsStr, ev.Notes, ts, ev.CreatedBy); err != nil {
		return fmt.Errorf("insert bike_unavailability: %w", err)
	}
	if _, err := d.ExecContext(ctx,
		`UPDATE bikes SET status = 'offline' WHERE id = ? AND school_id = ?`,
		ev.BikeID, r.SchoolID); err != nil {
		return fmt.Errorf("update bike status: %w", err)
	}
	if _, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO disruptions
		(id, school_id, bike_id, started_at, reason, created_by)
		VALUES (?, ?, ?, ?, ?, ?)`,
		ev.IntendedDisruptionID, r.SchoolID, ev.BikeID, ts, ev.Reason, ev.CreatedBy); err != nil {
		return fmt.Errorf("insert disruption: %w", err)
	}
	r.disruptionIDs[ev.IntendedDisruptionID] = ev.IntendedDisruptionID
	// Find all active bookings on the bike whose session overlaps
	// the unavailability window. Same predicate the engine uses.
	rows, err := d.QueryContext(ctx, `
		SELECT b.id
		FROM bookings b
		JOIN sessions s ON s.id = b.session_id AND s.school_id = b.school_id
		WHERE b.school_id = ?
		  AND b.bike_id = ?
		  AND b.status IN ('booked', 'needs_reassignment')
		  AND s.starts_at < ?
		  AND s.ends_at > ?
	`, r.SchoolID, ev.BikeID, endsStr, startsStr)
	if err != nil {
		return fmt.Errorf("find affected bookings: %w", err)
	}
	defer rows.Close()
	var affected []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return err
		}
		affected = append(affected, id)
	}
	for _, id := range affected {
		if _, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO disruption_affected_bookings
			(school_id, disruption_id, booking_id, resolution)
			VALUES (?, ?, ?, 'pending')`,
			r.SchoolID, ev.IntendedDisruptionID, id); err != nil {
			return fmt.Errorf("insert disruption_affected_bookings: %w", err)
		}
		if _, err := d.ExecContext(ctx, `UPDATE bookings
			SET status = 'needs_reassignment'
			WHERE id = ? AND school_id = ? AND status = 'booked'`,
			id, r.SchoolID); err != nil {
			return fmt.Errorf("flip booking to needs_reassignment: %w", err)
		}
	}
	return nil
}

// applyDirectResolveSwap mirrors booking.ResolveAffectedBooking on the
// swap path — same UPDATEs on bookings + disruption_affected_bookings.
func (r *Runner) applyDirectResolveSwap(ctx context.Context, d *sql.DB, ev ResolveAffectedBookingSwap, ts string) error {
	bookingID, ok := r.bookingIDs[ev.IntendedBookingID]
	if !ok {
		return fmt.Errorf("no prior BookSession for %s", ev.IntendedBookingID)
	}
	disruptionID, ok := r.disruptionIDs[ev.IntendedDisruptionID]
	if !ok {
		return fmt.Errorf("no prior TakeBikeOffline for %s", ev.IntendedDisruptionID)
	}
	if _, err := d.ExecContext(ctx, `UPDATE bookings
		SET bike_id = ?, status = 'booked'
		WHERE id = ? AND school_id = ? AND status = 'needs_reassignment'`,
		ev.NewBikeID, bookingID, r.SchoolID); err != nil {
		return fmt.Errorf("swap booking bike: %w", err)
	}
	if _, err := d.ExecContext(ctx, `UPDATE disruption_affected_bookings
		SET resolution = 'swapped', new_bike_id = ?, resolved_at = ?
		WHERE disruption_id = ? AND booking_id = ? AND school_id = ?`,
		ev.NewBikeID, ts, disruptionID, bookingID, r.SchoolID); err != nil {
		return fmt.Errorf("update disruption link: %w", err)
	}
	return nil
}

func (r *Runner) applyEngineOne(ctx context.Context, scope *tenant.Scope, e Event) error {
	nowFn := func() time.Time { return e.At() }
	switch ev := e.(type) {
	case BookSession:
		res, err := booking.BookAt(ctx, scope, booking.Request{
			SessionID: domain.SessionID(ev.SessionID),
			StudentID: domain.UserID(ev.StudentID),
			BikeID:    domain.BikeID(ev.BikeID),
		}, nowFn)
		if err != nil {
			return err
		}
		r.bookingIDs[ev.IntendedID] = string(res.Booking.ID)
		return nil
	case CancelBooking:
		id, ok := r.bookingIDs[ev.IntendedID]
		if !ok {
			return fmt.Errorf("no prior BookSession for %s", ev.IntendedID)
		}
		_, err := booking.CancelAt(ctx, scope, booking.CancelRequest{
			BookingID:   domain.BookingID(id),
			CancelledBy: ev.CancelledBy,
			Reason:      ev.Reason,
		}, nowFn)
		return err
	case MarkAttendance:
		id, ok := r.bookingIDs[ev.IntendedID]
		if !ok {
			return fmt.Errorf("no prior BookSession for %s", ev.IntendedID)
		}
		return progress.MarkAttendance(ctx, scope, progress.MarkAttendanceRequest{
			BookingID: domain.BookingID(id),
			Status:    ev.Status,
		})
	case TakeBikeOffline:
		res, err := booking.TakeBikeOffline(ctx, scope, booking.TakeBikeOfflineRequest{
			BikeID:    domain.BikeID(ev.BikeID),
			Reason:    ev.Reason,
			StartsAt:  ev.StartsAt,
			EndsAt:    ev.EndsAt,
			Notes:     ev.Notes,
			CreatedBy: domain.UserID(ev.CreatedBy),
		})
		if err != nil {
			return err
		}
		r.disruptionIDs[ev.IntendedDisruptionID] = string(res.DisruptionID)
		return nil
	case ResolveAffectedBookingSwap:
		bookingID, ok := r.bookingIDs[ev.IntendedBookingID]
		if !ok {
			return fmt.Errorf("no prior BookSession for %s", ev.IntendedBookingID)
		}
		disruptionID, ok := r.disruptionIDs[ev.IntendedDisruptionID]
		if !ok {
			return fmt.Errorf("no prior TakeBikeOffline for %s", ev.IntendedDisruptionID)
		}
		return booking.ResolveAffectedBooking(ctx, scope, booking.ResolveAffectedBookingRequest{
			DisruptionID: domain.DisruptionID(disruptionID),
			BookingID:    domain.BookingID(bookingID),
			Resolution:   booking.ResolveSwap,
			NewBikeID:    domain.BikeID(ev.NewBikeID),
			ApprovedBy:   domain.UserID(ev.ApprovedBy),
		})
	case RestoreBike:
		return admin.RestoreBike(ctx, scope, domain.BikeID(ev.BikeID))
	case RecordPayment:
		_, err := ledger.RecordPayment(ctx, scope, ledger.RecordPaymentRequest{
			StudentID:   domain.UserID(ev.StudentID),
			AmountPence: domain.Money(ev.AmountPence),
			Method:      ev.Method,
			ReceivedAt:  ev.ReceivedAt,
			RecordedBy:  domain.UserID(ev.RecordedBy),
			Notes:       ev.Notes,
		})
		return err
	case JoinWaitlist:
		nowFn := func() time.Time { return e.At() }
		_, err := booking.JoinWaitlistAt(ctx, scope,
			domain.SessionID(ev.SessionID),
			domain.UserID(ev.StudentID),
			nowFn)
		return err
	case AssessCompetency:
		bookingID, ok := r.bookingIDs[ev.IntendedBookingID]
		if !ok {
			return fmt.Errorf("no prior BookSession for %s", ev.IntendedBookingID)
		}
		_, err := progress.AssessCompetency(ctx, scope, progress.AssessCompetencyRequest{
			BookingID:    domain.BookingID(bookingID),
			CompetencyID: domain.CompetencyID(ev.CompetencyID),
			Status:       ev.Status,
			RecordedBy:   domain.UserID(ev.RecordedBy),
		})
		return err
	case LogIncident:
		var bookingID domain.BookingID
		if ev.IntendedBookingID != "" {
			id, ok := r.bookingIDs[ev.IntendedBookingID]
			if !ok {
				return fmt.Errorf("no prior BookSession for %s", ev.IntendedBookingID)
			}
			bookingID = domain.BookingID(id)
		}
		_, err := records.LogIncident(ctx, scope, records.LogIncidentRequest{
			BikeID:      domain.BikeID(ev.BikeID),
			StudentID:   domain.UserID(ev.StudentID),
			BookingID:   bookingID,
			OccurredAt:  e.At(),
			Description: ev.Note,
			CreatedBy:   domain.UserID(ev.CreatedBy),
		})
		return err
	case AddStudentNote:
		_, err := records.AddNote(ctx, scope, records.AddNoteRequest{
			StudentID: domain.UserID(ev.StudentID),
			Kind:      ev.Kind,
			Body:      ev.Body,
			CreatedBy: domain.UserID(ev.CreatedBy),
		})
		return err
	case RecordExternalTest:
		_, err := records.RecordExternalTest(ctx, scope, records.RecordExternalTestRequest{
			StudentID:   domain.UserID(ev.StudentID),
			TestType:    ev.TestType,
			Region:      ev.Region,
			ScheduledAt: ev.ScheduledAt,
			Reference:   ev.Reference,
			Outcome:     ev.Outcome,
			Notes:       ev.Notes,
		})
		return err
	case AddSchoolClosure:
		_, err := closures.Create(ctx, scope, closures.CreateRequest{
			FromDate:  ev.FromDate,
			ToDate:    ev.ToDate,
			Label:     ev.Label,
			Reason:    ev.Reason,
			CreatedBy: domain.UserID(ev.CreatedBy),
		})
		return err
	case CreateRecurringAvailability:
		_, err := availability.CreateRecurringSlot(ctx, scope, availability.CreateRecurringRequest{
			InstructorID:  domain.UserID(ev.InstructorID),
			Weekday:       ev.Weekday,
			StartsAtLocal: ev.StartsAtLocal,
			EndsAtLocal:   ev.EndsAtLocal,
			LocationID:    domain.LocationID(ev.LocationID),
		})
		return err
	case AddTimeOff:
		_, err := availability.AddTimeOff(ctx, scope, availability.AddTimeOffRequest{
			InstructorID: domain.UserID(ev.InstructorID),
			StartsAt:     ev.StartsAt,
			EndsAt:       ev.EndsAt,
			Reason:       ev.Reason,
		})
		return err
	case CreateSessionTemplate:
		_, err := templates.Create(ctx, scope, templates.CreateRequest{
			CourseTypeID:    domain.CourseTypeID(ev.CourseTypeID),
			InstructorID:    domain.UserID(ev.InstructorID),
			LocationID:      domain.LocationID(ev.LocationID),
			Weekday:         ev.Weekday,
			StartsAtTime:    ev.StartsAtTime,
			DurationMinutes: ev.DurationMinutes,
			Capacity:        ev.Capacity,
			CreatedBy:       domain.UserID(ev.CreatedBy),
		})
		return err
	case SetInstructorPayModel:
		return instructorpay.SetPayModel(ctx, scope, instructorpay.SetPayModelRequest{
			InstructorID: domain.UserID(ev.InstructorID),
			PayBasis:     ev.PayBasis,
			RateValue:    ev.RateValue,
		})
	case RecordInstructorEarning:
		var sourceCharges []domain.ChargeID
		for _, bookingIntendedID := range ev.SourceBookingIDs {
			bookingID, ok := r.bookingIDs[bookingIntendedID]
			if !ok {
				return fmt.Errorf("no prior BookSession for %s", bookingIntendedID)
			}
			var chargeID string
			if err := scope.Conn().QueryRowContext(ctx, `
				SELECT id FROM charges
				WHERE school_id = ? AND booking_id = ? AND voided_at IS NULL
				ORDER BY created_at ASC LIMIT 1`,
				string(scope.SchoolID()), bookingID).Scan(&chargeID); err != nil {
				return fmt.Errorf("lookup source charge: %w", err)
			}
			sourceCharges = append(sourceCharges, domain.ChargeID(chargeID))
		}
		_, err := instructorpay.RecordEarning(ctx, scope, instructorpay.RecordEarningRequest{
			InstructorID:    domain.UserID(ev.InstructorID),
			SessionID:       domain.SessionID(ev.SessionID),
			AmountPence:     domain.Money(ev.AmountPence),
			Basis:           ev.Basis,
			Notes:           ev.Notes,
			CreatedBy:       domain.UserID(ev.CreatedBy),
			SourceChargeIDs: sourceCharges,
		})
		return err
	case RecordInstructorPayment:
		_, err := instructorpay.RecordPayment(ctx, scope, instructorpay.RecordPaymentRequest{
			InstructorID: domain.UserID(ev.InstructorID),
			AmountPence:  domain.Money(ev.AmountPence),
			Method:       ev.Method,
			PaidAt:       ev.PaidAt,
			RecordedBy:   domain.UserID(ev.RecordedBy),
			Notes:        ev.Notes,
		})
		return err
	case RecordBikeExpense:
		_, err := bikemaint.Record(ctx, scope, bikemaint.RecordRequest{
			BikeID:             domain.BikeID(ev.BikeID),
			Category:           bikemaint.Category(ev.Category),
			AmountPence:        ev.AmountPence,
			OccurredAt:         ev.OccurredAt,
			Vendor:             ev.Vendor,
			Notes:              ev.Notes,
			ReceiptStorageKey:  ev.ReceiptStorageKey,
			ReceiptContentType: ev.ReceiptContentType,
			ReceiptSizeBytes:   ev.ReceiptSizeBytes,
			ReceiptThumb:       ev.ReceiptThumb,
			RecordedBy:         domain.UserID(ev.RecordedBy),
		})
		return err
	default:
		return fmt.Errorf("unknown event type %T", e)
	}
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}
