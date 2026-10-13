package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/db"
)

// A dedicated single-tenant instance must advertise only its own school on
// the public GET /schools, even if the database happens to hold others.
func TestListSchools_SingleTenantFiltersToPinnedSchool(t *testing.T) {
	ctx := context.Background()
	d, err := db.Open(t.TempDir() + "/st.db")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer d.Close()
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	now := time.Now().UTC().Format(time.RFC3339)
	for _, id := range []string{"sch-1", "sch-2"} {
		if _, err := d.ExecContext(ctx,
			`INSERT INTO schools (id, name, region, test_body_label, created_at)
			 VALUES (?, ?, 'NI', 'DVA', ?)`, id, "School "+id, now); err != nil {
			t.Fatalf("insert %s: %v", id, err)
		}
	}

	listIDs := func(s *Server) []string {
		rec := httptest.NewRecorder()
		s.handleListSchools(rec, httptest.NewRequest(http.MethodGet, "/schools", nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", rec.Code)
		}
		var body struct {
			Schools []struct {
				ID string `json:"id"`
			} `json:"schools"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatalf("decode: %v", err)
		}
		ids := make([]string, 0, len(body.Schools))
		for _, sc := range body.Schools {
			ids = append(ids, sc.ID)
		}
		return ids
	}

	// Shared (no pin): both schools visible.
	shared := NewServer(d, nil, nil)
	if got := listIDs(shared); len(got) != 2 {
		t.Errorf("shared mode returned %v, want both schools", got)
	}

	// Pinned: only the configured school.
	dedicated := NewServer(d, nil, nil)
	dedicated.SingleTenantSchoolID = "sch-1"
	got := listIDs(dedicated)
	if len(got) != 1 || got[0] != "sch-1" {
		t.Errorf("single-tenant mode returned %v, want [sch-1]", got)
	}
}
