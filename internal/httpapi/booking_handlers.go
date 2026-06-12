package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/audit"
	"github.com/michaeljohnwatters/kickstand/internal/booking"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// ----- Browse sessions -----

type sessionListingView struct {
	SessionID          string    `json:"sessionId"`
	CourseTypeID       string    `json:"courseTypeId"`
	CourseCode         string    `json:"courseCode"`
	CourseName         string    `json:"courseName"`
	CourseAccentColour string    `json:"courseAccentColour"`
	NonTeaching        bool      `json:"nonTeaching"`
	InstructorID       string    `json:"instructorId"`
	InstructorName     string    `json:"instructorName"`
	LocationID         string    `json:"locationId"`
	LocationName       string    `json:"locationName"`
	StartsAt           time.Time `json:"startsAt"`
	EndsAt             time.Time `json:"endsAt"`
	Capacity           int       `json:"capacity"`
	HonestCapacity     int       `json:"honestCapacity"`
	SuitableFreeBikes  int       `json:"suitableFreeBikes"`
	PricePence         int64     `json:"pricePence"`
}

func (s *Server) handleListSessions(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)

	from, err := parseTimeParam(r, "from", time.Now())
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_param", "from: "+err.Error())
		return
	}
	to, err := parseTimeParam(r, "to", from.Add(7*24*time.Hour))
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_param", "to: "+err.Error())
		return
	}
	loc := domain.LocationID(r.URL.Query().Get("locationId"))

	listings, err := booking.ListUpcomingSessions(r.Context(), scope, from, to, loc)
	if err != nil {
		writeEngineError(w, err)
		return
	}
	out := make([]sessionListingView, 0, len(listings))
	for _, l := range listings {
		out = append(out, sessionListingView{
			SessionID:          string(l.SessionID),
			CourseTypeID:       string(l.CourseTypeID),
			CourseCode:         l.CourseCode,
			CourseName:         l.CourseName,
			CourseAccentColour: l.CourseAccentColour,
			NonTeaching:        l.NonTeaching,
			InstructorID:       string(l.InstructorID),
			InstructorName:     l.InstructorName,
			LocationID:         string(l.LocationID),
			LocationName:       l.LocationName,
			StartsAt:           l.StartsAt,
			EndsAt:             l.EndsAt,
			Capacity:           l.Capacity,
			HonestCapacity:     l.HonestCapacity,
			SuitableFreeBikes:  l.SuitableFreeBikes,
			PricePence:         l.PricePence,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessions": out})
}

// GET /me/bookings?when=upcoming|past|all
//
// Returns the caller's own bookings (must be a student). Each row carries
// enough denormalised context to render a card without further round-trips.
func (s *Server) handleMyBookings(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role != domain.RoleStudent {
		// Staff use the per-student endpoint instead.
		writeError(w, http.StatusForbidden, "forbidden", "only students may use /me/bookings; staff use /students/{id}/bookings")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	when := r.URL.Query().Get("when")
	rows, err := booking.ListStudentBookings(r.Context(), scope, id.UserID, when, time.Now().UTC())
	if err != nil {
		writeEngineError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(rows))
	for _, b := range rows {
		out = append(out, myBookingView(b))
	}
	writeJSON(w, http.StatusOK, map[string]any{"bookings": out})
}

// GET /students/{id}/bookings — staff variant. Same shape, any student.
func (s *Server) handleStudentBookings(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent && id.UserID != domain.UserID(r.PathValue("id")) {
		writeError(w, http.StatusForbidden, "forbidden", "students may only view their own bookings")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	when := r.URL.Query().Get("when")
	rows, err := booking.ListStudentBookings(r.Context(), scope, domain.UserID(r.PathValue("id")), when, time.Now().UTC())
	if err != nil {
		writeEngineError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(rows))
	for _, b := range rows {
		out = append(out, myBookingView(b))
	}
	writeJSON(w, http.StatusOK, map[string]any{"bookings": out})
}

func myBookingView(b booking.MyBookingRow) map[string]any {
	v := map[string]any{
		"bookingId":      b.BookingID,
		"status":         b.Status,
		"bikeId":         b.BikeID,
		"bikeNickname":   b.BikeNickname,
		"sessionId":      b.SessionID,
		"courseTypeId":   b.CourseTypeID,
		"courseCode":         b.CourseCode,
		"courseName":         b.CourseName,
		"courseAccentColour": b.CourseAccentColour,
		"nonTeaching":        b.NonTeaching,
		"instructorId":   b.InstructorID,
		"instructorName": b.InstructorName,
		"locationId":     b.LocationID,
		"locationName":   b.LocationName,
		"startsAt":       b.StartsAt.Format(time.RFC3339),
		"endsAt":         b.EndsAt.Format(time.RFC3339),
		"pricePence":     b.PricePence,
		"createdAt":      b.CreatedAt.Format(time.RFC3339),
	}
	if !b.CancelledAt.IsZero() {
		v["cancelledAt"] = b.CancelledAt.Format(time.RFC3339)
		v["cancelledBy"] = b.CancelledBy
		v["cancellationReason"] = b.CancellationReason
	}
	return v
}

func parseTimeParam(r *http.Request, key string, fallback time.Time) (time.Time, error) {
	v := r.URL.Query().Get(key)
	if v == "" {
		return fallback, nil
	}
	return time.Parse(time.RFC3339, v)
}

// ----- Create booking -----

type createBookingRequest struct {
	SessionID string `json:"sessionId"`
	StudentID string `json:"studentId"` // optional: defaults to the caller if they're a student
	BikeID    string `json:"bikeId"`    // optional: "" = auto-assign
}

type bookingView struct {
	ID                 string `json:"id"`
	SessionID          string `json:"sessionId"`
	StudentID          string `json:"studentId"`
	BikeID             string `json:"bikeId"`
	Status             string `json:"status"`
	CreatedAt          string `json:"createdAt"`
	CancelledAt        string `json:"cancelledAt,omitempty"`
	CancelledBy        string `json:"cancelledBy,omitempty"`
	CancellationReason string `json:"cancellationReason,omitempty"`
}

type createBookingResponse struct {
	Booking    bookingView         `json:"booking"`
	Advisories []advisoryView      `json:"advisories,omitempty"`
}

type advisoryView struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (s *Server) handleCreateBooking(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)

	var req createBookingRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", "request body must be valid JSON")
		return
	}
	if req.SessionID == "" {
		writeError(w, http.StatusBadRequest, "missing_field", "sessionId is required")
		return
	}

	// Student field is optional for student callers (book for self) and
	// required for instructors/admins booking on behalf of a student.
	studentID := domain.UserID(req.StudentID)
	if studentID == "" {
		if id.Role != domain.RoleStudent {
			writeError(w, http.StatusBadRequest, "missing_field",
				"studentId is required when staff are booking on behalf of a student")
			return
		}
		studentID = id.UserID
	} else if id.Role == domain.RoleStudent && studentID != id.UserID {
		writeError(w, http.StatusForbidden, "forbidden",
			"students may only book for themselves")
		return
	}

	res, err := booking.Book(r.Context(), scope, booking.Request{
		SessionID: domain.SessionID(req.SessionID),
		StudentID: studentID,
		BikeID:    domain.BikeID(req.BikeID),
	})
	if err != nil {
		writeEngineError(w, err)
		return
	}

	audit.Describe(r.Context(),
		"Booked %s",
		sessionDisplayName(r.Context(), s.DB, id.SchoolID,
			domain.SessionID(req.SessionID)))
	resp := createBookingResponse{Booking: toBookingView(res.Booking)}
	for _, a := range res.Advisories {
		resp.Advisories = append(resp.Advisories, advisoryView{Code: a.Code, Message: a.Message})
	}
	writeJSON(w, http.StatusCreated, resp)
}

func toBookingView(b domain.Booking) bookingView {
	v := bookingView{
		ID:                 string(b.ID),
		SessionID:          string(b.SessionID),
		StudentID:          string(b.StudentID),
		BikeID:             string(b.BikeID),
		Status:             string(b.Status),
		CreatedAt:          b.CreatedAt.Format(time.RFC3339),
		CancelledBy:        string(b.CancelledBy),
		CancellationReason: b.CancellationReason,
	}
	if !b.CancelledAt.IsZero() {
		v.CancelledAt = b.CancelledAt.Format(time.RFC3339)
	}
	return v
}

// ----- Cancel booking -----

type cancelBookingRequest struct {
	Reason string `json:"reason"`
}

type cancelBookingResponse struct {
	Booking bookingView `json:"booking"`
	Late    bool        `json:"late"`
}

func (s *Server) handleCancelBooking(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	bookingID := domain.BookingID(r.PathValue("id"))
	if bookingID == "" {
		writeError(w, http.StatusBadRequest, "bad_path", "booking id missing")
		return
	}

	var req cancelBookingRequest
	if r.ContentLength > 0 {
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "bad_json", "request body must be valid JSON")
			return
		}
	}

	cancelledBy := domain.CancelledByStudent
	var expectedStudent domain.UserID
	if id.Role != domain.RoleStudent {
		cancelledBy = domain.CancelledBySchool
	} else {
		expectedStudent = id.UserID
	}

	res, err := booking.Cancel(r.Context(), scope, booking.CancelRequest{
		BookingID:         bookingID,
		CancelledBy:       cancelledBy,
		Reason:            req.Reason,
		ExpectedStudentID: expectedStudent,
	})
	if err != nil {
		writeEngineError(w, err)
		return
	}
	sessionLabel := sessionDisplayName(r.Context(), s.DB, id.SchoolID, res.Booking.SessionID)
	if req.Reason != "" {
		audit.Describe(r.Context(), "Cancelled booking on %s (reason: %s)",
			sessionLabel, req.Reason)
	} else {
		audit.Describe(r.Context(), "Cancelled booking on %s", sessionLabel)
	}
	writeJSON(w, http.StatusOK, cancelBookingResponse{
		Booking: toBookingView(res.Booking),
		Late:    res.Late,
	})
}

// ----- Bulk session cancel -----

type cancelSessionsBatchRequest struct {
	SessionIDs []string `json:"sessionIds"`
	Reason     string   `json:"reason"`
}

type cancelSessionsBatchResult struct {
	SessionID         string `json:"sessionId"`
	BookingsCancelled int    `json:"bookingsCancelled"`
	WaitlistDropped   int    `json:"waitlistDropped"`
	Error             string `json:"error,omitempty"`
}

// POST /sessions/cancel-batch — admin/owner cancels one or more
// sessions in one call. Each session is its own transaction so a
// failure on one doesn't roll back the rest; the per-session result
// surfaces the outcome.
//
// Per session:
//   - Every booked / needs-reassignment booking is cancelled by 'school'
//     with the shared reason; auto-charges void; cancel notifications
//     fire for each affected student.
//   - The waitlist is dropped (no point queuing for a dead session).
//   - The session is marked cancelled.
func (s *Server) handleCancelSessionsBatch(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req cancelSessionsBatchRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	if len(req.SessionIDs) == 0 {
		writeError(w, http.StatusBadRequest, "missing_field",
			"sessionIds must include at least one session")
		return
	}

	results := make([]cancelSessionsBatchResult, 0, len(req.SessionIDs))
	var totalSessions, totalBookings int
	for _, sid := range req.SessionIDs {
		res, err := booking.CancelSession(r.Context(), scope,
			domain.SessionID(sid), req.Reason)
		row := cancelSessionsBatchResult{SessionID: sid}
		switch {
		case err == nil:
			row.BookingsCancelled = res.BookingsCancelled
			row.WaitlistDropped = res.WaitlistDropped
			totalSessions++
			totalBookings += res.BookingsCancelled
		case errors.Is(err, booking.ErrSessionNotFound):
			row.Error = "not_found"
		default:
			row.Error = err.Error()
		}
		results = append(results, row)
	}
	if req.Reason == "" {
		audit.Describe(r.Context(),
			"Cancelled %d session%s — %d booking%s affected",
			totalSessions, plural(totalSessions),
			totalBookings, plural(totalBookings))
	} else {
		audit.Describe(r.Context(),
			"Cancelled %d session%s (reason: %s) — %d booking%s affected",
			totalSessions, plural(totalSessions), req.Reason,
			totalBookings, plural(totalBookings))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"results":            results,
		"sessionsCancelled":  totalSessions,
		"bookingsCancelled":  totalBookings,
	})
}

// ----- Reschedule booking -----

type rescheduleRequest struct {
	NewSessionID string `json:"newSessionId"`
	NewBikeID    string `json:"newBikeId"`
	Reason       string `json:"reason"`
}

type rescheduleResponse struct {
	CancelledBooking bookingView    `json:"cancelledBooking"`
	NewBooking       bookingView    `json:"newBooking"`
	Advisories       []advisoryView `json:"advisories,omitempty"`
	CancelWasLate    bool           `json:"cancelWasLate"`
}

func (s *Server) handleRescheduleBooking(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	bookingID := domain.BookingID(r.PathValue("id"))
	if bookingID == "" {
		writeError(w, http.StatusBadRequest, "bad_path", "booking id missing")
		return
	}

	var req rescheduleRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", "request body must be valid JSON")
		return
	}
	if req.NewSessionID == "" {
		writeError(w, http.StatusBadRequest, "missing_field", "newSessionId is required")
		return
	}

	cancelledBy := domain.CancelledByStudent
	var expectedStudent domain.UserID
	if id.Role != domain.RoleStudent {
		cancelledBy = domain.CancelledBySchool
	} else {
		expectedStudent = id.UserID
	}

	res, err := booking.Reschedule(r.Context(), scope, booking.RescheduleRequest{
		BookingID:         bookingID,
		NewSessionID:      domain.SessionID(req.NewSessionID),
		NewBikeID:         domain.BikeID(req.NewBikeID),
		CancelledBy:       cancelledBy,
		Reason:            req.Reason,
		ExpectedStudentID: expectedStudent,
	})
	if err != nil {
		writeEngineError(w, err)
		return
	}
	resp := rescheduleResponse{
		CancelledBooking: toBookingView(res.CancelledBooking),
		NewBooking:       toBookingView(res.NewBooking),
		CancelWasLate:    res.CancelWasLate,
	}
	for _, a := range res.Advisories {
		resp.Advisories = append(resp.Advisories, advisoryView{Code: a.Code, Message: a.Message})
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleSuitableBikes returns the bikes the engine considers valid candidates
// for the given session. Used by the student booking flow's bike-picker
// step. When the caller is a student we look up their transmission
// preference; otherwise we return the unfiltered list (staff exploring).
func (s *Server) handleSuitableBikes(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	sessionID := domain.SessionID(r.PathValue("id"))
	if sessionID == "" {
		writeError(w, http.StatusBadRequest, "bad_path", "session id missing")
		return
	}
	// For non-students we pass no studentID so transmission isn't filtered.
	var studentID domain.UserID
	if id.Role == domain.RoleStudent {
		studentID = id.UserID
	}
	bikes, err := booking.SuitableBikesForSession(r.Context(), scope, sessionID, studentID)
	if err != nil {
		writeEngineError(w, err)
		return
	}
	rows := make([]map[string]any, 0, len(bikes))
	for _, b := range bikes {
		rows = append(rows, map[string]any{
			"bikeId":              b.BikeID,
			"nickname":            b.Nickname,
			"registration":        b.Registration,
			"category":            b.Category,
			"transmission":        b.Transmission,
			"engineCc":            b.EngineCC,
			"currentLocationId":   b.CurrentLocationID,
			"currentLocationName": b.CurrentLocationName,
			"isCrossSite":         b.IsCrossSite,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"bikes": rows})
}

// POST /bookings/{id}/assign-bike — standalone bike swap for the
// master calendar's edit sheet. Reuses the same engine validation as
// the disruption-resolve flow (`findSuitableFreeBikes`) but without
// the disruption bookkeeping; a manager picking a better bike for a
// healthy booking just rewrites the bike_id in place. Admin/owner.
func (s *Server) handleAssignBookingBike(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	bookingID := domain.BookingID(r.PathValue("id"))
	if bookingID == "" {
		writeError(w, http.StatusBadRequest, "bad_path", "booking id missing")
		return
	}
	var req struct {
		BikeID string `json:"bikeId"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", "request body must be valid JSON")
		return
	}
	if req.BikeID == "" {
		writeError(w, http.StatusBadRequest, "missing_field", "bikeId is required")
		return
	}
	err := booking.AssignBike(r.Context(), scope, booking.AssignBikeRequest{
		BookingID: bookingID,
		NewBikeID: domain.BikeID(req.BikeID),
	})
	if err != nil {
		switch {
		case errors.Is(err, booking.ErrBookingNotFound):
			writeError(w, http.StatusNotFound, "not_found", "booking not found")
		case errors.Is(err, booking.ErrSwapBikeNotSuitable):
			writeError(w, http.StatusConflict, "bike_not_suitable",
				"this bike doesn't fit the session (category, transmission or already in use)")
		default:
			writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		}
		return
	}
	audit.Describe(r.Context(), "Reassigned a booking's bike")
	w.WriteHeader(http.StatusNoContent)
}
