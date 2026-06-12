package httpapi_test

import (
	"database/sql"
	"strings"
	"testing"
)

// TestAudit_MutationsAreLogged exercises a representative mix of
// mutating routes and asserts each lands an audit_log row with the
// expected (method, pattern, actor, target, status, error_code) shape.
//
// The full route table is covered by TestAuth_RoleAccessMatrix; here we
// only verify the middleware itself writes the row correctly, not that
// every route is auditable (it is — by construction).
func TestAudit_MutationsAreLogged(t *testing.T) {
	f := newLedgerFixture(t)

	// --- 1. POST /bikes (admin creating a bike → 201) ---
	resp, body := f.do("POST", "/bikes", map[string]any{
		"nickname": "Audit Test Bike", "make": "Honda", "model": "CB",
		"category": "A1", "transmission": "manual",
		"engineCc": 125, "homeLocationId": "loc_t",
	}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("create bike: %d body=%s", resp.StatusCode, body)
	}

	row := lastAuditRow(t, f.db, "POST", "/bikes")
	if row.method != "POST" || row.pathPattern != "/bikes" {
		t.Errorf("bike create: unexpected method/pattern %+v", row)
	}
	if row.actorUserID == nil || *row.actorUserID != "user_admin" {
		t.Errorf("bike create: actor_user_id = %v, want user_admin", row.actorUserID)
	}
	if row.actorRole != "admin" || row.statusCode != 201 || row.errorCode != "" {
		t.Errorf("bike create: actor/status/err %+v", row)
	}
	if row.targetEntity != "bikes" {
		t.Errorf("bike create: target_entity = %q, want bikes", row.targetEntity)
	}

	// --- 2. POST /bikes/{id}/restore — bound id should land in target_id ---
	resp, body = f.do("POST", "/bikes/bike_t/offline",
		map[string]any{"reason": "damaged"}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("take offline: %d body=%s", resp.StatusCode, body)
	}
	resp, _ = f.do("POST", "/bikes/bike_t/restore", nil, f.adminToken)
	if resp.StatusCode != 204 {
		t.Fatalf("restore: %d", resp.StatusCode)
	}
	row = lastAuditRow(t, f.db, "POST", "/bikes/{id}/restore")
	if row.targetEntity != "bikes" || row.targetID != "bike_t" {
		t.Errorf("restore: target = %q/%q, want bikes/bike_t",
			row.targetEntity, row.targetID)
	}
	if row.statusCode != 204 {
		t.Errorf("restore: status = %d, want 204", row.statusCode)
	}

	// --- 3. PATCH /school — admin-only settings update ---
	resp, _ = f.do("PATCH", "/school",
		map[string]any{"cancelCutoffHours": 36}, f.adminToken)
	if resp.StatusCode != 204 {
		t.Fatalf("patch school: %d", resp.StatusCode)
	}
	row = lastAuditRow(t, f.db, "PATCH", "/school")
	if row.method != "PATCH" || row.statusCode != 204 {
		t.Errorf("patch school: %+v", row)
	}

	// --- 4. Failed mutation — student attempting an admin-only POST.
	// Should still log, with status 403 and error_code = "forbidden". ---
	resp, _ = f.do("POST", "/students/user_stu/charges",
		map[string]any{"amountPence": 100, "description": "x"}, f.studentToken)
	if resp.StatusCode != 403 {
		t.Fatalf("expected 403, got %d", resp.StatusCode)
	}
	row = lastAuditRow(t, f.db, "POST", "/students/{id}/charges")
	if row.statusCode != 403 || row.errorCode != "forbidden" {
		t.Errorf("forbidden mutation: status=%d err=%q, want 403 forbidden",
			row.statusCode, row.errorCode)
	}
	if row.actorRole != "student" {
		t.Errorf("forbidden mutation: actor_role = %q, want student", row.actorRole)
	}
	if row.targetEntity != "students" || row.targetID != "user_stu" {
		t.Errorf("forbidden mutation: target = %q/%q", row.targetEntity, row.targetID)
	}
}

// Self-signup is the only public mutating route. The handler does its
// own Firebase verification, then publishes the resolved identity into
// the request state so the audit middleware picks it up.
func TestAudit_FirebaseSignupIsLogged(t *testing.T) {
	f := newSignupFixture(t, "open")
	resp, body, _ := f.signupViaFirebase(map[string]any{
		"schoolId":               "school_t",
		"name":                   "Audit Trail Tom",
		"email":                  "audit-tom@test.com",
		"phone":                  "+44 7700 900222",
		"transmissionPreference": "manual",
		"licenceCategoryPursued": "A2",
	})
	if resp.StatusCode != 201 {
		t.Fatalf("signup: %d body=%s", resp.StatusCode, body)
	}
	row := lastAuditRow(t, f.db, "POST", "/auth/firebase-signup")
	if row.statusCode != 201 {
		t.Errorf("signup audit: status = %d, want 201", row.statusCode)
	}
	if row.actorUserID == nil || *row.actorUserID == "" {
		t.Error("signup audit: expected actor_user_id to be set to the new user")
	}
	if row.actorRole != "student" {
		t.Errorf("signup audit: role = %q, want student", row.actorRole)
	}
}

// Handlers that opt into audit.Describe should populate the summary
// column. Take-bike-offline is one of the wired routes — verify the
// human sentence makes it into the row.
func TestAudit_HandlerSummariesAreCaptured(t *testing.T) {
	f := newLedgerFixture(t)

	resp, body := f.do("POST", "/bikes/bike_t/offline", map[string]any{
		"reason": "damaged",
	}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("take offline: %d body=%s", resp.StatusCode, body)
	}
	var summary string
	if err := f.db.QueryRow(`
		SELECT summary FROM audit_log
		WHERE method = 'POST' AND path_pattern = '/bikes/{id}/offline'
		ORDER BY at DESC, rowid DESC LIMIT 1
	`).Scan(&summary); err != nil {
		t.Fatalf("read summary: %v", err)
	}
	if !strings.Contains(summary, "offline") || !strings.Contains(summary, "damaged") {
		t.Errorf("expected human summary mentioning 'offline' and 'damaged', got %q", summary)
	}
}

func TestAudit_GETsAreNotLogged(t *testing.T) {
	f := newLedgerFixture(t)
	// Baseline: how many rows now?
	before := auditRowCount(t, f.db)
	_, _ = f.do("GET", "/bikes", nil, f.adminToken)
	_, _ = f.do("GET", "/locations", nil, f.adminToken)
	after := auditRowCount(t, f.db)
	if after != before {
		t.Errorf("GETs added rows: before=%d after=%d", before, after)
	}
}

// ---------- helpers ----------

type auditRow struct {
	method       string
	pathPattern  string
	actorUserID  *string
	actorRole    string
	actorName    string
	targetEntity string
	targetID     string
	statusCode   int
	errorCode    string
}

func lastAuditRow(t *testing.T, db *sql.DB, method, pattern string) auditRow {
	t.Helper()
	var r auditRow
	var actor sql.NullString
	err := db.QueryRow(`
		SELECT method, path_pattern, actor_user_id, actor_role, actor_name,
		       target_entity, target_id, status_code, error_code
		FROM audit_log
		WHERE method = ? AND path_pattern = ?
		ORDER BY at DESC, rowid DESC
		LIMIT 1
	`, method, pattern).Scan(
		&r.method, &r.pathPattern, &actor, &r.actorRole, &r.actorName,
		&r.targetEntity, &r.targetID, &r.statusCode, &r.errorCode,
	)
	if err != nil {
		t.Fatalf("read audit row for %s %s: %v", method, pattern, err)
	}
	if actor.Valid {
		r.actorUserID = &actor.String
	}
	return r
}

func auditRowCount(t *testing.T, db *sql.DB) int {
	t.Helper()
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM audit_log`).Scan(&n); err != nil {
		t.Fatalf("count audit rows: %v", err)
	}
	return n
}
