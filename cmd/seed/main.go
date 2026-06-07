// Command seed creates kickstand.db (if missing), runs migrations, and
// inserts the Lagan Valley Rider Training demo tenant — Northern Ireland,
// Belfast / Lisburn / Newry — matching the design prototype.
//
// Idempotent: re-runs detect existing rows by deterministic IDs and skip.
package main

import (
	"context"
	"database/sql"
	"flag"
	"fmt"
	"log"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/db"
	"golang.org/x/crypto/bcrypt"
)

func main() {
	dsn := flag.String("dsn", "kickstand.db", "SQLite database path")
	flag.Parse()

	if err := run(*dsn); err != nil {
		log.Fatal(err)
	}
}

func run(dsn string) error {
	d, err := db.Open(dsn)
	if err != nil {
		return fmt.Errorf("open: %w", err)
	}
	defer d.Close()

	ctx := context.Background()
	if err := db.Migrate(ctx, d); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}

	if err := seedLaganValley(ctx, d); err != nil {
		return fmt.Errorf("seed: %w", err)
	}
	fmt.Println("seeded Lagan Valley Rider Training into", dsn)
	return nil
}

// seedLaganValley fills the demo tenant. IDs are deterministic strings so
// re-running is a no-op (INSERT OR IGNORE).
func seedLaganValley(ctx context.Context, d *sql.DB) error {
	const (
		schoolID = "school_lagan"

		locBelfast = "loc_belfast"
		locLisburn = "loc_lisburn"
		locNewry   = "loc_newry"

		// Instructors
		instrDave  = "user_instr_dave"
		instrPriya = "user_instr_priya"
		instrAoife = "user_instr_aoife"

		// Course types — CBT pair (125 + 650) for the entry-level licences,
		// then Practice + Test for both MOD 1 (off-road slow control) and
		// MOD 2 (on-road). MOD 1/MOD 2 naming matches DVSA convention and
		// the school's modern marketing copy.
		ctCBT125   = "ct_cbt_125"
		ctCBT650   = "ct_cbt_650"
		ctPracMod1 = "ct_prac_mod1"
		ctPracMod2 = "ct_prac_mod2"
		ctTestMod1 = "ct_test_mod1"
		ctTestMod2 = "ct_test_mod2"

		// Bikes
		bikeA1Manual1 = "bike_a1_manual_1"
		bikeA1Manual2 = "bike_a1_manual_2"
		bikeA1Auto1   = "bike_a1_auto_1"
		bikeA2Manual1 = "bike_a2_manual_1"
		bikeA2Manual2 = "bike_a2_manual_2"
		bikeA2Manual3 = "bike_a2_manual_3" // second Honda CB500F — sits at Newry for logistics demo
		bikeAManual1  = "bike_a_manual_1"

		// Students
		studentAlex   = "user_student_alex"
		studentMaeve  = "user_student_maeve"
		studentRowan  = "user_student_rowan" // pending-approval to exercise that state
		studentCarlos = "user_student_carlos"
		studentNiamh  = "user_student_niamh"  // disruption demo: already swapped
		studentRyan   = "user_student_ryan"   // disruption demo: no suitable bike free
		studentEmma   = "user_student_emma"   // logistics demo: Belfast → Lisburn move
		studentJordan = "user_student_jordan" // logistics demo: Newry → Belfast move (AM)
		studentMark   = "user_student_mark"   // logistics demo: Newry → Belfast move (PM)
		studentLucy   = "user_student_lucy"   // alumni: passed Test MOD 2 — exercises the Passed filter

		// Sessions
		sessionCBTBelfast       = "sess_cbt_belfast"
		sessionCBTBelfastPM     = "sess_cbt_belfast_pm"       // sister CBT — disruption swapped + no-swap states
		sessionPractical        = "sess_practical_lisburn"
		sessionCBTLisburnFull   = "sess_cbt_lisburn_full"     // capacity-full demo
		sessionTestDayNewry     = "sess_test_day_newry"       // test-day variant
		sessionCBTPastBelfast   = "sess_cbt_past_belfast"     // Alex's completed CBT
		sessionPracPastLisburn  = "sess_prac_past_lisburn"    // Maeve's completed practical
		sessionCBTAlexCancelled = "sess_cbt_past_cancelled"   // Alex cancelled in past
		sessionTodayMorning     = "sess_today_morning"        // earlier today (completed)
		sessionTodayAfternoon   = "sess_today_afternoon"      // today PM (live / scheduled)
		sessionTodayDaveLisburn = "sess_today_dave_lisburn"   // creates the tight-travel warning
		// Tomorrow logistics demo — one bike moves into each destination site
		sessionCBTLisburnAM  = "sess_cbt_lisburn_am"  // Lexmoto Echo, Belfast → Lisburn
		sessionPracBelfastAM = "sess_prac_belfast_am" // Honda CB500F OEZ 6634, Newry → Belfast
		sessionPracBelfastPM = "sess_prac_belfast_pm" // Honda CB500F OEZ 6633, Newry → Belfast
	)

	now := time.Now().UTC()
	createdAt := now.Format(time.RFC3339)

	// Tomorrow 09:00–13:00 for CBT, Friday for practical, etc. Tied to "now"
	// so the engine considers them future bookings.
	cbtStart := nextMorning(now).Format(time.RFC3339)
	cbtEnd := nextMorning(now).Add(4 * time.Hour).Format(time.RFC3339)
	pracStart := nextMorning(now).Add(48 * time.Hour).Format(time.RFC3339)
	pracEnd := nextMorning(now).Add(48 * time.Hour).Add(2 * time.Hour).Format(time.RFC3339)

	// Additional future-session times.
	cbtFullStart := nextMorning(now).Add(5 * time.Hour).Format(time.RFC3339)             // tomorrow 14:00
	cbtFullEnd := nextMorning(now).Add(9 * time.Hour).Format(time.RFC3339)               // tomorrow 18:00
	testDayStart := nextMorning(now).Add(5 * 24 * time.Hour).Format(time.RFC3339)        // +6 days 09:00
	testDayEnd := nextMorning(now).Add(5*24*time.Hour + 90*time.Minute).Format(time.RFC3339)

	// Tomorrow's "disruption demo" and "logistics demo" sessions.
	// Belfast PM CBT carries Niamh's already-swapped row and Ryan's no-bike-free
	// row. Lisburn AM + Belfast AM/PM Practicals drive the 3 logistics moves.
	belfastPMStart := nextMorning(now).Add(5 * time.Hour).Format(time.RFC3339)          // 14:00
	belfastPMEnd := nextMorning(now).Add(9 * time.Hour).Format(time.RFC3339)            // 18:00
	lisburnAMStart := nextMorning(now).Add(-30 * time.Minute).Format(time.RFC3339)      // 08:30
	lisburnAMEnd := nextMorning(now).Add(3*time.Hour + 30*time.Minute).Format(time.RFC3339) // 12:30
	pracBelfastAMStart := nextMorning(now).Format(time.RFC3339)                        // 09:00
	pracBelfastAMEnd := nextMorning(now).Add(4 * time.Hour).Format(time.RFC3339)        // 13:00
	pracBelfastPMStart := nextMorning(now).Add(4*time.Hour + 30*time.Minute).Format(time.RFC3339) // 13:30
	pracBelfastPMEnd := nextMorning(now).Add(8*time.Hour + 30*time.Minute).Format(time.RFC3339)   // 17:30

	// Today-anchored session times: keep the demo populated for *today*
	// regardless of when the seed runs. The morning slot always ends up
	// "completed" (08:00 has passed by the time anyone's running the
	// demo), the afternoon slot is "scheduled" if seeded before its end,
	// "completed" otherwise. Status is decided at seed time so the
	// engine's "session not started" check stays honest.
	todayAt := func(h, m int) time.Time {
		return time.Date(now.Year(), now.Month(), now.Day(), h, m, 0, 0, time.UTC)
	}
	todayMorningStart := todayAt(8, 0)
	todayMorningEnd := todayAt(12, 0)
	todayAfternoonStart := todayAt(14, 0)
	todayAfternoonEnd := todayAt(18, 0)
	// Dave's Lisburn session today: starts only 30 min after his Belfast
	// morning ends. With Belfast↔Lisburn = 25 min and a 15 min buffer
	// (=40 min needed), the calendar's travel-warning logic surfaces this
	// as "tight travel" — matches the design's banner copy.
	todayDaveLisburnStart := todayAt(12, 30)
	todayDaveLisburnEnd := todayAt(14, 30)
	statusByEnd := func(end time.Time) string {
		if now.After(end) {
			return "completed"
		}
		return "scheduled"
	}
	todayMorningStatus := "completed" // 08:00 in the past for any sensible demo hour
	todayAfternoonStatus := statusByEnd(todayAfternoonEnd)
	todayDaveLisburnStatus := statusByEnd(todayDaveLisburnEnd)

	// Past-session times: anchored 7 / 14 days back, also at 09:00 UTC.
	pastDay := func(d int) time.Time {
		anchor := now.Add(-time.Duration(d) * 24 * time.Hour)
		return time.Date(anchor.Year(), anchor.Month(), anchor.Day(), 9, 0, 0, 0, time.UTC)
	}
	cbtPastStart := pastDay(7).Format(time.RFC3339)
	cbtPastEnd := pastDay(7).Add(4 * time.Hour).Format(time.RFC3339)
	pracPastStart := pastDay(10).Format(time.RFC3339)
	pracPastEnd := pastDay(10).Add(2 * time.Hour).Format(time.RFC3339)
	cancelledPastStart := pastDay(14).Format(time.RFC3339)
	cancelledPastEnd := pastDay(14).Add(4 * time.Hour).Format(time.RFC3339)

	pw, err := bcrypt.GenerateFromPassword([]byte("password"), bcrypt.DefaultCost)
	if err != nil {
		return fmt.Errorf("hash password: %w", err)
	}
	pwHash := string(pw)

	exec := func(q string, args ...any) error {
		_, err := d.ExecContext(ctx, q, args...)
		return err
	}

	steps := []func() error{
		// School
		func() error {
			return exec(`INSERT OR IGNORE INTO schools
				(id, name, region, test_body_label, onboarding_mode,
				 instructors_can_record_payments, cancel_cutoff_hours,
				 travel_buffer_minutes, cross_site_notice_hours, created_at)
				VALUES (?, 'Lagan Valley Rider Training', 'NI', 'DVA', 'approval', 1, 48, 15, 12, ?)`,
				schoolID, createdAt)
		},
		// Locations
		func() error {
			for _, l := range []struct{ id, name string }{
				{locBelfast, "Belfast"},
				{locLisburn, "Lisburn"},
				{locNewry, "Newry"},
			} {
				if err := exec(`INSERT OR IGNORE INTO locations (id, school_id, name, created_at) VALUES (?, ?, ?, ?)`,
					l.id, schoolID, l.name, createdAt); err != nil {
					return err
				}
			}
			return nil
		},
		// Travel-time matrix (illustrative). One row per ordered pair.
		func() error {
			for _, t := range []struct {
				from, to string
				mins     int
			}{
				{locBelfast, locLisburn, 25},
				{locLisburn, locBelfast, 25},
				{locBelfast, locNewry, 60},
				{locNewry, locBelfast, 60},
				{locLisburn, locNewry, 50},
				{locNewry, locLisburn, 50},
			} {
				if err := exec(`INSERT OR IGNORE INTO travel_times
					(school_id, from_location_id, to_location_id, minutes)
					VALUES (?, ?, ?, ?)`, schoolID, t.from, t.to, t.mins); err != nil {
					return err
				}
			}
			return nil
		},
		// Instructors (users + profiles)
		func() error {
			for _, u := range []struct {
				id, email, name, home string
			}{
				{instrDave, "dave@lagan.test", "Dave Mitchell", locBelfast},
				{instrPriya, "priya@lagan.test", "Priya Patel", locLisburn},
				{instrAoife, "aoife@lagan.test", "Aoife McGrath", locBelfast},
			} {
				if err := exec(`INSERT OR IGNORE INTO users
					(id, school_id, email, password_hash, name, role, account_status, created_at)
					VALUES (?, ?, ?, ?, ?, 'instructor', 'active', ?)`,
					u.id, schoolID, u.email, pwHash, u.name, createdAt); err != nil {
					return err
				}
				if err := exec(`INSERT OR IGNORE INTO instructor_profiles
					(user_id, school_id, home_location_id) VALUES (?, ?, ?)`,
					u.id, schoolID, u.home); err != nil {
					return err
				}
			}
			return nil
		},
		// Owner (admin role) — lets us log into the admin web app.
		func() error {
			return exec(`INSERT OR IGNORE INTO users
				(id, school_id, email, password_hash, name, role, account_status, created_at)
				VALUES ('user_owen','school_lagan','owen@lagan.test',?,'Owen O''Neill','owner','active',?)`,
				pwHash, createdAt)
		},
		// Course types — NI pathway. price_pence and durations are illustrative.
		// accent_colour is what the school configured in the editor; UI falls
		// back to a code-hashed colour when this is empty.
		func() error {
			courses := []struct {
				id, code, name, region, cat, accent string
				duration, ratio, price              int
				nonTeaching                         int
			}{
				{ctCBT125,   "CBT-125",   "CBT 125",        "NI", "A1", "#6366F1", 240, 4, 13000, 0},
				{ctCBT650,   "CBT-650",   "CBT 650",        "NI", "A2", "#9333EA", 240, 4, 15000, 0},
				{ctPracMod1, "PRAC-MOD1", "Practice MOD 1", "NI", "A2", "#0EA5E9", 120, 1, 9000, 0},
				{ctPracMod2, "PRAC-MOD2", "Practice MOD 2", "NI", "A2", "#1F9D6B", 120, 1, 9000, 0},
				{ctTestMod1, "TEST-MOD1", "Test MOD 1",     "NI", "A2", "#F59E0B", 90, 1, 6000, 1},
				{ctTestMod2, "TEST-MOD2", "Test MOD 2",     "NI", "A2", "#C98A1E", 90, 1, 6000, 1},
			}
			for _, c := range courses {
				if err := exec(`INSERT OR IGNORE INTO course_types
					(id, school_id, code, name, region, required_bike_category,
					 duration_minutes, max_ratio, price_pence, non_teaching,
					 accent_colour, created_at)
					VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
					c.id, schoolID, c.code, c.name, c.region, c.cat,
					c.duration, c.ratio, c.price, c.nonTeaching,
					c.accent, createdAt); err != nil {
					return err
				}
				// Backfill so re-seeding picks up palette changes without
				// needing to wipe the DB.
				if err := exec(`UPDATE course_types SET accent_colour = ?
				    WHERE id = ? AND school_id = ?`,
					c.accent, c.id, schoolID); err != nil {
					return err
				}
			}
			return nil
		},
		// Instructor qualifications — varied so the slot list / calendar
		// surface real constraints. Dave teaches everything (the principal);
		// Priya doesn't escort Test MOD 2; Aoife is newer and only handles
		// CBT + Practice MOD 1/MOD 2.
		func() error {
			grants := []struct{ instr, course string }{
				{instrDave, ctCBT125},
				{instrDave, ctCBT650},
				{instrDave, ctPracMod1},
				{instrDave, ctPracMod2},
				{instrDave, ctTestMod1},
				{instrDave, ctTestMod2},
				{instrPriya, ctCBT125},
				{instrPriya, ctCBT650},
				{instrPriya, ctPracMod1},
				{instrPriya, ctPracMod2},
				{instrPriya, ctTestMod1},
				{instrAoife, ctCBT125},
				{instrAoife, ctCBT650},
				{instrAoife, ctPracMod1},
				{instrAoife, ctPracMod2},
			}
			for _, g := range grants {
				if err := exec(`INSERT OR IGNORE INTO instructor_qualifications
					(school_id, instructor_id, course_type_id) VALUES (?, ?, ?)`,
					schoolID, g.instr, g.course); err != nil {
					return err
				}
			}
			// Re-run housekeeping: prior seed versions qualified instructors
			// for the legacy CBT-600 / Practical / Test course types. Clear
			// any leftover rows so a re-seed isn't tripped up by them.
			for _, legacyID := range []string{"ct_cbt_500_650", "ct_cbt_600", "ct_practical", "ct_test_practical"} {
				if _, err := d.ExecContext(ctx, `DELETE FROM instructor_qualifications
					WHERE school_id = ? AND course_type_id = ?`,
					schoolID, legacyID); err != nil {
					return err
				}
			}
			return nil
		},
		// Bikes — real makes/models/regs so the booking flow's bike picker
		// reads like a real motorcycle school, not an inventory app. UK-style
		// registration plates per region (NI plates are 3 letters + 4 digits).
		func() error {
			bikes := []struct {
				id, cat, trans, status, home, current   string
				cc                                      int
				nickname, make, model, registration string
			}{
				{bikeA1Manual1, "A1", "manual", "ready", locBelfast, locBelfast, 125,
					"Honda CB125F", "Honda", "CB125F", "GKZ 4471"},
				{bikeA1Manual2, "A1", "manual", "ready", locBelfast, locBelfast, 125,
					"Yamaha YBR125", "Yamaha", "YBR125", "RKZ 8810"},
				{bikeA1Auto1, "A1", "auto", "ready", locBelfast, locBelfast, 125,
					"Lexmoto Echo", "Lexmoto", "Echo", "LXZ 2204"},
				{bikeA2Manual1, "A2", "manual", "ready", locLisburn, locLisburn, 650,
					"Kawasaki Z650", "Kawasaki", "Z650", "WGZ 1197"},
				// Lives at Newry tomorrow morning — feeds the Belfast-bound
				// logistics row for the 13:30 Practical.
				{bikeA2Manual2, "A2", "manual", "ready", locLisburn, locNewry, 500,
					"Honda CB500F", "Honda", "CB500F", "OEZ 6633"},
				// Second Honda CB500F — feeds the Belfast-bound logistics row for
				// the 09:00 Practical.
				{bikeA2Manual3, "A2", "manual", "ready", locNewry, locNewry, 500,
					"Honda CB500F", "Honda", "CB500F", "OEZ 6634"},
				{bikeAManual1, "A", "manual", "ready", locNewry, locNewry, 649,
					"Honda CB650R", "Honda", "CB650R", "TRZ 5540"},
			}
			for _, b := range bikes {
				// First-run insert (idempotent via OR IGNORE).
				if err := exec(`INSERT OR IGNORE INTO bikes
					(id, school_id, category, transmission, engine_cc, status,
					 home_location_id, current_location_id,
					 nickname, make, model, registration, created_at)
					VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
					b.id, schoolID, b.cat, b.trans, b.cc, b.status,
					b.home, b.current,
					b.nickname, b.make, b.model, b.registration,
					createdAt); err != nil {
					return err
				}
				// Backfill: earlier seed runs created bikes without the
				// detail columns. UPDATE keeps re-running cheap and lets us
				// refresh values when this seed is edited.
				if err := exec(`UPDATE bikes SET
				    nickname = ?, make = ?, model = ?, registration = ?, engine_cc = ?
				    WHERE id = ? AND school_id = ?`,
					b.nickname, b.make, b.model, b.registration, b.cc,
					b.id, schoolID); err != nil {
					return err
				}
			}
			return nil
		},
		// Students (Alex and Maeve active; Rowan pending-approval to exercise the gate)
		func() error {
			students := []struct {
				id, email, name, status, transmission, phone, signupNote string
				cbt, theory                                              int
			}{
				{studentAlex, "alex@test", "Alex Hughes", "active", "manual", "07700 900 142", "", 0, 0},
				{studentMaeve, "maeve@test", "Maeve O'Connor", "active", "manual", "07700 900 188", "", 1, 1},
				{studentRowan, "rowan@test", "Rowan Doyle", "pending_approval", "manual",
					"07700 900 215", "", 0, 0},
				{studentCarlos, "carlos@test", "Carlos Reyes", "active", "manual", "07700 900 233", "", 1, 0},
				// Disruption-demo students: Niamh's row is already swapped; Ryan's
				// is pending with no free swap candidate.
				{studentNiamh, "niamh@test", "Niamh Quinn", "active", "manual", "07700 900 301", "", 0, 0},
				{studentRyan, "ryan@test", "Ryan Carson", "active", "manual", "07700 900 312", "", 1, 1},
				// Logistics-demo students: each rides a cross-site bike tomorrow.
				{studentEmma, "emma@test", "Emma Wilson", "active", "auto", "07700 900 325", "", 0, 0},
				{studentJordan, "jordan@test", "Jordan Reid", "active", "manual", "07700 900 336", "", 1, 1},
				{studentMark, "mark@test", "Mark Doherty", "active", "manual", "07700 900 347", "", 1, 1},
				// Alumni — finished training last month. Exercises the Students
				// page's "Passed" filter (default Active view hides her).
				{studentLucy, "lucy@test", "Lucy Boyd", "active", "manual", "07700 900 358", "", 1, 1},
				// Two more pending sign-ups so the admin signup queue shows real volume.
				{"user_student_sophie", "sophie@test", "Sophie Hart", "pending_approval", "manual",
					"07700 900 245",
					"Wants CBT asap — turns 17 next week.", 0, 0},
				{"user_student_conor", "conor@test", "Conor Magee", "pending_approval", "manual",
					"07700 900 267",
					"Returning rider, full car licence. Last on a bike ~10 years ago.", 0, 0},
			}
			for _, s := range students {
				if err := exec(`INSERT OR IGNORE INTO users
					(id, school_id, email, password_hash, name, role, account_status, created_at)
					VALUES (?, ?, ?, ?, ?, 'student', ?, ?)`,
					s.id, schoolID, s.email, pwHash, s.name, s.status, createdAt); err != nil {
					return err
				}
				if err := exec(`INSERT OR IGNORE INTO student_profiles
					(user_id, school_id, transmission_preference,
					 cbt_certificate_held, theory_passed, licence_category_pursued)
					VALUES (?, ?, ?, ?, ?, 'A2')`,
					s.id, schoolID, s.transmission, s.cbt, s.theory); err != nil {
					return err
				}
				// Backfill phone on users (may be empty on first insert) +
				// signup_note on student_profiles. UPDATE is idempotent.
				if err := exec(`UPDATE users SET phone = ?
				    WHERE id = ? AND school_id = ?`,
					s.phone, s.id, schoolID); err != nil {
					return err
				}
				if err := exec(`UPDATE student_profiles SET signup_note = ?
				    WHERE user_id = ? AND school_id = ?`,
					s.signupNote, s.id, schoolID); err != nil {
					return err
				}
			}
			return nil
		},
		// Sessions — mix of future + past so admin/student screens have history.
		// Past sessions get status='completed' so the engine ignores them but UI
		// can still surface them in "Past" tabs and the student progress view.
		func() error {
			sessions := []struct {
				id, ct, instructor, location, starts, ends, status string
				capacity                                           int
			}{
				// Future
				{sessionCBTBelfast, ctCBT125, instrDave, locBelfast, cbtStart, cbtEnd, "scheduled", 4},
				{sessionPractical, ctPracMod2, instrPriya, locLisburn, pracStart, pracEnd, "scheduled", 1},
				{sessionCBTLisburnFull, ctCBT650, instrPriya, locLisburn, cbtFullStart, cbtFullEnd, "scheduled", 1},
				{sessionTestDayNewry, ctTestMod2, instrDave, locNewry, testDayStart, testDayEnd, "scheduled", 1},
				// Today (the calendar / overview always show live content)
				{sessionTodayMorning, ctCBT125, instrDave, locBelfast,
					todayMorningStart.Format(time.RFC3339),
					todayMorningEnd.Format(time.RFC3339),
					todayMorningStatus, 4},
				{sessionTodayAfternoon, ctPracMod2, instrPriya, locLisburn,
					todayAfternoonStart.Format(time.RFC3339),
					todayAfternoonEnd.Format(time.RFC3339),
					todayAfternoonStatus, 1},
				// Dave dashing to Lisburn — creates the tight-travel banner.
				{sessionTodayDaveLisburn, ctPracMod2, instrDave, locLisburn,
					todayDaveLisburnStart.Format(time.RFC3339),
					todayDaveLisburnEnd.Format(time.RFC3339),
					todayDaveLisburnStatus, 1},
				// Past (completed and one cancelled)
				{sessionCBTPastBelfast, ctCBT125, instrDave, locBelfast, cbtPastStart, cbtPastEnd, "completed", 4},
				{sessionPracPastLisburn, ctPracMod2, instrPriya, locLisburn, pracPastStart, pracPastEnd, "completed", 1},
				{sessionCBTAlexCancelled, ctCBT125, instrDave, locBelfast, cancelledPastStart, cancelledPastEnd, "scheduled", 4},
				// Tomorrow PM — Niamh (already-swapped) and Ryan (no-bike-free)
				// share this session; both originally booked on the offline YBR125.
				{sessionCBTBelfastPM, ctCBT125, instrDave, locBelfast, belfastPMStart, belfastPMEnd, "scheduled", 4},
				// Tomorrow logistics demo — three cross-site bookings.
				{sessionCBTLisburnAM, ctCBT125, instrPriya, locLisburn, lisburnAMStart, lisburnAMEnd, "scheduled", 2},
				{sessionPracBelfastAM, ctPracMod2, instrAoife, locBelfast, pracBelfastAMStart, pracBelfastAMEnd, "scheduled", 1},
				{sessionPracBelfastPM, ctPracMod2, instrAoife, locBelfast, pracBelfastPMStart, pracBelfastPMEnd, "scheduled", 1},
			}
			for _, s := range sessions {
				if err := exec(`INSERT OR IGNORE INTO sessions
					(id, school_id, course_type_id, instructor_id, location_id,
					 starts_at, ends_at, capacity, status, created_at)
					VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
					s.id, schoolID, s.ct, s.instructor, s.location,
					s.starts, s.ends, s.capacity, s.status, createdAt); err != nil {
					return err
				}
			}
			return nil
		},
		// Competencies (just for the practical course type — CBT in this demo
		// is taught but not graded on individual competencies).
		func() error {
			comps := []struct {
				id, label string
				order     int
			}{
				{"comp_prac_signal", "Use of signals & rear observation", 0},
				{"comp_prac_braking", "Smooth, controlled braking", 1},
				{"comp_prac_uturn", "U-turn / low-speed control", 2},
				{"comp_prac_emerg", "Emergency stop", 3},
				{"comp_prac_obs", "Observation at junctions", 4},
				{"comp_prac_lane", "Lane positioning & filtering", 5},
			}
			for _, c := range comps {
				if err := exec(`INSERT OR IGNORE INTO competencies
					(id, school_id, course_type_id, label, sort_order)
					VALUES (?, ?, ?, ?, ?)`,
					c.id, schoolID, ctPracMod2, c.label, c.order); err != nil {
					return err
				}
			}
			return nil
		},
		// Course prerequisites — advisory only, so the engine surfaces a
		// banner but doesn't gate booking.
		func() error {
			prereqs := []struct{ ct, kind string }{
				{ctPracMod1, "cbt_held"},
				{ctPracMod2, "cbt_held"},
				{ctPracMod2, "theory_passed"},
				{ctTestMod1, "cbt_held"},
				{ctTestMod1, "theory_passed"},
				{ctTestMod2, "cbt_held"},
				{ctTestMod2, "theory_passed"},
			}
			for _, p := range prereqs {
				if err := exec(`INSERT OR IGNORE INTO course_prerequisites
					(school_id, course_type_id, prereq_kind)
					VALUES (?, ?, ?)`, schoolID, p.ct, p.kind); err != nil {
					return err
				}
			}
			return nil
		},
		// Bookings — future + completed past + one cancelled past.
		// Note: bk_alex_disrupted starts as 'booked' here; the disruption step
		// below flips it to 'needs_reassignment'.
		func() error {
			bookings := []struct {
				id, session, student, bike, status, cancelledBy, reason string
				cancelledAt                                             string // empty = NULL
			}{
				// Future
				{"bk_alex_disrupted", sessionCBTBelfast, studentAlex, bikeA1Manual2, "booked", "", "", ""},
				{"bk_maeve_practical", sessionPractical, studentMaeve, bikeA2Manual1, "booked", "", "", ""},
				// Carlos rides the Kawasaki Z650 (already at Lisburn) — keeps the
				// logistics demo to the 3 cross-site moves we want to surface.
				{"bk_carlos_cbt_full", sessionCBTLisburnFull, studentCarlos, bikeA2Manual1, "booked", "", "", ""},
				{"bk_maeve_testday", sessionTestDayNewry, studentMaeve, bikeAManual1, "booked", "", "", ""},
				// Disruption demo bookings (both originally booked onto the offline
				// YBR125 — Niamh gets swapped to the Honda CB125F, Ryan stays
				// pending because no A1 is free at this slot).
				{"bk_niamh_disrupted", sessionCBTBelfastPM, studentNiamh, bikeA1Manual1, "booked", "", "", ""},
				{"bk_ryan_disrupted", sessionCBTBelfastPM, studentRyan, bikeA1Manual2, "booked", "", "", ""},
				// Logistics demo bookings (rides cross-site bikes tomorrow).
				{"bk_emma_lisburn_am", sessionCBTLisburnAM, studentEmma, bikeA1Auto1, "booked", "", "", ""},
				{"bk_jordan_belfast_am", sessionPracBelfastAM, studentJordan, bikeA2Manual3, "booked", "", "", ""},
				{"bk_mark_belfast_pm", sessionPracBelfastPM, studentMark, bikeA2Manual2, "booked", "", "", ""},
				// Today — morning CBT (Alex), afternoon practical (Maeve).
				// Booking status mirrors the session's: completed sessions
				// get completed bookings; scheduled sessions stay 'booked'.
				{"bk_alex_today_cbt", sessionTodayMorning, studentAlex, bikeA1Manual1,
					todayMorningStatus, "", "", ""},
				{"bk_maeve_today_prac", sessionTodayAfternoon, studentMaeve, bikeA2Manual1,
					func() string {
						if todayAfternoonStatus == "completed" {
							return "completed"
						}
						return "booked"
					}(), "", "", ""},
				// Past completed
				{"bk_alex_past_cbt", sessionCBTPastBelfast, studentAlex, bikeA1Manual1, "completed", "", "", ""},
				{"bk_maeve_past_prac", sessionPracPastLisburn, studentMaeve, bikeA2Manual1, "completed", "", "", ""},
				// Past cancelled — student got cold feet before first CBT
				{"bk_alex_cancelled", sessionCBTAlexCancelled, studentAlex, "", "cancelled", "student", "Got cold feet — will rebook next month", pastDay(15).Format(time.RFC3339)},
			}
			for _, b := range bookings {
				var bikeArg any = nil
				if b.bike != "" {
					bikeArg = b.bike
				}
				var cancelledByArg, reasonArg, cancelledAtArg any = nil, nil, nil
				if b.cancelledBy != "" {
					cancelledByArg = b.cancelledBy
				}
				if b.reason != "" {
					reasonArg = b.reason
				}
				if b.cancelledAt != "" {
					cancelledAtArg = b.cancelledAt
				}
				if err := exec(`INSERT OR IGNORE INTO bookings
					(id, school_id, session_id, student_id, bike_id, status,
					 cancelled_by, cancellation_reason, created_at, cancelled_at)
					VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
					b.id, schoolID, b.session, b.student, bikeArg, b.status,
					cancelledByArg, reasonArg, createdAt, cancelledAtArg); err != nil {
					return err
				}
			}
			return nil
		},
		// Recorded competencies on Maeve's past practical — mixed outcomes
		// give the progress screen something interesting to show.
		func() error {
			recordedAt := pastDay(10).Add(2 * time.Hour).Format(time.RFC3339)
			recs := []struct{ id, comp, status string }{
				{"prog_maeve_signal", "comp_prac_signal", "competent"},
				{"prog_maeve_braking", "comp_prac_braking", "competent"},
				{"prog_maeve_uturn", "comp_prac_uturn", "developing"},
				{"prog_maeve_emerg", "comp_prac_emerg", "needs_work"},
			}
			for _, r := range recs {
				if err := exec(`INSERT OR IGNORE INTO progress_records
					(id, school_id, booking_id, student_id, competency_id,
					 status, recorded_at, recorded_by)
					VALUES (?, ?, 'bk_maeve_past_prac', ?, ?, ?, ?, ?)`,
					r.id, schoolID, studentMaeve, r.comp, r.status, recordedAt, instrPriya); err != nil {
					return err
				}
			}
			return nil
		},
		// Charges + payments — Alex has an outstanding balance, Maeve is paid up.
		func() error {
			// Alex: charge for past CBT (£130), part-paid £100 → £30 outstanding.
			if err := exec(`INSERT OR IGNORE INTO charges
				(id, school_id, student_id, booking_id, amount_pence,
				 description, incurred_at, created_at, created_by)
				VALUES ('chg_alex_cbt', ?, ?, 'bk_alex_past_cbt', 13000,
				        'CBT (125cc) — Belfast', ?, ?, 'user_owen')`,
				schoolID, studentAlex, cbtPastStart, cbtPastStart); err != nil {
				return err
			}
			if err := exec(`INSERT OR IGNORE INTO payments
				(id, school_id, student_id, amount_pence, method, received_at, recorded_by, notes)
				VALUES ('pay_alex_partial', ?, ?, 10000, 'cash', ?, 'user_owen',
				        'Cash deposit on the day')`,
				schoolID, studentAlex, cbtPastStart); err != nil {
				return err
			}
			// Maeve: charge for past practical (£90), fully paid.
			if err := exec(`INSERT OR IGNORE INTO charges
				(id, school_id, student_id, booking_id, amount_pence,
				 description, incurred_at, created_at, created_by)
				VALUES ('chg_maeve_prac', ?, ?, 'bk_maeve_past_prac', 9000,
				        'Practical training', ?, ?, 'user_owen')`,
				schoolID, studentMaeve, pracPastStart, pracPastStart); err != nil {
				return err
			}
			if err := exec(`INSERT OR IGNORE INTO payments
				(id, school_id, student_id, amount_pence, method, received_at, recorded_by, notes)
				VALUES ('pay_maeve_full', ?, ?, 9000, 'bank_transfer', ?, 'user_owen', '')`,
				schoolID, studentMaeve, pracPastStart); err != nil {
				return err
			}
			return nil
		},
		// Staff notes — one safety flag (Maeve), one progress note (Alex).
		func() error {
			notes := []struct {
				id, student, kind, body string
			}{
				{"note_maeve_safety", studentMaeve, "safety_flag",
					"Wears prescription glasses — confirm spare set in helmet pouch before riding."},
				{"note_alex_progress", studentAlex, "progress_note",
					"Nervous at busy junctions — Dave to repeat observation drill on next session."},
			}
			for _, n := range notes {
				if err := exec(`INSERT OR IGNORE INTO student_notes
					(id, school_id, student_id, kind, body, is_active, created_at, created_by)
					VALUES (?, ?, ?, ?, ?, 1, ?, 'user_owen')`,
					n.id, schoolID, n.student, n.kind, n.body, createdAt); err != nil {
					return err
				}
			}
			return nil
		},
		// External tests — Maeve's theory pass + her booked DVA practical,
		// plus Lucy's full pass record (alumni demo data).
		func() error {
			if err := exec(`INSERT OR IGNORE INTO external_tests
				(id, school_id, student_id, test_type, region, attempt_number,
				 scheduled_at, reference, outcome, notes, created_at)
				VALUES ('ext_maeve_theory', ?, ?, 'theory', 'NI', 1, ?, 'DVA-NI-AAA111',
				        'pass', 'Passed first time', ?)`,
				schoolID, studentMaeve, pastDay(30).Format(time.RFC3339), pastDay(30).Format(time.RFC3339)); err != nil {
				return err
			}
			// Lucy passed her theory then her practical last month — she's
			// the school's most recent alumna.
			lucyRows := []struct {
				id, kind, ref, outcome string
				attempt                int
				when                   time.Time
			}{
				{"ext_lucy_theory", "theory", "DVA-NI-CCC333", "pass", 1, pastDay(60)},
				{"ext_lucy_mod1", "mod1", "DVSA-MOD1-001", "pass", 1, pastDay(40)},
				{"ext_lucy_mod2", "mod2", "DVSA-MOD2-001", "pass", 1, pastDay(20)},
			}
			for _, t := range lucyRows {
				if err := exec(`INSERT OR IGNORE INTO external_tests
					(id, school_id, student_id, test_type, region, attempt_number,
					 scheduled_at, reference, outcome, notes, created_at)
					VALUES (?, ?, ?, ?, 'NI', ?, ?, ?, ?, '', ?)`,
					t.id, schoolID, studentLucy, t.kind, t.attempt,
					t.when.Format(time.RFC3339), t.ref, t.outcome, createdAt); err != nil {
					return err
				}
			}
			if err := exec(`INSERT OR IGNORE INTO external_tests
				(id, school_id, student_id, test_type, region, attempt_number,
				 scheduled_at, reference, outcome, notes, created_at)
				VALUES ('ext_maeve_practical', ?, ?, 'practical', 'NI', 1, ?, 'DVA-NI-BBB222',
				        'booked', '', ?)`,
				schoolID, studentMaeve, testDayStart, createdAt); err != nil {
				return err
			}
			return nil
		},
		// Incident — minor drop on Maeve's past practical, no injury.
		func() error {
			return exec(`INSERT OR IGNORE INTO incidents
				(id, school_id, bike_id, student_id, booking_id, occurred_at,
				 description, took_bike_offline, created_at, created_by)
				VALUES ('inc_maeve_drop', ?, ?, ?, 'bk_maeve_past_prac', ?,
				        'Low-speed drop in car park during U-turn practice. No injury, bike inspected and returned to service.',
				        0, ?, ?)`,
				schoolID, bikeA2Manual1, studentMaeve,
				pastDay(10).Add(time.Hour).Format(time.RFC3339), createdAt, instrPriya)
		},
		// Bike disruption — clutch issue on A1 Manual #2. Affects Alex's
		// upcoming CBT (which was auto-assigned to that bike). Flips the
		// booking to needs_reassignment so admin / student screens light up.
		func() error {
			// Take bike offline.
			if err := exec(`UPDATE bikes SET status = 'offline'
				WHERE id = ? AND school_id = ?`, bikeA1Manual2, schoolID); err != nil {
				return err
			}
			// Open-ended unavailability window. `reason` is an enum code; the
			// human-readable explanation goes in `notes`.
			if err := exec(`INSERT OR IGNORE INTO bike_unavailability
				(id, school_id, bike_id, reason, starts_at, ends_at, notes, created_at, created_by)
				VALUES ('unav_a1m2', ?, ?, 'mechanic', ?, ?, 'Clutch slipping — awaiting parts', ?, 'user_owen')`,
				schoolID, bikeA1Manual2, createdAt,
				now.Add(30*24*time.Hour).Format(time.RFC3339), createdAt); err != nil {
				return err
			}
			// Disruption record.
			if err := exec(`INSERT OR IGNORE INTO disruptions
				(id, school_id, bike_id, started_at, reason, created_by)
				VALUES ('disr_a1m2', ?, ?, ?, 'Clutch slipping — awaiting parts', 'user_owen')`,
				schoolID, bikeA1Manual2, createdAt); err != nil {
				return err
			}
			// Affected bookings — all three started on the broken YBR125:
			//  * Alex (CBT AM): pending → a free Honda CB125F gives a suggestion
			//  * Niamh (CBT PM): already swapped to the Honda CB125F (demo row
			//    for the "Swapped → bike" success state)
			//  * Ryan (CBT PM): pending → Honda is held by Niamh in this slot
			//    and the only other A1 is offline / auto, so no candidate
			//    surfaces — exercises the "Approve cancellation" fallback.
			resolvedAt := now.Add(-15 * time.Minute).Format(time.RFC3339)
			affected := []struct {
				bookingID, resolution, newBikeID, resolvedAt string
			}{
				{"bk_alex_disrupted", "pending", "", ""},
				{"bk_niamh_disrupted", "swapped", bikeA1Manual1, resolvedAt},
				{"bk_ryan_disrupted", "pending", "", ""},
			}
			for _, a := range affected {
				var newBikeArg, resolvedArg any
				if a.newBikeID != "" {
					newBikeArg = a.newBikeID
				}
				if a.resolvedAt != "" {
					resolvedArg = a.resolvedAt
				}
				if err := exec(`INSERT OR IGNORE INTO disruption_affected_bookings
					(school_id, disruption_id, booking_id, resolution, new_bike_id, resolved_at)
					VALUES (?, 'disr_a1m2', ?, ?, ?, ?)`,
					schoolID, a.bookingID, a.resolution, newBikeArg, resolvedArg); err != nil {
					return err
				}
			}
			// Flip the pending bookings to needs_reassignment. Niamh stays
			// 'booked' because her swap has already been applied (bike_id is
			// the Honda above).
			for _, bID := range []string{"bk_alex_disrupted", "bk_ryan_disrupted"} {
				if err := exec(`UPDATE bookings SET status = 'needs_reassignment'
					WHERE id = ? AND school_id = ?`, bID, schoolID); err != nil {
					return err
				}
			}
			return nil
		},
		// Instructor pay model + earnings + payments — gives the Instructor Pay
		// screen a non-empty hero ("£X outstanding") and per-instructor stats.
		func() error {
			// Dave: 50% percentage model. rate_value = 5000 basis points.
			if err := exec(`INSERT OR IGNORE INTO instructor_pay_models
				(id, school_id, instructor_id, pay_basis, rate_value, created_at)
				VALUES ('paymdl_dave', ?, ?, 'percentage', 5000, ?)`,
				schoolID, instrDave, createdAt); err != nil {
				return err
			}
			// Priya: per-session at £40 (4000 pence).
			if err := exec(`INSERT OR IGNORE INTO instructor_pay_models
				(id, school_id, instructor_id, pay_basis, rate_value, created_at)
				VALUES ('paymdl_priya', ?, ?, 'per_session', 4000, ?)`,
				schoolID, instrPriya, createdAt); err != nil {
				return err
			}
			// Aoife: 45% percentage model (newer hire). No earnings yet —
			// they haven't taught a seeded session.
			if err := exec(`INSERT OR IGNORE INTO instructor_pay_models
				(id, school_id, instructor_id, pay_basis, rate_value, created_at)
				VALUES ('paymdl_aoife', ?, ?, 'percentage', 4500, ?)`,
				schoolID, instrAoife, createdAt); err != nil {
				return err
			}
			// Dave earned 50% of Alex's £130 CBT charge.
			if err := exec(`INSERT OR IGNORE INTO instructor_earnings
				(id, school_id, instructor_id, session_id, amount_pence,
				 basis, notes, created_at, created_by)
				VALUES ('earn_dave_cbt', ?, ?, ?, 6500, 'percentage', '50%% of CBT charge', ?, 'user_owen')`,
				schoolID, instrDave, sessionCBTPastBelfast, cbtPastStart); err != nil {
				return err
			}
			if err := exec(`INSERT OR IGNORE INTO instructor_earning_sources
				(school_id, earning_id, charge_id)
				VALUES (?, 'earn_dave_cbt', 'chg_alex_cbt')`, schoolID); err != nil {
				return err
			}
			// Partial payment to Dave — £40 of £65 → £25 still owed.
			if err := exec(`INSERT OR IGNORE INTO instructor_payments
				(id, school_id, instructor_id, amount_pence, method, paid_at, recorded_by, notes)
				VALUES ('paymt_dave_partial', ?, ?, 4000, 'bank_transfer', ?, 'user_owen', 'Weekly run')`,
				schoolID, instrDave, cbtPastStart); err != nil {
				return err
			}
			// Priya earned £40 for her past practical session, paid in full.
			if err := exec(`INSERT OR IGNORE INTO instructor_earnings
				(id, school_id, instructor_id, session_id, amount_pence,
				 basis, notes, created_at, created_by)
				VALUES ('earn_priya_prac', ?, ?, ?, 4000, 'per_session', '', ?, 'user_owen')`,
				schoolID, instrPriya, sessionPracPastLisburn, pracPastStart); err != nil {
				return err
			}
			if err := exec(`INSERT OR IGNORE INTO instructor_payments
				(id, school_id, instructor_id, amount_pence, method, paid_at, recorded_by, notes)
				VALUES ('paymt_priya_full', ?, ?, 4000, 'bank_transfer', ?, 'user_owen', '')`,
				schoolID, instrPriya, pracPastStart); err != nil {
				return err
			}
			return nil
		},
		// Recurring availability — gives the Instructor app's Availability
		// screen something to render.
		func() error {
			avail := []struct {
				id, instructor string
				weekday        int
				start, end     string
				location       string
			}{
				{"avail_dave_mon", instrDave, 1, "09:00", "17:00", locBelfast},
				{"avail_dave_tue", instrDave, 2, "09:00", "17:00", locBelfast},
				{"avail_dave_wed", instrDave, 3, "09:00", "17:00", locBelfast},
				{"avail_dave_thu", instrDave, 4, "09:00", "17:00", locBelfast},
				{"avail_dave_fri", instrDave, 5, "09:00", "17:00", locBelfast},
				{"avail_priya_tue", instrPriya, 2, "10:00", "18:00", locLisburn},
				{"avail_priya_wed", instrPriya, 3, "10:00", "18:00", locLisburn},
				{"avail_priya_thu", instrPriya, 4, "10:00", "18:00", locLisburn},
				{"avail_priya_fri", instrPriya, 5, "10:00", "18:00", locLisburn},
				{"avail_priya_sat", instrPriya, 6, "09:00", "15:00", locLisburn},
				{"avail_aoife_mon", instrAoife, 1, "09:30", "16:30", locBelfast},
				{"avail_aoife_tue", instrAoife, 2, "09:30", "16:30", locBelfast},
				{"avail_aoife_wed", instrAoife, 3, "09:30", "16:30", locBelfast},
				{"avail_aoife_sat", instrAoife, 6, "09:00", "13:00", locBelfast},
			}
			for _, a := range avail {
				if err := exec(`INSERT OR IGNORE INTO instructor_recurring_availability
					(id, school_id, instructor_id, weekday, starts_at_local, ends_at_local, location_id)
					VALUES (?, ?, ?, ?, ?, ?, ?)`,
					a.id, schoolID, a.instructor, a.weekday, a.start, a.end, a.location); err != nil {
					return err
				}
			}
			// Dave on holiday in two weeks.
			return exec(`INSERT OR IGNORE INTO instructor_time_off
				(id, school_id, instructor_id, starts_at, ends_at, reason)
				VALUES ('off_dave_hols', ?, ?, ?, ?, 'Family holiday')`,
				schoolID, instrDave,
				now.Add(14*24*time.Hour).Format(time.RFC3339),
				now.Add(19*24*time.Hour).Format(time.RFC3339))
		},
		// Reimbursement categories — owner-curated list, defaults match the
		// design palette. Schools can edit them via the admin Reimbursements
		// page later.
		func() error {
			cats := []struct {
				id, label, icon string
				tone            int
			}{
				{"petrol", "Petrol", "fuel", 25},
				{"lunch", "Lunch", "cap", 70},
				{"parking", "Parking", "pin", 277},
				{"tolls", "Tolls", "route", 160},
				{"other", "Other", "more-h", 200},
			}
			for i, c := range cats {
				if err := exec(`INSERT OR IGNORE INTO expense_categories
					(school_id, id, label, icon, tone, active, sort_order, created_at)
					VALUES (?, ?, ?, ?, ?, 1, ?, ?)`,
					schoolID, c.id, c.label, c.icon, c.tone, i, createdAt); err != nil {
					return err
				}
			}
			return nil
		},
		// Instructor expenses — one of each status so the admin queue + the
		// instructor's list both have realistic data.
		func() error {
			type ex struct {
				id, instr, cat       string
				amount               int
				occurred, submitted  time.Time
				where, notes, status string
				reviewer, note       string
				reviewedAt           time.Time
				paid                 time.Time
				paidMethod           string
			}
			today := time.Date(now.Year(), now.Month(), now.Day(), 8, 14, 0, 0, time.UTC)
			yest := today.AddDate(0, 0, -1)
			rows := []ex{
				{"exp_dave_petrol_pending", instrDave, "petrol", 4250, today, today, "Esso · Sydenham", "Topped up for the week ahead", "pending", "", "", time.Time{}, time.Time{}, ""},
				{"exp_dave_parking_pending", instrDave, "parking", 600, yest, yest, "Newry test centre", "DVA visitor parking", "pending", "", "", time.Time{}, time.Time{}, ""},
				{"exp_dave_lunch_approved", instrDave, "lunch", 950, pastDay(3), pastDay(3), "Boucher caff", "", "approved", "user_owen", "OK once — keep within sensible limits.", pastDay(3).Add(4 * time.Hour), time.Time{}, ""},
				{"exp_dave_petrol_reimbursed", instrDave, "petrol", 3800, pastDay(8), pastDay(8), "Esso · Sydenham", "", "reimbursed", "user_owen", "", pastDay(8).Add(4 * time.Hour), pastDay(5), "bank"},
				{"exp_dave_lunch_rejected", instrDave, "lunch", 1250, pastDay(11), pastDay(11), "Nando's", "Treated student to lunch", "rejected", "user_owen", "Outside policy — instructor meals only, not students.", pastDay(10), time.Time{}, ""},
				{"exp_aoife_petrol_pending", "user_instr_aoife", "petrol", 3640, today, today, "BP · Lisburn", "", "pending", "", "", time.Time{}, time.Time{}, ""},
				{"exp_priya_tolls_pending", instrPriya, "tolls", 250, today, today, "Foyle Bridge", "", "pending", "", "", time.Time{}, time.Time{}, ""},
			}
			for _, e := range rows {
				key := fmt.Sprintf("expenses/%s/receipt.jpg", e.id)
				var reviewedBy, reviewedAt, reviewerNote, paidAt, paidMethod, paidBy any
				if e.reviewer != "" {
					reviewedBy = e.reviewer
					reviewedAt = e.reviewedAt.Format(time.RFC3339)
				}
				if e.note != "" {
					reviewerNote = e.note
				}
				if !e.paid.IsZero() {
					paidAt = e.paid.Format(time.RFC3339)
					paidMethod = e.paidMethod
					paidBy = e.reviewer
				}
				if err := exec(`INSERT OR IGNORE INTO expenses
					(id, school_id, instructor_id, category_id, amount_pence,
					 occurred_at, where_, notes, status,
					 receipt_storage_key, receipt_content_type, receipt_size_bytes,
					 submitted_at, reviewed_by, reviewed_at, reviewer_note,
					 paid_at, paid_method, paid_by)
					VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'image/jpeg', 102400, ?, ?, ?, ?, ?, ?, ?)`,
					e.id, schoolID, e.instr, e.cat, e.amount,
					e.occurred.Format(time.RFC3339), nullStr(e.where), nullStr(e.notes), e.status,
					key,
					e.submitted.Format(time.RFC3339), reviewedBy, reviewedAt, reviewerNote,
					paidAt, paidMethod, paidBy); err != nil {
					return err
				}
			}
			return nil
		},
	}

	for i, step := range steps {
		if err := step(); err != nil {
			return fmt.Errorf("step %d: %w", i, err)
		}
	}
	return nil
}

// nextMorning returns the next calendar day at 09:00 UTC. Keeps the seeded
// sessions "in the future" relative to whenever the seed runs.
// nullStr maps empty string → nil so we get a real SQL NULL in TEXT columns
// (rather than the literal empty string).
func nullStr(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func nextMorning(from time.Time) time.Time {
	tomorrow := from.Add(24 * time.Hour)
	return time.Date(tomorrow.Year(), tomorrow.Month(), tomorrow.Day(), 9, 0, 0, 0, time.UTC)
}
