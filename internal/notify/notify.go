// Package notify is the event/notification layer described in plan §8b:
// app logic records "X happened", and this package decides who to tell
// and what category to file it under. The dispatcher to external channels
// (FCM push, email) is intentionally NOT here yet — Flutter doesn't exist
// to receive pushes against. What IS here:
//
//   - Producer hooks (OnBookingCreated, OnBookingCancelled, ...) called
//     from the engine, within the engine's transaction. Writes a row to
//     `events` plus one `notifications` row per recipient at channel='in_app'.
//   - In-app consumer queries (List, MarkRead, MarkAllRead).
//
// The 'in_app' channel is "sent" the instant it's inserted — there's no
// network delivery to wait on. Email / push will be a separate worker
// reading from notifications WHERE status='pending', once we wire them.
//
// Categories — kept stable for UI grouping per the plan:
//   - 'booking'    routine confirmations, cancellations, reschedules
//   - 'disruption' bike-down events, swap suggestions, manager approvals
//   - 'payment'    (phase 2 reminders; surface defined now)
//   - 'reminder'   (phase 2 24h/2h before — surface defined now)
package notify

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

const (
	CategoryBooking    = "booking"
	CategoryDisruption = "disruption"
	CategoryPayment    = "payment"
	CategoryReminder   = "reminder"
)

const (
	EventBookingCreated      = "booking.created"
	EventBookingCancelled    = "booking.cancelled"
	EventBookingRescheduled  = "booking.rescheduled"
	EventBikeOffline         = "bike.offline"
	EventDisruptionAffected  = "disruption.affected_booking"
	EventDisruptionResolved  = "disruption.resolved"
	EventWaitlistPromoted    = "waitlist.promoted"
)

// ----- Producer hooks (called inside engine transactions) -----

// OnBookingCreated records the event and notifies the student. We don't
// notify the instructor in the in-app channel here — their schedule view
// will reflect the new booking the next time they refresh. (When we wire
// push, we'd want instructor confirmation too — a future hook can opt in.)
func OnBookingCreated(ctx context.Context, scope *tenant.Scope, b domain.Booking, courseName string) error {
	payload := map[string]any{
		"bookingId":  b.ID,
		"sessionId":  b.SessionID,
		"courseName": courseName,
	}
	eventID, err := insertEvent(ctx, scope, EventBookingCreated, string(b.ID), payload)
	if err != nil {
		return err
	}
	return insertNotification(ctx, scope, eventID, b.StudentID, CategoryBooking)
}

// OnBookingCancelled notifies the student if the school cancelled, and
// the instructor if the student cancelled. We don't ping the cancelling
// actor — they just clicked the button, they know.
func OnBookingCancelled(ctx context.Context, scope *tenant.Scope, b domain.Booking, by domain.CancelledBy, courseName string, instructorID domain.UserID) error {
	payload := map[string]any{
		"bookingId":   b.ID,
		"sessionId":   b.SessionID,
		"cancelledBy": by,
		"courseName":  courseName,
	}
	eventID, err := insertEvent(ctx, scope, EventBookingCancelled, string(b.ID), payload)
	if err != nil {
		return err
	}
	switch by {
	case domain.CancelledByStudent:
		return insertNotification(ctx, scope, eventID, instructorID, CategoryBooking)
	case domain.CancelledBySchool:
		return insertNotification(ctx, scope, eventID, b.StudentID, CategoryBooking)
	}
	return nil
}

// OnBookingRescheduled records the cancel+rebook pair atomically. The
// student is the actor (or, for school-driven rebooks, the school is) —
// we notify either way so the student has a confirmation of the new slot.
func OnBookingRescheduled(ctx context.Context, scope *tenant.Scope, oldBooking, newBooking domain.Booking, newCourseName string) error {
	payload := map[string]any{
		"oldBookingId":  oldBooking.ID,
		"newBookingId":  newBooking.ID,
		"newSessionId":  newBooking.SessionID,
		"newCourseName": newCourseName,
	}
	eventID, err := insertEvent(ctx, scope, EventBookingRescheduled, string(newBooking.ID), payload)
	if err != nil {
		return err
	}
	return insertNotification(ctx, scope, eventID, newBooking.StudentID, CategoryBooking)
}

// OnWaitlistPromoted tells the student they were auto-booked from the
// waitlist. Fires from cancelInTx inside the same transaction as the
// new booking, so the notification can never reference a booking that
// doesn't exist.
func OnWaitlistPromoted(ctx context.Context, scope *tenant.Scope, b domain.Booking, courseName string) error {
	payload := map[string]any{
		"bookingId":  b.ID,
		"sessionId":  b.SessionID,
		"courseName": courseName,
	}
	eventID, err := insertEvent(ctx, scope, EventWaitlistPromoted, string(b.ID), payload)
	if err != nil {
		return err
	}
	return insertNotification(ctx, scope, eventID, b.StudentID, CategoryBooking)
}

// OnBikeOffline pings admins (urgent: their attention may be needed for
// affected bookings). The disruption flow separately emits per-affected
// booking notifications via OnDisruptionAffected.
func OnBikeOffline(ctx context.Context, scope *tenant.Scope, bikeID domain.BikeID, disruptionID domain.DisruptionID, affectedCount int) error {
	payload := map[string]any{
		"bikeId":        bikeID,
		"disruptionId":  disruptionID,
		"affectedCount": affectedCount,
	}
	eventID, err := insertEvent(ctx, scope, EventBikeOffline, string(disruptionID), payload)
	if err != nil {
		return err
	}
	return notifyAdmins(ctx, scope, eventID, CategoryDisruption)
}

// OnDisruptionAffected tells the student their booking needs reassignment.
// The student doesn't act here — the manager resolves it — but we want them
// to know so a surprise "your bike was swapped" doesn't feel like silent
// magic.
func OnDisruptionAffected(ctx context.Context, scope *tenant.Scope, b domain.Booking, disruptionID domain.DisruptionID) error {
	var courseName, startsAt string
	_ = scope.Conn().QueryRowContext(ctx, `
		SELECT COALESCE(ct.name, ''), COALESCE(s.starts_at, '')
		FROM bookings b
		JOIN sessions s     ON s.id = b.session_id AND s.school_id = b.school_id
		JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		WHERE b.id = ? AND b.school_id = ?
	`, string(b.ID), string(scope.SchoolID())).
		Scan(&courseName, &startsAt)

	payload := map[string]any{
		"bookingId":       b.ID,
		"sessionId":       b.SessionID,
		"disruptionId":    disruptionID,
		"courseName":      courseName,
		"sessionStartsAt": startsAt,
	}
	eventID, err := insertEvent(ctx, scope, EventDisruptionAffected, string(b.ID), payload)
	if err != nil {
		return err
	}
	return insertNotification(ctx, scope, eventID, b.StudentID, CategoryDisruption)
}

// OnDisruptionResolved tells the student about the outcome. Resolution is
// either 'swapped' or 'cancel_with_approval'. We enrich the payload with
// the course name, session start time and new bike's nickname so the
// student's notification cell can render something useful ("CBT-125 ·
// Sat 14 Jun 09:00 — swapped to Honda CB125F") instead of a bare title.
func OnDisruptionResolved(ctx context.Context, scope *tenant.Scope, b domain.Booking, disruptionID domain.DisruptionID, resolution string) error {
	var (
		courseName, startsAt, newBikeNickname string
	)
	// Best-effort lookup — the notification fires from inside the
	// engine tx, so we use the same scope. If anything fails we still
	// emit the event with whatever we have; the title path on the
	// client tolerates missing fields.
	_ = scope.Conn().QueryRowContext(ctx, `
		SELECT COALESCE(ct.name, ''), COALESCE(s.starts_at, ''),
		       COALESCE(bk.nickname, '')
		FROM bookings b
		JOIN sessions s     ON s.id = b.session_id AND s.school_id = b.school_id
		JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		LEFT JOIN bikes bk  ON bk.id = b.bike_id AND bk.school_id = b.school_id
		WHERE b.id = ? AND b.school_id = ?
	`, string(b.ID), string(scope.SchoolID())).
		Scan(&courseName, &startsAt, &newBikeNickname)

	payload := map[string]any{
		"bookingId":       b.ID,
		"sessionId":       b.SessionID,
		"disruptionId":    disruptionID,
		"resolution":      resolution,
		"courseName":      courseName,
		"sessionStartsAt": startsAt,
	}
	// Bike nickname is only meaningful on the swap path — on cancel
	// the booking's bike_id was already cleared (or is irrelevant).
	if resolution == "swapped" && newBikeNickname != "" {
		payload["newBikeNickname"] = newBikeNickname
	}
	eventID, err := insertEvent(ctx, scope, EventDisruptionResolved, string(b.ID), payload)
	if err != nil {
		return err
	}
	return insertNotification(ctx, scope, eventID, b.StudentID, CategoryBooking)
}

// ----- Low-level helpers -----

func insertEvent(ctx context.Context, scope *tenant.Scope, kind, subjectID string, payload map[string]any) (domain.EventID, error) {
	id := domain.EventID(domain.NewID())
	js, err := json.Marshal(payload)
	if err != nil {
		return "", fmt.Errorf("marshal event payload: %w", err)
	}
	_, err = scope.Conn().ExecContext(ctx, `
		INSERT INTO events (id, school_id, kind, subject_id, payload, created_at)
		VALUES (?, ?, ?, ?, ?, ?)
	`, string(id), string(scope.SchoolID()), kind, subjectID, string(js),
		time.Now().UTC().Format(time.RFC3339),
	)
	if err != nil {
		return "", fmt.Errorf("insert event: %w", err)
	}
	return id, nil
}

func insertNotification(ctx context.Context, scope *tenant.Scope, eventID domain.EventID, recipient domain.UserID, category string) error {
	if recipient == "" {
		return nil // nothing to do (e.g. a school-cancelled booking with no recipient resolved)
	}
	_, err := scope.Conn().ExecContext(ctx, `
		INSERT INTO notifications (id, school_id, event_id, recipient_id, channel, category, status, sent_at)
		VALUES (?, ?, ?, ?, 'in_app', ?, 'sent', ?)
	`, domain.NewID(), string(scope.SchoolID()), string(eventID), string(recipient),
		category, time.Now().UTC().Format(time.RFC3339),
	)
	if err != nil {
		return fmt.Errorf("insert notification: %w", err)
	}
	return nil
}

func notifyAdmins(ctx context.Context, scope *tenant.Scope, eventID domain.EventID, category string) error {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT id FROM users
		WHERE school_id = ? AND role IN ('admin', 'owner') AND account_status = 'active'
	`, string(scope.SchoolID()))
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var uid domain.UserID
		if err := rows.Scan(&uid); err != nil {
			return err
		}
		if err := insertNotification(ctx, scope, eventID, uid, category); err != nil {
			return err
		}
	}
	return rows.Err()
}

// ----- In-app consumer queries -----

// Notification is one row in the bell-icon list.
type Notification struct {
	ID         domain.NotificationID
	EventID    domain.EventID
	EventKind  string
	Category   string
	Payload    map[string]any // unmarshalled from events.payload
	SentAt     time.Time
	ReadAt     time.Time // zero = unread
	Status     string    // 'sent' | 'read' | 'failed' | 'pending'
}

// ListResult bundles the page of notifications + the unread count for the
// bell badge. The bell needs both in one round-trip.
type ListResult struct {
	Notifications []Notification
	UnreadCount   int
}

// List returns the most recent N notifications for the caller plus their
// unread count. unreadOnly filters to status='sent' (= delivered but not
// yet read).
func List(ctx context.Context, scope *tenant.Scope, userID domain.UserID, limit int, unreadOnly bool) (*ListResult, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	q := `
		SELECT n.id, n.event_id, e.kind, n.category, e.payload,
		       COALESCE(n.sent_at, ''), COALESCE(n.read_at, ''), n.status
		FROM notifications n
		JOIN events e ON e.id = n.event_id AND e.school_id = n.school_id
		WHERE n.school_id = ? AND n.recipient_id = ? AND n.channel = 'in_app'
	`
	args := []any{string(scope.SchoolID()), string(userID)}
	if unreadOnly {
		q += ` AND n.status <> 'read'`
	}
	q += ` ORDER BY n.sent_at DESC LIMIT ?`
	args = append(args, limit)

	rows, err := scope.Conn().QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Notification
	for rows.Next() {
		var (
			n                  Notification
			payloadStr         string
			sentStr, readStr   string
		)
		if err := rows.Scan(&n.ID, &n.EventID, &n.EventKind, &n.Category, &payloadStr,
			&sentStr, &readStr, &n.Status); err != nil {
			return nil, err
		}
		if payloadStr != "" {
			_ = json.Unmarshal([]byte(payloadStr), &n.Payload)
		}
		if sentStr != "" {
			n.SentAt, _ = time.Parse(time.RFC3339, sentStr)
		}
		if readStr != "" {
			n.ReadAt, _ = time.Parse(time.RFC3339, readStr)
		}
		out = append(out, n)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	var unread int
	err = scope.Conn().QueryRowContext(ctx, `
		SELECT COUNT(*) FROM notifications
		WHERE school_id = ? AND recipient_id = ? AND channel = 'in_app' AND status <> 'read'
	`, string(scope.SchoolID()), string(userID)).Scan(&unread)
	if err != nil {
		return nil, err
	}
	return &ListResult{Notifications: out, UnreadCount: unread}, nil
}

// MarkRead flips one notification to read. Owner-only: caller must be the
// recipient.
func MarkRead(ctx context.Context, scope *tenant.Scope, userID domain.UserID, id domain.NotificationID) error {
	res, err := scope.Conn().ExecContext(ctx, `
		UPDATE notifications SET status = 'read', read_at = ?
		WHERE id = ? AND school_id = ? AND recipient_id = ? AND status <> 'read'
	`, time.Now().UTC().Format(time.RFC3339),
		string(id), string(scope.SchoolID()), string(userID))
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		// Either doesn't exist, isn't yours, or already read — treat all
		// as a no-op success.
		return nil
	}
	return nil
}

// MarkAllRead is the "mark all as read" affordance from the bell sheet.
func MarkAllRead(ctx context.Context, scope *tenant.Scope, userID domain.UserID) error {
	_, err := scope.Conn().ExecContext(ctx, `
		UPDATE notifications SET status = 'read', read_at = ?
		WHERE school_id = ? AND recipient_id = ? AND channel = 'in_app' AND status <> 'read'
	`, time.Now().UTC().Format(time.RFC3339),
		string(scope.SchoolID()), string(userID))
	return err
}

// ----- Device tokens (push surface, registration-only for now) -----

type RegisterDeviceRequest struct {
	UserID   domain.UserID
	SchoolID domain.SchoolID
	Token    string
	Platform string // 'ios' | 'android' | 'web'
}

// RegisterDevice upserts a device token row. Idempotent — the same token
// can be sent on every app launch.
func RegisterDevice(ctx context.Context, scope *tenant.Scope, req RegisterDeviceRequest) error {
	if req.Token == "" {
		return fmt.Errorf("notify: token required")
	}
	switch req.Platform {
	case "ios", "android", "web":
	default:
		return fmt.Errorf("notify: platform must be ios/android/web")
	}
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := scope.Conn().ExecContext(ctx, `
		INSERT INTO device_tokens (token, user_id, school_id, platform, created_at, last_seen_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(token) DO UPDATE SET
		    user_id = excluded.user_id,
		    school_id = excluded.school_id,
		    platform = excluded.platform,
		    last_seen_at = excluded.last_seen_at
	`, req.Token, string(req.UserID), string(req.SchoolID), req.Platform, now, now)
	return err
}

func UnregisterDevice(ctx context.Context, scope *tenant.Scope, token string) error {
	_, err := scope.Conn().ExecContext(ctx,
		`DELETE FROM device_tokens WHERE token = ? AND school_id = ?`,
		token, string(scope.SchoolID()))
	return err
}
