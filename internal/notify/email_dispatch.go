package notify

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/email"
)

// DispatchEmails drains the email outbox: it finds channel='email',
// status='pending' notifications, renders a plain-text message from the
// originating event, sends via the Sender, and marks each row sent (or failed,
// so a poison address doesn't retry forever). Returns the number sent.
//
// Runs as a single-goroutine worker on an interval (like the reminders
// worker), so there's no in-process concurrency; a crash between send and the
// status flip can at-worst re-send one message on restart (at-least-once).
// Rows are collected before sending so no read cursor is held open across the
// network calls + writes.
func DispatchEmails(ctx context.Context, d *sql.DB, sender email.Sender, now time.Time, limit int) (int, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := d.QueryContext(ctx, `
		SELECT n.id, e.kind, COALESCE(e.payload, ''), u.email, u.name, s.name
		FROM notifications n
		JOIN events e  ON e.id = n.event_id    AND e.school_id = n.school_id
		JOIN users u   ON u.id = n.recipient_id AND u.school_id = n.school_id
		JOIN schools s ON s.id = n.school_id
		WHERE n.channel = 'email' AND n.status = 'pending'
		ORDER BY n.id
		LIMIT ?
	`, limit)
	if err != nil {
		return 0, fmt.Errorf("load pending emails: %w", err)
	}
	type pending struct {
		id, kind, payload, addr, name, school string
	}
	var batch []pending
	for rows.Next() {
		var p pending
		if err := rows.Scan(&p.id, &p.kind, &p.payload, &p.addr, &p.name, &p.school); err != nil {
			rows.Close()
			return 0, err
		}
		batch = append(batch, p)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}

	sent := 0
	for _, p := range batch {
		if p.addr == "" {
			_, _ = d.ExecContext(ctx,
				`UPDATE notifications SET status='failed', failure_reason='no email address' WHERE id=? AND status='pending'`, p.id)
			continue
		}
		subject, body := renderEmail(p.kind, p.payload, p.name, p.school)
		if err := sender.Send(ctx, email.Message{To: p.addr, ToName: p.name, Subject: subject, Body: body}); err != nil {
			_, _ = d.ExecContext(ctx,
				`UPDATE notifications SET status='failed', failure_reason=? WHERE id=? AND status='pending'`,
				truncate(err.Error(), 500), p.id)
			continue
		}
		if _, err := d.ExecContext(ctx,
			`UPDATE notifications SET status='sent', sent_at=? WHERE id=? AND status='pending'`,
			now.UTC().Format(time.RFC3339), p.id); err != nil {
			return sent, err
		}
		sent++
	}
	return sent, nil
}

// renderEmail builds a plain-text subject + body for a notification from its
// event kind + payload. Unknown kinds fall back to a generic "open the app"
// nudge so a new event type never crashes the worker.
func renderEmail(kind, payloadJSON, recipientName, schoolName string) (subject, body string) {
	var p map[string]any
	if payloadJSON != "" {
		_ = json.Unmarshal([]byte(payloadJSON), &p)
	}
	course := strings.TrimSpace(fmt.Sprint(valOr(p, "courseName", "")))
	when := prettyWhen(fmt.Sprint(valOr(p, "startsAt", "")))
	hi := "Hi " + firstName(recipientName) + ",\n\n"
	sig := "\n\n— " + schoolName

	switch kind {
	case EventBookingCreated:
		subject = "Booking confirmed" + dash(course)
		body = hi + "Your booking is confirmed" + withCourse(course) + withWhen(when) + "." + sig
	case EventBookingRescheduled:
		subject = "Booking rescheduled" + dash(course)
		body = hi + "Your booking has been rescheduled" + withCourse(course) + withWhen(when) + "." + sig
	case EventBookingCancelled:
		subject = "Booking cancelled" + dash(course)
		body = hi + "Your booking" + withCourse(course) + " has been cancelled. If this wasn't you, please get in touch." + sig
	case EventWaitlistPromoted:
		subject = "A place opened up" + dash(course)
		body = hi + "Good news — a place opened up and you've been booked in" + withCourse(course) + withWhen(when) + "." + sig
	case "session.reminder_24h":
		subject = "Reminder: your session tomorrow" + dash(course)
		body = hi + "This is a reminder that you have a session" + withCourse(course) + withWhen(when) + ". See you there!" + sig
	case "session.reminder_2h":
		subject = "Reminder: your session soon" + dash(course)
		body = hi + "Your session" + withCourse(course) + withWhen(when) + " is coming up shortly. See you soon!" + sig
	case EventDisruptionAffected:
		subject = "Action needed on your booking" + dash(course)
		body = hi + "There's a disruption affecting your booking" + withCourse(course) + ". Please open the app to review your options." + sig
	default:
		subject = "Update from " + schoolName
		body = hi + "There's an update on your account. Open the app for details." + sig
	}
	return subject, body
}

// ----- small render helpers -----

func valOr(m map[string]any, k, def string) any {
	if m == nil {
		return def
	}
	if v, ok := m[k]; ok && v != nil {
		return v
	}
	return def
}

func dash(course string) string {
	if course == "" {
		return ""
	}
	return " — " + course
}

func withCourse(course string) string {
	if course == "" {
		return ""
	}
	return " for " + course
}

func withWhen(when string) string {
	if when == "" {
		return ""
	}
	return " on " + when
}

// prettyWhen formats an RFC3339 timestamp as "Mon 2 Jan at 15:04"; returns ""
// if it can't parse, so the templates just omit the time.
func prettyWhen(rfc3339 string) string {
	if rfc3339 == "" {
		return ""
	}
	t, err := time.Parse(time.RFC3339, rfc3339)
	if err != nil {
		return ""
	}
	return t.Format("Mon 2 Jan at 15:04")
}

func firstName(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return "there"
	}
	if i := strings.IndexByte(name, ' '); i > 0 {
		return name[:i]
	}
	return name
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
