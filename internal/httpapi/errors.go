package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/booking"
	"github.com/michaeljohnwatters/kickstand/internal/expenses"
)

// errorBody is the wire shape for every error response.
type errorBody struct {
	Error   string `json:"error"`
	Message string `json:"message"`
}

// writeJSON serialises v to the response, defaulting Content-Type.
// Errors during encoding are dropped — by then the headers are sent and
// there's nothing useful to surface.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, errorBody{Error: code, Message: message})
}

// writeEngineError maps a known engine/auth error to an HTTP status + code.
// Falls back to 500 for unrecognised errors — those are real bugs and we
// want them noisy in logs (logged by the recover middleware).
func writeEngineError(w http.ResponseWriter, err error) {
	switch {
	// Auth
	case errors.Is(err, auth.ErrAccountDisabled):
		writeError(w, http.StatusForbidden, "account_disabled", err.Error())
	case errors.Is(err, auth.ErrSessionInvalid):
		writeError(w, http.StatusUnauthorized, "session_invalid", err.Error())
	case errors.Is(err, auth.ErrProfileMissing):
		writeError(w, http.StatusUnauthorized, "no_profile", err.Error())

	// Booking — distinguish "user error" (4xx) from "not allowed in this state" (409).
	case errors.Is(err, booking.ErrSessionNotFound),
		errors.Is(err, booking.ErrStudentNotFound),
		errors.Is(err, booking.ErrBookingNotFound):
		writeError(w, http.StatusNotFound, "not_found", err.Error())

	case errors.Is(err, booking.ErrSessionInPast),
		errors.Is(err, booking.ErrSessionNotBookable),
		errors.Is(err, booking.ErrBookingNotCancellable):
		writeError(w, http.StatusConflict, "not_bookable", err.Error())

	case errors.Is(err, booking.ErrStudentNotActive):
		writeError(w, http.StatusForbidden, "student_not_active", err.Error())

	case errors.Is(err, booking.ErrAlreadyBooked):
		writeError(w, http.StatusConflict, "already_booked", err.Error())

	case errors.Is(err, booking.ErrCapacityFull):
		writeError(w, http.StatusConflict, "capacity_full", err.Error())

	case errors.Is(err, booking.ErrNoSuitableBike):
		writeError(w, http.StatusConflict, "no_suitable_bike", err.Error())

	case errors.Is(err, booking.ErrBikeNotSuitable),
		errors.Is(err, booking.ErrSwapBikeNotSuitable):
		writeError(w, http.StatusConflict, "bike_not_suitable", err.Error())

	case errors.Is(err, booking.ErrInstructorUnqualified):
		writeError(w, http.StatusConflict, "instructor_unqualified", err.Error())

	case errors.Is(err, booking.ErrNoInstructorAssigned):
		writeError(w, http.StatusConflict, "no_instructor_assigned", err.Error())

	// Expenses
	case errors.Is(err, expenses.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, expenses.ErrUnknownCategory):
		writeError(w, http.StatusBadRequest, "unknown_category", err.Error())
	case errors.Is(err, expenses.ErrAmountRequired):
		writeError(w, http.StatusBadRequest, "amount_required", err.Error())
	case errors.Is(err, expenses.ErrReceiptRequired):
		writeError(w, http.StatusBadRequest, "receipt_required", err.Error())
	case errors.Is(err, expenses.ErrReviewerNoteEmpty):
		writeError(w, http.StatusBadRequest, "reason_required", err.Error())
	case errors.Is(err, expenses.ErrInvalidStatus):
		writeError(w, http.StatusConflict, "invalid_status", err.Error())
	case errors.Is(err, expenses.ErrNotMyExpense):
		writeError(w, http.StatusForbidden, "not_my_expense", err.Error())

	default:
		// Unknown internal error.
		writeError(w, http.StatusInternalServerError, "internal_error", "an internal error occurred")
	}
}
