// Package httpapi is the HTTP-transport seam over the engine packages.
//
// Design choices:
//   - Uses stdlib net/http with Go 1.22+ pattern routing (no chi/gorilla).
//     The router complexity here is genuinely small; adding a router lib
//     would cost a dependency and a learning surface for not much gain.
//   - Bearer-token auth: clients send `Authorization: Bearer <token>` from
//     a /auth/login response. Auth middleware resolves it to an Identity
//     and stores it in the request context.
//   - Error responses are JSON: {"error": "<code>", "message": "<human>"}.
//     Codes are stable; messages may be tweaked. The known engine errors
//     have explicit code mappings (see errors.go).
package httpapi

import (
	"database/sql"
	"net/http"

	"github.com/michaeljohnwatters/kickstand/internal/filestore"
)

// Server holds the dependencies handlers need. Keep this struct flat — it's
// the dependency-injection surface for handlers.
type Server struct {
	DB    *sql.DB
	Files filestore.Store // receipt blobs (and any future file types)
}

func NewServer(d *sql.DB, files filestore.Store) *Server {
	return &Server{DB: d, Files: files}
}

// Routes returns the mounted handler. Call from main:
//
//	http.ListenAndServe(":8765", server.Routes())
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()

	// Public (no auth)
	mux.HandleFunc("POST /auth/login", s.handleLogin)
	mux.HandleFunc("POST /auth/signup", s.handleSignup)
	mux.HandleFunc("GET /schools", s.handleListSchools)
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"ok":true}`))
	})

	// Authenticated
	auth := s.authMiddleware
	mux.Handle("POST /auth/logout", auth(http.HandlerFunc(s.handleLogout)))
	mux.Handle("GET /me", auth(http.HandlerFunc(s.handleMe)))
	mux.Handle("GET /sessions", auth(http.HandlerFunc(s.handleListSessions)))
	mux.Handle("GET /sessions/{id}/suitable-bikes", auth(http.HandlerFunc(s.handleSuitableBikes)))
	mux.Handle("POST /bookings", auth(http.HandlerFunc(s.handleCreateBooking)))
	mux.Handle("DELETE /bookings/{id}", auth(http.HandlerFunc(s.handleCancelBooking)))
	mux.Handle("POST /bookings/{id}/reschedule", auth(http.HandlerFunc(s.handleRescheduleBooking)))
	mux.Handle("GET /me/bookings", auth(http.HandlerFunc(s.handleMyBookings)))
	mux.Handle("GET /me/student-profile", auth(http.HandlerFunc(s.handleMyStudentProfile)))
	mux.Handle("GET /students/{id}/bookings", auth(http.HandlerFunc(s.handleStudentBookings)))
	mux.Handle("GET /students", auth(http.HandlerFunc(s.handleListStudents)))

	// Ledger
	mux.Handle("GET /students/{id}/ledger", auth(http.HandlerFunc(s.handleGetLedger)))
	mux.Handle("POST /students/{id}/charges", auth(http.HandlerFunc(s.handleCreateCharge)))
	mux.Handle("DELETE /charges/{chargeId}", auth(http.HandlerFunc(s.handleVoidCharge)))
	mux.Handle("POST /students/{id}/payments", auth(http.HandlerFunc(s.handleCreatePayment)))
	mux.Handle("DELETE /payments/{paymentId}", auth(http.HandlerFunc(s.handleVoidPayment)))

	// Signup admin approval queue
	mux.Handle("GET /signups/pending", auth(http.HandlerFunc(s.handleListPendingSignups)))
	mux.Handle("POST /signups/{id}/approve", auth(http.HandlerFunc(s.handleApproveSignup)))
	mux.Handle("POST /signups/{id}/reject", auth(http.HandlerFunc(s.handleRejectSignup)))

	// Admin CRUD — sites + travel matrix
	mux.Handle("GET /locations", auth(http.HandlerFunc(s.handleListLocations)))
	mux.Handle("POST /locations", auth(http.HandlerFunc(s.handleCreateLocation)))
	mux.Handle("PUT /locations/{id}", auth(http.HandlerFunc(s.handleUpdateLocation)))
	mux.Handle("DELETE /locations/{id}", auth(http.HandlerFunc(s.handleDeleteLocation)))
	mux.Handle("GET /travel-times", auth(http.HandlerFunc(s.handleListTravelTimes)))
	mux.Handle("PUT /travel-times", auth(http.HandlerFunc(s.handleSetTravelTime)))
	mux.Handle("DELETE /travel-times/{from}/{to}", auth(http.HandlerFunc(s.handleDeleteTravelTime)))

	// Admin CRUD — fleet
	mux.Handle("GET /bikes", auth(http.HandlerFunc(s.handleListBikes)))
	mux.Handle("POST /bikes", auth(http.HandlerFunc(s.handleCreateBike)))
	mux.Handle("PUT /bikes/{id}", auth(http.HandlerFunc(s.handleUpdateBike)))
	mux.Handle("POST /bikes/{id}/restore", auth(http.HandlerFunc(s.handleRestoreBike)))
	mux.Handle("POST /bikes/{id}/move", auth(http.HandlerFunc(s.handleMoveBike)))
	mux.Handle("DELETE /bikes/{id}", auth(http.HandlerFunc(s.handleDeleteBike)))

	// Admin CRUD — catalog
	mux.Handle("GET /course-types", auth(http.HandlerFunc(s.handleListCourseTypes)))
	mux.Handle("POST /course-types", auth(http.HandlerFunc(s.handleCreateCourseType)))
	mux.Handle("PUT /course-types/{id}", auth(http.HandlerFunc(s.handleUpdateCourseType)))
	mux.Handle("DELETE /course-types/{id}", auth(http.HandlerFunc(s.handleDeleteCourseType)))
	mux.Handle("GET /course-types/{id}/competencies", auth(http.HandlerFunc(s.handleListCompetencies)))
	mux.Handle("POST /course-types/{id}/competencies", auth(http.HandlerFunc(s.handleCreateCompetency)))
	mux.Handle("DELETE /competencies/{compId}", auth(http.HandlerFunc(s.handleDeleteCompetency)))

	// Admin CRUD — staff
	mux.Handle("GET /instructors", auth(http.HandlerFunc(s.handleListInstructors)))
	mux.Handle("POST /instructors", auth(http.HandlerFunc(s.handleInviteInstructor)))
	mux.Handle("PUT /instructors/{id}/qualifications", auth(http.HandlerFunc(s.handleSetQualifications)))

	// Availability
	mux.Handle("GET /instructors/{id}/availability", auth(http.HandlerFunc(s.handleListRecurringAvailability)))
	mux.Handle("POST /instructors/{id}/availability", auth(http.HandlerFunc(s.handleCreateRecurringAvailability)))
	mux.Handle("DELETE /availability/{slotId}", auth(http.HandlerFunc(s.handleDeleteRecurringAvailability)))
	mux.Handle("GET /instructors/{id}/time-off", auth(http.HandlerFunc(s.handleListTimeOff)))
	mux.Handle("POST /instructors/{id}/time-off", auth(http.HandlerFunc(s.handleAddTimeOff)))
	mux.Handle("DELETE /time-off/{timeOffId}", auth(http.HandlerFunc(s.handleDeleteTimeOff)))

	// Records — incidents, notes, external tests (staff-only)
	mux.Handle("POST /incidents", auth(http.HandlerFunc(s.handleLogIncident)))
	mux.Handle("GET /students/{id}/incidents", auth(http.HandlerFunc(s.handleListStudentIncidents)))
	mux.Handle("GET /students/{id}/notes", auth(http.HandlerFunc(s.handleListStudentNotes)))
	mux.Handle("POST /students/{id}/notes", auth(http.HandlerFunc(s.handleAddStudentNote)))
	mux.Handle("DELETE /notes/{noteId}", auth(http.HandlerFunc(s.handleDeactivateNote)))
	mux.Handle("GET /students/{id}/tests", auth(http.HandlerFunc(s.handleListExternalTests)))
	mux.Handle("POST /students/{id}/tests", auth(http.HandlerFunc(s.handleRecordExternalTest)))
	mux.Handle("PATCH /tests/{testId}", auth(http.HandlerFunc(s.handleUpdateExternalTestOutcome)))

	// Student detail aggregate (manager-only big view)
	mux.Handle("GET /students/{id}", auth(http.HandlerFunc(s.handleGetStudentDetail)))

	// Progress capture (instructor + admin)
	mux.Handle("POST /bookings/{id}/attendance", auth(http.HandlerFunc(s.handleMarkAttendance)))
	mux.Handle("PUT /bookings/{id}/competencies/{compId}", auth(http.HandlerFunc(s.handleAssessCompetency)))
	mux.Handle("PUT /bookings/{id}/notes", auth(http.HandlerFunc(s.handleSetBookingNotes)))
	mux.Handle("GET /sessions/{id}/detail", auth(http.HandlerFunc(s.handleGetSessionDetail)))
	mux.Handle("GET /students/{id}/progress", auth(http.HandlerFunc(s.handleGetStudentProgress)))

	// Notifications (in-app bell)
	mux.Handle("GET /me/notifications", auth(http.HandlerFunc(s.handleListMyNotifications)))
	mux.Handle("POST /me/notifications/{id}/read", auth(http.HandlerFunc(s.handleMarkNotificationRead)))
	mux.Handle("POST /me/notifications/read-all", auth(http.HandlerFunc(s.handleMarkAllNotificationsRead)))
	mux.Handle("POST /me/device-tokens", auth(http.HandlerFunc(s.handleRegisterDeviceToken)))
	mux.Handle("DELETE /me/device-tokens/{token}", auth(http.HandlerFunc(s.handleUnregisterDeviceToken)))

	// Master calendar (staff)
	mux.Handle("GET /calendar", auth(http.HandlerFunc(s.handleCalendar)))

	// Logistics summary (admin)
	mux.Handle("GET /logistics", auth(http.HandlerFunc(s.handleLogistics)))

	// Admin CRUD — school settings
	mux.Handle("GET /school", auth(http.HandlerFunc(s.handleGetSchoolSettings)))
	mux.Handle("PATCH /school", auth(http.HandlerFunc(s.handleUpdateSchoolSettings)))

	// Disruption (bike down)
	mux.Handle("POST /bikes/{id}/offline", auth(http.HandlerFunc(s.handleTakeBikeOffline)))
	mux.Handle("GET /disruptions", auth(http.HandlerFunc(s.handleListDisruptions)))
	mux.Handle("POST /disruptions/{disruptionId}/bookings/{bookingId}/resolve",
		auth(http.HandlerFunc(s.handleResolveDisruption)))

	// Instructor pay (owed-tracking, admin-only)
	mux.Handle("GET /instructor-pay/outstanding", auth(http.HandlerFunc(s.handleListOutstanding)))
	mux.Handle("GET /instructors/{id}/pay-model", auth(http.HandlerFunc(s.handleGetPayModel)))
	mux.Handle("PUT /instructors/{id}/pay-model", auth(http.HandlerFunc(s.handleSetPayModel)))
	mux.Handle("POST /instructors/{id}/earnings", auth(http.HandlerFunc(s.handleCreateEarning)))
	mux.Handle("DELETE /earnings/{earningId}", auth(http.HandlerFunc(s.handleVoidEarning)))
	mux.Handle("POST /instructors/{id}/payments", auth(http.HandlerFunc(s.handleCreateInstructorPayment)))

	// Reimbursements — instructor self-serve + admin review
	mux.Handle("GET /expense-categories", auth(http.HandlerFunc(s.handleListExpenseCategories)))
	mux.Handle("PUT /expense-categories", auth(http.HandlerFunc(s.handleUpsertExpenseCategories)))
	mux.Handle("POST /me/expenses", auth(http.HandlerFunc(s.handleSubmitExpense)))
	mux.Handle("GET /me/expenses", auth(http.HandlerFunc(s.handleListMyExpenses)))
	mux.Handle("DELETE /me/expenses/{id}", auth(http.HandlerFunc(s.handleWithdrawExpense)))
	mux.Handle("GET /expenses", auth(http.HandlerFunc(s.handleListExpensesForReview)))
	mux.Handle("GET /expenses/{id}", auth(http.HandlerFunc(s.handleGetExpense)))
	mux.Handle("GET /expenses/{id}/receipt", auth(http.HandlerFunc(s.handleGetExpenseReceipt)))
	mux.Handle("POST /expenses/{id}/approve", auth(http.HandlerFunc(s.handleApproveExpense)))
	mux.Handle("POST /expenses/{id}/reject", auth(http.HandlerFunc(s.handleRejectExpense)))
	mux.Handle("POST /expenses/{id}/reimburse", auth(http.HandlerFunc(s.handleReimburseExpense)))

	// Cross-cutting: CORS → log → recover, all wrapping the mux. Order matters:
	// CORS must be outermost so preflights short-circuit before logging.
	return withCORS(withRecover(withLog(mux)))
}
