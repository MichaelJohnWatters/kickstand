package httpapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/expenses"
	"github.com/michaeljohnwatters/kickstand/internal/media"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// --- Category management ---

// GET /expense-categories?activeOnly=1
// Anyone in the school can read the list — instructors need it to populate
// the category chips on the Add Expense form.
func (s *Server) handleListExpenseCategories(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	cats, err := expenses.ListCategories(r.Context(), scope, r.URL.Query().Get("activeOnly") == "1")
	if err != nil {
		writeEngineError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"categories": cats})
}

// PUT /expense-categories — admin-only. Body is the full list (idempotent
// upsert; categories absent from the body get soft-deactivated).
func (s *Server) handleUpsertExpenseCategories(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role != domain.RoleAdmin && id.Role != domain.RoleOwner {
		writeError(w, http.StatusForbidden, "forbidden", "owner / manager only")
		return
	}
	var body struct {
		Categories []expenses.Category `json:"categories"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	if err := expenses.UpsertCategories(r.Context(), scope, body.Categories); err != nil {
		writeEngineError(w, err)
		return
	}
	cats, _ := expenses.ListCategories(r.Context(), scope, false)
	writeJSON(w, http.StatusOK, map[string]any{"categories": cats})
}

// --- Instructor side ---

// POST /me/expenses (multipart/form-data)
//
// Form fields:
//
//	receipt      file        required
//	categoryId   text        required
//	amountPence  text/int    required
//	occurredAt   text/RFC3339 required (the day the spend happened)
//	where        text        optional
//	notes        text        optional
//
// The receipt is staged into the file-store before the engine row is written
// so we never end up with a DB row pointing at a missing blob.
func (s *Server) handleSubmitExpense(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	// Only instructors can submit receipts. Admins/owners read but never
	// write — they pay reimbursements, they don't claim them.
	if id.Role != domain.RoleInstructor {
		writeError(w, http.StatusForbidden, "forbidden", "instructors only")
		return
	}
	if err := r.ParseMultipartForm(8 << 20); err != nil { // 8 MB max
		writeError(w, http.StatusBadRequest, "bad_form", err.Error())
		return
	}
	file, _, err := r.FormFile("receipt")
	if err != nil {
		writeError(w, http.StatusBadRequest, "receipt_required", "missing receipt file")
		return
	}
	defer file.Close()

	// Decode → resize to MaxLongEdge → JPEG q80, plus a 50×50 thumb.
	// All persisted receipts are JPEGs regardless of what the phone
	// uploaded, so the storage key always carries `.jpg`.
	processed, err := media.ProcessReceipt(file)
	if err != nil {
		if errors.Is(err, media.ErrUnsupported) {
			writeError(w, http.StatusBadRequest, "unsupported_image",
				"receipt must be a JPEG, PNG, or GIF")
			return
		}
		writeError(w, http.StatusInternalServerError, "image_process_failed", err.Error())
		return
	}

	expID := domain.ExpenseID(domain.NewID())
	key := fmt.Sprintf("expenses/%s/receipt.jpg", expID)
	if _, err := s.Files.Put(key, bytes.NewReader(processed.Main)); err != nil {
		writeError(w, http.StatusInternalServerError, "store_failed", err.Error())
		return
	}

	occurredAt, err := time.Parse(time.RFC3339, r.FormValue("occurredAt"))
	if err != nil {
		_ = s.Files.Delete(key)
		writeError(w, http.StatusBadRequest, "bad_occurred_at", "occurredAt must be RFC3339")
		return
	}
	amount, err := parseIntField(r, "amountPence")
	if err != nil {
		_ = s.Files.Delete(key)
		writeError(w, http.StatusBadRequest, "bad_amount", err.Error())
		return
	}

	scope := tenant.NewScope(s.DB, id.SchoolID)
	ex, err := expenses.Submit(r.Context(), scope, expenses.SubmitRequest{
		InstructorID:       id.UserID,
		CategoryID:         r.FormValue("categoryId"),
		AmountPence:        amount,
		OccurredAt:         occurredAt,
		Where:              strings.TrimSpace(r.FormValue("where")),
		Notes:              strings.TrimSpace(r.FormValue("notes")),
		ReceiptStorageKey:  key,
		ReceiptContentType: "image/jpeg",
		ReceiptSizeBytes:   processed.MainBytes,
		ReceiptThumb:       processed.Thumb,
	})
	if err != nil {
		// Engine rejected — clean up the receipt so the bucket doesn't fill
		// with orphaned blobs.
		_ = s.Files.Delete(key)
		writeEngineError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"expense": expensePayload(ex)})
}

// GET /me/expenses?status=pending|approved|reimbursed|rejected|withdrawn
func (s *Server) handleListMyExpenses(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	rows, err := expenses.ListForInstructor(r.Context(), scope, id.UserID, r.URL.Query().Get("status"))
	if err != nil {
		writeEngineError(w, err)
		return
	}
	out, totals, err := withTotals(r.Context(), scope, id.UserID, rows)
	if err != nil {
		writeEngineError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"expenses": out,
		"outstanding": map[string]any{
			"count":       totals.Count,
			"amountPence": totals.AmountPence,
		},
	})
}

// DELETE /me/expenses/{id} — instructor withdraws a pending expense.
func (s *Server) handleWithdrawExpense(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	// Engine already enforces "you can only withdraw your own", but the
	// role gate here makes it explicit: admins/owners never delete
	// receipts (audit trail), only instructors withdraw their own
	// pending submissions.
	if id.Role != domain.RoleInstructor {
		writeError(w, http.StatusForbidden, "forbidden", "instructors only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	ex, err := expenses.Withdraw(r.Context(), scope, expenses.WithdrawRequest{
		ID:           domain.ExpenseID(r.PathValue("id")),
		InstructorID: id.UserID,
	})
	if err != nil {
		writeEngineError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"expense": expensePayload(ex)})
}

// --- Admin side ---

// GET /expenses?status=pending|... — admin/owner review queue.
// Instructors see only their own list via GET /me/expenses.
func (s *Server) handleListExpensesForReview(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role != domain.RoleAdmin && id.Role != domain.RoleOwner {
		writeError(w, http.StatusForbidden, "forbidden", "owner / manager only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	rows, err := expenses.ListForReview(r.Context(), scope, r.URL.Query().Get("status"))
	if err != nil {
		writeEngineError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(rows))
	for i := range rows {
		out = append(out, expensePayload(&rows[i]))
	}
	pending, _ := expenses.CountPending(r.Context(), scope)
	writeJSON(w, http.StatusOK, map[string]any{
		"expenses":     out,
		"pendingCount": pending,
	})
}

// GET /expenses/{id} — single expense for the admin detail modal or
// the instructor's own expense detail view. Students have nothing to
// see here.
func (s *Server) handleGetExpense(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	ex, err := expenses.Get(r.Context(), scope, domain.ExpenseID(r.PathValue("id")))
	if err != nil {
		writeEngineError(w, err)
		return
	}
	// Instructors only see their own.
	if id.Role == domain.RoleInstructor && ex.InstructorID != id.UserID {
		writeError(w, http.StatusForbidden, "forbidden", "")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"expense": expensePayload(ex)})
}

// GET /expenses/{id}/receipt — auth-gated streaming receipt image.
// Students never see receipts; instructors only their own.
func (s *Server) handleGetExpenseReceipt(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	ex, err := expenses.Get(r.Context(), scope, domain.ExpenseID(r.PathValue("id")))
	if err != nil {
		writeEngineError(w, err)
		return
	}
	if id.Role == domain.RoleInstructor && ex.InstructorID != id.UserID {
		writeError(w, http.StatusForbidden, "forbidden", "")
		return
	}
	rc, err := s.Files.Open(ex.ReceiptStorageKey)
	if err != nil {
		writeError(w, http.StatusNotFound, "receipt_missing", err.Error())
		return
	}
	defer rc.Close()
	w.Header().Set("Content-Type", ex.ReceiptContentType)
	w.Header().Set("Cache-Control", "private, max-age=86400")
	_, _ = io.Copy(w, rc)
}

// POST /expenses/{id}/approve — optional `reviewerNote` in body.
func (s *Server) handleApproveExpense(w http.ResponseWriter, r *http.Request) {
	s.handleReview(w, r, "approve")
}

// POST /expenses/{id}/reject — required `reviewerNote`.
func (s *Server) handleRejectExpense(w http.ResponseWriter, r *http.Request) {
	s.handleReview(w, r, "reject")
}

// POST /expenses/{id}/reimburse — body: {paidMethod: 'bank'|'cash'|'other'}.
func (s *Server) handleReimburseExpense(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role != domain.RoleAdmin && id.Role != domain.RoleOwner {
		writeError(w, http.StatusForbidden, "forbidden", "owner / manager only")
		return
	}
	var body struct {
		PaidMethod string `json:"paidMethod"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	scope := tenant.NewScope(s.DB, id.SchoolID)
	ex, err := expenses.MarkReimbursed(r.Context(), scope, expenses.MarkReimbursedRequest{
		ID:         domain.ExpenseID(r.PathValue("id")),
		PaidBy:     id.UserID,
		PaidMethod: body.PaidMethod,
	})
	if err != nil {
		writeEngineError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"expense": expensePayload(ex)})
}

// shared body for approve/reject
type reviewBody struct {
	ReviewerNote string `json:"reviewerNote"`
}

func (s *Server) handleReview(w http.ResponseWriter, r *http.Request, kind string) {
	id, _ := identityFromContext(r.Context())
	if id.Role != domain.RoleAdmin && id.Role != domain.RoleOwner {
		writeError(w, http.StatusForbidden, "forbidden", "owner / manager only")
		return
	}
	var body reviewBody
	_ = json.NewDecoder(r.Body).Decode(&body)
	scope := tenant.NewScope(s.DB, id.SchoolID)
	expID := domain.ExpenseID(r.PathValue("id"))
	var (
		ex  *expenses.Expense
		err error
	)
	switch kind {
	case "approve":
		ex, err = expenses.Approve(r.Context(), scope, expenses.ApproveRequest{
			ID: expID, ApprovedBy: id.UserID, ReviewerNote: strings.TrimSpace(body.ReviewerNote),
		})
	case "reject":
		ex, err = expenses.Reject(r.Context(), scope, expenses.RejectRequest{
			ID: expID, RejectedBy: id.UserID, ReviewerNote: strings.TrimSpace(body.ReviewerNote),
		})
	}
	if err != nil {
		writeEngineError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"expense": expensePayload(ex)})
}

// --- Helpers ---

func parseIntField(r *http.Request, name string) (int, error) {
	v := r.FormValue(name)
	if v == "" {
		return 0, fmt.Errorf("%s missing", name)
	}
	var n int
	_, err := fmt.Sscanf(v, "%d", &n)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", name, err)
	}
	return n, nil
}

func withTotals(ctx context.Context, scope *tenant.Scope, instr domain.UserID, rows []expenses.Expense) ([]map[string]any, expenses.OutstandingTotals, error) {
	out := make([]map[string]any, 0, len(rows))
	for i := range rows {
		out = append(out, expensePayload(&rows[i]))
	}
	totals, err := expenses.OutstandingForInstructor(ctx, scope, instr)
	return out, totals, err
}

// expensePayload is the wire shape returned by every Expense-returning endpoint.
//
// The 50×50 thumbnail is base64-encoded into receiptThumb so the
// reviewer list paints a real preview per row without a per-row HTTP
// fetch. Around 2 KB of payload per expense; trivial.
func expensePayload(e *expenses.Expense) map[string]any {
	row := map[string]any{
		"id":                 e.ID,
		"instructorId":       e.InstructorID,
		"instructorName":     e.InstructorName,
		"categoryId":         e.CategoryID,
		"categoryLabel":      e.CategoryLabel,
		"categoryIcon":       e.CategoryIcon,
		"categoryTone":       e.CategoryTone,
		"amountPence":        e.AmountPence,
		"occurredAt":         e.OccurredAt.Format(time.RFC3339),
		"where":              e.Where,
		"notes":              e.Notes,
		"status":             e.Status,
		"receiptContentType": e.ReceiptContentType,
		"receiptSizeBytes":   e.ReceiptSizeBytes,
		"submittedAt":        e.SubmittedAt.Format(time.RFC3339),
	}
	if len(e.ReceiptThumb) > 0 {
		row["receiptThumb"] = base64.StdEncoding.EncodeToString(e.ReceiptThumb)
	}
	if e.ReviewedBy != "" {
		row["reviewedBy"] = e.ReviewedBy
		row["reviewedByName"] = e.ReviewedByName
		row["reviewedAt"] = e.ReviewedAt.Format(time.RFC3339)
	}
	if e.ReviewerNote != "" {
		row["reviewerNote"] = e.ReviewerNote
	}
	if e.PaidBy != "" {
		row["paidBy"] = e.PaidBy
		row["paidByName"] = e.PaidByName
		row["paidAt"] = e.PaidAt.Format(time.RFC3339)
		row["paidMethod"] = e.PaidMethod
	}
	if !e.WithdrawnAt.IsZero() {
		row["withdrawnAt"] = e.WithdrawnAt.Format(time.RFC3339)
	}
	return row
}
