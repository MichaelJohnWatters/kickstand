package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/instructorpay"
	"github.com/michaeljohnwatters/kickstand/internal/ledger"
	"github.com/michaeljohnwatters/kickstand/internal/progress"
	"github.com/michaeljohnwatters/kickstand/internal/records"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// Records endpoints are staff-only. The student-detail aggregate is the
// manager-only "big view" from plan §10b.

func writeRecordsError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, records.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, records.ErrInvalidInput):
		writeError(w, http.StatusBadRequest, "invalid_input", err.Error())
	case errors.Is(err, records.ErrInvalidKind):
		writeError(w, http.StatusBadRequest, "invalid_kind", err.Error())
	default:
		writeError(w, http.StatusInternalServerError, "internal_error", "internal error")
	}
}

// ----- Incidents -----

func (s *Server) handleLogIncident(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		BikeID          string `json:"bikeId"`
		StudentID       string `json:"studentId"`
		BookingID       string `json:"bookingId"`
		OccurredAt      string `json:"occurredAt"`
		Description     string `json:"description"`
		TakeBikeOffline bool   `json:"takeBikeOffline"`
		OfflineReason   string `json:"offlineReason"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	occurred := time.Time{}
	if req.OccurredAt != "" {
		t, err := time.Parse(time.RFC3339, req.OccurredAt)
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_param", "occurredAt: "+err.Error())
			return
		}
		occurred = t
	}
	inc, err := records.LogIncident(r.Context(), scope, records.LogIncidentRequest{
		BikeID: domain.BikeID(req.BikeID), StudentID: domain.UserID(req.StudentID),
		BookingID: domain.BookingID(req.BookingID), OccurredAt: occurred,
		Description: req.Description, TakeBikeOffline: req.TakeBikeOffline,
		OfflineReason: req.OfflineReason, CreatedBy: id.UserID,
	})
	if err != nil {
		writeRecordsError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, incidentView(inc))
}

func (s *Server) handleListStudentIncidents(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	out, err := records.ListIncidents(r.Context(), scope, domain.UserID(r.PathValue("id")))
	if err != nil {
		writeRecordsError(w, err)
		return
	}
	rows := make([]map[string]any, 0, len(out))
	for _, x := range out {
		rows = append(rows, incidentView(&x))
	}
	writeJSON(w, http.StatusOK, map[string]any{"incidents": rows})
}

func incidentView(i *records.Incident) map[string]any {
	v := map[string]any{
		"id":              i.ID,
		"description":     i.Description,
		"occurredAt":      i.OccurredAt.Format(time.RFC3339),
		"createdAt":       i.CreatedAt.Format(time.RFC3339),
		"createdBy":       i.CreatedBy,
		"tookBikeOffline": i.TookBikeOffline,
	}
	if i.BikeID != "" {
		v["bikeId"] = i.BikeID
	}
	if i.StudentID != "" {
		v["studentId"] = i.StudentID
	}
	if i.BookingID != "" {
		v["bookingId"] = i.BookingID
	}
	return v
}

// ----- Student notes -----

func (s *Server) handleListStudentNotes(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		// Notes are staff-visible only — never leak to the student themselves.
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	kind := r.URL.Query().Get("kind")
	out, err := records.ListNotes(r.Context(), scope, domain.UserID(r.PathValue("id")), kind)
	if err != nil {
		writeRecordsError(w, err)
		return
	}
	rows := make([]map[string]any, 0, len(out))
	for _, n := range out {
		rows = append(rows, noteView(n))
	}
	writeJSON(w, http.StatusOK, map[string]any{"notes": rows})
}

func (s *Server) handleAddStudentNote(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		Kind string `json:"kind"`
		Body string `json:"body"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	n, err := records.AddNote(r.Context(), scope, records.AddNoteRequest{
		StudentID: domain.UserID(r.PathValue("id")),
		Kind:      req.Kind,
		Body:      req.Body,
		CreatedBy: id.UserID,
	})
	if err != nil {
		writeRecordsError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, noteView(*n))
}

func (s *Server) handleDeactivateNote(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	if err := records.DeactivateNote(r.Context(), scope, domain.StudentNoteID(r.PathValue("noteId"))); err != nil {
		writeRecordsError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func noteView(n records.StudentNote) map[string]any {
	return map[string]any{
		"id":        n.ID,
		"studentId": n.StudentID,
		"kind":      n.Kind,
		"body":      n.Body,
		"isActive":  n.IsActive,
		"createdAt": n.CreatedAt.Format(time.RFC3339),
		"createdBy": n.CreatedBy,
	}
}

// ----- External tests -----

func (s *Server) handleListExternalTests(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	studentID := domain.UserID(r.PathValue("id"))
	// Students can see their own test history; staff can see anyone's.
	if id.Role == domain.RoleStudent && id.UserID != studentID {
		writeError(w, http.StatusForbidden, "forbidden", "students may only view their own tests")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	out, err := records.ListExternalTests(r.Context(), scope, studentID)
	if err != nil {
		writeRecordsError(w, err)
		return
	}
	rows := make([]map[string]any, 0, len(out))
	for _, t := range out {
		rows = append(rows, externalTestView(t))
	}
	writeJSON(w, http.StatusOK, map[string]any{"tests": rows})
}

func (s *Server) handleRecordExternalTest(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !isStaff(id.Role) {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		TestType    string `json:"testType"`
		Region      string `json:"region"`
		ScheduledAt string `json:"scheduledAt"`
		Reference   string `json:"reference"`
		Outcome     string `json:"outcome"`
		Notes       string `json:"notes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	var sched time.Time
	if req.ScheduledAt != "" {
		t, err := time.Parse(time.RFC3339, req.ScheduledAt)
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_param", "scheduledAt: "+err.Error())
			return
		}
		sched = t
	}
	t, err := records.RecordExternalTest(r.Context(), scope, records.RecordExternalTestRequest{
		StudentID:   domain.UserID(r.PathValue("id")),
		TestType:    req.TestType,
		Region:      domain.Region(req.Region),
		ScheduledAt: sched,
		Reference:   req.Reference,
		Outcome:     req.Outcome,
		Notes:       req.Notes,
	})
	if err != nil {
		writeRecordsError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, externalTestView(*t))
}

func (s *Server) handleUpdateExternalTestOutcome(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !isStaff(id.Role) {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		Outcome string `json:"outcome"`
		Notes   string `json:"notes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	if err := records.UpdateOutcome(r.Context(), scope, domain.ExternalTestID(r.PathValue("testId")), req.Outcome, req.Notes); err != nil {
		writeRecordsError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func externalTestView(t records.ExternalTest) map[string]any {
	v := map[string]any{
		"id":            t.ID,
		"studentId":     t.StudentID,
		"testType":      t.TestType,
		"region":        t.Region,
		"attemptNumber": t.AttemptNumber,
		"reference":     t.Reference,
		"outcome":       t.Outcome,
		"notes":         t.Notes,
		"createdAt":     t.CreatedAt.Format(time.RFC3339),
	}
	if !t.ScheduledAt.IsZero() {
		v["scheduledAt"] = t.ScheduledAt.Format(time.RFC3339)
	}
	return v
}

// ----- Student detail aggregate -----

// GET /students/{id} — the manager-only big-view that combines:
//   - basics (name, contact, status)
//   - financial summary (balance + last N entries)
//   - test history (region-aware)
//   - safety flags + progress notes (staff-only)
//   - incidents
//   - progress per course
//
// Staff-only. Students seeking their own profile use /me + /students/{id}/progress
// + /students/{id}/ledger which carry the appropriate filters.
func (s *Server) handleGetStudentDetail(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	studentID := domain.UserID(r.PathValue("id"))

	// Basics
	const userQ = `
		SELECT u.id, u.name, u.email, COALESCE(u.phone, ''), u.account_status,
		       COALESCE(u.anonymised_at, ''),
		       COALESCE(sp.transmission_preference, ''),
		       COALESCE(sp.licence_category_pursued, ''),
		       COALESCE(sp.rider_date_of_birth, ''),
		       COALESCE(sp.cbt_certificate_held, 0),
		       COALESCE(sp.cbt_variant, ''),
		       COALESCE(sp.cbt_expires_on, ''),
		       COALESCE(sp.theory_passed, 0),
		       COALESCE(sp.theory_passed_on, '')
		FROM users u
		LEFT JOIN student_profiles sp ON sp.user_id = u.id AND sp.school_id = u.school_id
		WHERE u.id = ? AND u.school_id = ? AND u.role = 'student'
	`
	var (
		userID, name, email, phone, status, anonymisedAt, transmission, lic, dob string
		cbtHeld, theoryPassed                                                     int
		cbtVariant, cbtExpires, theoryOn                                          string
	)
	err := s.DB.QueryRowContext(r.Context(), userQ, string(studentID), string(scope.SchoolID())).Scan(
		&userID, &name, &email, &phone, &status, &anonymisedAt,
		&transmission, &lic, &dob,
		&cbtHeld, &cbtVariant, &cbtExpires, &theoryPassed, &theoryOn,
	)
	if err != nil {
		writeError(w, http.StatusNotFound, "not_found", "student not found")
		return
	}

	// Financial
	bal, err := ledger.GetStudentBalance(r.Context(), scope, studentID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "balance: "+err.Error())
		return
	}
	entries, err := ledger.GetStudentLedger(r.Context(), scope, studentID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "ledger: "+err.Error())
		return
	}

	// Tests, notes, incidents, progress
	tests, _ := records.ListExternalTests(r.Context(), scope, studentID)
	flags, _ := records.ListNotes(r.Context(), scope, studentID, records.NoteSafetyFlag)
	notes, _ := records.ListNotes(r.Context(), scope, studentID, records.NoteProgressNote)
	incidents, _ := records.ListIncidents(r.Context(), scope, studentID)
	prog, _ := progress.GetStudentProgress(r.Context(), scope, studentID)

	// Helper renders
	ledgerOut := make([]map[string]any, 0, len(entries))
	for _, e := range entries {
		ledgerOut = append(ledgerOut, map[string]any{
			"kind": e.Kind, "id": e.ID, "amountPence": e.AmountPence,
			"description": e.Description, "method": e.Method,
			"at":         e.At.Format(time.RFC3339),
			"recordedBy": e.RecordedBy, "voided": e.Voided,
		})
	}
	testsOut := make([]map[string]any, 0, len(tests))
	for _, t := range tests {
		testsOut = append(testsOut, externalTestView(t))
	}
	flagsOut := make([]map[string]any, 0, len(flags))
	for _, n := range flags {
		flagsOut = append(flagsOut, noteView(n))
	}
	notesOut := make([]map[string]any, 0, len(notes))
	for _, n := range notes {
		notesOut = append(notesOut, noteView(n))
	}
	incidentsOut := make([]map[string]any, 0, len(incidents))
	for _, i := range incidents {
		incidentsOut = append(incidentsOut, incidentView(&i))
	}
	progOut := make([]map[string]any, 0)
	if prog != nil {
		for _, c := range prog.Courses {
			comps := make([]map[string]any, 0, len(c.Competencies))
			for _, cc := range c.Competencies {
				v := map[string]any{
					"competencyId": cc.CompetencyID,
					"label":        cc.Label,
					"status":       cc.Status,
				}
				if !cc.LastSeen.IsZero() {
					v["lastSeen"] = cc.LastSeen.Format(time.RFC3339)
				}
				comps = append(comps, v)
			}
			progOut = append(progOut, map[string]any{
				"courseTypeId":      c.CourseTypeID,
				"courseName":        c.CourseName,
				"totalCompetencies": c.TotalCompetencies,
				"competentCount":    c.CompetentCount,
				"needsWorkCount":    c.NeedsWorkCount,
				"competencies":      comps,
			})
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"basics": map[string]any{
			"id":                     userID,
			"name":                   name,
			"email":                  email,
			"phone":                  phone,
			"accountStatus":          status,
			"anonymisedAt":           anonymisedAt,
			"transmissionPreference": transmission,
			"licenceCategoryPursued": lic,
			"dateOfBirth":            dob,
			"cbtHeld":                cbtHeld == 1,
			"cbtVariant":             cbtVariant,
			"cbtExpiresOn":           cbtExpires,
			"theoryPassed":           theoryPassed == 1,
			"theoryPassedOn":         theoryOn,
		},
		"financial": map[string]any{
			"totalChargedPence": bal.TotalCharged,
			"totalPaidPence":    bal.TotalPaid,
			"balancePence":      bal.Balance,
			"ledger":            ledgerOut,
		},
		"tests":       testsOut,
		"safetyFlags": flagsOut,
		"notes":       notesOut,
		"incidents":   incidentsOut,
		"progress":    progOut,
	})
}

// GET /followups — staff cross-school list of open follow-ups +
// open/overdue counts. One round-trip powers both the /admin/incidents
// list and the Overview "Needs attention" badge.
func (s *Server) handleListOpenFollowups(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	rows, err := records.ListOpenFollowups(r.Context(), scope)
	if err != nil {
		writeRecordsError(w, err)
		return
	}
	counts, err := records.CountOpenFollowups(r.Context(), scope)
	if err != nil {
		writeRecordsError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(rows))
	for _, ro := range rows {
		out = append(out, map[string]any{
			"id":                  ro.ID,
			"incidentId":          ro.IncidentID,
			"kind":                ro.Kind,
			"description":         ro.Description,
			"dueOn":               ro.DueOn,
			"notes":               ro.Notes,
			"incidentOccurredAt":  ro.IncidentOccurredAt,
			"incidentDescription": ro.IncidentDescription,
			"studentId":           ro.StudentID,
			"studentName":         ro.StudentName,
			"bikeId":              ro.BikeID,
			"bikeLabel":           ro.BikeLabel,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"followups": out,
		"counts": map[string]any{
			"open":    counts.Open,
			"overdue": counts.Overdue,
		},
	})
}

// GET /incidents/{id}/followups — staff list of follow-up actions.
func (s *Server) handleListIncidentFollowups(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	out, err := records.ListFollowups(r.Context(), scope,
		domain.IncidentID(r.PathValue("id")))
	if err != nil {
		writeRecordsError(w, err)
		return
	}
	rows := make([]map[string]any, 0, len(out))
	for _, f := range out {
		row := map[string]any{
			"id":          f.ID,
			"incidentId":  f.IncidentID,
			"kind":        f.Kind,
			"description": f.Description,
			"dueOn":       f.DueOn,
			"notes":       f.Notes,
			"done":        f.IsDone(),
		}
		if f.IsDone() {
			row["doneAt"] = f.DoneAt
			row["doneBy"] = f.DoneBy
		}
		rows = append(rows, row)
	}
	writeJSON(w, http.StatusOK, map[string]any{"followups": rows})
}

// POST /followups/{id}/done — staff mark a follow-up as handled.
// Optional `notes` body field captures what was done.
func (s *Server) handleCompleteFollowup(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		Notes string `json:"notes"`
	}
	if r.ContentLength > 0 {
		_ = json.NewDecoder(r.Body).Decode(&req)
	}
	if err := records.MarkFollowupDone(r.Context(), scope,
		r.PathValue("id"), id.UserID, req.Notes); err != nil {
		writeRecordsError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// POST /followups/{id}/reopen — undo a "done" mark.
func (s *Server) handleReopenFollowup(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	if err := records.ReopenFollowup(r.Context(), scope, r.PathValue("id")); err != nil {
		writeRecordsError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// Keep the instructorpay import live (used by the aggregate's neighbours in
// other files); silences the unused-import false-positive if you trim
// references during refactors.
var _ = instructorpay.AllOutstanding
