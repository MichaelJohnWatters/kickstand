package notify

import (
	"context"
	"fmt"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// QueueEmail inserts a pending email-channel notification for the recipient
// when their per-category email preference is on. It's the outbox write: the
// email worker (DispatchEmails) later drains channel='email' AND
// status='pending' rows and actually sends them. Safe to call inside the same
// transaction as the in_app insert — only a row is written here, no network.
//
// The notifications schema already models this (channel email/push/sms,
// status pending/sent/failed), so no migration is needed; the in_app consumer
// query filters channel='in_app', so these rows never show in the bell.
func QueueEmail(ctx context.Context, scope *tenant.Scope, eventID domain.EventID, recipient domain.UserID, category string) error {
	if recipient == "" {
		return nil
	}
	enabled, err := channelEnabledForUser(ctx, scope, recipient, "email", category)
	if err != nil {
		return err
	}
	if !enabled {
		return nil
	}
	_, err = scope.Conn().ExecContext(ctx, `
		INSERT INTO notifications (id, school_id, event_id, recipient_id, channel, category, status)
		VALUES (?, ?, ?, ?, 'email', ?, 'pending')
	`, domain.NewID(), string(scope.SchoolID()), string(eventID), string(recipient), category)
	if err != nil {
		return fmt.Errorf("queue email notification: %w", err)
	}
	return nil
}
