package httpapi

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCORS_AllowlistFailsClosed(t *testing.T) {
	allowed := "https://app.kickstand.example"
	h := withCORS([]string{allowed})(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	cases := []struct {
		name      string
		origin    string
		wantAllow string // expected Access-Control-Allow-Origin ("" = header absent)
	}{
		{"allow-listed origin reflected", allowed, allowed},
		{"unknown remote origin denied", "https://evil.example", ""},
		{"localhost denied once allow-list is set", "http://localhost:1234", ""},
		{"no origin header", "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/x", nil)
			if tc.origin != "" {
				req.Header.Set("Origin", tc.origin)
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if got := rec.Header().Get("Access-Control-Allow-Origin"); got != tc.wantAllow {
				t.Fatalf("Allow-Origin = %q, want %q", got, tc.wantAllow)
			}
			// Credentials header must only ride along with a reflected origin.
			gotCreds := rec.Header().Get("Access-Control-Allow-Credentials")
			if tc.wantAllow == "" && gotCreds != "" {
				t.Fatalf("Allow-Credentials set (%q) without an allowed origin", gotCreds)
			}
		})
	}
}

func TestCORS_DevModeAllowsLocalhostOnly(t *testing.T) {
	// Empty allow-list = dev mode: localhost reflected, remote refused.
	h := withCORS(nil)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	for _, tc := range []struct {
		origin string
		want   bool
	}{
		{"http://localhost:8080", true},
		{"http://127.0.0.1:3000", true},
		{"http://[::1]:9000", true},
		{"https://app.kickstand.example", false},
		{"https://localhost.evil.example", false},
	} {
		req := httptest.NewRequest(http.MethodGet, "/x", nil)
		req.Header.Set("Origin", tc.origin)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		reflected := rec.Header().Get("Access-Control-Allow-Origin") == tc.origin
		if reflected != tc.want {
			t.Errorf("origin %q reflected=%v, want %v", tc.origin, reflected, tc.want)
		}
	}
}

func TestCORS_PreflightShortCircuits(t *testing.T) {
	called := false
	h := withCORS(nil)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
	}))
	req := httptest.NewRequest(http.MethodOptions, "/x", nil)
	req.Header.Set("Origin", "http://localhost:8080")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if called {
		t.Fatal("OPTIONS preflight should not reach the next handler")
	}
	if rec.Code != http.StatusNoContent {
		t.Fatalf("preflight status = %d, want %d", rec.Code, http.StatusNoContent)
	}
}

func TestMaxBytes_RejectsOversizedBody(t *testing.T) {
	const limit = 1 << 10 // 1 KiB
	h := withMaxBytes(limit)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "too big", http.StatusRequestEntityTooLarge)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))

	t.Run("under limit passes", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(strings.Repeat("a", 512)))
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", rec.Code)
		}
	})

	t.Run("over limit rejected", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(strings.Repeat("a", 4096)))
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusRequestEntityTooLarge {
			t.Fatalf("status = %d, want 413", rec.Code)
		}
	})
}

func TestMaxBytes_ZeroDisablesCap(t *testing.T) {
	read := int64(-1)
	h := withMaxBytes(0)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n, _ := io.Copy(io.Discard, r.Body)
		read = n
	}))
	req := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(strings.Repeat("a", 100_000)))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if read != 100_000 {
		t.Fatalf("read %d bytes, want 100000 (cap should be disabled)", read)
	}
}
