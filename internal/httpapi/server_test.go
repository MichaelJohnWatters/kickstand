package httpapi_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	firebaseauth "firebase.google.com/go/v4/auth"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/filestore"
	"github.com/michaeljohnwatters/kickstand/internal/httpapi"
)

// apiFixture runs a real Server against a real SQLite file and a real
// Firebase Auth Emulator. Black-box: tests only touch the HTTP surface
// and the test seed, never internal types.
//
// All token-minting goes through the emulator — there's no in-process
// shortcut any more. The fixture creates a Firebase user per call to
// mintToken, exchanges a custom token for a real ID token via the
// emulator REST endpoint, and lets the server's middleware verify it
// the same way production traffic does.
//
// Tests are skipped when FIREBASE_AUTH_EMULATOR_HOST isn't set. Use
// `make emulator-test` (which starts the emulator and exports the env)
// to run the full suite locally.
type apiFixture struct {
	t         *testing.T
	db        *sql.DB
	srv       *httptest.Server
	fb        *auth.FirebaseClient
	emuHost   string
	projectID string
	// uidPrefix isolates Firebase users between fixtures so parallel
	// runs (or repeated runs in the same emulator process) don't
	// collide on UIDs like "user_stu".
	uidPrefix string
	now       time.Time
}

func newAPIFixture(t *testing.T) *apiFixture {
	t.Helper()
	emuHost := os.Getenv("FIREBASE_AUTH_EMULATOR_HOST")
	if emuHost == "" {
		t.Skip("FIREBASE_AUTH_EMULATOR_HOST not set; run `make emulator` then `make emulator-test`")
	}
	projectID := os.Getenv("FIREBASE_PROJECT_ID")
	if projectID == "" {
		projectID = "kickstand-dev"
	}

	path := t.TempDir() + "/api_test.db"
	d, err := db.Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { d.Close() })

	ctx := context.Background()
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	files, err := filestore.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("filestore: %v", err)
	}
	fb, err := auth.NewFirebaseClient(ctx)
	if err != nil {
		t.Fatalf("firebase init: %v", err)
	}
	if fb == nil {
		t.Fatal("firebase client nil — FIREBASE_AUTH_EMULATOR_HOST is set but the SDK didn't pick it up")
	}

	api := httpapi.NewServer(d, files, fb)
	srv := httptest.NewServer(api.Routes())
	t.Cleanup(srv.Close)

	f := &apiFixture{
		t:         t,
		db:        d,
		srv:       srv,
		fb:        fb,
		emuHost:   emuHost,
		projectID: projectID,
		uidPrefix: randomPrefix(),
		// Anchor at real wallclock so seeded sessions stay in the future
		// no matter what date the test happens to run on. (Booking engine
		// uses time.Now() directly for its "session not started" check.)
		now: time.Now().UTC(),
	}
	// Fresh emulator on every fixture — between tests and between
	// `go test` runs. Without this, state from earlier sessions
	// (especially Firebase users created via handlers like
	// InviteInstructor that we don't track per-call) leaks forward
	// and causes spurious "email already exists" failures.
	f.clearEmulator()
	f.seed()
	return f
}

func (f *apiFixture) seed() {
	f.t.Helper()
	createdAt := f.now.Format(time.RFC3339)
	sessionStart := f.now.Add(24 * time.Hour).Format(time.RFC3339)
	sessionEnd := f.now.Add(28 * time.Hour).Format(time.RFC3339)

	exec := func(q string, args ...any) {
		f.t.Helper()
		if _, err := f.db.Exec(q, args...); err != nil {
			f.t.Fatalf("seed %q: %v", q, err)
		}
	}

	// password_hash is a vestigial NOT NULL column — empty string for now
	// until a future migration drops it.
	exec(`INSERT INTO schools (id, name, region, test_body_label, created_at)
	      VALUES ('school_t', 'Test School', 'NI', 'DVA', ?)`, createdAt)
	exec(`INSERT INTO locations (id, school_id, name, created_at) VALUES ('loc_t','school_t','Belfast',?)`, createdAt)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, created_at)
	      VALUES ('user_instr','school_t','instr@test','','Instructor','instructor',?)`, createdAt)
	exec(`INSERT INTO instructor_profiles (user_id, school_id, home_location_id) VALUES ('user_instr','school_t','loc_t')`)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	      VALUES ('user_stu','school_t','stu@test','','Student','student','active',?)`, createdAt)
	exec(`INSERT INTO student_profiles (user_id, school_id, transmission_preference, cbt_certificate_held, theory_passed)
	      VALUES ('user_stu','school_t','manual',0,0)`)
	exec(`INSERT INTO course_types (id, school_id, code, name, region, required_bike_category,
	          duration_minutes, max_ratio, price_pence, non_teaching, created_at)
	      VALUES ('ct_cbt','school_t','CBT-125','CBT 125','NI','A1',240,4,13000,0,?)`, createdAt)
	exec(`INSERT INTO instructor_accreditations (school_id, instructor_id, course_type_id)
	      VALUES ('school_t','user_instr','ct_cbt')`)
	exec(`INSERT INTO bikes (id, school_id, category, transmission, status, home_location_id, current_location_id, created_at)
	      VALUES ('bike_t','school_t','A1','manual','ready','loc_t','loc_t',?)`, createdAt)
	exec(`INSERT INTO sessions (id, school_id, course_type_id, instructor_id, location_id, starts_at, ends_at, capacity, created_at)
	      VALUES ('sess_t','school_t','ct_cbt','user_instr','loc_t',?,?,2,?)`, sessionStart, sessionEnd, createdAt)
	// Multi-instructor join is the booking engine's qualification check
	// target; mirror the legacy instructor_id column into it.
	exec(`INSERT INTO session_instructors (id, school_id, session_id, instructor_id, is_primary, assigned_at, assigned_by)
	      VALUES ('si_t','school_t','sess_t','user_instr',1,?,?)`, createdAt, "user_instr")
}

// do is a tiny HTTP-call helper for tests.
func (f *apiFixture) do(method, path string, body any, token string) (*http.Response, []byte) {
	f.t.Helper()
	var bodyReader *bytes.Buffer
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			f.t.Fatalf("marshal: %v", err)
		}
		bodyReader = bytes.NewBuffer(b)
	} else {
		bodyReader = bytes.NewBuffer(nil)
	}
	req, err := http.NewRequest(method, f.srv.URL+path, bodyReader)
	if err != nil {
		f.t.Fatal(err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		f.t.Fatal(err)
	}
	defer resp.Body.Close()
	buf := new(bytes.Buffer)
	buf.ReadFrom(resp.Body)
	return resp, buf.Bytes()
}

// mintToken issues a real Firebase ID token for the given local user.
//
// Steps:
//  1. Ensure a Firebase user exists with UID = <fixture-prefix>_<userID>.
//     Idempotent — re-creates are ignored.
//  2. Link the UID to the local users row (UPDATE firebase_uid).
//  3. Mint a custom token via the Admin SDK and exchange it for an ID
//     token via the emulator's REST endpoint — same dance Flutter does
//     post-cutover.
//  4. Register a cleanup so the Firebase user gets deleted after the
//     test, keeping the emulator's user store small.
//
// The fixture prefix isolates UIDs so two fixtures (or repeated runs in
// the same emulator session) don't collide on names like "user_stu".
func (f *apiFixture) mintToken(userID string) string {
	f.t.Helper()
	ctx := context.Background()
	uid := f.uidPrefix + "_" + userID

	// Look up the email so the Firebase user is identifiable in the
	// emulator UI, but it's not load-bearing for the verify path.
	var email string
	if err := f.db.QueryRow(`SELECT email FROM users WHERE id = ?`, userID).Scan(&email); err != nil {
		f.t.Fatalf("mintToken: user %q not found: %v", userID, err)
	}

	_, err := f.fb.Auth.CreateUser(ctx, (&firebaseauth.UserToCreate{}).
		UID(uid).
		Email(email).
		Password("test-only-password-never-used").
		EmailVerified(true))
	if err != nil && !firebaseauth.IsUIDAlreadyExists(err) && !firebaseauth.IsEmailAlreadyExists(err) {
		f.t.Fatalf("mintToken: create firebase user %q: %v", uid, err)
	}
	f.t.Cleanup(func() {
		_ = f.fb.Auth.DeleteUser(ctx, uid)
	})

	if _, err := f.db.Exec(`UPDATE users SET firebase_uid = ? WHERE id = ?`, uid, userID); err != nil {
		f.t.Fatalf("mintToken: link firebase_uid: %v", err)
	}

	idToken, err := f.exchangeCustomToken(ctx, uid)
	if err != nil {
		f.t.Fatalf("mintToken: exchange: %v", err)
	}
	return idToken
}

func (f *apiFixture) loginStudent() string {
	return f.mintToken("user_stu")
}

// clearEmulator deletes every user from the Firebase Auth emulator
// project. Called inside the fixture cleanup to keep state from
// leaking between tests (and across `go test` runs — the emulator
// persists in-process for its whole lifetime).
//
// Uses the emulator REST endpoint instead of the Admin SDK because the
// SDK doesn't expose a "delete all" — only paged iteration + per-user
// delete, which is slower and noisier in tests.
func (f *apiFixture) clearEmulator() {
	url := "http://" + f.emuHost + "/emulator/v1/projects/" + f.projectID + "/accounts"
	req, _ := http.NewRequest("DELETE", url, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return
	}
	resp.Body.Close()
}

// signupViaFirebase performs the full client-side dance that Flutter does
// when a new student signs up:
//
//  1. Create a Firebase user (email + dummy password) via the Admin SDK.
//  2. Mint a custom token and exchange it for an ID token.
//  3. POST /auth/firebase-signup with the ID token + profile body.
//
// Returns the HTTP response, the response body, and the ID token so the
// caller can make follow-up authenticated calls. Profile-write failures
// are surfaced to the caller — the helper doesn't assert on status.
func (f *apiFixture) signupViaFirebase(profileBody map[string]any) (*http.Response, []byte, string) {
	f.t.Helper()
	ctx := context.Background()

	emailVal, _ := profileBody["email"].(string)
	email := strings.ToLower(strings.TrimSpace(emailVal))
	if email == "" {
		f.t.Fatal("signupViaFirebase: profileBody.email required")
	}

	uid := f.uidPrefix + "_signup_" + randomShort()
	if _, err := f.fb.Auth.CreateUser(ctx, (&firebaseauth.UserToCreate{}).
		UID(uid).
		Email(email).
		Password("test-only-password-never-used").
		EmailVerified(true)); err != nil && !firebaseauth.IsUIDAlreadyExists(err) && !firebaseauth.IsEmailAlreadyExists(err) {
		f.t.Fatalf("signupViaFirebase: create firebase user: %v", err)
	}
	f.t.Cleanup(func() { _ = f.fb.Auth.DeleteUser(ctx, uid) })

	idToken, err := f.exchangeCustomToken(ctx, uid)
	if err != nil {
		f.t.Fatalf("signupViaFirebase: exchange: %v", err)
	}
	resp, body := f.do("POST", "/auth/firebase-signup", profileBody, idToken)
	return resp, body, idToken
}

func randomShort() string {
	var b [3]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// exchangeCustomToken mints a custom JWT via the Admin SDK and then
// calls the emulator's REST endpoint signInWithCustomToken to get back
// an ID token. This is the same exchange the Flutter SDK does — we're
// just doing it explicitly because tests don't run a Firebase client.
func (f *apiFixture) exchangeCustomToken(ctx context.Context, uid string) (string, error) {
	customToken, err := f.fb.Auth.CustomToken(ctx, uid)
	if err != nil {
		return "", err
	}
	payload, _ := json.Marshal(map[string]any{
		"token":             customToken,
		"returnSecureToken": true,
	})
	// The emulator ignores the apiKey value but the URL requires it.
	url := "http://" + f.emuHost +
		"/identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=emulator"
	req, _ := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return "", &exchangeErr{status: resp.StatusCode, body: string(raw)}
	}
	var out struct {
		IDToken string `json:"idToken"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", err
	}
	return out.IDToken, nil
}

type exchangeErr struct {
	status int
	body   string
}

func (e *exchangeErr) Error() string {
	return "exchange failed: status=" + http.StatusText(e.status) + " body=" + e.body
}

func randomPrefix() string {
	var b [6]byte
	_, _ = rand.Read(b[:])
	return "fx" + hex.EncodeToString(b[:])
}

// ----- Tests -----

func TestHealthcheck(t *testing.T) {
	f := newAPIFixture(t)
	resp, _ := f.do("GET", "/health", nil, "")
	if resp.StatusCode != 200 {
		t.Errorf("expected 200, got %d", resp.StatusCode)
	}
}

func TestMe_RequiresAuth(t *testing.T) {
	f := newAPIFixture(t)
	resp, _ := f.do("GET", "/me", nil, "")
	if resp.StatusCode != 401 {
		t.Errorf("expected 401 without token, got %d", resp.StatusCode)
	}
}

func TestMe_OK(t *testing.T) {
	f := newAPIFixture(t)
	tok := f.loginStudent()
	resp, body := f.do("GET", "/me", nil, tok)
	if resp.StatusCode != 200 {
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), "stu@test") {
		t.Errorf("expected email in /me response, got %s", body)
	}
}

func TestListSessions_ShowsHonestCapacity(t *testing.T) {
	f := newAPIFixture(t)
	tok := f.loginStudent()
	from := f.now.Add(-time.Hour).Format(time.RFC3339)
	to := f.now.Add(7 * 24 * time.Hour).Format(time.RFC3339)
	resp, body := f.do("GET", "/sessions?from="+from+"&to="+to, nil, tok)
	if resp.StatusCode != 200 {
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	var out struct {
		Sessions []struct {
			SessionID         string `json:"sessionId"`
			Capacity          int    `json:"capacity"`
			HonestCapacity    int    `json:"honestCapacity"`
			SuitableFreeBikes int    `json:"suitableFreeBikes"`
		} `json:"sessions"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatal(err)
	}
	if len(out.Sessions) != 1 {
		t.Fatalf("expected 1 session, got %d", len(out.Sessions))
	}
	s := out.Sessions[0]
	if s.Capacity != 2 {
		t.Errorf("capacity: got %d want 2", s.Capacity)
	}
	// One A1 bike → honest capacity = min(2, 1) = 1
	if s.HonestCapacity != 1 {
		t.Errorf("honest capacity: got %d want 1 (bike-limited)", s.HonestCapacity)
	}
	if s.SuitableFreeBikes != 1 {
		t.Errorf("suitable bikes: got %d want 1", s.SuitableFreeBikes)
	}
}

func TestBookCancelFlow_StudentEndToEnd(t *testing.T) {
	f := newAPIFixture(t)
	tok := f.loginStudent()

	// Book
	resp, body := f.do("POST", "/bookings",
		map[string]string{"sessionId": "sess_t"}, tok)
	if resp.StatusCode != 201 {
		t.Fatalf("create: status=%d body=%s", resp.StatusCode, body)
	}
	var created struct {
		Booking struct {
			ID, Status, BikeID string
		}
	}
	if err := json.Unmarshal(body, &created); err != nil {
		t.Fatal(err)
	}
	if created.Booking.Status != "booked" {
		t.Errorf("expected booked, got %s", created.Booking.Status)
	}
	if created.Booking.BikeID != "bike_t" {
		t.Errorf("expected bike assigned, got %s", created.Booking.BikeID)
	}

	// Cancel
	resp, body = f.do("DELETE", "/bookings/"+created.Booking.ID, nil, tok)
	if resp.StatusCode != 200 {
		t.Fatalf("cancel: status=%d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), `"status":"cancelled"`) {
		t.Errorf("expected status cancelled in response, got %s", body)
	}
}

func TestBook_StudentCannotBookForAnother(t *testing.T) {
	f := newAPIFixture(t)
	tok := f.loginStudent()
	resp, body := f.do("POST", "/bookings",
		map[string]string{"sessionId": "sess_t", "studentId": "user_instr"}, tok)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403 when student books for another, got %d body=%s", resp.StatusCode, body)
	}
}

func TestBook_DoubleBookReturnsConflict(t *testing.T) {
	f := newAPIFixture(t)
	// Add a second A1 bike so the second booking attempt gets past the
	// suitable-bike check and hits the UNIQUE(school_id, session_id,
	// student_id) constraint we're actually testing.
	if _, err := f.db.Exec(`INSERT INTO bikes (id, school_id, category, transmission, status, home_location_id, current_location_id, created_at)
	                        VALUES ('bike_t2','school_t','A1','manual','ready','loc_t','loc_t',?)`,
		f.now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	tok := f.loginStudent()
	resp, body := f.do("POST", "/bookings", map[string]string{"sessionId": "sess_t"}, tok)
	if resp.StatusCode != 201 {
		t.Fatalf("first book: %d %s", resp.StatusCode, body)
	}
	resp, body = f.do("POST", "/bookings", map[string]string{"sessionId": "sess_t"}, tok)
	if resp.StatusCode != 409 {
		t.Errorf("expected 409 conflict on double book, got %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), "already_booked") {
		t.Errorf("expected already_booked code, got %s", body)
	}
}

// TestForgedToken_Rejected — three-segment garbage that looks like a
// JWT to the dot-count sniff must still be rejected at signature
// verification.
func TestForgedToken_Rejected(t *testing.T) {
	f := newAPIFixture(t)
	resp, body := f.do("GET", "/me", nil, "aaa.bbb.ccc")
	if resp.StatusCode != 401 {
		t.Errorf("expected 401, got %d body=%s", resp.StatusCode, body)
	}
}
