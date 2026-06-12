package notify

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

// CategoryPrefs is the per-(user, category) channel pref row.
// `true` = deliver on that channel; `false` = mute. Defaults are
// applied by GetPrefs when no row exists yet: in_app/email/push on,
// sms off (the paid channel never auto-enables).
type CategoryPrefs struct {
	Category string
	InApp    bool
	Email    bool
	Push     bool
	SMS      bool
}

// AllCategories is the canonical category list. Mirrors the
// CategoryXxx constants and the migration CHECK constraint.
var AllCategories = []string{
	CategoryBooking,
	CategoryDisruption,
	CategoryPayment,
	CategoryReminder,
}

func defaultPrefs(category string) CategoryPrefs {
	return CategoryPrefs{
		Category: category,
		InApp:    true,
		Email:    true,
		Push:     true,
		SMS:      false,
	}
}

// GetPrefs returns one CategoryPrefs row per known category for the
// user, filling in defaults for any categories that don't yet have a
// row. The result is always exactly len(AllCategories) entries in
// canonical order — UI code can render without re-sorting.
func GetPrefs(ctx context.Context, scope *tenant.Scope, userID domain.UserID) ([]CategoryPrefs, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT category, in_app, email, push, sms
		FROM notification_prefs
		WHERE school_id = ? AND user_id = ?
	`, string(scope.SchoolID()), string(userID))
	if err != nil {
		return nil, fmt.Errorf("notify prefs: %w", err)
	}
	defer rows.Close()
	byCategory := make(map[string]CategoryPrefs, len(AllCategories))
	for rows.Next() {
		var p CategoryPrefs
		var inApp, email, push, sms int
		if err := rows.Scan(&p.Category, &inApp, &email, &push, &sms); err != nil {
			return nil, err
		}
		p.InApp = inApp == 1
		p.Email = email == 1
		p.Push = push == 1
		p.SMS = sms == 1
		byCategory[p.Category] = p
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	out := make([]CategoryPrefs, 0, len(AllCategories))
	for _, c := range AllCategories {
		if p, ok := byCategory[c]; ok {
			out = append(out, p)
		} else {
			out = append(out, defaultPrefs(c))
		}
	}
	return out, nil
}

// SetPrefs upserts the user's prefs in one transaction. Unknown
// categories are rejected (avoid silent typos polluting the table).
func SetPrefs(ctx context.Context, scope *tenant.Scope, userID domain.UserID, prefs []CategoryPrefs) error {
	known := make(map[string]bool, len(AllCategories))
	for _, c := range AllCategories {
		known[c] = true
	}
	for _, p := range prefs {
		if !known[strings.ToLower(p.Category)] {
			return fmt.Errorf("notify prefs: unknown category %q", p.Category)
		}
	}
	now := time.Now().UTC().Format(time.RFC3339)
	return scope.WithTx(ctx, func(tx *tenant.Scope) error {
		for _, p := range prefs {
			_, err := tx.Conn().ExecContext(ctx, `
				INSERT INTO notification_prefs
				    (school_id, user_id, category, in_app, email, push, sms, updated_at)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?)
				ON CONFLICT (user_id, category) DO UPDATE SET
				    in_app = excluded.in_app,
				    email = excluded.email,
				    push = excluded.push,
				    sms = excluded.sms,
				    updated_at = excluded.updated_at
			`, string(scope.SchoolID()), string(userID),
				strings.ToLower(p.Category),
				boolInt(p.InApp), boolInt(p.Email),
				boolInt(p.Push), boolInt(p.SMS), now)
			if err != nil {
				return err
			}
		}
		return nil
	})
}

// channelEnabledForUser reports whether the user has opted in to
// receiving notifications for (channel, category). Missing row → use
// defaults (in_app/email/push on, sms off). Used by the dispatcher
// before inserting a row; the in_app path is the only one that fires
// today, but the same gate covers email/push/sms when they light up.
func channelEnabledForUser(
	ctx context.Context,
	scope *tenant.Scope,
	userID domain.UserID,
	channel, category string,
) (bool, error) {
	var inApp, email, push, sms int
	err := scope.Conn().QueryRowContext(ctx, `
		SELECT in_app, email, push, sms
		FROM notification_prefs
		WHERE school_id = ? AND user_id = ? AND category = ?
	`, string(scope.SchoolID()), string(userID), category).
		Scan(&inApp, &email, &push, &sms)
	if errors.Is(err, sql.ErrNoRows) {
		d := defaultPrefs(category)
		return channelOf(d, channel), nil
	}
	if err != nil {
		return false, err
	}
	p := CategoryPrefs{InApp: inApp == 1, Email: email == 1, Push: push == 1, SMS: sms == 1}
	return channelOf(p, channel), nil
}

func channelOf(p CategoryPrefs, channel string) bool {
	switch channel {
	case "in_app":
		return p.InApp
	case "email":
		return p.Email
	case "push":
		return p.Push
	case "sms":
		return p.SMS
	}
	return true
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
