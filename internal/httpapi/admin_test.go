package httpapi_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

// All admin endpoints share the same fixture: admin token, student token,
// seeded school/location/instructor/course/bike already in place from
// newLedgerFixture. Reuse it.

// ----- Locations & travel matrix -----

func TestAdmin_LocationsCRUD(t *testing.T) {
	f := newLedgerFixture(t)

	// List (should include the seeded location)
	resp, body := f.do("GET", "/locations", nil, f.adminToken)
	if resp.StatusCode != 200 || !strings.Contains(string(body), "Belfast") {
		t.Fatalf("list: %d body=%s", resp.StatusCode, body)
	}

	// Create
	resp, body = f.do("POST", "/locations",
		map[string]any{"name": "Newry", "address": "5 Main St"}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("create: %d body=%s", resp.StatusCode, body)
	}
	var loc struct{ ID string }
	json.Unmarshal(body, &loc)

	// Update
	resp, _ = f.do("PUT", "/locations/"+loc.ID,
		map[string]any{"name": "Newry Renamed"}, f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("update: %d", resp.StatusCode)
	}

	// Delete
	resp, _ = f.do("DELETE", "/locations/"+loc.ID, nil, f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("delete: %d", resp.StatusCode)
	}
}

func TestAdmin_DeleteLocation_RefusesWhenInUse(t *testing.T) {
	f := newLedgerFixture(t)
	// seed Belfast 'loc_t' is referenced by bikes + sessions → delete should fail
	resp, body := f.do("DELETE", "/locations/loc_t", nil, f.adminToken)
	if resp.StatusCode != 409 || !strings.Contains(string(body), "in_use") {
		t.Errorf("expected 409 in_use, got %d body=%s", resp.StatusCode, body)
	}
}

func TestAdmin_StudentCannotCreateLocation(t *testing.T) {
	f := newLedgerFixture(t)
	resp, _ := f.do("POST", "/locations",
		map[string]any{"name": "Sneaky"}, f.studentToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403, got %d", resp.StatusCode)
	}
}

func TestAdmin_TravelTimes_Upsert(t *testing.T) {
	f := newLedgerFixture(t)
	// Create a second location to pair with.
	resp, body := f.do("POST", "/locations", map[string]any{"name": "Lisburn"}, f.adminToken)
	var loc struct{ ID string }
	json.Unmarshal(body, &loc)

	// Set
	resp, _ = f.do("PUT", "/travel-times",
		map[string]any{"fromLocationId": "loc_t", "toLocationId": loc.ID, "minutes": 25},
		f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("set: %d", resp.StatusCode)
	}
	// List shows it
	resp, body = f.do("GET", "/travel-times", nil, f.adminToken)
	if !strings.Contains(string(body), `"minutes":25`) {
		t.Errorf("expected 25 min, got %s", body)
	}
	// Update (upsert)
	resp, _ = f.do("PUT", "/travel-times",
		map[string]any{"fromLocationId": "loc_t", "toLocationId": loc.ID, "minutes": 30},
		f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("update: %d", resp.StatusCode)
	}
	resp, body = f.do("GET", "/travel-times", nil, f.adminToken)
	if !strings.Contains(string(body), `"minutes":30`) {
		t.Errorf("expected updated to 30 min, got %s", body)
	}
}

// ----- Bikes -----

func TestAdmin_Bikes_CreateUpdateRestoreDelete(t *testing.T) {
	f := newLedgerFixture(t)

	// Create
	resp, body := f.do("POST", "/bikes", map[string]any{
		"nickname": "Blue Honda", "make": "Honda", "model": "CB125",
		"registration": "AB12 CDE",
		"category": "A1", "transmission": "manual", "engineCc": 125,
		"homeLocationId": "loc_t",
	}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("create: %d body=%s", resp.StatusCode, body)
	}
	var b struct {
		ID     string `json:"id"`
		Status string `json:"status"`
	}
	json.Unmarshal(body, &b)
	if b.Status != "ready" {
		t.Errorf("expected ready, got %s", b.Status)
	}

	// Update
	resp, _ = f.do("PUT", "/bikes/"+b.ID, map[string]any{
		"nickname": "Blue Honda v2", "homeLocationId": "loc_t", "engineCc": 125,
	}, f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("update: %d", resp.StatusCode)
	}

	// Take offline → restore → delete
	resp, _ = f.do("POST", "/bikes/"+b.ID+"/offline",
		map[string]any{"reason": "broken"}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Errorf("offline: %d", resp.StatusCode)
	}
	resp, _ = f.do("POST", "/bikes/"+b.ID+"/restore", nil, f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("restore: %d", resp.StatusCode)
	}
	resp, _ = f.do("DELETE", "/bikes/"+b.ID, nil, f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("delete: %d", resp.StatusCode)
	}
}

func TestAdmin_DeleteBike_RefusesWhenUsed(t *testing.T) {
	f := newLedgerFixture(t)
	// Book a student so bike_t has a booking
	stu := f.loginStudent()
	resp, _ := f.do("POST", "/bookings", map[string]string{"sessionId": "sess_t"}, stu)
	if resp.StatusCode != 201 {
		t.Fatal("seed booking")
	}
	resp, body := f.do("DELETE", "/bikes/bike_t", nil, f.adminToken)
	if resp.StatusCode != 409 || !strings.Contains(string(body), "in_use") {
		t.Errorf("expected 409 in_use, got %d body=%s", resp.StatusCode, body)
	}
}

// ----- Course types -----

func TestAdmin_CourseTypes_CreateListDelete(t *testing.T) {
	f := newLedgerFixture(t)

	// Create
	resp, body := f.do("POST", "/course-types", map[string]any{
		"code": "TEST-COURSE", "name": "Test Course", "region": "NI",
		"requiredBikeCategory": "A1",
		"durationMinutes":      120, "maxRatio": 2, "pricePence": 8000,
		"nonTeaching":          false,
		"prerequisites":        []string{"cbt_held"},
	}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("create: %d body=%s", resp.StatusCode, body)
	}
	var c struct {
		ID            string   `json:"id"`
		Prerequisites []string `json:"prerequisites"`
	}
	json.Unmarshal(body, &c)
	if len(c.Prerequisites) != 1 || c.Prerequisites[0] != "cbt_held" {
		t.Errorf("expected cbt_held prereq, got %v", c.Prerequisites)
	}

	// List
	resp, body = f.do("GET", "/course-types", nil, f.adminToken)
	if !strings.Contains(string(body), "TEST-COURSE") {
		t.Errorf("expected new course in list, got %s", body)
	}

	// Delete
	resp, _ = f.do("DELETE", "/course-types/"+c.ID, nil, f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("delete: %d", resp.StatusCode)
	}
}

func TestAdmin_CourseType_RejectsInvalidPrereq(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("POST", "/course-types", map[string]any{
		"code": "X", "name": "X", "region": "NI", "requiredBikeCategory": "A1",
		"durationMinutes": 60, "maxRatio": 1,
		"prerequisites":   []string{"breathe_fire"},
	}, f.adminToken)
	if resp.StatusCode != 400 || !strings.Contains(string(body), "invalid_input") {
		t.Errorf("expected 400 invalid_input, got %d body=%s", resp.StatusCode, body)
	}
}

func TestAdmin_CourseType_DuplicateCodeConflict(t *testing.T) {
	f := newLedgerFixture(t)
	payload := map[string]any{
		"code": "DUPE-CODE", "name": "Dupe", "region": "NI", "requiredBikeCategory": "A1",
		"durationMinutes": 60, "maxRatio": 1,
	}
	if resp, _ := f.do("POST", "/course-types", payload, f.adminToken); resp.StatusCode != 201 {
		t.Fatal("first")
	}
	resp, body := f.do("POST", "/course-types", payload, f.adminToken)
	if resp.StatusCode != 409 || !strings.Contains(string(body), "conflict") {
		t.Errorf("expected 409 conflict, got %d body=%s", resp.StatusCode, body)
	}
}

// ----- Competencies -----

func TestAdmin_Competencies_CRUD(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("POST", "/course-types/ct_cbt/competencies",
		map[string]any{"label": "U-turn", "sortOrder": 1}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("create: %d body=%s", resp.StatusCode, body)
	}
	var c struct{ ID string }
	json.Unmarshal(body, &c)

	resp, body = f.do("GET", "/course-types/ct_cbt/competencies", nil, f.adminToken)
	if !strings.Contains(string(body), "U-turn") {
		t.Errorf("expected U-turn in list, got %s", body)
	}

	resp, _ = f.do("DELETE", "/competencies/"+c.ID, nil, f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("delete: %d", resp.StatusCode)
	}
}

// ----- Instructors -----

func TestAdmin_InviteInstructor_AndSetAccreditations(t *testing.T) {
	f := newLedgerFixture(t)

	resp, body := f.do("POST", "/instructors", map[string]any{
		"name": "Priya P", "email": "priya@test.com", "phone": "07700900000",
		"password": "longenoughpw", "homeLocationId": "loc_t",
		"accreditations": []map[string]any{
			{"courseTypeId": "ct_cbt", "expiresOn": "2027-01-01"},
		},
	}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("invite: %d body=%s", resp.StatusCode, body)
	}
	var i struct {
		UserID         string `json:"userId"`
		Accreditations []struct {
			CourseTypeID string `json:"courseTypeId"`
			ExpiresOn    string `json:"expiresOn"`
		} `json:"accreditations"`
	}
	json.Unmarshal(body, &i)
	if len(i.Accreditations) != 1 {
		t.Errorf("expected 1 accreditation, got %d", len(i.Accreditations))
	} else if i.Accreditations[0].ExpiresOn != "2027-01-01" {
		t.Errorf("expected expiresOn 2027-01-01, got %q", i.Accreditations[0].ExpiresOn)
	}

	// InviteInstructor should have created a Firebase user with UID
	// pinned to the local user_id, and stored that UID on the row.
	var firebaseUID string
	if err := f.db.QueryRow(`SELECT COALESCE(firebase_uid, '') FROM users WHERE id = ?`, i.UserID).
		Scan(&firebaseUID); err != nil {
		t.Fatalf("read firebase_uid: %v", err)
	}
	if firebaseUID == "" {
		t.Error("expected firebase_uid to be set on invited instructor")
	}
	if firebaseUID != i.UserID {
		t.Errorf("expected firebase_uid to equal user_id (UID pinning), got %q vs %q", firebaseUID, i.UserID)
	}
	if _, err := f.fb.Auth.GetUser(context.Background(), firebaseUID); err != nil {
		t.Errorf("Firebase user not found: %v", err)
	}
	t.Cleanup(func() { _ = f.fb.Auth.DeleteUser(context.Background(), firebaseUID) })

	// Duplicate-email invite — Firebase rejects and our handler maps it
	// to a 409 with the right code.
	resp, body = f.do("POST", "/instructors", map[string]any{
		"name": "Priya Twin", "email": "priya@test.com",
		"password": "longenoughpw", "homeLocationId": "loc_t",
	}, f.adminToken)
	if resp.StatusCode != 409 {
		t.Errorf("expected 409 duplicate, got %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), "email_in_use") {
		t.Errorf("expected email_in_use code, got %s", body)
	}

	// Clear accreditations
	resp, _ = f.do("PUT", "/instructors/"+i.UserID+"/accreditations",
		map[string]any{"accreditations": []map[string]any{}}, f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("clear accreditations: %d", resp.StatusCode)
	}

	// List
	resp, body = f.do("GET", "/instructors", nil, f.adminToken)
	if !strings.Contains(string(body), "Priya P") {
		t.Errorf("expected Priya in list, got %s", body)
	}
}

// ----- Students -----

func TestAdmin_CreateStudent(t *testing.T) {
	f := newLedgerFixture(t)

	resp, body := f.do("POST", "/students", map[string]any{
		"name": "Rowan New", "email": "rowan-new@test.com",
		"phone": "07700900111", "password": "longenoughpw",
	}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("create: %d body=%s", resp.StatusCode, body)
	}
	var st struct {
		ID            string `json:"id"`
		Stage         string `json:"stage"`
		AccountStatus string `json:"accountStatus"`
		BalancePence  int    `json:"balancePence"`
	}
	if err := json.Unmarshal(body, &st); err != nil {
		t.Fatalf("decode: %v body=%s", err, body)
	}
	if st.Stage != "Pre-CBT" || st.AccountStatus != "active" || st.BalancePence != 0 {
		t.Errorf("unexpected initial row: %+v", st)
	}

	// Firebase identity should exist and be pinned to the local user_id.
	var firebaseUID string
	if err := f.db.QueryRow(`SELECT COALESCE(firebase_uid, '') FROM users WHERE id = ?`, st.ID).
		Scan(&firebaseUID); err != nil {
		t.Fatalf("read firebase_uid: %v", err)
	}
	if firebaseUID != st.ID {
		t.Errorf("expected firebase_uid == user_id, got %q vs %q", firebaseUID, st.ID)
	}
	if _, err := f.fb.Auth.GetUser(context.Background(), firebaseUID); err != nil {
		t.Errorf("Firebase user not found: %v", err)
	}
	t.Cleanup(func() { _ = f.fb.Auth.DeleteUser(context.Background(), firebaseUID) })

	// New student must show up in GET /students.
	resp, body = f.do("GET", "/students", nil, f.adminToken)
	if resp.StatusCode != 200 || !strings.Contains(string(body), "Rowan New") {
		t.Errorf("expected Rowan in list, got %d body=%s", resp.StatusCode, body)
	}

	// Duplicate-email — Firebase rejects, handler returns 409.
	resp, body = f.do("POST", "/students", map[string]any{
		"name": "Rowan Twin", "email": "rowan-new@test.com",
		"password": "longenoughpw",
	}, f.adminToken)
	if resp.StatusCode != 409 || !strings.Contains(string(body), "email_in_use") {
		t.Errorf("expected 409 email_in_use, got %d body=%s", resp.StatusCode, body)
	}

	// Short password rejected before we hit Firebase.
	resp, _ = f.do("POST", "/students", map[string]any{
		"name": "Short Pw", "email": "shortpw@test.com", "password": "abc",
	}, f.adminToken)
	if resp.StatusCode != 400 {
		t.Errorf("expected 400 for short password, got %d", resp.StatusCode)
	}
}

// ----- School settings -----

func TestAdmin_SchoolSettings_GetAndPatch(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("GET", "/school", nil, f.adminToken)
	if resp.StatusCode != 200 || !strings.Contains(string(body), "Test School") {
		t.Fatalf("get: %d body=%s", resp.StatusCode, body)
	}

	// Patch a couple of fields
	resp, _ = f.do("PATCH", "/school", map[string]any{
		"onboardingMode": "approval", "cancelCutoffHours": 24,
	}, f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("patch: %d", resp.StatusCode)
	}

	resp, body = f.do("GET", "/school", nil, f.adminToken)
	if !strings.Contains(string(body), `"onboardingMode":"approval"`) {
		t.Errorf("expected approval mode, got %s", body)
	}
	if !strings.Contains(string(body), `"cancelCutoffHours":24`) {
		t.Errorf("expected 24h cutoff, got %s", body)
	}
}

func TestAdmin_SchoolSettings_RejectsInvalidOnboardingMode(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("PATCH", "/school",
		map[string]any{"onboardingMode": "invitation_only"}, f.adminToken)
	if resp.StatusCode != 400 || !strings.Contains(string(body), "invalid_input") {
		t.Errorf("expected 400 invalid_input, got %d body=%s", resp.StatusCode, body)
	}
}
