package booking

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/logging"
	"github.com/michaeljohnwatters/kickstand/internal/notify"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

var (
	ErrAlreadyOnWaitlist     = errors.New("waitlist: student already on this list")
	ErrWaitlistNotApplicable = errors.New("waitlist: session is not full (book directly)")
)

// WaitlistEntry is one row, lightly denormalised for list reads.
type WaitlistEntry struct {
	ID                domain.WaitlistID
	SessionID         domain.SessionID
	StudentID         domain.UserID
	StudentName       string
	JoinedAt          time.Time
	Position          int       // 1-based, computed on read
	PromotedAt        time.Time // zero when not promoted
	PromotedBookingID domain.BookingID
}

// JoinWaitlist adds the student to a session's waitlist. Only allowed
// when the session is currently at capacity (otherwise the student
// should just book). Rejects duplicate joins via the UNIQUE index.
func JoinWaitlist(ctx context.Context, scope *tenant.Scope, sessionID domain.SessionID, studentID domain.UserID) (*WaitlistEntry, error) {
	return JoinWaitlistAt(ctx, scope, sessionID, studentID, time.Now)
}

// JoinWaitlistAt is the testable form — exposes the clock so tests can
// pin "now" to a deterministic moment.
func JoinWaitlistAt(ctx context.Context, scope *tenant.Scope, sessionID domain.SessionID, studentID domain.UserID, nowFn func() time.Time) (*WaitlistEntry, error) {
	var out *WaitlistEntry
	err := scope.WithTx(ctx, func(tx *tenant.Scope) error {
		sess, err := loadSession(ctx, tx, sessionID)
		if err != nil {
			return err
		}
		if sess.status != "scheduled" {
			return ErrSessionNotBookable
		}
		now := nowFn()
		if !sess.startsAt.After(now) {
			return ErrSessionInPast
		}
		active, err := countActiveBookings(ctx, tx, sess.id)
		if err != nil {
			return err
		}
		// If there's still room, refuse the waitlist join — the student
		// should book instead. Avoids a "joined waitlist on a session you
		// could've just booked" trap.
		if active < sess.capacity {
			return ErrWaitlistNotApplicable
		}

		id := domain.WaitlistID(domain.NewID())
		at := now.UTC()
		_, err = tx.Conn().ExecContext(ctx, `
			INSERT INTO waitlist_entries (id, school_id, session_id, student_id, joined_at)
			VALUES (?, ?, ?, ?, ?)
		`, string(id), string(tx.SchoolID()), string(sessionID), string(studentID), at.Format(time.RFC3339))
		if err != nil {
			if isUniqueViolation(err) {
				return ErrAlreadyOnWaitlist
			}
			return fmt.Errorf("insert waitlist: %w", err)
		}
		out = &WaitlistEntry{
			ID:        id,
			SessionID: sessionID,
			StudentID: studentID,
			JoinedAt:  at,
			Position:  0,
		}
		return nil
	})
	return out, err
}

// LeaveWaitlist removes the student's entry. Idempotent — leaving a
// list you're not on returns nil (no error).
func LeaveWaitlist(ctx context.Context, scope *tenant.Scope, sessionID domain.SessionID, studentID domain.UserID) error {
	_, err := scope.Conn().ExecContext(ctx, `
		DELETE FROM waitlist_entries
		WHERE school_id = ? AND session_id = ? AND student_id = ?
		  AND promoted_at IS NULL
	`, string(scope.SchoolID()), string(sessionID), string(studentID))
	return err
}

// ListWaitlist returns active (un-promoted) entries for a session in
// queue order. Admin / instructor use.
func ListWaitlist(ctx context.Context, scope *tenant.Scope, sessionID domain.SessionID) ([]WaitlistEntry, error) {
	const q = `
		SELECT w.id, w.student_id, COALESCE(u.name, ''), w.joined_at,
		       COALESCE(w.promoted_at, ''), COALESCE(w.promoted_booking_id, '')
		FROM waitlist_entries w
		LEFT JOIN users u ON u.id = w.student_id AND u.school_id = w.school_id
		WHERE w.school_id = ? AND w.session_id = ? AND w.promoted_at IS NULL
		ORDER BY w.joined_at ASC, w.id ASC
	`
	rows, err := scope.Conn().QueryContext(ctx, q, string(scope.SchoolID()), string(sessionID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []WaitlistEntry
	pos := 1
	for rows.Next() {
		var e WaitlistEntry
		var joinedStr, promotedStr, promotedBookingID string
		if err := rows.Scan(&e.ID, &e.StudentID, &e.StudentName, &joinedStr, &promotedStr, &promotedBookingID); err != nil {
			return nil, err
		}
		e.SessionID = sessionID
		e.JoinedAt, _ = parseTime(joinedStr)
		if promotedStr != "" {
			e.PromotedAt, _ = parseTime(promotedStr)
		}
		e.PromotedBookingID = domain.BookingID(promotedBookingID)
		e.Position = pos
		pos++
		out = append(out, e)
	}
	return out, rows.Err()
}

// MyWaitlistEntries returns a student's active waitlist entries. Used
// by /me to render "you're 3rd on the list for Saturday's CBT".
func MyWaitlistEntries(ctx context.Context, scope *tenant.Scope, studentID domain.UserID) ([]WaitlistEntry, error) {
	const q = `
		SELECT w.id, w.session_id, w.joined_at
		FROM waitlist_entries w
		WHERE w.school_id = ? AND w.student_id = ? AND w.promoted_at IS NULL
		ORDER BY w.joined_at ASC
	`
	rows, err := scope.Conn().QueryContext(ctx, q, string(scope.SchoolID()), string(studentID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []WaitlistEntry
	for rows.Next() {
		var e WaitlistEntry
		var joinedStr string
		if err := rows.Scan(&e.ID, &e.SessionID, &joinedStr); err != nil {
			return nil, err
		}
		e.StudentID = studentID
		e.JoinedAt, _ = parseTime(joinedStr)
		// Position computed by counting earlier entries on the same session.
		var pos int
		_ = scope.Conn().QueryRowContext(ctx, `
			SELECT COUNT(*) + 1 FROM waitlist_entries
			WHERE school_id = ? AND session_id = ?
			  AND promoted_at IS NULL AND joined_at < ?
		`, string(scope.SchoolID()), string(e.SessionID), joinedStr).Scan(&pos)
		e.Position = pos
		out = append(out, e)
	}
	return out, rows.Err()
}

// promoteFromWaitlist consumes the head of the waitlist for a session
// inside the supplied tx and books them via the regular booking flow.
// Best-effort: returns nil even if no one can be promoted (queue empty,
// no suitable bike, etc.) — the caller is the cancel path, which must
// never fail because a promotion attempt did.
//
// Runs INSIDE the cancel transaction so the freed seat and the new
// booking land atomically.
func promoteFromWaitlist(ctx context.Context, tx *tenant.Scope, sessionID domain.SessionID, now time.Time) {
	log := logging.FromContext(ctx)
	for {
		var entryID, studentID, joinedStr string
		err := tx.Conn().QueryRowContext(ctx, `
			SELECT id, student_id, joined_at FROM waitlist_entries
			WHERE school_id = ? AND session_id = ? AND promoted_at IS NULL
			ORDER BY joined_at ASC, id ASC
			LIMIT 1
		`, string(tx.SchoolID()), string(sessionID)).Scan(&entryID, &studentID, &joinedStr)
		if errors.Is(err, sql.ErrNoRows) {
			return // empty queue
		}
		if err != nil {
			log.LogAttrs(ctx, slog.LevelWarn, "waitlist peek failed",
				slog.String("err", err.Error()))
			return
		}

		// Try to book the next person via the engine inner. The outer
		// notify hook for "booking created" lives in Book/BookAt which
		// we deliberately skip — for waitlist promotions we want the
		// more specific waitlist.promoted event, fired below.
		bookResult, bookErr := bookInTx(ctx, tx, Request{
			SessionID: sessionID,
			StudentID: domain.UserID(studentID),
		}, now)

		if bookErr != nil {
			// Common skip case: ErrAlreadyBooked (they made a parallel
			// booking already), ErrNoSuitableBike (no transmission match
			// for this student), ErrStudentNotActive. None should fail
			// the cancel — drop the entry and move on so a stuck student
			// doesn't block everyone behind them.
			if errors.Is(bookErr, ErrAlreadyBooked) ||
				errors.Is(bookErr, ErrStudentNotActive) {
				if _, err := tx.Conn().ExecContext(ctx,
					`DELETE FROM waitlist_entries WHERE id = ?`, entryID); err == nil {
					continue
				}
				return
			}
			// Capacity / bike / qualification issues are session-wide:
			// no one will succeed, give up.
			log.LogAttrs(ctx, slog.LevelInfo, "waitlist promotion skipped",
				slog.String("err", bookErr.Error()),
				slog.String("session", string(sessionID)))
			return
		}

		// Booked. Mark the entry promoted with the resulting booking id.
		_, err = tx.Conn().ExecContext(ctx, `
			UPDATE waitlist_entries
			   SET promoted_at = ?, promoted_booking_id = ?
			 WHERE id = ?
		`, now.UTC().Format(time.RFC3339), string(bookResult.Booking.ID), entryID)
		if err != nil {
			log.LogAttrs(ctx, slog.LevelWarn, "waitlist mark-promoted failed",
				slog.String("err", err.Error()))
		}

		// Notify the promoted student in the same tx. The course name is
		// best-effort: if lookup fails the notify still goes out with an
		// empty courseName, which renders as "Booked from waitlist".
		courseName, _ := sessionCourseName(ctx, tx, sessionID)
		if err := notify.OnWaitlistPromoted(ctx, tx, bookResult.Booking, courseName); err != nil {
			log.LogAttrs(ctx, slog.LevelWarn, "waitlist promoted notify failed",
				slog.String("err", err.Error()))
		}
		return
	}
}
