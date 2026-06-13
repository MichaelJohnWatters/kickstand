// Package httpapi is the HTTP-transport seam over the engine packages.
//
// Design choices:
//   - Uses stdlib net/http with Go 1.22+ pattern routing (no chi/gorilla).
//     The router complexity here is genuinely small; adding a router lib
//     would cost a dependency and a learning surface for not much gain.
//   - Bearer-token auth: clients send `Authorization: Bearer <token>`
//     containing a Firebase ID token. The auth middleware verifies it
//     via the Admin SDK and stores the resolved Identity in request
//     context.
//   - Error responses are JSON: {"error": "<code>", "message": "<human>"}.
//     Codes are stable; messages may be tweaked. The known engine errors
//     have explicit code mappings (see errors.go).
//   - The full route list is declared by `routeTable()` and mounted in a
//     single loop, so adding a new endpoint means adding one row. The
//     `Public` flag on each row is what TestAuth_AllProtectedRoutes
//     uses to verify every authenticated route rejects missing tokens
//     and forged tokens — see auth_coverage_test.go.
package httpapi

import (
	"database/sql"
	"net/http"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/filestore"
)

// Server holds the dependencies handlers need. Keep this struct flat — it's
// the dependency-injection surface for handlers.
type Server struct {
	DB       *sql.DB
	Files    filestore.Store      // receipt blobs (and any future file types)
	Firebase *auth.FirebaseClient // nil when running without Firebase Auth (tests, legacy `make run` target).
}

func NewServer(d *sql.DB, files filestore.Store, fb *auth.FirebaseClient) *Server {
	return &Server{DB: d, Files: files, Firebase: fb}
}

// RoutePattern describes a single route mount-point. Exported so tests
// can enumerate the full route table and assert authentication coverage.
type RoutePattern struct {
	Method  string
	Pattern string
	Public  bool // true if no auth middleware is applied
}

// routeSpec is the internal form — same as RoutePattern but with the
// actual handler attached.
type routeSpec struct {
	method  string
	pattern string
	public  bool
	handler http.HandlerFunc
}

// RouteTable returns the (method, pattern, public) triples for every
// route the server mounts. Used by auth-coverage tests to enumerate
// every authenticated route and verify it rejects missing/forged
// tokens.
func (s *Server) RouteTable() []RoutePattern {
	specs := s.routeTable()
	out := make([]RoutePattern, len(specs))
	for i, sp := range specs {
		out[i] = RoutePattern{Method: sp.method, Pattern: sp.pattern, Public: sp.public}
	}
	return out
}

func (s *Server) routeTable() []routeSpec {
	return []routeSpec{
		// Public — identity is owned by Firebase, so the only auth-adjacent
		// endpoint we expose is "create the local profile for an already-
		// authenticated Firebase user".
		{"POST", "/auth/firebase-signup", true, s.handleFirebaseSignup},
		{"GET", "/schools", true, s.handleListSchools},
		{"GET", "/health", true, healthCheck},

		// Identity + sessions
		{"GET", "/me", false, s.handleMe},
		{"GET", "/sessions", false, s.handleListSessions},
		{"GET", "/sessions/{id}/suitable-bikes", false, s.handleSuitableBikes},

		// Sessions — ad-hoc create + instructor assignment + drag-to-move
		{"POST", "/sessions", false, s.handleCreateSession},
		{"PATCH", "/sessions/{id}", false, s.handleUpdateSession},
		{"PUT", "/sessions/{id}/instructors", false, s.handleSetSessionInstructors},

		// Bookings
		{"POST", "/bookings", false, s.handleCreateBooking},
		{"DELETE", "/bookings/{id}", false, s.handleCancelBooking},
		{"POST", "/bookings/{id}/reschedule", false, s.handleRescheduleBooking},
		{"POST", "/bookings/{id}/assign-bike", false, s.handleAssignBookingBike},
		{"GET", "/me/bookings", false, s.handleMyBookings},
		{"GET", "/me/student-profile", false, s.handleMyStudentProfile},
		{"GET", "/students/{id}/bookings", false, s.handleStudentBookings},
		{"GET", "/students", false, s.handleListStudents},
		{"POST", "/students", false, s.handleCreateStudent},

		// Audit log — admin/owner read-only view of the mutation history.
		{"GET", "/audit", false, s.handleListAudit},

		// GDPR / privacy — Article 20 (data portability) + Article 17
		// (right to erasure). Anyone can download their own data;
		// admins/owners trigger anonymisation of another user.
		{"GET", "/me/data-export", false, s.handleMyDataExport},
		{"POST", "/admin/users/{id}/anonymise", false, s.handleAnonymiseUser},

		// Compliance dashboard — bike docs, instructor accreditation, school insurance.
		// Per-course accreditation expiries are managed on the Instructors
		// page via PUT /instructors/{id}/accreditations.
		{"GET", "/compliance", false, s.handleGetCompliance},
		{"PUT", "/school/insurance", false, s.handleSetInsurance},

		// Revenue overview — monthly buckets, ageing, per-course breakdown.
		{"GET", "/revenue", false, s.handleGetRevenue},

		// School closures — block session-creating flows on these dates.
		{"GET", "/closures", false, s.handleListClosures},
		{"POST", "/closures", false, s.handleCreateClosure},
		{"DELETE", "/closures/{id}", false, s.handleDeleteClosure},

		// Bulk session cancellation — manager's rainy-day workflow.
		{"POST", "/sessions/cancel-batch", false, s.handleCancelSessionsBatch},

		// Waitlist — students opt into full sessions; cancels auto-promote.
		{"POST", "/sessions/{id}/waitlist", false, s.handleJoinWaitlist},
		{"DELETE", "/sessions/{id}/waitlist", false, s.handleLeaveWaitlist},
		{"GET", "/sessions/{id}/waitlist", false, s.handleListWaitlist},
		{"DELETE", "/sessions/{id}/waitlist/{entryId}", false, s.handleRemoveWaitlistEntry},
		{"GET", "/me/waitlist", false, s.handleMyWaitlist},

		// Session templates — recurring schedule recipes that materialise sessions.
		{"GET", "/session-templates", false, s.handleListTemplates},
		{"POST", "/session-templates", false, s.handleCreateTemplate},
		{"DELETE", "/session-templates/{id}", false, s.handleDeleteTemplate},
		{"POST", "/session-templates/materialise", false, s.handleMaterialiseTemplates},
		{"POST", "/session-templates/{id}/materialise", false, s.handleMaterialiseOneTemplate},
		{"GET", "/session-templates/{id}/preview", false, s.handlePreviewTemplate},
		{"GET", "/session-templates/materialisations", false, s.handleListMaterialisations},
		{"POST", "/session-templates/materialisations/{id}/undo", false, s.handleUndoMaterialisation},

		// Ledger
		{"GET", "/students/{id}/ledger", false, s.handleGetLedger},
		{"POST", "/students/{id}/charges", false, s.handleCreateCharge},
		{"DELETE", "/charges/{chargeId}", false, s.handleVoidCharge},
		{"POST", "/students/{id}/payments", false, s.handleCreatePayment},
		{"DELETE", "/payments/{paymentId}", false, s.handleVoidPayment},

		// Signup admin approval queue
		{"GET", "/signups/pending", false, s.handleListPendingSignups},
		{"GET", "/signups/rejected", false, s.handleListRejectedSignups},
		{"GET", "/signups/approved", false, s.handleListApprovedSignups},
		{"POST", "/signups/{id}/approve", false, s.handleApproveSignup},
		{"POST", "/signups/{id}/reject", false, s.handleRejectSignup},
		{"POST", "/signups/{id}/restore", false, s.handleRestoreSignup},

		// Admin CRUD — sites + travel matrix
		{"GET", "/locations", false, s.handleListLocations},
		{"POST", "/locations", false, s.handleCreateLocation},
		{"PUT", "/locations/{id}", false, s.handleUpdateLocation},
		{"DELETE", "/locations/{id}", false, s.handleDeleteLocation},
		{"GET", "/travel-times", false, s.handleListTravelTimes},
		{"PUT", "/travel-times", false, s.handleSetTravelTime},
		{"DELETE", "/travel-times/{from}/{to}", false, s.handleDeleteTravelTime},

		// Admin CRUD — fleet
		{"GET", "/bikes", false, s.handleListBikes},
		{"POST", "/bikes", false, s.handleCreateBike},
		{"PUT", "/bikes/{id}", false, s.handleUpdateBike},
		{"POST", "/bikes/{id}/restore", false, s.handleRestoreBike},
		{"POST", "/bikes/{id}/move", false, s.handleMoveBike},
		{"POST", "/bikes/{id}/mileage", false, s.handleRecordBikeMileage},
		{"POST", "/bikes/{id}/gps", false, s.handleUpdateBikeGPS},
		{"GET", "/admin/bikes/gps", false, s.handleListBikeGPS},
		{"GET", "/bikes/{id}/gps/history", false, s.handleListBikeGPSHistory},
		{"GET", "/admin/analytics/bike-utilisation", false, s.handleAnalyticsBikeUtilisation},
		{"GET", "/admin/analytics/instructor-utilisation", false, s.handleAnalyticsInstructorUtilisation},
		{"GET", "/admin/analytics/funnel", false, s.handleAnalyticsFunnel},
		{"DELETE", "/bikes/{id}", false, s.handleDeleteBike},

		// Admin CRUD — catalog
		{"GET", "/course-types", false, s.handleListCourseTypes},
		{"POST", "/course-types", false, s.handleCreateCourseType},
		{"PUT", "/course-types/{id}", false, s.handleUpdateCourseType},
		{"DELETE", "/course-types/{id}", false, s.handleDeleteCourseType},
		{"GET", "/course-types/{id}/competencies", false, s.handleListCompetencies},
		{"POST", "/course-types/{id}/competencies", false, s.handleCreateCompetency},
		{"DELETE", "/competencies/{compId}", false, s.handleDeleteCompetency},

		// Admin CRUD — staff
		{"GET", "/instructors", false, s.handleListInstructors},
		{"POST", "/instructors", false, s.handleInviteInstructor},
		{"PUT", "/instructors/{id}/accreditations", false, s.handleSetAccreditations},

		// Availability
		{"GET", "/instructors/{id}/availability", false, s.handleListRecurringAvailability},
		{"POST", "/instructors/{id}/availability", false, s.handleCreateRecurringAvailability},
		{"DELETE", "/availability/{slotId}", false, s.handleDeleteRecurringAvailability},
		{"GET", "/instructors/{id}/time-off", false, s.handleListTimeOff},
		{"POST", "/instructors/{id}/time-off", false, s.handleAddTimeOff},
		{"DELETE", "/time-off/{timeOffId}", false, s.handleDeleteTimeOff},

		// Records — incidents, notes, external tests
		{"POST", "/incidents", false, s.handleLogIncident},
		{"GET", "/students/{id}/incidents", false, s.handleListStudentIncidents},
		{"GET", "/followups", false, s.handleListOpenFollowups},
		{"GET", "/incidents/{id}/followups", false, s.handleListIncidentFollowups},
		{"POST", "/followups/{id}/done", false, s.handleCompleteFollowup},
		{"POST", "/followups/{id}/reopen", false, s.handleReopenFollowup},
		{"GET", "/students/{id}/notes", false, s.handleListStudentNotes},
		{"POST", "/students/{id}/notes", false, s.handleAddStudentNote},
		{"DELETE", "/notes/{noteId}", false, s.handleDeactivateNote},
		{"GET", "/students/{id}/tests", false, s.handleListExternalTests},
		{"POST", "/students/{id}/tests", false, s.handleRecordExternalTest},
		{"PATCH", "/tests/{testId}", false, s.handleUpdateExternalTestOutcome},

		// Student detail aggregate (manager-only big view)
		{"GET", "/students/{id}", false, s.handleGetStudentDetail},

		// Progress capture (instructor + admin)
		{"POST", "/bookings/{id}/attendance", false, s.handleMarkAttendance},
		{"PUT", "/bookings/{id}/competencies/{compId}", false, s.handleAssessCompetency},
		{"PUT", "/bookings/{id}/notes", false, s.handleSetBookingNotes},
		{"GET", "/sessions/{id}/detail", false, s.handleGetSessionDetail},
		{"GET", "/students/{id}/progress", false, s.handleGetStudentProgress},

		// Notifications (in-app bell)
		{"GET", "/me/notifications", false, s.handleListMyNotifications},
		{"POST", "/me/notifications/{id}/read", false, s.handleMarkNotificationRead},
		{"POST", "/me/notifications/read-all", false, s.handleMarkAllNotificationsRead},
		{"GET", "/me/notification-prefs", false, s.handleGetNotificationPrefs},
		{"PUT", "/me/notification-prefs", false, s.handlePutNotificationPrefs},
		{"POST", "/me/device-tokens", false, s.handleRegisterDeviceToken},
		{"DELETE", "/me/device-tokens/{token}", false, s.handleUnregisterDeviceToken},

		// Master calendar (staff)
		{"GET", "/calendar", false, s.handleCalendar},

		// Logistics summary (admin)
		{"GET", "/logistics", false, s.handleLogistics},

		// School settings
		{"GET", "/school", false, s.handleGetSchoolSettings},
		{"PATCH", "/school", false, s.handleUpdateSchoolSettings},

		// Disruption (bike down)
		{"POST", "/bikes/{id}/offline", false, s.handleTakeBikeOffline},
		{"GET", "/disruptions", false, s.handleListDisruptions},
		{"POST", "/disruptions/{disruptionId}/bookings/{bookingId}/resolve", false, s.handleResolveDisruption},
		{"POST", "/disruptions/dismiss-past", false, s.handleDismissPastDisruptions},

		// Instructor pay
		{"GET", "/instructor-pay/outstanding", false, s.handleListOutstanding},
		{"GET", "/instructors/{id}/pay-model", false, s.handleGetPayModel},
		{"PUT", "/instructors/{id}/pay-model", false, s.handleSetPayModel},
		{"POST", "/instructors/{id}/earnings", false, s.handleCreateEarning},
		{"DELETE", "/earnings/{earningId}", false, s.handleVoidEarning},
		{"POST", "/instructors/{id}/payments", false, s.handleCreateInstructorPayment},

		// Reimbursements
		{"GET", "/expense-categories", false, s.handleListExpenseCategories},
		{"PUT", "/expense-categories", false, s.handleUpsertExpenseCategories},
		{"POST", "/me/expenses", false, s.handleSubmitExpense},
		{"GET", "/me/expenses", false, s.handleListMyExpenses},
		{"DELETE", "/me/expenses/{id}", false, s.handleWithdrawExpense},
		{"GET", "/expenses", false, s.handleListExpensesForReview},
		{"GET", "/expenses/{id}", false, s.handleGetExpense},
		{"GET", "/expenses/{id}/receipt", false, s.handleGetExpenseReceipt},
		{"POST", "/expenses/{id}/approve", false, s.handleApproveExpense},
		{"POST", "/expenses/{id}/reject", false, s.handleRejectExpense},
		{"POST", "/expenses/{id}/reimburse", false, s.handleReimburseExpense},

		// Bike maintenance log (per-bike capex with receipts).
		{"GET", "/bikes/{id}/expenses", false, s.handleListBikeExpenses},
		{"POST", "/bikes/{id}/expenses", false, s.handleRecordBikeExpense},
		{"GET", "/bike-expenses/{id}/receipt", false, s.handleGetBikeExpenseReceipt},
		{"DELETE", "/bike-expenses/{id}", false, s.handleDeleteBikeExpense},
	}
}

// Routes returns the mounted handler. Call from main:
//
//	http.ListenAndServe(":8765", server.Routes())
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	authMW := s.authMiddleware
	for _, r := range s.routeTable() {
		h := http.Handler(r.handler)
		if !r.public {
			h = authMW(h)
		}
		mux.Handle(r.method+" "+r.pattern, h)
	}
	// Cross-cutting: CORS → log → recover, all wrapping the mux. Order matters:
	// CORS must be outermost so preflights short-circuit before logging.
	return withCORS(withRecover(s.withLog(mux)))
}

func healthCheck(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"ok":true}`))
}
