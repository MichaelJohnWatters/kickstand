package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/bikemaint"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/media"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// GET /bikes/{id}/expenses — maintenance history for a bike, newest
// first. Inline 50×50 thumbs come back base64-encoded so the list
// view paints without a per-row fetch.
func (s *Server) handleListBikeExpenses(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	rows, err := bikemaint.ListForBike(r.Context(), scope, domain.BikeID(r.PathValue("id")))
	if err != nil {
		writeBikeMaintError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(rows))
	for i := range rows {
		out = append(out, bikeExpensePayload(&rows[i]))
	}
	ytd, _ := bikemaint.YearToDateTotal(r.Context(), scope, domain.BikeID(r.PathValue("id")))
	writeJSON(w, http.StatusOK, map[string]any{
		"expenses":   out,
		"ytdPence":   ytd,
	})
}

// POST /bikes/{id}/expenses (multipart/form-data) — record one
// maintenance line. Mirrors POST /me/expenses: same upload pipeline,
// same compression + thumb generation. Auth: admin/owner only.
func (s *Server) handleRecordBikeExpense(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	if err := r.ParseMultipartForm(8 << 20); err != nil {
		writeError(w, http.StatusBadRequest, "bad_form", err.Error())
		return
	}
	file, _, err := r.FormFile("receipt")
	if err != nil {
		writeError(w, http.StatusBadRequest, "receipt_required", "missing receipt file")
		return
	}
	defer file.Close()
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

	bikeID := domain.BikeID(r.PathValue("id"))
	expID := domain.ExpenseID(domain.NewID())
	key := fmt.Sprintf("bike-expenses/%s/receipt.jpg", expID)
	if _, err := s.Files.Put(key, bytes.NewReader(processed.Main)); err != nil {
		writeError(w, http.StatusInternalServerError, "store_failed", err.Error())
		return
	}

	amount, err := parseIntField(r, "amountPence")
	if err != nil {
		_ = s.Files.Delete(key)
		writeError(w, http.StatusBadRequest, "bad_amount", err.Error())
		return
	}

	scope := tenant.NewScope(s.DB, id.SchoolID)
	ex, err := bikemaint.Record(r.Context(), scope, bikemaint.RecordRequest{
		BikeID:             bikeID,
		Category:           bikemaint.Category(r.FormValue("category")),
		AmountPence:        amount,
		OccurredAt:         strings.TrimSpace(r.FormValue("occurredAt")),
		Vendor:             strings.TrimSpace(r.FormValue("vendor")),
		Notes:              strings.TrimSpace(r.FormValue("notes")),
		ReceiptStorageKey:  key,
		ReceiptContentType: "image/jpeg",
		ReceiptSizeBytes:   processed.MainBytes,
		ReceiptThumb:       processed.Thumb,
		RecordedBy:         id.UserID,
	})
	if err != nil {
		_ = s.Files.Delete(key)
		writeBikeMaintError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"expense": bikeExpensePayload(ex)})
}

// GET /bike-expenses/{id}/receipt — stream the full receipt image.
func (s *Server) handleGetBikeExpenseReceipt(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	ex, err := bikemaint.Get(r.Context(), scope, domain.ExpenseID(r.PathValue("id")))
	if err != nil {
		writeBikeMaintError(w, err)
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

// DELETE /bike-expenses/{id} — remove a maintenance record. Also
// deletes the receipt blob from the filestore (best-effort; an orphan
// blob is harmless, a half-deleted row would confuse the UI).
func (s *Server) handleDeleteBikeExpense(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	expenseID := domain.ExpenseID(r.PathValue("id"))
	ex, err := bikemaint.Get(r.Context(), scope, expenseID)
	if err != nil {
		writeBikeMaintError(w, err)
		return
	}
	if err := bikemaint.Delete(r.Context(), scope, expenseID); err != nil {
		writeBikeMaintError(w, err)
		return
	}
	_ = s.Files.Delete(ex.ReceiptStorageKey)
	w.WriteHeader(http.StatusNoContent)
}

func writeBikeMaintError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, bikemaint.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, bikemaint.ErrInvalidCategory):
		writeError(w, http.StatusBadRequest, "invalid_category", err.Error())
	case errors.Is(err, bikemaint.ErrAmountRequired):
		writeError(w, http.StatusBadRequest, "invalid_amount", err.Error())
	case errors.Is(err, bikemaint.ErrReceiptRequired):
		writeError(w, http.StatusBadRequest, "receipt_required", err.Error())
	case errors.Is(err, bikemaint.ErrBadDate):
		writeError(w, http.StatusBadRequest, "bad_date", err.Error())
	default:
		writeError(w, http.StatusInternalServerError, "internal_error", "internal error")
	}
}

func bikeExpensePayload(e *bikemaint.Expense) map[string]any {
	row := map[string]any{
		"id":                 e.ID,
		"bikeId":             e.BikeID,
		"category":           e.Category,
		"amountPence":        e.AmountPence,
		"occurredAt":         e.OccurredAt,
		"vendor":             e.Vendor,
		"notes":              e.Notes,
		"receiptContentType": e.ReceiptContentType,
		"receiptSizeBytes":   e.ReceiptSizeBytes,
		"recordedBy":         e.RecordedBy,
		"recordedByName":     e.RecordedByName,
		"recordedAt":         e.RecordedAt.Format(time.RFC3339),
	}
	if len(e.ReceiptThumb) > 0 {
		row["receiptThumb"] = base64.StdEncoding.EncodeToString(e.ReceiptThumb)
	}
	return row
}

// (json import is used by json.NewDecoder elsewhere; this file uses
// only base64/json indirectly via the helpers above.)
var _ = json.NewDecoder
