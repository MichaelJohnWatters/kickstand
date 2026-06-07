package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/michaeljohnwatters/kickstand/internal/admin"
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
	rows := make([]map[string]any, 0, len(out))
	for _, l := range out {
		rows = append(rows, map[string]any{
			"id":      l.ID,
			"name":    l.Name,
			"address": l.Address,
		})
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
	writeJSON(w, http.StatusCreated, bikeRowView(*b))
}

func (s *Server) handleUpdateBike(w http.ResponseWriter, r *http.Request) {
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
		EngineCC       int    `json:"engineCc"`
		HomeLocationID string `json:"homeLocationId"`
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
	if err := admin.MoveBike(r.Context(), scope,
		domain.BikeID(r.PathValue("id")),
		domain.LocationID(req.LocationId)); err != nil {
		writeAdminError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleRestoreBike(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	if err := admin.RestoreBike(r.Context(), scope, domain.BikeID(r.PathValue("id"))); err != nil {
		writeAdminError(w, err)
		return
	}
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
	return map[string]any{
		"userId":             i.UserID,
		"name":               i.Name,
		"email":              i.Email,
		"phone":              i.Phone,
		"homeLocationId":     i.HomeLocationID,
		"homeLocationName":   i.HomeLocationName,
		"accountStatus":      i.AccountStatus,
		"qualifiedCourseIds": i.QualifiedCourseIDs,
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
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		Name               string   `json:"name"`
		Email              string   `json:"email"`
		Phone              string   `json:"phone"`
		Password           string   `json:"password"`
		HomeLocationID     string   `json:"homeLocationId"`
		QualifiedCourseIDs []string `json:"qualifiedCourseIds"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	courses := make([]domain.CourseTypeID, 0, len(req.QualifiedCourseIDs))
	for _, c := range req.QualifiedCourseIDs {
		courses = append(courses, domain.CourseTypeID(c))
	}
	i, err := admin.InviteInstructor(r.Context(), scope, admin.InviteInstructorRequest{
		Name:               req.Name,
		Email:              req.Email,
		Phone:              req.Phone,
		Password:           req.Password,
		HomeLocationID:     domain.LocationID(req.HomeLocationID),
		QualifiedCourseIDs: courses,
	})
	if err != nil {
		writeAdminError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, instructorView(*i))
}

func (s *Server) handleSetQualifications(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		CourseTypeIDs []string `json:"courseTypeIds"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	courses := make([]domain.CourseTypeID, 0, len(req.CourseTypeIDs))
	for _, c := range req.CourseTypeIDs {
		courses = append(courses, domain.CourseTypeID(c))
	}
	if err := admin.SetQualifications(r.Context(), scope,
		domain.UserID(r.PathValue("id")),
		admin.SetQualificationsRequest{CourseTypeIDs: courses}); err != nil {
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
	w.WriteHeader(http.StatusNoContent)
}
