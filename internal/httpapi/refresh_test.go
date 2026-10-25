package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"
)

// loginAndGetRefresh logs sam in and returns (accessToken, refreshToken).
func loginAndGetRefresh(t *testing.T, s *Server) (string, string) {
	t.Helper()
	rec := postLogin(t, s, `{"schoolId":"sch1","email":"sam@test.co","password":"correct horse battery"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("login status = %d, want 200 (%s)", rec.Code, rec.Body.String())
	}
	var resp struct {
		Token        string `json:"token"`
		RefreshToken string `json:"refreshToken"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode login: %v", err)
	}
	if resp.Token == "" || resp.RefreshToken == "" {
		t.Fatalf("login missing tokens: %s", rec.Body.String())
	}
	return resp.Token, resp.RefreshToken
}

func TestRefresh_RotatesAndIssuesUsableAccessToken(t *testing.T) {
	s := loginServer(t)
	_, refresh := loginAndGetRefresh(t, s)

	rec := postReq(t, "/auth/refresh", s.handleRefresh, `{"refreshToken":"`+refresh+`"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("refresh status = %d, want 200 (%s)", rec.Code, rec.Body.String())
	}
	var resp struct {
		Token        string `json:"token"`
		RefreshToken string `json:"refreshToken"`
		Identity     struct {
			UserID string `json:"userId"`
		} `json:"identity"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.Identity.UserID != "u1" {
		t.Errorf("identity userId = %q, want u1", resp.Identity.UserID)
	}
	if resp.RefreshToken == "" || resp.RefreshToken == refresh {
		t.Errorf("refresh should rotate, got %q (old %q)", resp.RefreshToken, refresh)
	}
	// The new access token verifies back to the user.
	if uid, err := s.Tokens.VerifyAccess(resp.Token); err != nil || string(uid) != "u1" {
		t.Errorf("new access token invalid: uid=%q err=%v", uid, err)
	}
	// The consumed refresh token can't be reused.
	if again := postReq(t, "/auth/refresh", s.handleRefresh, `{"refreshToken":"`+refresh+`"}`); again.Code != http.StatusUnauthorized {
		t.Errorf("reused refresh token: status = %d, want 401", again.Code)
	}
}

func TestRefresh_RejectsGarbage(t *testing.T) {
	s := loginServer(t)
	if rec := postReq(t, "/auth/refresh", s.handleRefresh, `{"refreshToken":"nope"}`); rec.Code != http.StatusUnauthorized {
		t.Errorf("garbage token: status = %d, want 401", rec.Code)
	}
}

func TestRefresh_DisabledAccountRejected(t *testing.T) {
	s := loginServer(t)
	_, refresh := loginAndGetRefresh(t, s)
	if _, err := s.DB.Exec(`UPDATE users SET account_status = 'disabled' WHERE id = 'u1'`); err != nil {
		t.Fatal(err)
	}
	if rec := postReq(t, "/auth/refresh", s.handleRefresh, `{"refreshToken":"`+refresh+`"}`); rec.Code != http.StatusForbidden {
		t.Errorf("disabled account: status = %d, want 403 (%s)", rec.Code, rec.Body.String())
	}
}

func TestRefresh_DisabledWhenNoTokenService(t *testing.T) {
	s := &Server{}
	if rec := postReq(t, "/auth/refresh", s.handleRefresh, `{"refreshToken":"x"}`); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("no token service: status = %d, want 503", rec.Code)
	}
}
