package httpapi

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"

	firebaseauth "firebase.google.com/go/v4/auth"

	"github.com/michaeljohnwatters/kickstand/internal/admin"
	"github.com/michaeljohnwatters/kickstand/internal/audit"
	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// Helpers ------------------------------------------------------------------

func requireAdminOwner(w http.ResponseWriter, id *auth.Identity) bool {
	if id.Role != domain.RoleAdmin && id.Role != domain.RoleOwner {
		writeError(w, http.StatusForbidden, "forbidden", "admin/owner only")
		return false
	}
	return true
}

func writeAdminError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, admin.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, admin.ErrConflict):
		writeError(w, http.StatusConflict, "conflict", err.Error())
	case errors.Is(err, admin.ErrCannotDeleteUsed):
		writeError(w, http.StatusConflict, "in_use", err.Error())
	case errors.Is(err, admin.ErrInvalidInput):
		writeError(w, http.StatusBadRequest, "invalid_input", err.Error())
	default:
		writeError(w, http.StatusInternalServerError, "internal_error", "internal error")
	}
}

// ----- Locations -----

func (s *Server) handleListLocations(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	out, err := admin.ListLocations(r.Context(), scope)
	if err != nil {
		writeAdminError(w, err)
		return
	}
	// Explicit camelCase keys for consistency with the rest of the API.
	// `image` is base64'd inline so the cards paint without a separate
	// fetch per row (locations are a small set, ~3-10 per tenant).
	rows := make([]map[string]any, 0, len(out))
	for _, l := range out {
		row := map[string]any{
			"id":      l.ID,
			"name":    l.Name,
			"address": l.Address,
		}
		if l.Lat != nil {
			row["lat"] = *l.Lat
		}
		if l.Lng != nil {
			row["lng"] = *l.Lng
		}
		if len(l.Image) > 0 {
			row["image"] = base64.StdEncoding.EncodeToString(l.Image)
		}
		rows = append(rows, row)
	}
	writeJSON(w, http.StatusOK, map[string]any{"locations": rows})
}

func (s *Server) handleCreateLocation(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req admin.CreateLocationRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	loc, err := admin.CreateLocation(r.Context(), scope, req)
	if err != nil {
		writeAdminError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":      loc.ID,
		"name":    loc.Name,
		"address": loc.Address,
	})
}

func (s *Server) handleUpdateLocation(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req admin.UpdateLocationRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	if err := admin.UpdateLocation(r.Context(), scope, domain.LocationID(r.PathValue("id")), req); err != nil {
		writeAdminError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleDeleteLocation(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	if err := admin.DeleteLocation(r.Context(), scope, domain.LocationID(r.PathValue("id"))); err != nil {
		writeAdminError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ----- Travel matrix -----

func (s *Server) handleListTravelTimes(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	out, err := admin.ListTravelTimes(r.Context(), scope)
	if err != nil {
		writeAdminError(w, err)
		return
	}
	rows := make([]map[string]any, 0, len(out))
	for _, t := range out {
		rows = append(rows, map[string]any{
			"fromLocationId": t.FromLocationID,
			"toLocationId":   t.ToLocationID,
			"minutes":        t.Minutes,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"travelTimes": rows})
}

func (s *Server) handleSetTravelTime(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		FromLocationID string `json:"fromLocationId"`
		ToLocationID   string `json:"toLocationId"`
		Minutes        int    `json:"minutes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	if err := admin.SetTravelTime(r.Context(), scope, admin.TravelTime{
		FromLocationID: domain.LocationID(req.FromLocationID),
		ToLocationID:   domain.LocationID(req.ToLocationID),
		Minutes:        req.Minutes,
	}); err != nil {
		writeAdminError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleDeleteTravelTime(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	if err := admin.DeleteTravelTime(r.Context(), scope,
		domain.LocationID(r.PathValue("from")),
		domain.LocationID(r.PathValue("to"))); err != nil {
		writeAdminError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ----- Bikes -----

func (s *Server) handleListBikes(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	out, err := admin.ListBikes(r.Context(), scope)
	if err != nil {
		writeAdminError(w, err)
		return
	}
	rows := make([]map[string]any, 0, len(out))
	for _, b := range out {
		rows = append(rows, bikeRowView(b))
	}
	writeJSON(w, http.StatusOK, map[string]any{"bikes": rows})
}

func bikeRowView(b admin.BikeRow) map[string]any {
	return map[string]any{
		"id":                  b.ID,
		"nickname":            b.Nickname,
		"make":                b.Make,
		"model":               b.Model,
		"registration":        b.Registration,
		"category":            b.Category,
		"transmission":        b.Transmission,
		"engineCc":            b.EngineCC,
		"status":              b.Status,
		"homeLocationId":      b.HomeLocationID,
		"homeLocationName":    b.HomeLocationName,
		"currentLocationId":   b.CurrentLocationID,
		"currentLocationName": b.CurrentLocationName,
		"isCrossSite":         b.IsCrossSite,
		"motExpiresOn":        b.MOTExpiresOn,
		"taxExpiresOn":        b.TaxExpiresOn,
		"currentMileageMiles": b.CurrentMileageMiles,
	}
}

func (s *Server) handleCreateBike(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		Nickname       string `json:"nickname"`
		Make           string `json:"make"`
		Model          string `json:"model"`
		Registration   string `json:"registration"`
		Category       string `json:"category"`
		Transmission   string `json:"transmission"`
		EngineCC       int    `json:"engineCc"`
		HomeLocationID string `json:"homeLocationId"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	b, err := admin.CreateBike(r.Context(), scope, admin.CreateBikeRequest{
		Nickname:       req.Nickname,
		Make:           req.Make,
		Model:          req.Model,
		Registration:   req.Registration,
		Category:       domain.LicenceCategory(req.Category),
		Transmission:   domain.Transmission(req.Transmission),
		EngineCC:       req.EngineCC,
		HomeLocationID: domain.LocationID(req.HomeLocationID),
	})
	if err != nil {
		writeAdminError(w, err)
		return
	}
	label := b.Nickname
	if label == "" {
		label = strings.TrimSpace(b.Make + " " + b.Model)
	}
	if label == "" {
		label = string(b.ID)
	}
	audit.Describe(r.Context(), "Added bike %s (%s)", label, b.Category)
	writeJSON(w, http.StatusCreated, bikeRowView(*b))
}

func (s *Server) handleUpdateBike(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	// Pointer types for MOT/tax so a missing key means "leave unchanged"
	// while an empty string explicitly clears the value.
	var req struct {
		Nickname       string  `json:"nickname"`
		Make           string  `json:"make"`
		Model          string  `json:"model"`
		Registration   string  `json:"registration"`
		EngineCC       int     `json:"engineCc"`
		HomeLocationID string  `json:"homeLocationId"`
		MOTExpiresOn   *string `json:"motExpiresOn"`
		TaxExpiresOn   *string `json:"taxExpiresOn"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	if err := admin.UpdateBike(r.Context(), scope, domain.BikeID(r.PathValue("id")), admin.UpdateBikeRequest{
		Nickname:       req.Nickname,
		Make:           req.Make,
		Model:          req.Model,
		Registration:   req.Registration,
		EngineCC:       req.EngineCC,
		HomeLocationID: domain.LocationID(req.HomeLocationID),
		MOTExpiresOn:   req.MOTExpiresOn,
		TaxExpiresOn:   req.TaxExpiresOn,
	}); err != nil {
		writeAdminError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// POST /bikes/{id}/mileage — record a new mileage reading. Body:
//
//	{ "miles": 12840, "source": "manual" | "mot" | "service" | "incident" }
//
// Updates the snapshot column on the bike row and appends to
// bike_mileage_log atomically.
func (s *Server) handleRecordBikeMileage(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		Miles  int    `json:"miles"`
		Source string `json:"source"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	if err := admin.RecordMileage(r.Context(), scope,
		domain.BikeID(r.PathValue("id")),
		admin.RecordMileageRequest{
			Miles:      req.Miles,
			Source:     req.Source,
			RecordedBy: id.UserID,
		}); err != nil {
		writeAdminError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleMoveBike(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		LocationId string `json:"locationId"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	bikeID := domain.BikeID(r.PathValue("id"))
	bikeLabel := bikeDisplayName(r.Context(), s.DB, id.SchoolID, bikeID)
	locName := locationDisplayName(r.Context(), s.DB, id.SchoolID, domain.LocationID(req.LocationId))
	if err := admin.MoveBike(r.Context(), scope, bikeID,
		domain.LocationID(req.LocationId)); err != nil {
		writeAdminError(w, err)
		return
	}
	audit.Describe(r.Context(), "Moved %s to %s", bikeLabel, locName)
	w.WriteHeader(http.StatusNoContent)
}

// locationDisplayName fetches a location's name for human audit
// summaries. Falls back to the ID on miss.
func locationDisplayName(ctx context.Context, db *sql.DB, schoolID domain.SchoolID, locID domain.LocationID) string {
	var name string
	if err := db.QueryRowContext(ctx,
		`SELECT name FROM locations WHERE id = ? AND school_id = ?`,
		string(locID), string(schoolID),
	).Scan(&name); err != nil {
		return string(locID)
	}
	return name
}

func (s *Server) handleRestoreBike(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	bikeID := domain.BikeID(r.PathValue("id"))
	bikeLabel := bikeDisplayName(r.Context(), s.DB, id.SchoolID, bikeID)
	if err := admin.RestoreBike(r.Context(), scope, bikeID); err != nil {
		writeAdminError(w, err)
		return
	}
	audit.Describe(r.Context(), "Restored %s to service", bikeLabel)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleDeleteBike(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	if err := admin.DeleteBike(r.Context(), scope, domain.BikeID(r.PathValue("id"))); err != nil {
		writeAdminError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ----- Bike GPS (live map view) -----
//
// The scheduling/logistics engine never reads these endpoints — they
// feed the presentational live-map screen only. See plan §7 + the
// invariant in `gps-and-analytics-plan.md`.

func (s *Server) handleUpdateBikeGPS(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		Lat float64 `json:"lat"`
		Lng float64 `json:"lng"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	bikeID := domain.BikeID(r.PathValue("id"))
	if err := admin.UpdateBikeGPS(r.Context(), scope, bikeID,
		admin.UpdateBikeGPSRequest{Lat: req.Lat, Lng: req.Lng}); err != nil {
		writeAdminError(w, err)
		return
	}
	audit.Describe(r.Context(), "Updated GPS for %s",
		bikeDisplayName(r.Context(), s.DB, id.SchoolID, bikeID))
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleListBikeGPS(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	rows, err := admin.ListBikeGPS(r.Context(), scope)
	if err != nil {
		writeAdminError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(rows))
	for _, b := range rows {
		view := map[string]any{
			"id":                  b.ID,
			"nickname":            b.Nickname,
			"registration":        b.Registration,
			"status":              b.Status,
			"liveStatus":          b.LiveStatus,
			"currentLocationId":   b.CurrentLocationID,
			"currentLocationName": b.CurrentLocationName,
			"lastSeenAt":          b.LastSeenAt,
		}
		if b.Lat != nil {
			view["lat"] = *b.Lat
		}
		if b.Lng != nil {
			view["lng"] = *b.Lng
		}
		out = append(out, view)
	}
	writeJSON(w, http.StatusOK, map[string]any{"bikes": out})
}

// GET /bikes/{id}/gps/history?since=&limit=
//
// Returns one bike's recent GPS fixes for the breadcrumb-trail panel
// on the live map. Admin/owner only — same gate as the rest of the
// fleet surface.
func (s *Server) handleListBikeGPSHistory(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	bikeID := domain.BikeID(r.PathValue("id"))
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	fixes, err := admin.ListBikeGPSHistory(r.Context(), scope, bikeID, q.Get("since"), limit)
	if err != nil {
		writeAdminError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(fixes))
	for _, f := range fixes {
		out = append(out, map[string]any{
			"at":  f.At,
			"lat": f.Lat,
			"lng": f.Lng,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"fixes": out})
}

// ----- Course types -----

func courseTypeView(c admin.CourseTypeRow) map[string]any {
	return map[string]any{
		"id":                      c.ID,
		"code":                    c.Code,
		"name":                    c.Name,
		"region":                  c.Region,
		"requiredBikeCategory":    c.RequiredBikeCategory,
		"durationMinutes":         c.DurationMinutes,
		"maxRatio":                c.MaxRatio,
		"pricePence":              c.PricePence,
		"nonTeaching":             c.NonTeaching,
		"cancellationCutoffHours": c.CancellationCutoffHours,
		"accentColour":            c.AccentColour,
		"icon":                    c.Icon,
		"prerequisites":           c.Prerequisites,
	}
}

func (s *Server) handleListCourseTypes(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	out, err := admin.ListCourseTypes(r.Context(), scope)
	if err != nil {
		writeAdminError(w, err)
		return
	}
	rows := make([]map[string]any, 0, len(out))
	for _, c := range out {
		rows = append(rows, courseTypeView(c))
	}
	writeJSON(w, http.StatusOK, map[string]any{"courseTypes": rows})
}

type courseTypePayload struct {
	Code                    string   `json:"code"`
	Name                    string   `json:"name"`
	Region                  string   `json:"region"`
	RequiredBikeCategory    string   `json:"requiredBikeCategory"`
	DurationMinutes         int      `json:"durationMinutes"`
	MaxRatio                int      `json:"maxRatio"`
	PricePence              int64    `json:"pricePence"`
	NonTeaching             bool     `json:"nonTeaching"`
	CancellationCutoffHours int      `json:"cancellationCutoffHours"`
	AccentColour            string   `json:"accentColour"`
	Icon                    string   `json:"icon"`
	Prerequisites           []string `json:"prerequisites"`
}

func (p courseTypePayload) toReq() admin.CreateCourseTypeRequest {
	return admin.CreateCourseTypeRequest{
		Code:                    p.Code,
		Name:                    p.Name,
		Region:                  domain.Region(p.Region),
		RequiredBikeCategory:    domain.LicenceCategory(p.RequiredBikeCategory),
		DurationMinutes:         p.DurationMinutes,
		MaxRatio:                p.MaxRatio,
		PricePence:              domain.Money(p.PricePence),
		NonTeaching:             p.NonTeaching,
		CancellationCutoffHours: p.CancellationCutoffHours,
		AccentColour:            p.AccentColour,
		Icon:                    p.Icon,
		Prerequisites:           p.Prerequisites,
	}
}

func (s *Server) handleCreateCourseType(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var p courseTypePayload
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	c, err := admin.CreateCourseType(r.Context(), scope, p.toReq())
	if err != nil {
		writeAdminError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, courseTypeView(*c))
}

func (s *Server) handleUpdateCourseType(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var p courseTypePayload
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	if err := admin.UpdateCourseType(r.Context(), scope, domain.CourseTypeID(r.PathValue("id")), p.toReq()); err != nil {
		writeAdminError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleDeleteCourseType(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	if err := admin.DeleteCourseType(r.Context(), scope, domain.CourseTypeID(r.PathValue("id"))); err != nil {
		writeAdminError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ----- Competencies -----

func (s *Server) handleListCompetencies(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	out, err := admin.ListCompetencies(r.Context(), scope, domain.CourseTypeID(r.PathValue("id")))
	if err != nil {
		writeAdminError(w, err)
		return
	}
	rows := make([]map[string]any, 0, len(out))
	for _, c := range out {
		rows = append(rows, map[string]any{
			"id": c.ID, "courseTypeId": c.CourseTypeID, "label": c.Label, "sortOrder": c.SortOrder,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"competencies": rows})
}

func (s *Server) handleCreateCompetency(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		Label     string `json:"label"`
		SortOrder int    `json:"sortOrder"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	c, err := admin.CreateCompetency(r.Context(), scope, admin.CreateCompetencyRequest{
		CourseTypeID: domain.CourseTypeID(r.PathValue("id")),
		Label:        req.Label,
		SortOrder:    req.SortOrder,
	})
	if err != nil {
		writeAdminError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"id": c.ID, "courseTypeId": c.CourseTypeID, "label": c.Label, "sortOrder": c.SortOrder,
	})
}

func (s *Server) handleDeleteCompetency(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	if err := admin.DeleteCompetency(r.Context(), scope, domain.CompetencyID(r.PathValue("compId"))); err != nil {
		writeAdminError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ----- Instructors -----

func instructorView(i admin.InstructorRow) map[string]any {
	accs := make([]map[string]any, 0, len(i.Accreditations))
	for _, a := range i.Accreditations {
		accs = append(accs, map[string]any{
			"courseTypeId": a.CourseTypeID,
			"expiresOn":    a.ExpiresOn,
		})
	}
	return map[string]any{
		"userId":           i.UserID,
		"name":             i.Name,
		"email":            i.Email,
		"phone":            i.Phone,
		"homeLocationId":   i.HomeLocationID,
		"homeLocationName": i.HomeLocationName,
		"accountStatus":    i.AccountStatus,
		"accreditations":   accs,
	}
}

func (s *Server) handleListInstructors(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	out, err := admin.ListInstructors(r.Context(), scope)
	if err != nil {
		writeAdminError(w, err)
		return
	}
	rows := make([]map[string]any, 0, len(out))
	for _, i := range out {
		rows = append(rows, instructorView(i))
	}
	writeJSON(w, http.StatusOK, map[string]any{"instructors": rows})
}

func (s *Server) handleInviteInstructor(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	if s.Firebase == nil {
		writeError(w, http.StatusServiceUnavailable, "firebase_disabled",
			"Firebase Auth is not configured on this server")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		Name           string `json:"name"`
		Email          string `json:"email"`
		Phone          string `json:"phone"`
		Password       string `json:"password"`
		HomeLocationID string `json:"homeLocationId"`
		Accreditations []struct {
			CourseTypeID string `json:"courseTypeId"`
			ExpiresOn    string `json:"expiresOn"`
		} `json:"accreditations"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	if len(req.Password) < 6 {
		// Firebase enforces ≥6; we surface a 400 early to avoid the
		// Firebase create call when we know it'll fail.
		writeError(w, http.StatusBadRequest, "invalid_input",
			"password must be at least 6 characters")
		return
	}

	// Pin the Firebase UID to the local user_id so the firebase_uid
	// column doubles as the join key.
	userID := domain.UserID(domain.NewID())
	email := strings.ToLower(strings.TrimSpace(req.Email))
	fbUser, err := s.Firebase.Auth.CreateUser(r.Context(), (&firebaseauth.UserToCreate{}).
		UID(string(userID)).
		Email(email).
		Password(req.Password).
		DisplayName(req.Name))
	if err != nil {
		// Most common failure: email already exists in Firebase. Surface
		// as 409 so the admin sees a clean message.
		if firebaseauth.IsEmailAlreadyExists(err) || firebaseauth.IsUIDAlreadyExists(err) {
			writeError(w, http.StatusConflict, "email_in_use", "email already in use")
			return
		}
		writeError(w, http.StatusBadGateway, "firebase_error", "could not create auth identity")
		return
	}

	accs := make([]admin.Accreditation, 0, len(req.Accreditations))
	for _, a := range req.Accreditations {
		if a.CourseTypeID == "" {
			continue
		}
		accs = append(accs, admin.Accreditation{
			CourseTypeID: domain.CourseTypeID(a.CourseTypeID),
			ExpiresOn:    a.ExpiresOn,
		})
	}
	i, err := admin.InviteInstructor(r.Context(), scope, admin.InviteInstructorRequest{
		UserID:         userID,
		FirebaseUID:    fbUser.UID,
		Name:           req.Name,
		Email:          email,
		Phone:          req.Phone,
		HomeLocationID: domain.LocationID(req.HomeLocationID),
		Accreditations: accs,
	})
	if err != nil {
		// Roll back the Firebase user so the email stays available.
		_ = s.Firebase.Auth.DeleteUser(r.Context(), fbUser.UID)
		writeAdminError(w, err)
		return
	}
	audit.Describe(r.Context(), "Invited instructor %s", req.Name)
	writeJSON(w, http.StatusCreated, instructorView(*i))
}

// POST /students — admin/owner manually adds a student (the alternative
// to self-signup). Mirrors handleInviteInstructor: create the Firebase
// identity first, write the local rows, and roll back the Firebase user
// if the local write fails so the email stays available for retry.
func (s *Server) handleCreateStudent(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	if s.Firebase == nil {
		writeError(w, http.StatusServiceUnavailable, "firebase_disabled",
			"Firebase Auth is not configured on this server")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		Name     string `json:"name"`
		Email    string `json:"email"`
		Phone    string `json:"phone"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	if len(req.Password) < 6 {
		writeError(w, http.StatusBadRequest, "invalid_input",
			"password must be at least 6 characters")
		return
	}

	userID := domain.UserID(domain.NewID())
	email := strings.ToLower(strings.TrimSpace(req.Email))
	fbUser, err := s.Firebase.Auth.CreateUser(r.Context(), (&firebaseauth.UserToCreate{}).
		UID(string(userID)).
		Email(email).
		Password(req.Password).
		DisplayName(req.Name))
	if err != nil {
		if firebaseauth.IsEmailAlreadyExists(err) || firebaseauth.IsUIDAlreadyExists(err) {
			writeError(w, http.StatusConflict, "email_in_use", "email already in use")
			return
		}
		writeError(w, http.StatusBadGateway, "firebase_error", "could not create auth identity")
		return
	}

	st, err := admin.CreateStudent(r.Context(), scope, admin.CreateStudentRequest{
		UserID:      userID,
		FirebaseUID: fbUser.UID,
		Name:        req.Name,
		Email:       email,
		Phone:       req.Phone,
	})
	if err != nil {
		_ = s.Firebase.Auth.DeleteUser(r.Context(), fbUser.UID)
		writeAdminError(w, err)
		return
	}
	audit.Describe(r.Context(), "Added student %s", st.Name)
	// Response shape matches one row of GET /students so the Flutter
	// client can append optimistically. Derived fields (balance,
	// completed bookings, safety flags) all start at zero for a fresh
	// student.
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":                     st.UserID,
		"name":                   st.Name,
		"email":                  st.Email,
		"phone":                  st.Phone,
		"accountStatus":          st.AccountStatus,
		"licenceCategoryPursued": "",
		"transmissionPreference": "",
		"stage":                  "Pre-CBT",
		"balancePence":           0,
		"completedBookings":      0,
		"safetyFlagCount":        0,
		"hasSafetyFlag":          false,
		"passed":                 false,
	})
}

func (s *Server) handleSetAccreditations(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		Accreditations []struct {
			CourseTypeID string `json:"courseTypeId"`
			ExpiresOn    string `json:"expiresOn"`
		} `json:"accreditations"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	accs := make([]admin.Accreditation, 0, len(req.Accreditations))
	for _, a := range req.Accreditations {
		if a.CourseTypeID == "" {
			continue
		}
		accs = append(accs, admin.Accreditation{
			CourseTypeID: domain.CourseTypeID(a.CourseTypeID),
			ExpiresOn:    a.ExpiresOn,
		})
	}
	if err := admin.SetAccreditations(r.Context(), scope,
		domain.UserID(r.PathValue("id")),
		admin.SetAccreditationsRequest{Accreditations: accs}); err != nil {
		writeAdminError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ----- School settings -----

func (s *Server) handleGetSchoolSettings(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	settings, err := admin.GetSchoolSettings(r.Context(), scope)
	if err != nil {
		writeAdminError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"name":                         settings.Name,
		"region":                       settings.Region,
		"testBodyLabel":                settings.TestBodyLabel,
		"onboardingMode":               settings.OnboardingMode,
		"instructorsCanRecordPayments": settings.InstructorsCanRecordPayments,
		"cancelCutoffHours":            settings.CancelCutoffHours,
		"travelBufferMinutes":          settings.TravelBufferMinutes,
		"crossSiteNoticeHours":         settings.CrossSiteNoticeHours,
		"motWarnDays":                  settings.MOTWarnDays,
		"motUrgentDays":                settings.MOTUrgentDays,
		"taxWarnDays":                  settings.TaxWarnDays,
		"taxUrgentDays":                settings.TaxUrgentDays,
		"accreditationWarnDays":        settings.AccreditationWarnDays,
		"accreditationUrgentDays":      settings.AccreditationUrgentDays,
		"insuranceWarnDays":            settings.InsuranceWarnDays,
		"insuranceUrgentDays":          settings.InsuranceUrgentDays,
	})
}

func (s *Server) handleUpdateSchoolSettings(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	// Pointer-fields so we can tell "missing" from "false/0".
	var req admin.UpdateSchoolSettingsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	if err := admin.UpdateSchoolSettings(r.Context(), scope, req); err != nil {
		writeAdminError(w, err)
		return
	}
	audit.Describe(r.Context(), "Updated school settings (%s)",
		schoolSettingsFieldsTouched(req))
	w.WriteHeader(http.StatusNoContent)
}

// schoolSettingsFieldsTouched lists the human names of the non-nil
// fields in a settings patch so the audit summary tells you WHAT was
// changed, not just THAT something was. Order matches the settings
// page UI so the sentence reads naturally to the owner.
func schoolSettingsFieldsTouched(r admin.UpdateSchoolSettingsRequest) string {
	parts := []string{}
	if r.Name != nil {
		parts = append(parts, "name")
	}
	if r.OnboardingMode != nil {
		parts = append(parts, "onboarding mode")
	}
	if r.InstructorsCanRecordPayments != nil {
		parts = append(parts, "instructor payments toggle")
	}
	if r.CancelCutoffHours != nil {
		parts = append(parts, "cancel cutoff")
	}
	if r.TravelBufferMinutes != nil {
		parts = append(parts, "travel buffer")
	}
	if r.CrossSiteNoticeHours != nil {
		parts = append(parts, "cross-site notice")
	}
	if r.TestBodyLabel != nil {
		parts = append(parts, "test body label")
	}
	if r.MOTWarnDays != nil || r.MOTUrgentDays != nil {
		parts = append(parts, "MOT thresholds")
	}
	if r.TaxWarnDays != nil || r.TaxUrgentDays != nil {
		parts = append(parts, "tax thresholds")
	}
	if r.AccreditationWarnDays != nil || r.AccreditationUrgentDays != nil {
		parts = append(parts, "accreditation thresholds")
	}
	if r.InsuranceWarnDays != nil || r.InsuranceUrgentDays != nil {
		parts = append(parts, "insurance thresholds")
	}
	if len(parts) == 0 {
		return "no changes"
	}
	return strings.Join(parts, ", ")
}
