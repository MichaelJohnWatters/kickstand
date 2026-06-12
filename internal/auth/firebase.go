package auth

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"

	firebase "firebase.google.com/go/v4"
	firebaseauth "firebase.google.com/go/v4/auth"
	"google.golang.org/api/option"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

// FirebaseClient is a thin wrapper around the Firebase Admin Auth client.
// Constructed once at server boot, shared across requests (it's safe for
// concurrent use). Phase 1 of the migration will route the auth
// middleware through `VerifyIDToken`; today it's plumbed but unused.
//
// Configuration:
//
//   - FIREBASE_AUTH_EMULATOR_HOST=localhost:9099 makes the SDK talk to
//     the local emulator. The Admin SDK auto-detects this env var; no
//     code branch needed on our side.
//   - GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
//     points at a service-account credential for production. Cloud Run
//     and friends set this automatically from the attached service
//     identity.
//   - FIREBASE_PROJECT_ID forces a specific project id when running
//     against the emulator (no credential present otherwise).
type FirebaseClient struct {
	Auth *firebaseauth.Client
}

// NewFirebaseClient returns a configured client, or nil + nil error when
// no Firebase context is present (no creds, no emulator). The server
// boots either way — callers handle the nil case if they need auth.
//
// This makes Phase 0 a safe no-op: nothing requires Firebase yet, so
// "no creds" doesn't fail startup. From Phase 1 onwards the server will
// error out at boot if this returns nil and we're not in test mode.
func NewFirebaseClient(ctx context.Context) (*FirebaseClient, error) {
	if !firebaseConfigured() {
		return nil, nil
	}
	cfg := &firebase.Config{}
	if pid := os.Getenv("FIREBASE_PROJECT_ID"); pid != "" {
		cfg.ProjectID = pid
	}
	opts := []option.ClientOption{}
	if cred := os.Getenv("GOOGLE_APPLICATION_CREDENTIALS"); cred != "" {
		opts = append(opts, option.WithCredentialsFile(cred))
	}
	app, err := firebase.NewApp(ctx, cfg, opts...)
	if err != nil {
		return nil, fmt.Errorf("firebase init: %w", err)
	}
	a, err := app.Auth(ctx)
	if err != nil {
		return nil, fmt.Errorf("firebase auth: %w", err)
	}
	return &FirebaseClient{Auth: a}, nil
}

// firebaseConfigured reports whether we have at least one of the env
// vars that would let the Admin SDK actually do something. Used to
// short-circuit init during normal local dev where Firebase isn't yet
// wired into the running flow.
func firebaseConfigured() bool {
	return os.Getenv("FIREBASE_AUTH_EMULATOR_HOST") != "" ||
		os.Getenv("GOOGLE_APPLICATION_CREDENTIALS") != "" ||
		os.Getenv("FIREBASE_PROJECT_ID") != ""
}

// VerifyAndLoad verifies the Firebase ID token, looks up the matching
// local profile, and returns a full Identity. The token verification +
// the local lookup are intentionally bundled — every authed request
// needs both, and combining them gives the middleware a single seam.
//
// Errors:
//   - ErrSessionInvalid: signature failed, token expired, wrong project, etc.
//   - ErrProfileMissing: token verified but no users row carries this UID
//     (signup race, or a Firebase user we don't know about).
//   - ErrAccountDisabled: local profile exists but the school disabled them.
func (c *FirebaseClient) VerifyAndLoad(ctx context.Context, d *sql.DB, idToken string) (*Identity, error) {
	tok, err := c.Auth.VerifyIDToken(ctx, idToken)
	if err != nil {
		return nil, ErrSessionInvalid
	}
	return LoadByFirebaseUID(ctx, d, tok.UID)
}

// LoadByFirebaseUID returns the local profile for the given Firebase
// UID. Exported so signup handlers and tests can use the same query
// without re-implementing it.
func LoadByFirebaseUID(ctx context.Context, d *sql.DB, firebaseUID string) (*Identity, error) {
	const q = `
		SELECT id, school_id, email, name, role, account_status, COALESCE(firebase_uid, '')
		FROM users WHERE firebase_uid = ?
	`
	var (
		id, schoolID, email, name, role, status, uid string
	)
	err := d.QueryRowContext(ctx, q, firebaseUID).Scan(
		&id, &schoolID, &email, &name, &role, &status, &uid,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrProfileMissing
	}
	if err != nil {
		return nil, fmt.Errorf("load by firebase_uid: %w", err)
	}
	if domain.AccountStatus(status) == domain.AccountDisabled {
		return nil, ErrAccountDisabled
	}
	return &Identity{
		UserID:        domain.UserID(id),
		SchoolID:      domain.SchoolID(schoolID),
		Role:          domain.Role(role),
		AccountStatus: domain.AccountStatus(status),
		Email:         email,
		Name:          name,
		FirebaseUID:   uid,
	}, nil
}
