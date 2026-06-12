package booking

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// DisruptionRow is one disruption + all the context the admin "Disruptions"
// screen needs in a single round-trip.
type DisruptionRow struct {
	ID               domain.DisruptionID
	BikeID           domain.BikeID
	BikeNickname     string
	BikeRegistration string
	Reason           string
	StartedAt        time.Time
	ResolvedAt       time.Time // zero if still open
	ReportedByName   string             // who created the disruption record
	LocationID       domain.LocationID  // bike's current location at list-time
	LocationName     string
	Affected         []AffectedBookingRow
}

// AffectedBookingRow extends the AffectedBooking from take-offline with the
// current resolution and student/course info for display.
type AffectedBookingRow struct {
	BookingID       domain.BookingID
	SessionID       domain.SessionID
	CourseName      string
	SessionStartsAt time.Time
	SessionEndsAt   time.Time
	StudentID       domain.UserID
	StudentName     string
	LocationID      domain.LocationID
	LocationName    string
	Resolution      string // 'pending' | 'swapped' | 'cancel_with_approval' | 'cancelled'
	NewBikeID       domain.BikeID
	NewBikeNickname string
	ResolvedAt      time.Time
	SwapCandidates  []SwapCandidate // populated for 'pending' only
}

// ListDisruptions returns rows for the disruptions screen.
//
// When openOnly is true (default for the admin sidebar badge) we omit any
// disruption whose every affected booking is resolved AND whose own
// resolved_at is set. With openOnly=false we return everything for an
// audit-style view.
func ListDisruptions(ctx context.Context, scope *tenant.Scope, openOnly bool) ([]DisruptionRow, error) {
	const dq = `
		SELECT d.id, d.bike_id, COALESCE(b.nickname, ''), COALESCE(b.registration, ''),
		       d.reason, d.started_at, COALESCE(d.resolved_at, ''),
		       COALESCE(u.name, ''),
		       COALESCE(b.current_location_id, ''), COALESCE(l.name, '')
		FROM disruptions d
		LEFT JOIN bikes b     ON b.id = d.bike_id            AND b.school_id = d.school_id
		LEFT JOIN users u     ON u.id = d.created_by         AND u.school_id = d.school_id
		LEFT JOIN locations l ON l.id = b.current_location_id AND l.school_id = b.school_id
		WHERE d.school_id = ?
		ORDER BY d.started_at DESC
	`
	rows, err := scope.Conn().QueryContext(ctx, dq, string(scope.SchoolID()))
	if err != nil {
		return nil, fmt.Errorf("list disruptions: %w", err)
	}
	defer rows.Close()

	var out []DisruptionRow
	for rows.Next() {
		var (
			r                       DisruptionRow
			startedStr, resolvedStr string
		)
		if err := rows.Scan(&r.ID, &r.BikeID, &r.BikeNickname, &r.BikeRegistration,
			&r.Reason, &startedStr, &resolvedStr,
			&r.ReportedByName, &r.LocationID, &r.LocationName); err != nil {
			return nil, err
		}
		r.StartedAt, _ = parseTime(startedStr)
		if resolvedStr != "" {
			r.ResolvedAt, _ = parseTime(resolvedStr)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Load affected per disruption (separate query each — N is small and the
	// admin list is paginated by recent date if it ever grows).
	for i := range out {
		ab, err := loadAffectedForDisruption(ctx, scope, out[i].ID)
		if err != nil {
			return nil, err
		}
		out[i].Affected = ab
	}

	if openOnly {
		filtered := out[:0]
		for _, r := range out {
			if r.ResolvedAt.IsZero() && hasPending(r.Affected) {
				filtered = append(filtered, r)
			} else if r.ResolvedAt.IsZero() && len(r.Affected) == 0 {
				// Bike-down with nobody affected — keep visible until admin
				// restores the bike. Common case for proactive maintenance.
				filtered = append(filtered, r)
			}
		}
		out = filtered
	}
	return out, nil
}

func hasPending(ab []AffectedBookingRow) bool {
	for _, r := range ab {
		if r.Resolution == "pending" {
			return true
		}
	}
	return false
}

func loadAffectedForDisruption(ctx context.Context, scope *tenant.Scope, disruptionID domain.DisruptionID) ([]AffectedBookingRow, error) {
	const q = `
		SELECT dab.booking_id, dab.resolution,
		       COALESCE(dab.new_bike_id, ''),
		       COALESCE(nb.nickname, ''),
		       COALESCE(dab.resolved_at, ''),
		       b.session_id, b.student_id, COALESCE(u.name, ''),
		       s.starts_at, s.ends_at,
		       s.location_id, COALESCE(l.name, ''),
		       COALESCE(ct.name, ''),
		       COALESCE(ct.required_bike_category, ''),
		       COALESCE(sp.transmission_preference, '')
		FROM disruption_affected_bookings dab
		JOIN bookings b      ON b.id = dab.booking_id AND b.school_id = dab.school_id
		JOIN sessions s      ON s.id = b.session_id    AND s.school_id = b.school_id
		JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		LEFT JOIN users u    ON u.id = b.student_id     AND u.school_id = b.school_id
		LEFT JOIN locations l ON l.id = s.location_id   AND l.school_id = s.school_id
		LEFT JOIN bikes nb   ON nb.id = dab.new_bike_id AND nb.school_id = dab.school_id
		LEFT JOIN student_profiles sp ON sp.user_id = b.student_id AND sp.school_id = b.school_id
		WHERE dab.school_id = ? AND dab.disruption_id = ?
		ORDER BY s.starts_at ASC
	`
	rows, err := scope.Conn().QueryContext(ctx, q, string(scope.SchoolID()), string(disruptionID))
	if err != nil {
		return nil, fmt.Errorf("load affected: %w", err)
	}
	defer rows.Close()

	type withFilter struct {
		row              AffectedBookingRow
		requiredCategory string
		transmissionPref string
	}
	var collected []withFilter
	for rows.Next() {
		var (
			wf                  withFilter
			startsStr, endsStr  string
			resolvedStr         string
		)
		if err := rows.Scan(
			&wf.row.BookingID, &wf.row.Resolution,
			&wf.row.NewBikeID, &wf.row.NewBikeNickname,
			&resolvedStr,
			&wf.row.SessionID, &wf.row.StudentID, &wf.row.StudentName,
			&startsStr, &endsStr,
			&wf.row.LocationID, &wf.row.LocationName,
			&wf.row.CourseName,
			&wf.requiredCategory, &wf.transmissionPref,
		); err != nil {
			return nil, err
		}
		wf.row.SessionStartsAt, _ = parseTime(startsStr)
		wf.row.SessionEndsAt, _ = parseTime(endsStr)
		if resolvedStr != "" {
			wf.row.ResolvedAt, _ = parseTime(resolvedStr)
		}
		collected = append(collected, wf)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Compute live swap candidates for any still-pending affected booking.
	wantBikes := map[domain.BikeID]struct{}{}
	for i, wf := range collected {
		if wf.row.Resolution != "pending" {
			continue
		}
		sess := &sessionRow{
			id:                   wf.row.SessionID,
			startsAt:             wf.row.SessionStartsAt,
			endsAt:               wf.row.SessionEndsAt,
			locationID:           wf.row.LocationID,
			requiredBikeCategory: wf.requiredCategory,
		}
		bikes, err := findSuitableFreeBikes(ctx, scope, sess, wf.transmissionPref)
		if err != nil {
			return nil, fmt.Errorf("swap candidates: %w", err)
		}
		for _, b := range bikes {
			collected[i].row.SwapCandidates = append(collected[i].row.SwapCandidates, SwapCandidate{
				BikeID:            b.id,
				CurrentLocationID: b.currentLocationID,
				IsCrossSite:       b.currentLocationID != wf.row.LocationID,
			})
			wantBikes[b.id] = struct{}{}
		}
	}

	// Hydrate nickname + registration for every candidate bike. The design's
	// "Suggested swap" line shows the human-friendly name + reg, not the ID.
	if len(wantBikes) > 0 {
		nicks, regs, err := lookupBikeLabels(ctx, scope, wantBikes)
		if err != nil {
			return nil, fmt.Errorf("hydrate candidate bikes: %w", err)
		}
		// Travel-time matrix — small (≤ N² for N locations), loaded
		// once and reused for every candidate. Lookup misses (e.g. a
		// school hasn't filled the cell) yield 0, which the UI treats
		// as "unknown" rather than rendering a misleading number.
		travel, err := loadTravelMatrix(ctx, scope)
		if err != nil {
			return nil, fmt.Errorf("hydrate travel matrix: %w", err)
		}
		// School-wide travel buffer (added to the raw drive time when
		// judging back-to-back feasibility). Falls back to 15 min if
		// the column wasn't set up — same default the calendar's
		// tight-travel banner uses.
		bufferMins, err := loadTravelBuffer(ctx, scope)
		if err != nil {
			return nil, fmt.Errorf("load travel buffer: %w", err)
		}
		// Pass 1: compute tight-from-prior, accumulating every location
		// id we'll need a human name for (candidates' current locations
		// AND prior-session locations).
		type priorInfo struct {
			endsAt time.Time
			locID  domain.LocationID
		}
		// indexed by (affected-index, candidate-index)
		priors := map[[2]int]priorInfo{}
		wantLocs := map[domain.LocationID]struct{}{}
		for i := range collected {
			toLoc := collected[i].row.LocationID
			targetStart := collected[i].row.SessionStartsAt
			for j, sc := range collected[i].row.SwapCandidates {
				if sc.CurrentLocationID != "" {
					wantLocs[sc.CurrentLocationID] = struct{}{}
				}
				priorEnd, priorLoc, ok, err := findPriorBookingForBike(
					ctx, scope, sc.BikeID, targetStart)
				if err != nil {
					return nil, fmt.Errorf("prior-session lookup: %w", err)
				}
				if !ok {
					continue
				}
				travelMins := 0
				if priorLoc != toLoc {
					travelMins = travel[travelKey{from: priorLoc, to: toLoc}]
				}
				available := int(targetStart.Sub(priorEnd).Minutes())
				if available < travelMins+bufferMins {
					priors[[2]int{i, j}] = priorInfo{
						endsAt: priorEnd, locID: priorLoc,
					}
					wantLocs[priorLoc] = struct{}{}
				}
			}
		}
		locNames, err := lookupLocationNames(ctx, scope, wantLocs)
		if err != nil {
			return nil, fmt.Errorf("hydrate candidate locations: %w", err)
		}
		// Pass 2: apply everything to the candidates.
		for i := range collected {
			toLoc := collected[i].row.LocationID
			for j, sc := range collected[i].row.SwapCandidates {
				collected[i].row.SwapCandidates[j].BikeNickname = nicks[sc.BikeID]
				collected[i].row.SwapCandidates[j].BikeRegistration = regs[sc.BikeID]
				collected[i].row.SwapCandidates[j].CurrentLocationName =
					locNames[sc.CurrentLocationID]
				if sc.IsCrossSite {
					collected[i].row.SwapCandidates[j].TravelMinutes =
						travel[travelKey{from: sc.CurrentLocationID, to: toLoc}]
				}
				if p, ok := priors[[2]int{i, j}]; ok {
					collected[i].row.SwapCandidates[j].TightFromPrior = true
					collected[i].row.SwapCandidates[j].PriorSessionEndsAt = p.endsAt
					collected[i].row.SwapCandidates[j].PriorSessionLocation =
						locNames[p.locID]
				}
			}
		}
	}

	out := make([]AffectedBookingRow, len(collected))
	for i, wf := range collected {
		out[i] = wf.row
	}
	return out, nil
}

// travelKey is the (from, to) pair we key the school's travel-time
// matrix by. We load the matrix into memory once per request rather
// than running a query per swap candidate.
type travelKey struct {
	from, to domain.LocationID
}

// loadTravelBuffer reads the school's configured buffer minutes — the
// padding added on top of raw drive time when judging back-to-back
// feasibility. Defaults to 15 if the column isn't populated.
func loadTravelBuffer(ctx context.Context, scope *tenant.Scope) (int, error) {
	var mins int
	err := scope.Conn().QueryRowContext(ctx,
		`SELECT COALESCE(travel_buffer_minutes, 15) FROM schools WHERE id = ?`,
		string(scope.SchoolID())).Scan(&mins)
	if errors.Is(err, sql.ErrNoRows) || mins <= 0 {
		return 15, nil
	}
	return mins, err
}

// findPriorBookingForBike looks up the candidate bike's most recent
// booking ending strictly before `before`. Returns (ends_at, location_id,
// true) when one exists; (zero, "", false) when the bike has no prior
// commitment in the window. Only active bookings count — cancelled and
// no-show rows are skipped (they don't physically tie up the bike).
func findPriorBookingForBike(ctx context.Context, scope *tenant.Scope, bikeID domain.BikeID, before time.Time) (time.Time, domain.LocationID, bool, error) {
	var endsStr, locID string
	err := scope.Conn().QueryRowContext(ctx, `
		SELECT s.ends_at, s.location_id
		FROM bookings b
		JOIN sessions s ON s.id = b.session_id AND s.school_id = b.school_id
		WHERE b.school_id = ? AND b.bike_id = ?
		  AND b.status IN ('booked', 'needs_reassignment', 'completed')
		  AND s.ends_at < ?
		ORDER BY s.ends_at DESC
		LIMIT 1
	`, string(scope.SchoolID()), string(bikeID),
		before.UTC().Format(time.RFC3339)).
		Scan(&endsStr, &locID)
	if errors.Is(err, sql.ErrNoRows) {
		return time.Time{}, "", false, nil
	}
	if err != nil {
		return time.Time{}, "", false, err
	}
	ends, perr := parseTime(endsStr)
	if perr != nil {
		return time.Time{}, "", false, perr
	}
	return ends, domain.LocationID(locID), true, nil
}

func loadTravelMatrix(ctx context.Context, scope *tenant.Scope) (map[travelKey]int, error) {
	rows, err := scope.Conn().QueryContext(ctx,
		`SELECT from_location_id, to_location_id, minutes
		   FROM travel_times WHERE school_id = ?`,
		string(scope.SchoolID()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[travelKey]int{}
	for rows.Next() {
		var f, t string
		var m int
		if err := rows.Scan(&f, &t, &m); err != nil {
			return nil, err
		}
		out[travelKey{from: domain.LocationID(f), to: domain.LocationID(t)}] = m
	}
	return out, rows.Err()
}

// lookupLocationNames returns a location-id → name map. Mirrors
// lookupBikeLabels — single SELECT, N is small.
func lookupLocationNames(ctx context.Context, scope *tenant.Scope, ids map[domain.LocationID]struct{}) (map[domain.LocationID]string, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	args := []any{string(scope.SchoolID())}
	placeholders := make([]byte, 0, len(ids)*2)
	for id := range ids {
		if len(placeholders) > 0 {
			placeholders = append(placeholders, ',')
		}
		placeholders = append(placeholders, '?')
		args = append(args, string(id))
	}
	q := "SELECT id, COALESCE(name,'') FROM locations WHERE school_id = ? AND id IN (" + string(placeholders) + ")"
	rows, err := scope.Conn().QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[domain.LocationID]string{}
	for rows.Next() {
		var id, name string
		if err := rows.Scan(&id, &name); err != nil {
			return nil, err
		}
		out[domain.LocationID(id)] = name
	}
	return out, rows.Err()
}

// lookupBikeLabels returns nickname + registration maps for the given bike IDs.
// Single SELECT — N is small (candidates for a few affected bookings).
func lookupBikeLabels(ctx context.Context, scope *tenant.Scope, ids map[domain.BikeID]struct{}) (map[domain.BikeID]string, map[domain.BikeID]string, error) {
	if len(ids) == 0 {
		return nil, nil, nil
	}
	args := []any{string(scope.SchoolID())}
	placeholders := make([]byte, 0, len(ids)*2)
	for id := range ids {
		if len(placeholders) > 0 {
			placeholders = append(placeholders, ',')
		}
		placeholders = append(placeholders, '?')
		args = append(args, string(id))
	}
	q := "SELECT id, COALESCE(nickname,''), COALESCE(registration,'') FROM bikes WHERE school_id = ? AND id IN (" + string(placeholders) + ")"
	rows, err := scope.Conn().QueryContext(ctx, q, args...)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	nicks := map[domain.BikeID]string{}
	regs := map[domain.BikeID]string{}
	for rows.Next() {
		var id, nick, reg string
		if err := rows.Scan(&id, &nick, &reg); err != nil {
			return nil, nil, err
		}
		nicks[domain.BikeID(id)] = nick
		regs[domain.BikeID(id)] = reg
	}
	return nicks, regs, rows.Err()
}
