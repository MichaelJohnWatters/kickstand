package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/instructorpay"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// Instructor-pay endpoints are admin-only (owed-tracking is a manager view).
// An instructor's own "what I'm owed" view is plan §10b "Instructor-facing
// additions (Optional, later)" — defer.

// GET /instructors/{id}/pay-model — returns the current pay model or
// 404 if none is set yet. Admin/owner only.
func (s *Server) handleGetPayModel(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !canManageInstructorPay(id.Role) {
		writeError(w, http.StatusForbidden, "forbidden", "admin/owner only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	m, err := instructorpay.GetPayModel(r.Context(), scope, domain.UserID(r.PathValue("id")))
	if err != nil {
		writeInstructorPayError(w, err)
		return
	}
	if m == nil {
		writeError(w, http.StatusNotFound, "not_set", "pay model not configured")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"instructorId": m.InstructorID,
		"payBasis":     m.PayBasis,
		"rateValue":    m.RateValue,
	})
}

func (s *Server) handleSetPayModel(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !canManageInstructorPay(id.Role) {
		writeError(w, http.StatusForbidden, "forbidden", "only admin/owner can set pay models")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	instructorID := domain.UserID(r.PathValue("id"))

	var req struct {
		PayBasis  string `json:"payBasis"`
		RateValue int64  `json:"rateValue"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	if err := instructorpay.SetPayModel(r.Context(), scope, instructorpay.SetPayModelRequest{
		InstructorID: instructorID,
		PayBasis:     domain.PayBasis(req.PayBasis),
		RateValue:    req.RateValue,
	}); err != nil {
		writeInstructorPayError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleCreateEarning(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !canManageInstructorPay(id.Role) {
		writeError(w, http.StatusForbidden, "forbidden", "only admin/owner can record earnings")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	instructorID := domain.UserID(r.PathValue("id"))

	var req struct {
		SessionID       string   `json:"sessionId"`
		AmountPence     int64    `json:"amountPence"`
		Basis           string   `json:"basis"`
		Notes           string   `json:"notes"`
		SourceChargeIDs []string `json:"sourceChargeIds"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	sources := make([]domain.ChargeID, 0, len(req.SourceChargeIDs))
	for _, c := range req.SourceChargeIDs {
		sources = append(sources, domain.ChargeID(c))
	}
	e, err := instructorpay.RecordEarning(r.Context(), scope, instructorpay.RecordEarningRequest{
		InstructorID:    instructorID,
		SessionID:       domain.SessionID(req.SessionID),
		AmountPence:     domain.Money(req.AmountPence),
		Basis:           domain.PayBasis(req.Basis),
		Notes:           req.Notes,
		CreatedBy:       id.UserID,
		SourceChargeIDs: sources,
	})
	if err != nil {
		writeInstructorPayError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":           e.ID,
		"instructorId": e.InstructorID,
		"sessionId":    e.SessionID,
		"amountPence":  e.AmountPence,
		"basis":        e.Basis,
		"notes":        e.Notes,
		"createdAt":    e.CreatedAt.Format(time.RFC3339),
	})
}

func (s *Server) handleVoidEarning(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !canManageInstructorPay(id.Role) {
		writeError(w, http.StatusForbidden, "forbidden", "only admin/owner can void earnings")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	earningID := domain.EarningID(r.PathValue("earningId"))

	var body struct{ Reason string `json:"reason"` }
	if r.ContentLength > 0 {
		_ = json.NewDecoder(r.Body).Decode(&body)
	}
	if err := instructorpay.VoidEarning(r.Context(), scope, instructorpay.VoidEarningRequest{
		EarningID: earningID, VoidedBy: id.UserID, Reason: body.Reason,
	}); err != nil {
		writeInstructorPayError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleCreateInstructorPayment(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !canManageInstructorPay(id.Role) {
		writeError(w, http.StatusForbidden, "forbidden", "only admin/owner can record instructor payments")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	instructorID := domain.UserID(r.PathValue("id"))

	var req struct {
		AmountPence int64  `json:"amountPence"`
		Method      string `json:"method"`
		PaidAt      string `json:"paidAt"`
		Notes       string `json:"notes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	paidAt := time.Now()
	if req.PaidAt != "" {
		t, err := time.Parse(time.RFC3339, req.PaidAt)
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_param", "paidAt: "+err.Error())
			return
		}
		paidAt = t
	}
	p, err := instructorpay.RecordPayment(r.Context(), scope, instructorpay.RecordPaymentRequest{
		InstructorID: instructorID,
		AmountPence:  domain.Money(req.AmountPence),
		Method:       domain.PaymentMethod(req.Method),
		PaidAt:       paidAt,
		RecordedBy:   id.UserID,
		Notes:        req.Notes,
	})
	if err != nil {
		writeInstructorPayError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":           p.ID,
		"instructorId": p.InstructorID,
		"amountPence":  p.AmountPence,
		"method":       p.Method,
		"paidAt":       p.PaidAt.Format(time.RFC3339),
		"recordedBy":   p.RecordedBy,
	})
}

func (s *Server) handleListOutstanding(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !canManageInstructorPay(id.Role) {
		writeError(w, http.StatusForbidden, "forbidden", "admin/owner only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	out, err := instructorpay.AllOutstanding(r.Context(), scope)
	if err != nil {
		writeInstructorPayError(w, err)
		return
	}
	rows := make([]map[string]any, 0, len(out))
	var totalOwed domain.Money
	for _, o := range out {
		totalOwed += o.Balance
		rows = append(rows, map[string]any{
			"instructorId":      o.InstructorID,
			"instructorName":    o.InstructorName,
			"totalEarnedPence":  o.TotalEarned,
			"totalPaidPence":    o.TotalPaid,
			"outstandingPence":  o.Balance,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"totalOwedPence": totalOwed,
		"instructors":    rows,
	})
}

func canManageInstructorPay(r domain.Role) bool {
	return r == domain.RoleAdmin || r == domain.RoleOwner
}

func writeInstructorPayError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, instructorpay.ErrInstructorNotFound):
		writeError(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, instructorpay.ErrEarningNotFound):
		writeError(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, instructorpay.ErrAlreadyVoided):
		writeError(w, http.StatusConflict, "already_voided", err.Error())
	case errors.Is(err, instructorpay.ErrAmountInvalid):
		writeError(w, http.StatusBadRequest, "invalid_amount", err.Error())
	case errors.Is(err, instructorpay.ErrInvalidBasis):
		writeError(w, http.StatusBadRequest, "invalid_basis", err.Error())
	default:
		writeError(w, http.StatusInternalServerError, "internal_error", "internal error")
	}
}
