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
	"github.com/michaeljohnwatters/kickstand/internal/filestore"
	"github.com/michaeljohnwatters/kickstand/internal/httpapi"
)

// apiFixture runs a real Server against a real SQLite file. Black-box: tests
// only touch the HTTP surface and the test seed, never internal types.
type apiFixture struct {
	t        *testing.T
	db       *sql.DB
	srv      *httptest.Server
	pw       string
	password string
	now      time.Time
}

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
	api := httpapi.NewServer(d, files)
	srv := httptest.NewServer(api.Routes())
	t.Cleanup(srv.Close)

	f := &apiFixture{
		t:        t,
		db:       d,
		srv:      srv,
		password: "correct horse battery staple",
		// Anchor at real wallclock so seeded sessions stay in the future no
		// matter what date the test happens to run on. (Booking engine uses
		// time.Now() directly for its "session not started" check.)
		now: time.Now().UTC(),
	}
	f.seed()
	return f
}

func (f *apiFixture) seed() {
	f.t.Helper()
	hash, err := auth.HashPassword(f.password)
	if err != nil {
		f.t.Fatal(err)
	}
	createdAt := f.now.Format(time.RFC3339)
	sessionStart := f.now.Add(24 * time.Hour).Format(time.RFC3339)
	sessionEnd := f.now.Add(28 * time.Hour).Format(time.RFC3339)

	exec := func(q string, args ...any) {
		f.t.Helper()
		if _, err := f.db.Exec(q, args...); err != nil {
			f.t.Fatalf("seed %q: %v", q, err)
		}
	}

	exec(`INSERT INTO schools (id, name, region, test_body_label, created_at)
	      VALUES ('school_t', 'Test School', 'NI', 'DVA', ?)`, createdAt)
	exec(`INSERT INTO locations (id, school_id, name, created_at) VALUES ('loc_t','school_t','Belfast',?)`, createdAt)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, created_at)
	      VALUES ('user_instr','school_t','instr@test',?,'Instructor','instructor',?)`, hash, createdAt)
	exec(`INSERT INTO instructor_profiles (user_id, school_id, home_location_id) VALUES ('user_instr','school_t','loc_t')`)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	      VALUES ('user_stu','school_t','stu@test',?,'Student','student','active',?)`, hash, createdAt)
	exec(`INSERT INTO student_profiles (user_id, school_id, transmission_preference, cbt_certificate_held, theory_passed)
	      VALUES ('user_stu','school_t','manual',0,0)`)
	exec(`INSERT INTO course_types (id, school_id, code, name, region, required_bike_category,
	          duration_minutes, max_ratio, price_pence, non_teaching, created_at)
	      VALUES ('ct_cbt','school_t','CBT-125','CBT 125','NI','A1',240,4,13000,0,?)`, createdAt)
	exec(`INSERT INTO instructor_qualifications (school_id, instructor_id, course_type_id)
	      VALUES ('school_t','user_instr','ct_cbt')`)
	exec(`INSERT INTO bikes (id, school_id, category, transmission, status, home_location_id, current_location_id, created_at)
	      VALUES ('bike_t','school_t','A1','manual','ready','loc_t','loc_t',?)`, createdAt)
	exec(`INSERT INTO sessions (id, school_id, course_type_id, instructor_id, location_id, starts_at, ends_at, capacity, created_at)
	      VALUES ('sess_t','school_t','ct_cbt','user_instr','loc_t',?,?,2,?)`, sessionStart, sessionEnd, createdAt)
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

func (f *apiFixture) loginStudent() string {
	f.t.Helper()
	resp, body := f.do("POST", "/auth/login", map[string]string{"email": "stu@test", "password": f.password}, "")
	if resp.StatusCode != 200 {
		f.t.Fatalf("login: status=%d body=%s", resp.StatusCode, body)
	}
	var out struct{ Token string }
	if err := json.Unmarshal(body, &out); err != nil {
		f.t.Fatal(err)
	}
	return out.Token
}

// ----- Tests -----

func TestHealthcheck(t *testing.T) {
	f := newAPIFixture(t)
	resp, _ := f.do("GET", "/health", nil, "")
	if resp.StatusCode != 200 {
		t.Errorf("expected 200, got %d", resp.StatusCode)
	}
}

func TestLogin_OK(t *testing.T) {
	f := newAPIFixture(t)
	resp, body := f.do("POST", "/auth/login", map[string]string{"email": "stu@test", "password": f.password}, "")
	if resp.StatusCode != 200 {
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatal(err)
	}
	if out["token"] == "" {
		t.Errorf("expected non-empty token")
	}
}

func TestLogin_BadPassword(t *testing.T) {
	f := newAPIFixture(t)
	resp, body := f.do("POST", "/auth/login", map[string]string{"email": "stu@test", "password": "wrong"}, "")
	if resp.StatusCode != 401 {
		t.Errorf("expected 401, got %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), "invalid_credentials") {
		t.Errorf("expected invalid_credentials code, got %s", body)
	}
}

func TestLogin_MissingField(t *testing.T) {
	f := newAPIFixture(t)
	resp, body := f.do("POST", "/auth/login", map[string]string{"email": "stu@test"}, "")
	if resp.StatusCode != 400 {
		t.Errorf("expected 400, got %d body=%s", resp.StatusCode, body)
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
