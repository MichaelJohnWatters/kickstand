package httpapi_test

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/filestore"
	"github.com/michaeljohnwatters/kickstand/internal/httpapi"
)

// apiFixture runs a real Server against a real SQLite file. Black-box: tests
// only touch the HTTP surface and the test seed, never internal types.
//
// Auth is hand-rolled: the fixture's TokenService mints the same HS256 access
// tokens /auth/login issues, so mintToken(userID) hands a test a Bearer token
// that the server's middleware verifies exactly like production traffic. No
// external services — the whole suite runs under plain `go test`.
type apiFixture struct {
	t      *testing.T
	db     *sql.DB
	srv    *httptest.Server
	tokens *auth.TokenService
	now    time.Time
}

// testSigningKey is a fixed 32-byte HS256 key for the test TokenService.
const testSigningKey = "test-signing-key-0123456789abcdef"

func newAPIFixture(t *testing.T) *apiFixture {
	t.Helper()

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
	tokens, err := auth.NewTokenService([]byte(testSigningKey))
	if err != nil {
		t.Fatalf("token service: %v", err)
	}

	api := httpapi.NewServer(d, files)
	api.Tokens = tokens
	srv := httptest.NewServer(api.Routes())
	t.Cleanup(srv.Close)

	f := &apiFixture{
		t:      t,
		db:     d,
		srv:    srv,
		tokens: tokens,
		// Anchor at real wallclock so seeded sessions stay in the future
		// no matter what date the test happens to run on. (Booking engine
		// uses time.Now() directly for its "session not started" check.)
		now: time.Now().UTC(),
	}
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

// mintToken issues a hand-rolled access token for the given local user —
// the same HS256 JWT /auth/login returns. The user must already exist in
// the DB (the middleware re-loads role/status from it on every request).
func (f *apiFixture) mintToken(userID string) string {
	f.t.Helper()
	var one int
	if err := f.db.QueryRow(`SELECT 1 FROM users WHERE id = ?`, userID).Scan(&one); err != nil {
		f.t.Fatalf("mintToken: user %q not found: %v", userID, err)
	}
	token, err := f.tokens.IssueAccess(domain.UserID(userID), time.Hour, f.now)
	if err != nil {
		f.t.Fatalf("mintToken: issue: %v", err)
	}
	return token
}

func (f *apiFixture) loginStudent() string {
	return f.mintToken("user_stu")
}

// signupViaPassword performs a student self-signup through the public
// /auth/signup endpoint. A password is injected if the profile body doesn't
// carry one. Returns the HTTP response, the body, and the access token from
// a successful (201) signup (empty on failure). Profile-write failures are
// surfaced to the caller — the helper doesn't assert on status.
func (f *apiFixture) signupViaPassword(profileBody map[string]any) (*http.Response, []byte, string) {
	f.t.Helper()
	if _, ok := profileBody["password"]; !ok {
		profileBody["password"] = "a-good-password"
	}
	resp, body := f.do("POST", "/auth/signup", profileBody, "")
	var out struct {
		Token string `json:"token"`
	}
	_ = json.Unmarshal(body, &out)
	return resp, body, out.Token
}

// ----- Tests -----

func TestHealthcheck(t *testing.T) {
	f := newAPIFixture(t)
	resp, _ := f.do("GET", "/healthz", nil, "")
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
