package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/db"
)

// loginServer builds a Server with hand-rolled tokens + a seeded password user,
// no Firebase / emulator needed.
func loginServer(t *testing.T) *Server {
	t.Helper()
	ctx := context.Background()
	d, err := db.Open(t.TempDir() + "/login.db")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	hash, _ := auth.HashPassword("correct horse battery")
	now := time.Now().UTC().Format(time.RFC3339)
	if _, err := d.ExecContext(ctx,
		`INSERT INTO schools (id, name, region, test_body_label, created_at) VALUES ('sch1','T','NI','DVA',?)`, now); err != nil {
		t.Fatal(err)
	}
	if _, err := d.ExecContext(ctx,
		`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
		 VALUES ('u1','sch1','sam@test.co',?,'Sam','owner','active',?)`, hash, now); err != nil {
		t.Fatal(err)
	}
	ts, err := auth.NewTokenService([]byte("0123456789abcdef0123456789abcdef"))
	if err != nil {
		t.Fatal(err)
	}
	return &Server{DB: d, Tokens: ts}
}

func postLogin(t *testing.T, s *Server, body string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/auth/login", strings.NewReader(body))
	s.handleLogin(rec, req)
	return rec
}

func TestLogin_Success(t *testing.T) {
	s := loginServer(t)
	rec := postLogin(t, s, `{"schoolId":"sch1","email":"SAM@test.co","password":"correct horse battery"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}
	var resp struct {
		Token    string `json:"token"`
		Identity struct {
			UserID string `json:"userId"`
			Role   string `json:"role"`
		} `json:"identity"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.Token == "" || resp.Identity.UserID != "u1" || resp.Identity.Role != "owner" {
		t.Fatalf("unexpected response: %s", rec.Body.String())
	}
	// The issued token verifies back to the user.
	uid, err := s.Tokens.VerifyAccess(resp.Token)
	if err != nil || string(uid) != "u1" {
		t.Errorf("issued token invalid: uid=%q err=%v", uid, err)
	}
}

func TestLogin_WrongPassword(t *testing.T) {
	s := loginServer(t)
	rec := postLogin(t, s, `{"schoolId":"sch1","email":"sam@test.co","password":"nope nope nope"}`)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("wrong password: status = %d, want 401", rec.Code)
	}
}

func TestLogin_DisabledWhenNoTokenService(t *testing.T) {
	s := &Server{} // no Tokens configured
	rec := postLogin(t, s, `{"email":"x","password":"y"}`)
	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("no token service: status = %d, want 503", rec.Code)
	}
}

func postSignup(t *testing.T, s *Server, body string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/auth/signup", strings.NewReader(body))
	s.handleSignup(rec, req)
	return rec
}

func TestSignup_ThenLogin(t *testing.T) {
	s := loginServer(t) // seeds school sch1 (onboarding defaults to 'open')
	rec := postSignup(t, s, `{"schoolId":"sch1","name":"New Rider","email":"NEW@test.co","password":"a-good-password"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("signup status = %d, want 201 (%s)", rec.Code, rec.Body.String())
	}
	var resp struct {
		Token    string `json:"token"`
		Identity struct {
			Role          string `json:"role"`
			AccountStatus string `json:"accountStatus"`
			Email         string `json:"email"`
		} `json:"identity"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.Token == "" || resp.Identity.Role != "student" || resp.Identity.AccountStatus != "active" || resp.Identity.Email != "new@test.co" {
		t.Fatalf("unexpected signup response: %s", rec.Body.String())
	}
	// The new account can log in with the chosen password.
	if lr := postLogin(t, s, `{"schoolId":"sch1","email":"new@test.co","password":"a-good-password"}`); lr.Code != http.StatusOK {
		t.Errorf("login after signup: status = %d, want 200 (%s)", lr.Code, lr.Body.String())
	}
}

func TestSignup_RejectsShortPassword(t *testing.T) {
	s := loginServer(t)
	rec := postSignup(t, s, `{"schoolId":"sch1","name":"X","email":"x@test.co","password":"short"}`)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("short password: status = %d, want 400 (%s)", rec.Code, rec.Body.String())
	}
}

func TestSignup_DuplicateEmail(t *testing.T) {
	s := loginServer(t) // already has sam@test.co
	rec := postSignup(t, s, `{"schoolId":"sch1","name":"Dup","email":"sam@test.co","password":"a-good-password"}`)
	if rec.Code != http.StatusConflict {
		t.Errorf("duplicate email: status = %d, want 409 (%s)", rec.Code, rec.Body.String())
	}
}
