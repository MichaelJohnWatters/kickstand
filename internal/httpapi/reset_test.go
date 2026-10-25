package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
)

func postReq(t *testing.T, path string, h http.HandlerFunc, body string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	h(rec, httptest.NewRequest(http.MethodPost, path, strings.NewReader(body)))
	return rec
}

func authTokenCount(t *testing.T, s *Server) int {
	t.Helper()
	var n int
	if err := s.DB.QueryRow(`SELECT COUNT(*) FROM auth_tokens`).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	return n
}

func TestPasswordReset_EndToEnd(t *testing.T) {
	s := loginServer(t) // u1 sam@test.co, password "correct horse battery"

	// Unknown email → 204, no token created (no enumeration).
	if rec := postReq(t, "/auth/password-reset/request", s.handlePasswordResetRequest,
		`{"schoolId":"sch1","email":"ghost@test.co"}`); rec.Code != http.StatusNoContent {
		t.Fatalf("unknown email: status %d, want 204", rec.Code)
	}
	if authTokenCount(t, s) != 0 {
		t.Fatal("a token was created for an unknown email")
	}

	// Known email → 204 + a token row.
	if rec := postReq(t, "/auth/password-reset/request", s.handlePasswordResetRequest,
		`{"schoolId":"sch1","email":"sam@test.co"}`); rec.Code != http.StatusNoContent {
		t.Fatalf("known email: status %d, want 204", rec.Code)
	}
	if authTokenCount(t, s) != 1 {
		t.Fatalf("expected 1 reset token, got %d", authTokenCount(t, s))
	}

	// Confirm with a freshly-minted token → new password takes effect.
	tok, err := auth.CreateResetToken(context.Background(), s.DB, "sch1", "u1", time.Now())
	if err != nil {
		t.Fatalf("mint token: %v", err)
	}
	if rec := postReq(t, "/auth/password-reset/confirm", s.handlePasswordResetConfirm,
		`{"token":"`+tok+`","newPassword":"a-fresh-password"}`); rec.Code != http.StatusNoContent {
		t.Fatalf("confirm: status %d, want 204 (%s)", rec.Code, "")
	}
	if postLogin(t, s, `{"schoolId":"sch1","email":"sam@test.co","password":"a-fresh-password"}`).Code != http.StatusOK {
		t.Error("new password should log in")
	}
	if postLogin(t, s, `{"schoolId":"sch1","email":"sam@test.co","password":"correct horse battery"}`).Code != http.StatusUnauthorized {
		t.Error("old password should no longer log in")
	}

	// Reusing the (now consumed) token → 400.
	if rec := postReq(t, "/auth/password-reset/confirm", s.handlePasswordResetConfirm,
		`{"token":"`+tok+`","newPassword":"another-password"}`); rec.Code != http.StatusBadRequest {
		t.Errorf("reused token: status %d, want 400", rec.Code)
	}
}

func TestPasswordResetConfirm_RejectsGarbageAndShort(t *testing.T) {
	s := loginServer(t)
	if rec := postReq(t, "/auth/password-reset/confirm", s.handlePasswordResetConfirm,
		`{"token":"garbage","newPassword":"a-good-password"}`); rec.Code != http.StatusBadRequest {
		t.Errorf("garbage token: status %d, want 400", rec.Code)
	}
	// Short password is rejected before the token is even checked.
	tok, _ := auth.CreateResetToken(context.Background(), s.DB, "sch1", "u1", time.Now())
	if rec := postReq(t, "/auth/password-reset/confirm", s.handlePasswordResetConfirm,
		`{"token":"`+tok+`","newPassword":"short"}`); rec.Code != http.StatusBadRequest {
		t.Errorf("short password: status %d, want 400", rec.Code)
	}
}
