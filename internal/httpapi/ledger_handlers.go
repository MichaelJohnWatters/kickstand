package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/ledger"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// Permissions, per plan §3 "Payment ledger":
//   - Recording a payment: admin OR (instructor when school setting allows)
//   - Adjusting/voiding a payment: admin-only
//   - Creating/editing/voiding a charge: admin-only
//
// Students can read their own ledger; admins/instructors can read any
// student's ledger in their school.

func (s *Server) handleCreateCharge(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !isStaff(id.Role) || id.Role == domain.RoleInstructor {
		writeError(w, http.StatusForbidden, "forbidden", "only admin/owner can create charges")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	studentID := domain.UserID(r.PathValue("id"))

	var req struct {
		BookingID   string `json:"bookingId"`
		AmountPence int64  `json:"amountPence"`
		Description string `json:"description"`
		IncurredAt  string `json:"incurredAt"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	incurredAt := time.Now()
	if req.IncurredAt != "" {
		t, err := time.Parse(time.RFC3339, req.IncurredAt)
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_param", "incurredAt: "+err.Error())
			return
		}
		incurredAt = t
	}

	c, err := ledger.RecordCharge(r.Context(), scope, ledger.RecordChargeRequest{
		StudentID:   studentID,
		BookingID:   domain.BookingID(req.BookingID),
		AmountPence: domain.Money(req.AmountPence),
		Description: req.Description,
		IncurredAt:  incurredAt,
		CreatedBy:   id.UserID,
	})
	if err != nil {
		writeLedgerError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, chargeView(*c))
}

func (s *Server) handleVoidCharge(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !isStaff(id.Role) || id.Role == domain.RoleInstructor {
		writeError(w, http.StatusForbidden, "forbidden", "only admin/owner can void charges")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	chargeID := domain.ChargeID(r.PathValue("chargeId"))

	var body struct {
		Reason string `json:"reason"`
	}
	if r.ContentLength > 0 {
		_ = json.NewDecoder(r.Body).Decode(&body)
	}

	err := ledger.VoidCharge(r.Context(), scope, ledger.VoidChargeRequest{
		ChargeID: chargeID,
		VoidedBy: id.UserID,
		Reason:   body.Reason,
	})
	if err != nil {
		writeLedgerError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleCreatePayment(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !canRecordPayment(s, id) {
		writeError(w, http.StatusForbidden, "forbidden",
			"you don't have permission to record payments")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	studentID := domain.UserID(r.PathValue("id"))

	var req struct {
		AmountPence int64  `json:"amountPence"`
		Method      string `json:"method"`
		ReceivedAt  string `json:"receivedAt"`
		Notes       string `json:"notes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	receivedAt := time.Now()
	if req.ReceivedAt != "" {
		t, err := time.Parse(time.RFC3339, req.ReceivedAt)
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_param", "receivedAt: "+err.Error())
			return
		}
		receivedAt = t
	}

	res, err := ledger.RecordPayment(r.Context(), scope, ledger.RecordPaymentRequest{
		StudentID:   studentID,
		AmountPence: domain.Money(req.AmountPence),
		Method:      domain.PaymentMethod(req.Method),
		ReceivedAt:  receivedAt,
		RecordedBy:  id.UserID,
		Notes:       req.Notes,
	})
	if err != nil {
		writeLedgerError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"payment":    paymentView(res.Payment),
		"newBalance": res.NewBalance,
	})
}

func (s *Server) handleVoidPayment(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !isStaff(id.Role) || id.Role == domain.RoleInstructor {
		writeError(w, http.StatusForbidden, "forbidden", "only admin/owner can void payments")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	paymentID := domain.PaymentID(r.PathValue("paymentId"))

	var body struct {
		Reason string `json:"reason"`
	}
	if r.ContentLength > 0 {
		_ = json.NewDecoder(r.Body).Decode(&body)
	}

	err := ledger.VoidPayment(r.Context(), scope, ledger.VoidPaymentRequest{
		PaymentID: paymentID,
		VoidedBy:  id.UserID,
		Reason:    body.Reason,
	})
	if err != nil {
		writeLedgerError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleGetLedger(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	studentID := domain.UserID(r.PathValue("id"))
	// Students can only read their own ledger.
	if id.Role == domain.RoleStudent && id.UserID != studentID {
		writeError(w, http.StatusForbidden, "forbidden", "students may only view their own ledger")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)

	bal, err := ledger.GetStudentBalance(r.Context(), scope, studentID)
	if err != nil {
		writeLedgerError(w, err)
		return
	}
	entries, err := ledger.GetStudentLedger(r.Context(), scope, studentID)
	if err != nil {
		writeLedgerError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(entries))
	for _, e := range entries {
		out = append(out, map[string]any{
			"kind":        e.Kind,
			"id":          e.ID,
			"amountPence": e.AmountPence,
			"description": e.Description,
			"method":      e.Method,
			"at":          e.At.Format(time.RFC3339),
			"recordedBy":  e.RecordedBy,
			"voided":      e.Voided,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"balance": map[string]any{
			"totalChargedPence": bal.TotalCharged,
			"totalPaidPence":    bal.TotalPaid,
			"balancePence":      bal.Balance,
		},
		"entries": out,
	})
}

// ----- helpers -----

func isStaff(r domain.Role) bool {
	switch r {
	case domain.RoleAdmin, domain.RoleOwner, domain.RoleInstructor:
		return true
	}
	return false
}

// canRecordPayment is admin/owner always, plus instructors when the
// school's `instructors_can_record_payments` toggle is on. Per plan §3.
func canRecordPayment(s *Server, id *auth.Identity) bool {
	switch id.Role {
	case domain.RoleAdmin, domain.RoleOwner:
		return true
	case domain.RoleInstructor:
		var allowed int
		err := s.DB.QueryRow(
			`SELECT instructors_can_record_payments FROM schools WHERE id = ?`,
			string(id.SchoolID),
		).Scan(&allowed)
		if err != nil {
			return false
		}
		return allowed == 1
	}
	return false
}

func chargeView(c domain.Charge) map[string]any {
	v := map[string]any{
		"id":          c.ID,
		"studentId":   c.StudentID,
		"amountPence": c.AmountPence,
		"description": c.Description,
		"incurredAt":  c.IncurredAt.Format(time.RFC3339),
		"createdAt":   c.CreatedAt.Format(time.RFC3339),
		"createdBy":   c.CreatedBy,
	}
	if c.BookingID != "" {
		v["bookingId"] = c.BookingID
	}
	return v
}

func paymentView(p domain.Payment) map[string]any {
	return map[string]any{
		"id":          p.ID,
		"studentId":   p.StudentID,
		"amountPence": p.AmountPence,
		"method":      p.Method,
		"receivedAt":  p.ReceivedAt.Format(time.RFC3339),
		"recordedBy":  p.RecordedBy,
		"notes":       p.Notes,
	}
}

func writeLedgerError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ledger.ErrStudentNotFound):
		writeError(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, ledger.ErrChargeNotFound), errors.Is(err, ledger.ErrPaymentNotFound):
		writeError(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, ledger.ErrAlreadyVoided):
		writeError(w, http.StatusConflict, "already_voided", err.Error())
	case errors.Is(err, ledger.ErrAmountInvalid):
		writeError(w, http.StatusBadRequest, "invalid_amount", err.Error())
	default:
		writeError(w, http.StatusInternalServerError, "internal_error", "internal error")
	}
}
