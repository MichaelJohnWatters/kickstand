package httpapi

import (
	"net/http"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/analytics"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// parseAnalyticsWindow reads the standard `from`+`to` query params
// every analytics endpoint takes. Missing → defaults from
// analytics.NewWindow (last 30 days). Bad values → 400.
func parseAnalyticsWindow(w http.ResponseWriter, r *http.Request) (analytics.Window, bool) {
	parse := func(s string) (time.Time, error) {
		if s == "" {
			return time.Time{}, nil
		}
		// Accept both YYYY-MM-DD and full RFC3339 for client convenience.
		if t, err := time.Parse("2006-01-02", s); err == nil {
			return t.UTC(), nil
		}
		return time.Parse(time.RFC3339, s)
	}
	from, err := parse(r.URL.Query().Get("from"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_from", err.Error())
		return analytics.Window{}, false
	}
	to, err := parse(r.URL.Query().Get("to"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_to", err.Error())
		return analytics.Window{}, false
	}
	return analytics.NewWindow(from, to), true
}

func (s *Server) handleAnalyticsBikeUtilisation(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	win, ok := parseAnalyticsWindow(w, r)
	if !ok {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	rows, err := analytics.BikeUtilisation(r.Context(), scope, win)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "analytics_failed", err.Error())
		return
	}
	out := make([]map[string]any, 0, len(rows))
	for _, r := range rows {
		out = append(out, map[string]any{
			"bikeId":           r.BikeID,
			"nickname":         r.Nickname,
			"registration":     r.Registration,
			"sessionsCount":    r.SessionsCount,
			"bookedMinutes":    r.BookedMinutes,
			"availableMinutes": r.AvailableMinutes,
			"utilisationPct":   r.UtilisationPct,
			"lastSessionAt":    r.LastSessionAt,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"bikes": out,
		"window": map[string]any{
			"from": win.From.Format(time.RFC3339),
			"to":   win.To.Format(time.RFC3339),
		},
	})
}

func (s *Server) handleAnalyticsInstructorUtilisation(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	win, ok := parseAnalyticsWindow(w, r)
	if !ok {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	rows, err := analytics.InstructorUtilisation(r.Context(), scope, win)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "analytics_failed", err.Error())
		return
	}
	out := make([]map[string]any, 0, len(rows))
	for _, r := range rows {
		out = append(out, map[string]any{
			"instructorId":     r.InstructorID,
			"name":             r.Name,
			"sessionsTaught":   r.SessionsTaught,
			"hoursTaughtX10":   r.HoursTaughtX10,
			"earnedPence":      r.EarnedPence,
			"paidPence":        r.PaidPence,
			"outstandingPence": r.OutstandingPence,
			"weeklyTrend":      r.WeeklyTrend,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"instructors": out,
		"window": map[string]any{
			"from": win.From.Format(time.RFC3339),
			"to":   win.To.Format(time.RFC3339),
		},
	})
}

func (s *Server) handleAnalyticsFunnel(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	win, ok := parseAnalyticsWindow(w, r)
	if !ok {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	fs, err := analytics.Funnel(r.Context(), scope, win)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "analytics_failed", err.Error())
		return
	}
	perInstr := make([]map[string]any, 0, len(fs.PerInstructorPassRate))
	for _, p := range fs.PerInstructorPassRate {
		perInstr = append(perInstr, map[string]any{
			"instructorId": p.InstructorID,
			"name":         p.Name,
			"attempts":     p.Attempts,
			"passes":       p.Passes,
			"passPct":      p.PassPct,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"signupToFirstBookingPct": fs.SignupToFirstBookingPct,
		"signupSample":            fs.SignupSample,
		"cbtCompletionPct":        fs.CBTCompletionPct,
		"cbtSample":               fs.CBTSample,
		"theoryPassPct":           fs.TheoryPassPct,
		"theorySample":            fs.TheorySample,
		"practicalPassPct":        fs.PracticalPassPct,
		"practicalSample":         fs.PracticalSample,
		"perInstructorPassRate":   perInstr,
		"window": map[string]any{
			"from": win.From.Format(time.RFC3339),
			"to":   win.To.Format(time.RFC3339),
		},
	})
}
