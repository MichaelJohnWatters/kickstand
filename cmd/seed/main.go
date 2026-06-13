// Command seed creates kickstand.db (if missing), runs migrations, and
// inserts the Lagan Valley Rider Training demo tenant — Northern Ireland,
// Belfast / Lisburn / Newry — matching the design prototype.
//
// Idempotent: re-runs detect existing rows by deterministic IDs and skip.
package main

import (
	"bytes"
	"context"
	"database/sql"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"log"
	"math"
	"strings"
	"time"

	firebaseauth "firebase.google.com/go/v4/auth"
	"golang.org/x/crypto/bcrypt"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/filestore"
	"github.com/michaeljohnwatters/kickstand/internal/media"
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

	// Mirror the server's Firebase wiring: if env vars are present we
	// create users in both places (Firebase emulator + local DB) with
	// the local user_id used as the Firebase UID. If not, only the
	// local DB rows get written; firebase_uid stays NULL until someone
	// re-seeds with the emulator running.
	fb, err := auth.NewFirebaseClient(ctx)
	if err != nil {
		return fmt.Errorf("firebase init: %w", err)
	}

	// Receipt blobs: same logic as the HTTP server — GCS-backed when
	// the storage env is configured, local-disk fallback otherwise.
	// Seeding into the wrong store is a UX papercut, not a correctness
	// issue (the modal will 404 until the right backend is wired), so
	// fail soft on init errors.
	var files filestore.Store
	if gcs, err := filestore.NewGCS(ctx); err == nil && gcs != nil {
		files = gcs
	} else {
		local, err := filestore.NewLocal("./uploads")
		if err != nil {
			return fmt.Errorf("filestore: %w", err)
		}
		files = local
	}

	applyDirect := func(events []Event, _ time.Time) error {
		runner := NewRunner("school_lagan")
		return runner.ApplyDirect(ctx, d, events)
	}
	if err := seedLaganValley(ctx, d, fb, files, applyDirect); err != nil {
		return fmt.Errorf("seed: %w", err)
	}
	suffix := "(local users only)"
	if fb != nil {
		suffix = "(also created in Firebase Auth)"
	}
	fmt.Println("seeded Lagan Valley Rider Training into", dsn, suffix)
	return nil
}

// seedLaganValley fills the demo tenant. IDs are deterministic strings so
// re-running is a no-op (INSERT OR IGNORE). When fb is non-nil, each
// seeded user is also created in Firebase Auth with UID == local user_id.
// `files` is used to upload synthetic receipt images so the
// reimbursement screens have visible thumbs + clickable receipts.
//
// applyEventLog is the hook the seed binary uses to run the event-log
// slice via the Direct path. The replay test passes nil here so it can
// run the same log through Engine paths on a parallel DB and diff.
func seedLaganValley(
	ctx context.Context,
	d *sql.DB,
	fb *auth.FirebaseClient,
	files filestore.Store,
	applyEventLog func(events []Event, now time.Time) error,
) error {
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
	// regardless of when the seed runs. Sessions stay 'scheduled' even
	// after their end time — that's how prod actually works (the only
	// engine transition for a session is scheduled → cancelled). UI
	// computes "is this session over?" from now > ends_at, not from a
	// status flip.
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
	// Today's booking statuses are now decided by the event log
	// (BookingEventLog reads `now` and only emits MarkAttendance for
	// today's afternoon when it's already over). The morning is
	// always over by any sensible demo time, so its no-show /
	// completed events fire unconditionally.

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

	// bikeExpenseEvents is populated by the bike-expenses prep step
	// below. Receipts are filestore-bound work (synth JPEG + upload),
	// so the prep stays in the seed binary; the resulting events
	// land on the event log alongside everything else.
	var bikeExpenseEvents []Event

	// lookupBookingID used to resolve booking ids for the
	// progress/charges/incidents/earnings steps before those moved to
	// the event log (where the Runner's bookingIDs map handles the
	// resolution). No remaining caller; helper removed.


	// seedAudit writes one synthetic audit row attributed to the
	// "owner" so the /admin/audit page has visible history on first
	// load. We attribute to user_owen by default with the school-name
	// shown as the actor — same shape the runtime middleware writes,
	// so the viewer can't tell apart "seeded" from "real".
	//
	// `at` controls when this action notionally happened; spreading
	// timestamps across the seed makes the audit page look like a
	// week of real activity instead of one big bulk insert.
	seedAudit := func(at time.Time, actorID, actorRole, actorName, method, pattern, entity, targetID, summary string, status int) error {
		return exec(`INSERT INTO audit_log
			(id, school_id, at, actor_user_id, actor_role, actor_name,
			 method, path_pattern, target_entity, target_id,
			 status_code, error_code, summary)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', ?)`,
			domain.NewID(), schoolID, at.UTC().Format(time.RFC3339),
			actorID, actorRole, actorName,
			method, pattern, entity, targetID, status, summary)
	}
	// Most seed audit rows are owen creating things during a chunky
	// setup session a week ago. Helper keeps the call sites short.
	audit := func(offsetMinutes int, method, pattern, entity, targetID, summary string, status int) error {
		at := now.AddDate(0, 0, -7).Add(time.Duration(offsetMinutes) * time.Minute)
		return seedAudit(at, "user_owen", "owner", "Owen O'Neill",
			method, pattern, entity, targetID, summary, status)
	}

	// createUser does both halves of seeding a single user: optional
	// Firebase create (UID pinned to the local user id for re-seed
	// idempotency) + INSERT INTO users (always). password_hash is left
	// populated so the legacy auth path still works for tests / dev
	// without the emulator running.
	createUser := func(id, email, name, role, status string) error {
		if fb != nil {
			_, err := fb.Auth.CreateUser(ctx, (&firebaseauth.UserToCreate{}).
				UID(id).
				Email(email).
				Password("password").
				DisplayName(name))
			// Re-seed lands here; Firebase keeps the user and we keep going.
			if err != nil && !strings.Contains(err.Error(), "ALREADY_EXISTS") {
				return fmt.Errorf("firebase create %s: %w", id, err)
			}
		}
		var fbUID any
		if fb != nil {
			fbUID = id
		}
		return exec(`INSERT OR IGNORE INTO users
			(id, school_id, email, password_hash, name, role, account_status, created_at, firebase_uid)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			id, schoolID, email, pwHash, name, role, status, createdAt, fbUID)
	}

	steps := []func() error{
		// School. `insurance_expires_on` deliberately lands in the
		// "due_soon" bucket (~55 days out) so the Compliance dashboard
		// has a visible amber row right after seeding — exercises the
		// warning UI without making the demo look broken.
		func() error {
			insuranceDate := now.AddDate(0, 0, 55).Format("2006-01-02")
			return exec(`INSERT OR IGNORE INTO schools
				(id, name, region, test_body_label, onboarding_mode,
				 instructors_can_record_payments, cancel_cutoff_hours,
				 travel_buffer_minutes, cross_site_notice_hours,
				 insurance_expires_on, created_at)
				VALUES (?, 'Lagan Valley Rider Training', 'NI', 'DVA', 'approval', 1, 48, 15, 12, ?, ?)`,
				schoolID, insuranceDate, createdAt)
		},
		// Locations — address fields are real public training-pad
		// addresses near each town so the "open in Google Maps" link
		// from the locations card lands somewhere sensible during demos.
		// Each row carries a synthetic ~300×120 banner image (different
		// hue per site) so the admin card header isn't a generic
		// placeholder.
		func() error {
			for _, l := range []struct {
				id, name, addr string
				hue            int
				lat, lng       float64
			}{
				{locBelfast, "Belfast", "Boucher Crescent, Belfast BT12 6HU", 215, 54.5825, -5.9655},
				{locLisburn, "Lisburn", "Knockmore Industrial Estate, Lisburn BT28 2EX", 145, 54.5188, -6.0640},
				{locNewry, "Newry", "Greenbank Industrial Estate, Newry BT34 2QU", 25, 54.1750, -6.3380},
			} {
				banner, err := makeLocationBanner(l.hue)
				if err != nil {
					return fmt.Errorf("location banner %s: %w", l.id, err)
				}
				if err := exec(`INSERT OR IGNORE INTO locations (id, school_id, name, address, image, lat, lng, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
					l.id, schoolID, l.name, l.addr, banner, l.lat, l.lng, createdAt); err != nil {
					return err
				}
				// Backfill lat/lng for runs that pre-date migration 0029
				// (INSERT OR IGNORE above skips when the row already exists).
				if err := exec(`UPDATE locations SET lat = ?, lng = ? WHERE id = ? AND school_id = ?`,
					l.lat, l.lng, l.id, schoolID); err != nil {
					return err
				}
				if err := audit(10, "POST", "/locations", "locations", l.id,
					fmt.Sprintf("Added location %s", l.name), 201); err != nil {
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
			// One audit row covers the matrix — it was a single setup
			// action in real terms.
			return audit(20, "PUT", "/travel-times", "travel-times", "",
				"Updated travel-time matrix across all sites", 204)
		},
		// Instructors (users + profiles). Per-course accreditation expiry
		// is set further down with the grants; the global column on
		// instructor_profiles was dropped in migration 0022.
		func() error {
			for _, u := range []struct {
				id, email, name, home string
			}{
				{instrDave, "dave@lagan.test", "Dave Mitchell", locBelfast},
				{instrPriya, "priya@lagan.test", "Priya Patel", locLisburn},
				{instrAoife, "aoife@lagan.test", "Aoife McGrath", locBelfast},
			} {
				if err := createUser(u.id, u.email, u.name, "instructor", "active"); err != nil {
					return err
				}
				if err := exec(`INSERT OR IGNORE INTO instructor_profiles
					(user_id, school_id, home_location_id)
					VALUES (?, ?, ?)`,
					u.id, schoolID, u.home); err != nil {
					return err
				}
				if err := audit(30, "POST", "/instructors", "instructors", u.id,
					fmt.Sprintf("Invited instructor %s", u.name), 201); err != nil {
					return err
				}
			}
			return nil
		},
		// Owner (admin role) — lets us log into the admin web app.
		func() error {
			return createUser("user_owen", "owen@lagan.test", "Owen O'Neill", "owner", "active")
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
				if err := audit(40, "POST", "/course-types", "course-types", c.id,
					fmt.Sprintf("Added course type %s (%s)", c.name, c.code), 201); err != nil {
					return err
				}
			}
			return nil
		},
		// Instructor accreditations — varied so the slot list / calendar
		// surface real constraints. Dave teaches everything (the principal);
		// Priya doesn't escort Test MOD 2; Aoife is newer and only handles
		// CBT + Practice MOD 1/MOD 2.
		//
		// Expiries are spread across all four severity buckets so the
		// Compliance dashboard shows variety on first load:
		//   - Dave  → 200 days out (OK)
		//   - Priya →  20 days out (urgent — exercises the red pill)
		//   - Aoife → empty        (unknown — exercises the "record it" prompt)
		func() error {
			daveExp := now.AddDate(0, 0, 200).Format("2006-01-02")
			priyaExp := now.AddDate(0, 0, 20).Format("2006-01-02")
			grants := []struct{ instr, course, expires string }{
				{instrDave, ctCBT125, daveExp},
				{instrDave, ctCBT650, daveExp},
				{instrDave, ctPracMod1, daveExp},
				{instrDave, ctPracMod2, daveExp},
				{instrDave, ctTestMod1, daveExp},
				{instrDave, ctTestMod2, daveExp},
				{instrPriya, ctCBT125, priyaExp},
				{instrPriya, ctCBT650, priyaExp},
				{instrPriya, ctPracMod1, priyaExp},
				{instrPriya, ctPracMod2, priyaExp},
				{instrPriya, ctTestMod1, priyaExp},
				{instrAoife, ctCBT125, ""},
				{instrAoife, ctCBT650, ""},
				{instrAoife, ctPracMod1, ""},
				{instrAoife, ctPracMod2, ""},
			}
			for _, g := range grants {
				if err := exec(`INSERT OR IGNORE INTO instructor_accreditations
					(school_id, instructor_id, course_type_id, expires_on)
					VALUES (?, ?, ?, NULLIF(?, ''))`,
					schoolID, g.instr, g.course, g.expires); err != nil {
					return err
				}
			}
			// Re-run housekeeping: prior seed versions qualified instructors
			// for the legacy CBT-600 / Practical / Test course types. Clear
			// any leftover rows so a re-seed isn't tripped up by them.
			for _, legacyID := range []string{"ct_cbt_500_650", "ct_cbt_600", "ct_practical", "ct_test_practical"} {
				if _, err := d.ExecContext(ctx, `DELETE FROM instructor_accreditations
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
		// motDays / taxDays are days-from-today the expiry sits so the
		// dev fleet demonstrates every warning bucket out of the box:
		// healthy, warn, urgent, expired, unknown.
		func() error {
			bikes := []struct {
				id, cat, trans, status, home, current string
				cc                                    int
				nickname, make, model, registration   string
				motDays, taxDays                      int // -1 = unknown
				mileage                               int // 0 = unknown
			}{
				// Healthy — both expiries far out.
				{bikeA1Manual1, "A1", "manual", "ready", locBelfast, locBelfast, 125,
					"Honda CB125F", "Honda", "CB125F", "GKZ 4471", 280, 240, 8420},
				// Warn — MOT due in 2 months, tax fine.
				{bikeA1Manual2, "A1", "manual", "ready", locBelfast, locBelfast, 125,
					"Yamaha YBR125", "Yamaha", "YBR125", "RKZ 8810", 60, 180, 11250},
				// Urgent — MOT in 10 days.
				{bikeA1Auto1, "A1", "auto", "ready", locBelfast, locBelfast, 125,
					"Lexmoto Echo", "Lexmoto", "Echo", "LXZ 2204", 10, 70, 6840},
				// Expired tax — MOT still healthy.
				{bikeA2Manual1, "A2", "manual", "ready", locLisburn, locLisburn, 650,
					"Kawasaki Z650", "Kawasaki", "Z650", "WGZ 1197", 200, -3, 14600},
				// Healthy — high mileage demo.
				{bikeA2Manual2, "A2", "manual", "ready", locLisburn, locNewry, 500,
					"Honda CB500F", "Honda", "CB500F", "OEZ 6633", 300, 320, 22480},
				// Tax urgent (5 days), MOT due-soon.
				{bikeA2Manual3, "A2", "manual", "ready", locNewry, locNewry, 500,
					"Honda CB500F", "Honda", "CB500F", "OEZ 6634", 55, 5, 19100},
				// Unknown state — both blank, no mileage. Newly imported bike.
				{bikeAManual1, "A", "manual", "ready", locNewry, locNewry, 649,
					"Honda CB650R", "Honda", "CB650R", "TRZ 5540", -1, -1, 0},
			}
			// Site centroids for GPS seeding — used to plant each bike on
			// the live-map screen near its current location with a small
			// per-bike offset. The scheduling/logistics engine never reads
			// these (plan §7); they only feed the manager map. Coords are
			// the ~industrial-estate centres for each site.
			siteCoords := map[string][2]float64{
				locBelfast: {54.5825, -5.9655},
				locLisburn: {54.5188, -6.0640},
				locNewry:   {54.1750, -6.3380},
			}
			// Deterministic jitter so bikes at the same site don't stack
			// on one pixel. Salt is the bike ID's checksum.
			jitter := func(id string, lat, lng float64) (float64, float64) {
				var sum int
				for _, c := range id {
					sum += int(c)
				}
				dLat := float64((sum%21)-10) / 1000.0 // ±0.010° ≈ ±1.1 km
				dLng := float64(((sum/21)%21)-10) / 1000.0
				return lat + dLat, lng + dLng
			}
			gpsTimestamp := now.UTC().Format(time.RFC3339)
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
				var motExpiry, taxExpiry any
				if b.motDays >= 0 {
					motExpiry = now.AddDate(0, 0, b.motDays).Format("2006-01-02")
				}
				if b.taxDays >= 0 {
					taxExpiry = now.AddDate(0, 0, b.taxDays).Format("2006-01-02")
				}
				var mileage any
				if b.mileage > 0 {
					mileage = b.mileage
				}
				// Last bike (Honda CB650R — "newly imported") stays without
				// a GPS fix so the live-map "No signal" panel demos.
				var gpsLat, gpsLng, gpsAt any
				if b.id != bikeAManual1 {
					base, ok := siteCoords[b.current]
					if ok {
						la, lo := jitter(b.id, base[0], base[1])
						gpsLat, gpsLng, gpsAt = la, lo, gpsTimestamp
					}
				}
				// Backfill: earlier seed runs created bikes without the
				// detail columns. UPDATE keeps re-running cheap and lets us
				// refresh values when this seed is edited.
				if err := exec(`UPDATE bikes SET
				    nickname = ?, make = ?, model = ?, registration = ?, engine_cc = ?,
				    mot_expires_on = ?, tax_expires_on = ?, current_mileage_miles = ?,
				    last_known_lat = ?, last_known_lng = ?, last_known_at = ?
				    WHERE id = ? AND school_id = ?`,
					b.nickname, b.make, b.model, b.registration, b.cc,
					motExpiry, taxExpiry, mileage,
					gpsLat, gpsLng, gpsAt,
					b.id, schoolID); err != nil {
					return err
				}
				bikeName := b.nickname
				if bikeName == "" {
					bikeName = strings.TrimSpace(b.make + " " + b.model)
				}
				if err := audit(50, "POST", "/bikes", "bikes", b.id,
					fmt.Sprintf("Added bike %s (%s)", bikeName, b.cat), 201); err != nil {
					return err
				}
				// Breadcrumb trail — six fixes walking outward from the
				// centroid over the last hour, so the live map shows a
				// short polyline when the operator taps the marker.
				// Skipped for the "no signal" bike that intentionally has
				// no snapshot, and for any bike without a centroid.
				if b.id == bikeAManual1 {
					continue
				}
				base, ok := siteCoords[b.current]
				if !ok {
					continue
				}
				headLat, headLng := jitter(b.id, base[0], base[1])
				for i := 1; i <= 6; i++ {
					trailAt := now.UTC().Add(-time.Duration(i*10) * time.Minute).Format(time.RFC3339)
					// ~50–100 m steps in a deterministic direction per bike.
					trailLat := headLat + float64(i)*0.0005
					trailLng := headLng - float64(i)*0.0007
					trailID := fmt.Sprintf("gpsfix_%s_%d", b.id, i)
					if err := exec(`INSERT OR IGNORE INTO bike_gps_fixes
						(id, school_id, bike_id, at, lat, lng)
						VALUES (?, ?, ?, ?, ?, ?)`,
						trailID, schoolID, b.id, trailAt, trailLat, trailLng); err != nil {
						return err
					}
				}
			}
			return nil
		},
		// Bike maintenance log — a handful of historical entries across
		// the fleet so the new bike-detail screen demos full. Receipts
		// are the same synthetic JPEG pipeline as the instructor
		// reimbursements; each entry gets a colour-tinted thumb based
		// on category so the list scans visually.
		func() error {
			type maint struct {
				id, bikeID, category, vendor, notes string
				daysAgo                             int
				amountPence                         int
			}
			rows := []maint{
				{"bm_a1m1_service", bikeA1Manual1, "service", "Belfast Honda Service", "Annual service + new chain", 92, 18900},
				{"bm_a1m1_tyres", bikeA1Manual1, "parts", "Phoenix Tyres", "Front tyre", 41, 9800},
				{"bm_a1m1_mot", bikeA1Manual1, "mot", "Belfast Honda Service", "MOT pass — no advisories", 30, 6900},
				{"bm_a1m2_chain", bikeA1Manual2, "parts", "M&P Direct", "Chain & sprocket set", 65, 7400},
				{"bm_a1m2_labour", bikeA1Manual2, "labour", "Belfast Honda Service", "Drive train fit + adjust", 64, 11000},
				{"bm_a2m1_tax", bikeA2Manual1, "tax", "DVA", "12 months", 70, 9800},
				{"bm_a2m1_service", bikeA2Manual1, "service", "Lisburn Kawasaki", "Major service", 21, 32000},
				{"bm_am1_brakes", bikeAManual1, "parts", "M&P Direct", "Front brake pads", 12, 5400},
			}
			toneFor := map[string]int{
				"parts":   215,
				"labour":  277,
				"mot":     25,
				"tax":     70,
				"service": 145,
				"other":   200,
			}
			for _, m := range rows {
				key := fmt.Sprintf("bike-expenses/%s/receipt.jpg", m.id)
				processed, err := makeSyntheticReceipt(toneFor[m.category])
				if err != nil {
					return fmt.Errorf("synth bike-expense receipt %s: %w", m.id, err)
				}
				if _, err := files.Put(key, bytes.NewReader(processed.Main)); err != nil {
					return fmt.Errorf("store bike-expense %s: %w", m.id, err)
				}
				occurred := now.AddDate(0, 0, -m.daysAgo).Format("2006-01-02")
				// Stash a RecordBikeExpense event; applyEventLog
				// picks them up alongside BookingEventLog's events.
				bikeExpenseEvents = append(bikeExpenseEvents, RecordBikeExpense{
					Time:               now.AddDate(0, 0, -m.daysAgo),
					IntendedID:         m.id,
					BikeID:             m.bikeID,
					Category:           m.category,
					AmountPence:        m.amountPence,
					OccurredAt:         occurred,
					Vendor:             m.vendor,
					Notes:              m.notes,
					ReceiptStorageKey:  key,
					ReceiptContentType: "image/jpeg",
					ReceiptSizeBytes:   processed.MainBytes,
					ReceiptThumb:       processed.Thumb,
					RecordedBy:         "user_owen",
				})
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
			for stuIdx, s := range students {
				if err := createUser(s.id, s.email, s.name, "student", s.status); err != nil {
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
				// Audit: self-signups land via POST /auth/firebase-signup
				// (the actor is the new student themselves); admin-created
				// students would go via POST /students. Spread across the
				// last week so the audit page looks like an organic intake.
				at := now.AddDate(0, 0, -6).Add(time.Duration(stuIdx*7) * time.Hour)
				if err := seedAudit(at, s.id, "student", s.name,
					"POST", "/auth/firebase-signup", "auth", s.id,
					"Signed up", 201); err != nil {
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
				// Today (the calendar / overview always show live content).
				// Sessions stay 'scheduled' regardless of whether the end
				// time is in the past — that matches prod (no cron flips
				// the status; "is this over?" is computed from now > ends_at).
				{sessionTodayMorning, ctCBT125, instrDave, locBelfast,
					todayMorningStart.Format(time.RFC3339),
					todayMorningEnd.Format(time.RFC3339),
					"scheduled", 4},
				{sessionTodayAfternoon, ctPracMod2, instrPriya, locLisburn,
					todayAfternoonStart.Format(time.RFC3339),
					todayAfternoonEnd.Format(time.RFC3339),
					"scheduled", 1},
				// Dave dashing to Lisburn — creates the tight-travel banner.
				{sessionTodayDaveLisburn, ctPracMod2, instrDave, locLisburn,
					todayDaveLisburnStart.Format(time.RFC3339),
					todayDaveLisburnEnd.Format(time.RFC3339),
					"scheduled", 1},
				// Past sessions — also stay 'scheduled'. The bookings on
				// them get marked 'completed' / 'no_show' via the
				// per-booking status logic below.
				{sessionCBTPastBelfast, ctCBT125, instrDave, locBelfast, cbtPastStart, cbtPastEnd, "scheduled", 4},
				{sessionPracPastLisburn, ctPracMod2, instrPriya, locLisburn, pracPastStart, pracPastEnd, "scheduled", 1},
				{sessionCBTAlexCancelled, ctCBT125, instrDave, locBelfast, cancelledPastStart, cancelledPastEnd, "scheduled", 4},
				// Tomorrow PM — Niamh (already-swapped) and Ryan (no-bike-free)
				// share this session; both originally booked on the offline YBR125.
				{sessionCBTBelfastPM, ctCBT125, instrDave, locBelfast, belfastPMStart, belfastPMEnd, "scheduled", 4},
				// Tomorrow logistics demo — three cross-site bookings.
				{sessionCBTLisburnAM, ctCBT125, instrPriya, locLisburn, lisburnAMStart, lisburnAMEnd, "scheduled", 2},
				{sessionPracBelfastAM, ctPracMod2, instrAoife, locBelfast, pracBelfastAMStart, pracBelfastAMEnd, "scheduled", 1},
				{sessionPracBelfastPM, ctPracMod2, instrAoife, locBelfast, pracBelfastPMStart, pracBelfastPMEnd, "scheduled", 1},
				// Fully cancelled future session — demos the calendar's
				// faded-block + diagonal strikethrough + "Cancelled"
				// pill when the Show Cancelled toggle is on. Two days
				// out at Newry so it doesn't overlap any other demo.
				{"sess_cancelled_demo", ctCBT650, instrAoife, locNewry,
					nextMorning(now).Add(48 * time.Hour).Format(time.RFC3339),
					nextMorning(now).Add(52 * time.Hour).Format(time.RFC3339),
					"cancelled", 4},
			}
			for sessIdx, s := range sessions {
				if err := exec(`INSERT OR IGNORE INTO sessions
					(id, school_id, course_type_id, instructor_id, location_id,
					 starts_at, ends_at, capacity, status, created_at)
					VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
					s.id, schoolID, s.ct, s.instructor, s.location,
					s.starts, s.ends, s.capacity, s.status, createdAt); err != nil {
					return err
				}
				// Multi-instructor join is the new source of truth — mirror
				// the legacy instructor_id column into it as primary so
				// the calendar's instructor read works.
				if err := exec(`INSERT OR IGNORE INTO session_instructors
					(id, school_id, session_id, instructor_id, is_primary, assigned_at, assigned_by)
					VALUES (?, ?, ?, ?, 1, ?, 'user_owen')`,
					domain.NewID(), schoolID, s.id, s.instructor, createdAt); err != nil {
					return err
				}
				if err := audit(60+sessIdx, "POST", "/sessions", "sessions", s.id,
					"Scheduled a new session", 201); err != nil {
					return err
				}
			}
			return nil
		},
		// Two extra demo-only sessions that exercise edge cases of the
		// multi-instructor / null-instructor model:
		//   1. "Needs instructor" — session created by the manager
		//      ahead of time, instructor to be assigned later. Renders
		//      as a red pill on the master calendar block.
		//   2. Multi-instructor — Dave + Priya co-teach a busy CBT day.
		//      Calendar block lists "Dave, Priya" instead of one name.
		// Both are anchored to next Sunday so they don't collide with
		// the existing hand-curated or bulk-generated weekday sessions.
		func() error {
			anchor := nextMorning(now)
			// Walk forward until we hit a Sunday (1..7 ahead).
			for anchor.Weekday() != time.Sunday {
				anchor = anchor.Add(24 * time.Hour)
			}
			// 1. Unstaffed session — manager created the shell at 10:00,
			// hasn't picked who's teaching yet. instructor_id NULL +
			// no session_instructors rows = the calendar's
			// "Needs instructor" red pill.
			unstaffedStart := time.Date(anchor.Year(), anchor.Month(), anchor.Day(),
				10, 0, 0, 0, time.UTC).Format(time.RFC3339)
			unstaffedEnd := time.Date(anchor.Year(), anchor.Month(), anchor.Day(),
				14, 0, 0, 0, time.UTC).Format(time.RFC3339)
			if err := exec(`INSERT OR IGNORE INTO sessions
				(id, school_id, course_type_id, instructor_id, location_id,
				 starts_at, ends_at, capacity, status, created_at)
				VALUES ('sess_needs_instr', ?, ?, NULL, ?, ?, ?, 4,
				        'scheduled', ?)`,
				schoolID, ctCBT125, locBelfast,
				unstaffedStart, unstaffedEnd, createdAt); err != nil {
				return err
			}
			// 2. Co-taught session — same Sunday afternoon, two
			// instructors on a capacity-4 CBT. Dave as primary, Priya
			// as the second hand. The session_instructors join carries
			// both rows; sessions.instructor_id is the primary cache.
			coTaughtStart := time.Date(anchor.Year(), anchor.Month(), anchor.Day(),
				14, 30, 0, 0, time.UTC).Format(time.RFC3339)
			coTaughtEnd := time.Date(anchor.Year(), anchor.Month(), anchor.Day(),
				18, 30, 0, 0, time.UTC).Format(time.RFC3339)
			if err := exec(`INSERT OR IGNORE INTO sessions
				(id, school_id, course_type_id, instructor_id, location_id,
				 starts_at, ends_at, capacity, status, created_at)
				VALUES ('sess_co_taught', ?, ?, ?, ?, ?, ?, 4,
				        'scheduled', ?)`,
				schoolID, ctCBT125, instrDave, locBelfast,
				coTaughtStart, coTaughtEnd, createdAt); err != nil {
				return err
			}
			// Both instructors get a session_instructors row — Dave's
			// is_primary=1 (matches sessions.instructor_id), Priya
			// is_primary=0.
			if err := exec(`INSERT OR IGNORE INTO session_instructors
				(id, school_id, session_id, instructor_id, is_primary,
				 assigned_at, assigned_by)
				VALUES (?, ?, 'sess_co_taught', ?, 1, ?, 'user_owen')`,
				domain.NewID(), schoolID, instrDave, createdAt); err != nil {
				return err
			}
			if err := exec(`INSERT OR IGNORE INTO session_instructors
				(id, school_id, session_id, instructor_id, is_primary,
				 assigned_at, assigned_by)
				VALUES (?, ?, 'sess_co_taught', ?, 0, ?, 'user_owen')`,
				domain.NewID(), schoolID, instrPriya, createdAt); err != nil {
				return err
			}
			return nil
		},
		// Bulk calendar fill — ±2 weeks of recurring sessions on top of
		// the hand-curated "demo" sessions above. Gives the master
		// calendar realistic density without us hand-writing 50 inserts.
		// Pattern repeats weekly:
		//   Mon/Wed/Fri 09:00  CBT-125 @ Belfast — Dave
		//   Tue/Thu 09:00      CBT-650 @ Lisburn — Priya
		//   Wed 14:00          MOD 1 practice @ Belfast — Priya
		//   Fri 14:00          MOD 2 practice @ Lisburn — Aoife
		//   Sat 10:00          CBT-125 @ Newry — Aoife
		//   Sat 13:30          MOD 2 practice @ Belfast — Dave
		// Each session gets a deterministic uuid-style id so re-seeding
		// is idempotent (INSERT OR IGNORE skips). Past sessions are
		// marked completed; future stays scheduled.
		func() error {
			type slot struct {
				weekday   time.Weekday
				hour, dur int
				ct        string
				instr     string
				loc       string
			}
			pattern := []slot{
				{time.Monday, 9, 240, ctCBT125, instrDave, locBelfast},
				{time.Tuesday, 9, 240, ctCBT650, instrPriya, locLisburn},
				{time.Wednesday, 9, 240, ctCBT125, instrDave, locBelfast},
				{time.Wednesday, 14, 120, ctPracMod1, instrPriya, locBelfast},
				{time.Thursday, 9, 240, ctCBT650, instrPriya, locLisburn},
				{time.Friday, 9, 240, ctCBT125, instrDave, locBelfast},
				{time.Friday, 14, 120, ctPracMod2, instrAoife, locLisburn},
				{time.Saturday, 10, 240, ctCBT125, instrAoife, locNewry},
				{time.Saturday, 13, 120, ctPracMod2, instrDave, locBelfast},
			}
			// Walk every day in [-14, +21] and emit one session per
			// matching slot. Skip the day if it collides with a
			// hand-curated session (same day + same instructor + same
			// hour) to avoid the engine's overlap warnings firing on
			// data the manager didn't enter.
			start := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC).
				AddDate(0, 0, -14)
			for dayOffset := 0; dayOffset < 36; dayOffset++ {
				day := start.AddDate(0, 0, dayOffset)
				for _, p := range pattern {
					if day.Weekday() != p.weekday {
						continue
					}
					sessStart := time.Date(day.Year(), day.Month(), day.Day(),
						p.hour, 0, 0, 0, time.UTC)
					sessEnd := sessStart.Add(time.Duration(p.dur) * time.Minute)
					sessID := fmt.Sprintf("sess_bulk_%04d%02d%02d_%02d_%s",
						day.Year(), day.Month(), day.Day(), p.hour, shortCourseTag(p.ct))
					// All bulk sessions stay 'scheduled' — past-vs-future
					// is derived from now > ends_at at read time.
					status := "scheduled"
					// Skip if this instructor already has a scheduled
					// session that overlaps the bulk slot — otherwise
					// we'd produce a double-booking the engine wouldn't
					// allow (and the seed validation test would flag).
					var clash int
					if err := d.QueryRowContext(ctx, `
						SELECT COUNT(1)
						FROM session_instructors si
						JOIN sessions s ON s.id = si.session_id AND s.school_id = si.school_id
						WHERE si.school_id = ?
						  AND si.instructor_id = ?
						  AND s.status = 'scheduled'
						  AND s.starts_at < ?
						  AND s.ends_at > ?
					`, schoolID, p.instr,
						sessEnd.Format(time.RFC3339),
						sessStart.Format(time.RFC3339),
					).Scan(&clash); err != nil {
						return err
					}
					if clash > 0 {
						continue
					}
					// Cap at 4 for CBT, 1 for practice — matches the
					// course-type max_ratio values seeded earlier.
					capacity := 4
					if p.ct == ctPracMod1 || p.ct == ctPracMod2 {
						capacity = 1
					}
					if err := exec(`INSERT OR IGNORE INTO sessions
						(id, school_id, course_type_id, instructor_id, location_id,
						 starts_at, ends_at, capacity, status, created_at)
						VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
						sessID, schoolID, p.ct, p.instr, p.loc,
						sessStart.Format(time.RFC3339),
						sessEnd.Format(time.RFC3339),
						capacity, status, createdAt); err != nil {
						return err
					}
					if err := exec(`INSERT OR IGNORE INTO session_instructors
						(id, school_id, session_id, instructor_id, is_primary, assigned_at, assigned_by)
						VALUES (?, ?, ?, ?, 1, ?, 'user_owen')`,
						domain.NewID(), schoolID, sessID, p.instr, createdAt); err != nil {
						return err
					}
				}
			}
			return nil
		},
		// Competencies — one list per teaching course type. The DVSA
		// structures CBT around 5 elements (A–E) so both CBT-125 and
		// CBT-650 share the same list. Practical MOD 1 is the off-road
		// slow-control module; Practical MOD 2 is the on-road riding
		// module — different lists each so Assess surfaces the right
		// skills. The test days (MOD 1 / MOD 2) are non-teaching (the
		// DVA examiner grades them), so they get no competencies.
		func() error {
			// Shared CBT elements list — applied per-course-type below
			// (CBT-125 and CBT-650). The Insert helper rebrands the IDs
			// per course so each course gets its own rows (the
			// competencies table keys on `id` alone, so the two CBTs
			// can't share rows).
			cbtElements := []struct {
				suffix, label string
				order         int
			}{
				{"a", "Element A — Introduction & eyesight", 0},
				{"b", "Element B — On-site controls & handling", 1},
				{"c", "Element C — On-site riding & manoeuvres", 2},
				{"d", "Element D — On-road theory & safety", 3},
				{"e", "Element E — On-road riding (2 hrs)", 4},
			}
			mod1Comps := []struct {
				id, label string
				order     int
			}{
				{"comp_mod1_slalom", "Slalom — smooth, controlled lines", 0},
				{"comp_mod1_fig8", "Figure-8 — full lock without footing down", 1},
				{"comp_mod1_slow", "Slow ride — even pace, balance held", 2},
				{"comp_mod1_uturn", "U-turn — within marked area", 3},
				{"comp_mod1_emerg", "Emergency stop — controlled, no skid", 4},
				{"comp_mod1_hazard", "Hazard avoidance — line + speed", 5},
			}
			mod2Comps := []struct {
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
			insert := func(courseID string, comps []struct {
				id, label string
				order     int
			}) error {
				for _, c := range comps {
					if _, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO competencies
						(id, school_id, course_type_id, label, sort_order)
						VALUES (?, ?, ?, ?, ?)`,
						c.id, schoolID, courseID, c.label, c.order); err != nil {
						return err
					}
				}
				return nil
			}
			// CBT-125 and CBT-650 share the elements list but need
			// distinct competency IDs (PK is `id` alone).
			insertCBT := func(courseID, prefix string) error {
				for _, e := range cbtElements {
					if _, err := d.ExecContext(ctx, `INSERT OR IGNORE INTO competencies
						(id, school_id, course_type_id, label, sort_order)
						VALUES (?, ?, ?, ?, ?)`,
						prefix+e.suffix, schoolID, courseID, e.label, e.order); err != nil {
						return err
					}
				}
				return nil
			}
			if err := insertCBT(ctCBT125, "comp_cbt125_"); err != nil {
				return err
			}
			if err := insertCBT(ctCBT650, "comp_cbt650_"); err != nil {
				return err
			}
			if err := insert(ctPracMod1, mod1Comps); err != nil {
				return err
			}
			if err := insert(ctPracMod2, mod2Comps); err != nil {
				return err
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
		// Stale-disruption session bootstrap — the event log books
		// Jordan onto this session, so the row has to exist before
		// the event log runs. Audit log entries for the disruption
		// stay further down in their own step.
		func() error {
			pastSessStart := pastDay(3).Add(7 * time.Hour).Format(time.RFC3339)
			pastSessEnd := pastDay(3).Add(9 * time.Hour).Format(time.RFC3339)
			if err := exec(`INSERT OR IGNORE INTO sessions
				(id, school_id, course_type_id, instructor_id, location_id,
				 starts_at, ends_at, capacity, status, created_at)
				VALUES (?, ?, ?, ?, ?, ?, ?, 1, 'scheduled', ?)`,
				"sess_stale_demo", schoolID, ctPracMod2, instrDave, locNewry,
				pastSessStart, pastSessEnd, pastDay(10).Format(time.RFC3339)); err != nil {
				return err
			}
			return exec(`INSERT OR IGNORE INTO session_instructors
				(id, school_id, session_id, instructor_id, is_primary, assigned_at, assigned_by)
				VALUES (?, ?, ?, ?, 1, ?, 'user_owen')`,
				domain.NewID(), schoolID, "sess_stale_demo", instrDave,
				pastDay(10).Format(time.RFC3339))
		},
		// Tight-from-prior session bootstrap. Mark's booking on this
		// session lives on the event log, so the row has to exist
		// before the event log runs.
		func() error {
			tightStart := time.Date(now.Year(), now.Month(), now.Day(),
				4, 30, 0, 0, time.UTC).Add(24 * time.Hour).Format(time.RFC3339)
			tightEnd := time.Date(now.Year(), now.Month(), now.Day(),
				8, 30, 0, 0, time.UTC).Add(24 * time.Hour).Format(time.RFC3339)
			if err := exec(`INSERT OR IGNORE INTO sessions
				(id, school_id, course_type_id, instructor_id, location_id,
				 starts_at, ends_at, capacity, status, created_at)
				VALUES ('sess_tight_demo_prior', ?, ?, ?, ?, ?, ?, 1,
				        'scheduled', ?)`,
				schoolID, ctCBT125, instrPriya, locLisburn,
				tightStart, tightEnd, createdAt); err != nil {
				return err
			}
			return exec(`INSERT OR IGNORE INTO session_instructors
				(id, school_id, session_id, instructor_id, is_primary,
				 assigned_at, assigned_by)
				VALUES (?, ?, 'sess_tight_demo_prior', ?, 1, ?, 'user_owen')`,
				domain.NewID(), schoolID, instrPriya, createdAt)
		},
		// Event log — applied here, before the steps that depend on
		// event-log booking ids (progress_records, charges, incidents)
		// and before the disruption step that takes YBR125 offline.
		// Direct path is unaffected by ordering; Engine path needs
		// YBR125 'ready' at engine-call time.
		//
		// We append the bike-expense events (built by the prep step
		// further up so the filestore upload happens once per DB)
		// to the booking event log.
		func() error {
			if applyEventLog != nil {
				events := append(BookingEventLog(now), bikeExpenseEvents...)
				return applyEventLog(events, now)
			}
			return nil
		},
		// progress_records for Maeve's past practical live on the
		// event log (4 AssessCompetency events). Engine path goes
		// through progress.AssessCompetency.
		// Charges + payments live on the event log now. BookSession
		// auto-charges (mirroring engine), and RecordPayment events
		// emit the two demo payments (Alex's £100 deposit, Maeve's
		// full £90).
		// Student notes live on the event log (2 AddStudentNote
		// events — Maeve's safety flag, Alex's progress note).
		// External tests live on the event log. Note: Lucy's mod1/mod2
		// were originally seeded with region='NI' but those test types
		// only exist for GB region under DVSA rules — the engine
		// rejects them with NI. Migrated as GB to preserve the demo
		// rows without bypassing the engine validator.
		// Incidents live on the event log (5 LogIncident events). The
		// engine emits 3 standard follow-up tasks per incident, which
		// the Direct path mirrors exactly so the diff stays clean.
		// Active-disruption audit log entries. The disruption itself
		// (TakeBikeOffline + affected_bookings linking + status flips)
		// is fully on the event log now, so this step is just the
		// "what happened, in plain English" trail.
		func() error {
			daveAt := now.AddDate(0, 0, -1).Add(15 * time.Hour)
			return seedAudit(daveAt, instrDave, "instructor", "Dave Mitchell",
				"POST", "/bikes/{id}/offline", "bikes", bikeA1Manual2,
				"Took Yamaha YBR125 offline (reason: mechanic) — 2 bookings need reassignment",
				201)
		},
		// Stale-disruption audit entries — runs after the event log so
		// the disruption row exists. The audit rows themselves only
		// reference the bike id (not the disruption id), so they
		// don't need the lookup helper.
		func() error {
			downAt := pastDay(7).Add(10 * time.Hour)
			if err := seedAudit(downAt, instrPriya, "instructor", "Priya Patel",
				"POST", "/bikes/{id}/offline", "bikes", bikeA2Manual2,
				"Took Honda CB500F #2 offline — service overrun",
				201); err != nil {
				return err
			}
			restoreAt := pastDay(2).Add(11 * time.Hour)
			return seedAudit(restoreAt, "user_owen", "owner", "Owen O'Neill",
				"POST", "/bikes/{id}/restore", "bikes", bikeA2Manual2,
				"Restored Honda CB500F #2 to service (1 affected booking still pending)",
				204)
		},
		// Instructor pay model + earnings + payments live on the
		// event log (3 SetInstructorPayModel + 10 RecordInstructorEarning
		// + 4 RecordInstructorPayment events). Engine path goes through
		// instructorpay.SetPayModel / RecordEarning / RecordPayment.
		func() error {
			return nil
		},
		// Recurring availability + Dave's holiday live on the event
		// log (14 CreateRecurringAvailability events + 1 AddTimeOff).
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
			// Tone (hue) per category — matches the seeded
			// `expense_categories` rows above. Drives the synthetic
			// receipt colour so each row's thumb is visually
			// distinguishable in the admin queue.
			toneFor := map[string]int{
				"petrol":  25,
				"lunch":   70,
				"parking": 277,
				"tolls":   160,
				"other":   200,
			}

			for _, e := range rows {
				key := fmt.Sprintf("expenses/%s/receipt.jpg", e.id)
				processed, err := makeSyntheticReceipt(toneFor[e.cat])
				if err != nil {
					return fmt.Errorf("synthesise receipt %s: %w", e.id, err)
				}
				if _, err := files.Put(key, bytes.NewReader(processed.Main)); err != nil {
					return fmt.Errorf("store receipt %s: %w", e.id, err)
				}
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
					 receipt_thumb,
					 submitted_at, reviewed_by, reviewed_at, reviewer_note,
					 paid_at, paid_method, paid_by)
					VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'image/jpeg', ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
					e.id, schoolID, e.instr, e.cat, e.amount,
					e.occurred.Format(time.RFC3339), nullStr(e.where), nullStr(e.notes), e.status,
					key, processed.MainBytes, processed.Thumb,
					e.submitted.Format(time.RFC3339), reviewedBy, reviewedAt, reviewerNote,
					paidAt, paidMethod, paidBy); err != nil {
					return err
				}
			}
			return nil
		},
		// Session templates + the demo closure live on the event log.
		// The matching audit rows still get written here since they
		// reference template/closure ids that the event log produces.
		func() error {
			if err := audit(180, "POST", "/closures", "closures", "cls_demo_closure",
				fmt.Sprintf("Added closure on %s — Owner-training day",
					now.AddDate(0, 0, 28).Format("2006-01-02")),
				201); err != nil {
				return err
			}
			if err := audit(200, "POST", "/session-templates",
				"session-templates", "tpl_cbt_belfast_sat",
				"Created template — CBT-125 at Belfast, Sats 09:00, capacity 4",
				201); err != nil {
				return err
			}
			return audit(201, "POST", "/session-templates",
				"session-templates", "tpl_pracmod1_lisburn_wed",
				"Created template — PRAC-MOD1 at Lisburn, Weds 14:00, capacity 1",
				201)
		},
		// Waitlist — Ryan's queue entry on the fully-booked CBT lives
		// on the event log. The audit row stays here since the
		// waitlist event itself doesn't emit one.
		func() error {
			return seedAudit(now.Add(-2*time.Hour), studentRyan, "student", "Ryan Carson",
				"POST", "/sessions/{id}/waitlist", "sessions", sessionCBTLisburnFull,
				"Joined waitlist for CBT-650 · 2026-06-10", 201)
		},
	}

	for i, step := range steps {
		if err := step(); err != nil {
			return fmt.Errorf("step %d: %w", i, err)
		}
	}
	return nil
}

// BookingEventLog is the slice of demo state changes also expressed
// as engine-replayable events. The seed binary applies them via
// Runner.ApplyDirect; the replay test applies the same list via
// Runner.ApplyEngine to verify the engine accepts each transition.
//
// Every event picks its bike explicitly so Direct and Engine paths
// pick the same one — otherwise the engine's auto-assign could pick a
// different "first available" and the diff would flag a non-issue.
//
// Bookings tied to the disruption flow (Alex's needs_reassignment,
// Niamh's swap, Ryan's no-candidate, the stale-disruption demo) stay
// as direct INSERTs for now — they need TakeBikeOffline / ResolveSwap
// event types we haven't added yet.
func BookingEventLog(now time.Time) []Event {
	day := func(d int) time.Time { return now.Add(time.Duration(-d) * 24 * time.Hour) }
	todayAfternoonEnd := time.Date(now.Year(), now.Month(), now.Day(), 18, 0, 0, 0, time.UTC)

	events := []Event{
		// ---------- Future bookings (tomorrow + later) ----------

		// Maeve practical MOD 2 — two days from now at Lisburn on
		// Kawasaki Z650 (only A2 manual already at Lisburn).
		BookSession{
			Time:       day(5),
			IntendedID: "bk_maeve_practical",
			SessionID:  "sess_practical_lisburn",
			StudentID:  "user_student_maeve",
			BikeID:     "bike_a2_manual_1",
		},
		// Carlos on the capacity-1 CBT-650 demo — same Kawasaki, but
		// tomorrow afternoon so the windows don't overlap with Maeve's.
		BookSession{
			Time:       day(5),
			IntendedID: "bk_carlos_cbt_full",
			SessionID:  "sess_cbt_lisburn_full",
			StudentID:  "user_student_carlos",
			BikeID:     "bike_a2_manual_1",
		},
		// Maeve's Test MOD 2 day — six days out at Newry. CB500F
		// already lives at Newry so no cross-site move.
		BookSession{
			Time:       day(5),
			IntendedID: "bk_maeve_testday",
			SessionID:  "sess_test_day_newry",
			StudentID:  "user_student_maeve",
			BikeID:     "bike_a2_manual_3",
		},
		// Logistics demo: Emma (auto) on the Lexmoto Echo for
		// tomorrow's Lisburn AM CBT. Echo lives at Belfast and needs
		// to move — the cross-site advisory is the whole point of
		// this row.
		BookSession{
			Time:       day(5),
			IntendedID: "bk_emma_lisburn_am",
			SessionID:  "sess_cbt_lisburn_am",
			StudentID:  "user_student_emma",
			BikeID:     "bike_a1_auto_1",
		},
		// Logistics demo: Jordan on a CB500F (lives at Newry, needs
		// to move to Belfast for tomorrow AM practical).
		BookSession{
			Time:       day(5),
			IntendedID: "bk_jordan_belfast_am",
			SessionID:  "sess_prac_belfast_am",
			StudentID:  "user_student_jordan",
			BikeID:     "bike_a2_manual_3",
		},
		// Logistics demo: Mark on the other CB500F for tomorrow PM
		// practical at Belfast (same cross-site shape).
		//
		// Booked 10 days back so it precedes the stale-disruption
		// TakeBikeOffline event at pastDay(7) — that disruption takes
		// the same CB500F offline. Mark's tomorrow-PM session sits
		// well outside the stale unavailability window so the engine
		// doesn't list him as affected.
		BookSession{
			Time:       day(10),
			IntendedID: "bk_mark_belfast_pm",
			SessionID:  "sess_prac_belfast_pm",
			StudentID:  "user_student_mark",
			BikeID:     "bike_a2_manual_2",
		},

		// ---------- Today's bookings ----------

		// Alex booked today's morning CBT a week back. By seed-run
		// time the session has ended; the instructor's marked it
		// completed (MarkAttendance below).
		BookSession{
			Time:       day(7),
			IntendedID: "bk_alex_today_cbt",
			SessionID:  "sess_today_morning",
			StudentID:  "user_student_alex",
			BikeID:     "bike_a1_manual_1",
		},
		MarkAttendance{
			Time:       now.Add(-2 * time.Hour),
			IntendedID: "bk_alex_today_cbt",
			Status:     domain.BookingCompleted,
		},

		// Mark booked today's morning CBT three days ago on the
		// Yamaha YBR125. YBR125 only goes offline at seed-run time
		// (the disruption demo) so the bike was 'ready' at engine-call
		// time.
		BookSession{
			Time:       day(3),
			IntendedID: "bk_mark_today_noshow",
			SessionID:  "sess_today_morning",
			StudentID:  "user_student_mark",
			BikeID:     "bike_a1_manual_2",
		},
		MarkAttendance{
			Time:       now.Add(-30 * time.Minute),
			IntendedID: "bk_mark_today_noshow",
			Status:     domain.BookingNoShow,
		},

		// Maeve booked today's afternoon practical a week back.
		BookSession{
			Time:       day(7),
			IntendedID: "bk_maeve_today_prac",
			SessionID:  "sess_today_afternoon",
			StudentID:  "user_student_maeve",
			BikeID:     "bike_a2_manual_1",
		},

		// ---------- Past completed (7-10 days ago) ----------

		BookSession{
			Time:       day(14),
			IntendedID: "bk_alex_past_cbt",
			SessionID:  "sess_cbt_past_belfast",
			StudentID:  "user_student_alex",
			BikeID:     "bike_a1_manual_1",
		},
		MarkAttendance{
			Time:       day(7).Add(13 * time.Hour),
			IntendedID: "bk_alex_past_cbt",
			Status:     domain.BookingCompleted,
		},

		BookSession{
			Time:       day(17),
			IntendedID: "bk_maeve_past_prac",
			SessionID:  "sess_prac_past_lisburn",
			StudentID:  "user_student_maeve",
			BikeID:     "bike_a2_manual_1",
		},
		MarkAttendance{
			Time:       day(10).Add(13 * time.Hour),
			IntendedID: "bk_maeve_past_prac",
			Status:     domain.BookingCompleted,
		},

		// ---------- Past cancelled ----------

		// Alex booked a CBT 17 days ago, then got cold feet and
		// cancelled the day before. Honda CB125F was free at the time.
		BookSession{
			Time:       day(20),
			IntendedID: "bk_alex_cancelled",
			SessionID:  "sess_cbt_past_cancelled",
			StudentID:  "user_student_alex",
			BikeID:     "bike_a1_manual_1",
		},
		CancelBooking{
			Time:        day(15),
			IntendedID:  "bk_alex_cancelled",
			CancelledBy: domain.CancelledByStudent,
			Reason:      "Got cold feet — will rebook next month",
		},

		// ---------- Jordan's tomorrow cancellation ----------

		BookSession{
			Time:       day(4),
			IntendedID: "bk_jordan_tomorrow_cancelled",
			SessionID:  "sess_cbt_belfast",
			StudentID:  "user_student_jordan",
			BikeID:     "bike_a1_manual_1",
		},
		CancelBooking{
			Time:        now.Add(-2 * time.Hour),
			IntendedID:  "bk_jordan_tomorrow_cancelled",
			CancelledBy: domain.CancelledByStudent,
			Reason:      "Conflict at work — will rebook",
		},

		// ---------- Active disruption ----------

		// Alex booked tomorrow's CBT on YBR125 five days back. YBR125
		// was still 'ready' at that time (the disruption opens later
		// in this log).
		BookSession{
			Time:       day(5),
			IntendedID: "bk_alex_disrupted",
			SessionID:  "sess_cbt_belfast",
			StudentID:  "user_student_alex",
			BikeID:     "bike_a1_manual_2",
		},
		// Niamh's tomorrow-PM booking is on Honda CB125F directly —
		// she's a regular booking, not part of the disruption demo.
		// We used to have her on YBR125-then-swapped-to-Honda but
		// that required the engine to allow two students on YBR125
		// for the same session (Niamh + Ryan), which it doesn't.
		// Trade-off: lose the "swap success" UI demo state to gain
		// Ryan's "no candidate" state engine-reachably.
		BookSession{
			Time:       day(5),
			IntendedID: "bk_niamh_disrupted",
			SessionID:  "sess_cbt_belfast_pm",
			StudentID:  "user_student_niamh",
			BikeID:     "bike_a1_manual_1",
		},
		// Ryan books YBR125 for tomorrow afternoon. Alex's YBR125
		// booking is tomorrow morning so the windows don't overlap —
		// engine accepts both on the same bike.
		BookSession{
			Time:       day(5),
			IntendedID: "bk_ryan_disrupted",
			SessionID:  "sess_cbt_belfast_pm",
			StudentID:  "user_student_ryan",
			BikeID:     "bike_a1_manual_2",
		},
		// Dave finds the clutch slipping yesterday afternoon and takes
		// YBR125 offline. The engine flips both Alex (morning) and
		// Ryan (afternoon) to needs_reassignment and opens the
		// disruption row. Niamh, on Honda, is unaffected.
		//
		// Ryan ends up "pending, no candidate" automatically: the
		// only other A1 manual at Belfast (Honda CB125F) is held by
		// Niamh in the same window, and Lexmoto Echo is auto.
		// Alex ends up "pending with candidate" because Honda is
		// free in his morning window.
		TakeBikeOffline{
			Time:                 now.AddDate(0, 0, -1).Add(15 * time.Hour),
			IntendedDisruptionID: "disr_a1m2",
			IntendedUnavailID:    "unav_a1m2",
			BikeID:               "bike_a1_manual_2",
			Reason:               "mechanic",
			StartsAt:             now,
			EndsAt:               now.Add(30 * 24 * time.Hour),
			Notes:                "Clutch slipping — awaiting parts",
			CreatedBy:            "user_instr_dave",
		},

		// ---------- Stale disruption (past-due cleanup demo) ----------

		// Jordan booked the past Practice-MOD2 at Newry on the CB500F
		// 9 days back, before the bike went down for service. Emma
		// would have been the natural narrative pick but her
		// transmission preference is 'auto' and the engine wouldn't
		// have let her on an A2 manual — Jordan's manual pref keeps
		// the demo engine-reachable without restructuring her profile.
		BookSession{
			Time:       day(9),
			IntendedID: "bk_stale_jordan",
			SessionID:  "sess_stale_demo",
			StudentID:  "user_student_jordan",
			BikeID:     "bike_a2_manual_2",
		},
		// Bike taken offline 7 days back for a "routine service" that
		// dragged on. Closed window [day(7), day(2)] catches Jordan's
		// session at day(3). No one resolved the affected-booking
		// link, which is the whole point of the demo.
		TakeBikeOffline{
			Time:                 day(7),
			IntendedDisruptionID: "disr_stale_a2m2",
			IntendedUnavailID:    "unav_stale_a2m2",
			BikeID:               "bike_a2_manual_2",
			Reason:               "mechanic",
			StartsAt:             day(7),
			EndsAt:               day(2),
			Notes:                "Annual service overran by a day — back in service",
			CreatedBy:            "user_instr_priya",
		},
		// Bike came back 2 days ago. RestoreBike flips bikes.status
		// to 'ready' but leaves the disruption_affected_bookings link
		// pending — that's the "Past · needs cleanup" badge fuel.
		RestoreBike{
			Time:   day(2),
			BikeID: "bike_a2_manual_2",
		},

		// ---------- Payments ----------
		// Both BookSession events above auto-charged the course price
		// (engine path emits the charge inside Book's tx; Direct path
		// mirrors that in autoChargeDirect). We then record what each
		// student paid: Alex part-paid £100 of £130, Maeve cleared
		// her £90 in full.
		RecordPayment{
			Time:        day(7).Add(11 * time.Hour),
			IntendedID:  "pay_alex_partial",
			StudentID:   "user_student_alex",
			AmountPence: 10000,
			Method:      domain.PayCash,
			ReceivedAt:  day(7).Add(11 * time.Hour),
			RecordedBy:  "user_owen",
			Notes:       "Cash deposit on the day",
		},
		RecordPayment{
			Time:        day(10).Add(11 * time.Hour),
			IntendedID:  "pay_maeve_full",
			StudentID:   "user_student_maeve",
			AmountPence: 9000,
			Method:      domain.PayBankTransfer,
			ReceivedAt:  day(10).Add(11 * time.Hour),
			RecordedBy:  "user_owen",
		},

		// ---------- Tight-from-prior swap candidate demo ----------
		// Mark books the early Lisburn CBT on the Honda CB125F.
		// His session ends 30 min before Alex's tomorrow-morning
		// Belfast session starts, and Belfast↔Lisburn travel is
		// 25 min + 15 min default buffer, so the engine surfaces
		// this candidate with a "tight from prior" red warning.
		BookSession{
			Time:       day(5),
			IntendedID: "bk_tight_demo",
			SessionID:  "sess_tight_demo_prior",
			StudentID:  "user_student_mark",
			BikeID:     "bike_a1_manual_1",
		},

		// ---------- Progress assessments ----------
		// Priya recorded mixed competency outcomes for Maeve's past
		// practical right after the lesson — gives the progress
		// screen something interesting to demo. Engine path goes
		// through progress.AssessCompetency which gates on
		// session-must-be-teaching + competency-must-match-course.
		AssessCompetency{
			Time:              day(10).Add(11 * time.Hour),
			IntendedID:        "prog_maeve_signal",
			IntendedBookingID: "bk_maeve_past_prac",
			CompetencyID:      "comp_prac_signal",
			Status:            "competent",
			RecordedBy:        "user_instr_priya",
		},
		AssessCompetency{
			Time:              day(10).Add(11 * time.Hour),
			IntendedID:        "prog_maeve_braking",
			IntendedBookingID: "bk_maeve_past_prac",
			CompetencyID:      "comp_prac_braking",
			Status:            "competent",
			RecordedBy:        "user_instr_priya",
		},
		AssessCompetency{
			Time:              day(10).Add(11 * time.Hour),
			IntendedID:        "prog_maeve_uturn",
			IntendedBookingID: "bk_maeve_past_prac",
			CompetencyID:      "comp_prac_uturn",
			Status:            "developing",
			RecordedBy:        "user_instr_priya",
		},
		AssessCompetency{
			Time:              day(10).Add(11 * time.Hour),
			IntendedID:        "prog_maeve_emerg",
			IntendedBookingID: "bk_maeve_past_prac",
			CompetencyID:      "comp_prac_emerg",
			Status:            "needs_work",
			RecordedBy:        "user_instr_priya",
		},

		// ---------- Instructor availability ----------
		// Dave Mon-Fri Belfast.
		CreateRecurringAvailability{Time: day(60), IntendedID: "avail_dave_mon", InstructorID: "user_instr_dave", Weekday: 1, StartsAtLocal: "09:00", EndsAtLocal: "17:00", LocationID: "loc_belfast"},
		CreateRecurringAvailability{Time: day(60), IntendedID: "avail_dave_tue", InstructorID: "user_instr_dave", Weekday: 2, StartsAtLocal: "09:00", EndsAtLocal: "17:00", LocationID: "loc_belfast"},
		CreateRecurringAvailability{Time: day(60), IntendedID: "avail_dave_wed", InstructorID: "user_instr_dave", Weekday: 3, StartsAtLocal: "09:00", EndsAtLocal: "17:00", LocationID: "loc_belfast"},
		CreateRecurringAvailability{Time: day(60), IntendedID: "avail_dave_thu", InstructorID: "user_instr_dave", Weekday: 4, StartsAtLocal: "09:00", EndsAtLocal: "17:00", LocationID: "loc_belfast"},
		CreateRecurringAvailability{Time: day(60), IntendedID: "avail_dave_fri", InstructorID: "user_instr_dave", Weekday: 5, StartsAtLocal: "09:00", EndsAtLocal: "17:00", LocationID: "loc_belfast"},
		// Priya Tue-Sat Lisburn.
		CreateRecurringAvailability{Time: day(60), IntendedID: "avail_priya_tue", InstructorID: "user_instr_priya", Weekday: 2, StartsAtLocal: "10:00", EndsAtLocal: "18:00", LocationID: "loc_lisburn"},
		CreateRecurringAvailability{Time: day(60), IntendedID: "avail_priya_wed", InstructorID: "user_instr_priya", Weekday: 3, StartsAtLocal: "10:00", EndsAtLocal: "18:00", LocationID: "loc_lisburn"},
		CreateRecurringAvailability{Time: day(60), IntendedID: "avail_priya_thu", InstructorID: "user_instr_priya", Weekday: 4, StartsAtLocal: "10:00", EndsAtLocal: "18:00", LocationID: "loc_lisburn"},
		CreateRecurringAvailability{Time: day(60), IntendedID: "avail_priya_fri", InstructorID: "user_instr_priya", Weekday: 5, StartsAtLocal: "10:00", EndsAtLocal: "18:00", LocationID: "loc_lisburn"},
		CreateRecurringAvailability{Time: day(60), IntendedID: "avail_priya_sat", InstructorID: "user_instr_priya", Weekday: 6, StartsAtLocal: "09:00", EndsAtLocal: "15:00", LocationID: "loc_lisburn"},
		// Aoife Mon/Tue/Wed/Sat Belfast.
		CreateRecurringAvailability{Time: day(60), IntendedID: "avail_aoife_mon", InstructorID: "user_instr_aoife", Weekday: 1, StartsAtLocal: "09:30", EndsAtLocal: "16:30", LocationID: "loc_belfast"},
		CreateRecurringAvailability{Time: day(60), IntendedID: "avail_aoife_tue", InstructorID: "user_instr_aoife", Weekday: 2, StartsAtLocal: "09:30", EndsAtLocal: "16:30", LocationID: "loc_belfast"},
		CreateRecurringAvailability{Time: day(60), IntendedID: "avail_aoife_wed", InstructorID: "user_instr_aoife", Weekday: 3, StartsAtLocal: "09:30", EndsAtLocal: "16:30", LocationID: "loc_belfast"},
		CreateRecurringAvailability{Time: day(60), IntendedID: "avail_aoife_sat", InstructorID: "user_instr_aoife", Weekday: 6, StartsAtLocal: "09:00", EndsAtLocal: "13:00", LocationID: "loc_belfast"},
		// Dave's family holiday in two weeks.
		AddTimeOff{
			Time:         day(7),
			IntendedID:   "off_dave_hols",
			InstructorID: "user_instr_dave",
			StartsAt:     now.Add(14 * 24 * time.Hour),
			EndsAt:       now.Add(19 * 24 * time.Hour),
			Reason:       "Family holiday",
		},

		// ---------- Instructor pay models ----------
		// Dave: 50% percentage. Priya: per-session £40. Aoife: 45%.
		SetInstructorPayModel{Time: day(45), IntendedID: "paymdl_dave", InstructorID: "user_instr_dave", PayBasis: domain.BasisPercentage, RateValue: 5000},
		SetInstructorPayModel{Time: day(45), IntendedID: "paymdl_priya", InstructorID: "user_instr_priya", PayBasis: domain.BasisPerSession, RateValue: 4000},
		SetInstructorPayModel{Time: day(45), IntendedID: "paymdl_aoife", InstructorID: "user_instr_aoife", PayBasis: domain.BasisPercentage, RateValue: 4500},

		// ---------- Instructor earnings ----------
		// Dave: 50% of Alex's past £130 CBT charge (£65). Sourced
		// from bk_alex_past_cbt's auto-charge via lookup in the
		// event applier.
		RecordInstructorEarning{
			Time:             day(7),
			IntendedID:       "earn_dave_cbt",
			InstructorID:     "user_instr_dave",
			SessionID:        "sess_cbt_past_belfast",
			AmountPence:      6500,
			Basis:            domain.BasisPercentage,
			Notes:            "50% of CBT charge",
			SourceBookingIDs: []string{"bk_alex_past_cbt"},
			CreatedBy:        "user_owen",
		},
		RecordInstructorEarning{Time: day(10), IntendedID: "earn_priya_prac", InstructorID: "user_instr_priya", SessionID: "sess_prac_past_lisburn", AmountPence: 4000, Basis: domain.BasisPerSession, CreatedBy: "user_owen"},
		// Synthetic earnings spread across the past 4 weeks so the
		// Instructor Pay screen shows real history.
		RecordInstructorEarning{Time: day(3), IntendedID: "earn_dave_extra1", InstructorID: "user_instr_dave", AmountPence: 6500, Basis: domain.BasisPercentage, Notes: "50% of completed CBT", CreatedBy: "user_owen"},
		RecordInstructorEarning{Time: day(11), IntendedID: "earn_dave_extra2", InstructorID: "user_instr_dave", AmountPence: 6500, Basis: domain.BasisPercentage, Notes: "50% of completed CBT", CreatedBy: "user_owen"},
		RecordInstructorEarning{Time: day(21), IntendedID: "earn_dave_extra3", InstructorID: "user_instr_dave", AmountPence: 6500, Basis: domain.BasisPercentage, Notes: "50% of completed CBT", CreatedBy: "user_owen"},
		RecordInstructorEarning{Time: day(5), IntendedID: "earn_priya_extra1", InstructorID: "user_instr_priya", AmountPence: 4000, Basis: domain.BasisPerSession, Notes: "Practice MOD 2", CreatedBy: "user_owen"},
		RecordInstructorEarning{Time: day(17), IntendedID: "earn_priya_extra2", InstructorID: "user_instr_priya", AmountPence: 4000, Basis: domain.BasisPerSession, Notes: "Practice MOD 1", CreatedBy: "user_owen"},
		RecordInstructorEarning{Time: day(8), IntendedID: "earn_aoife_extra1", InstructorID: "user_instr_aoife", AmountPence: 5850, Basis: domain.BasisPercentage, Notes: "45% of CBT", CreatedBy: "user_owen"},
		RecordInstructorEarning{Time: day(19), IntendedID: "earn_aoife_extra2", InstructorID: "user_instr_aoife", AmountPence: 5850, Basis: domain.BasisPercentage, Notes: "45% of CBT", CreatedBy: "user_owen"},

		// ---------- Instructor payouts ----------
		RecordInstructorPayment{Time: day(7), IntendedID: "paymt_dave_partial", InstructorID: "user_instr_dave", AmountPence: 4000, Method: domain.PayBankTransfer, PaidAt: day(7), RecordedBy: "user_owen", Notes: "Weekly run"},
		RecordInstructorPayment{Time: day(10), IntendedID: "paymt_priya_full", InstructorID: "user_instr_priya", AmountPence: 4000, Method: domain.PayBankTransfer, PaidAt: day(10), RecordedBy: "user_owen"},
		RecordInstructorPayment{Time: day(12), IntendedID: "paymt_dave_extra1", InstructorID: "user_instr_dave", AmountPence: 6500, Method: domain.PayBankTransfer, PaidAt: day(12), RecordedBy: "user_owen", Notes: "Weekly run · cleared earn_dave_extra1"},
		RecordInstructorPayment{Time: day(6), IntendedID: "paymt_priya_extra1", InstructorID: "user_instr_priya", AmountPence: 4000, Method: domain.PayBankTransfer, PaidAt: day(6), RecordedBy: "user_owen", Notes: "Weekly run"},

		// ---------- Session templates ----------
		CreateSessionTemplate{
			Time:            day(50),
			IntendedID:      "tpl_cbt_belfast_sat",
			CourseTypeID:    "ct_cbt_125",
			InstructorID:    "user_instr_dave",
			LocationID:      "loc_belfast",
			Weekday:         6,
			StartsAtTime:    "09:00",
			DurationMinutes: 240,
			Capacity:        4,
			CreatedBy:       "user_owen",
		},
		CreateSessionTemplate{
			Time:            day(50),
			IntendedID:      "tpl_pracmod1_lisburn_wed",
			CourseTypeID:    "ct_prac_mod1",
			InstructorID:    "user_instr_priya",
			LocationID:      "loc_lisburn",
			Weekday:         3,
			StartsAtTime:    "14:00",
			DurationMinutes: 120,
			Capacity:        1,
			CreatedBy:       "user_owen",
		},

		// ---------- School closure ----------
		AddSchoolClosure{
			Time:       day(40),
			IntendedID: "cls_demo_closure",
			FromDate:   now.AddDate(0, 0, 28).Format("2006-01-02"),
			ToDate:     now.AddDate(0, 0, 28).Format("2006-01-02"),
			Label:      "Owner-training day",
			Reason:     "Annual instructor training day — no student sessions.",
			CreatedBy:  "user_owen",
		},

		// ---------- External tests ----------
		// Maeve's theory pass (past), Maeve's booked DVA practical
		// (future, for the test-day session), Lucy's full pass record
		// (alumni demo data — theory + practical for the NI region).
		RecordExternalTest{
			Time:        day(30),
			IntendedID:  "ext_maeve_theory",
			StudentID:   "user_student_maeve",
			TestType:    "theory",
			Region:      domain.RegionNI,
			ScheduledAt: day(30),
			Reference:   "DVA-NI-AAA111",
			Outcome:     "pass",
			Notes:       "Passed first time",
		},
		RecordExternalTest{
			Time:        day(60),
			IntendedID:  "ext_lucy_theory",
			StudentID:   "user_student_lucy",
			TestType:    "theory",
			Region:      domain.RegionNI,
			ScheduledAt: day(60),
			Reference:   "DVA-NI-CCC333",
			Outcome:     "pass",
		},
		RecordExternalTest{
			Time:        day(40),
			IntendedID:  "ext_lucy_mod1",
			StudentID:   "user_student_lucy",
			TestType:    "mod1",
			Region:      domain.RegionGB,
			ScheduledAt: day(40),
			Reference:   "DVSA-MOD1-001",
			Outcome:     "pass",
		},
		RecordExternalTest{
			Time:        day(20),
			IntendedID:  "ext_lucy_mod2",
			StudentID:   "user_student_lucy",
			TestType:    "mod2",
			Region:      domain.RegionGB,
			ScheduledAt: day(20),
			Reference:   "DVSA-MOD2-001",
			Outcome:     "pass",
		},
		RecordExternalTest{
			Time:        now.Add(-time.Hour),
			IntendedID:  "ext_maeve_practical",
			StudentID:   "user_student_maeve",
			TestType:    "practical",
			Region:      domain.RegionNI,
			ScheduledAt: nextMorning(now).Add(5 * 24 * time.Hour),
			Reference:   "DVA-NI-BBB222",
			Outcome:     "booked",
		},

		// ---------- Student notes ----------
		// Two demo notes for the Student Detail screen: Maeve's
		// safety flag and Alex's progress reminder.
		AddStudentNote{
			Time:       day(8).Add(10 * time.Hour),
			IntendedID: "note_maeve_safety",
			StudentID:  "user_student_maeve",
			Kind:       "safety_flag",
			Body:       "Wears prescription glasses — confirm spare set in helmet pouch before riding.",
			CreatedBy:  "user_owen",
		},
		AddStudentNote{
			Time:       day(6).Add(10 * time.Hour),
			IntendedID: "note_alex_progress",
			StudentID:  "user_student_alex",
			Kind:       "progress_note",
			Body:       "Nervous at busy junctions — Dave to repeat observation drill on next session.",
			CreatedBy:  "user_owen",
		},

		// ---------- Incidents ----------
		// Five demo incidents across the past few weeks so the
		// Incidents board has real content. Each LogIncident event
		// also writes the three standard follow-up tasks on both
		// paths (mechanical_check, student_welfare, insurance_notify).
		LogIncident{
			Time:              day(14).Add(time.Hour),
			IntendedID:        "inc_lucy_tipover",
			BikeID:            "bike_a2_manual_1",
			StudentID:         "user_student_lucy",
			Note:              "Tip-over at low speed on roundabout exit. Mirror cracked, otherwise fine. Mirror replaced same day.",
			CreatedBy:         "user_instr_priya",
		},
		LogIncident{
			Time:              day(10).Add(time.Hour),
			IntendedID:        "inc_maeve_drop",
			BikeID:            "bike_a2_manual_1",
			StudentID:         "user_student_maeve",
			IntendedBookingID: "bk_maeve_past_prac",
			Note:              "Low-speed drop in car park during U-turn practice. No injury, bike inspected and returned to service.",
			CreatedBy:         "user_instr_priya",
		},
		LogIncident{
			Time:              day(6).Add(time.Hour),
			IntendedID:        "inc_jordan_stall",
			BikeID:            "bike_a2_manual_2",
			StudentID:         "user_student_jordan",
			Note:              "Repeated stalls on hill start — possible clutch judder reported. Test ride confirms ok, monitoring.",
			CreatedBy:         "user_instr_dave",
		},
		LogIncident{
			Time:              day(4).Add(time.Hour),
			IntendedID:        "inc_alex_clip",
			BikeID:            "bike_a1_manual_1",
			StudentID:         "user_student_alex",
			Note:              "Clipped a cone on the slalom — bike unhurt, student a bit shaken. Took five and continued.",
			CreatedBy:         "user_instr_dave",
		},
		LogIncident{
			Time:              day(2).Add(time.Hour),
			IntendedID:        "inc_emma_nearmiss",
			BikeID:            "bike_a1_auto_1",
			StudentID:         "user_student_emma",
			Note:              "Near-miss with a parked car during lane change. Debriefed with the student; no contact.",
			CreatedBy:         "user_instr_aoife",
		},

		// ---------- Waitlist ----------
		// Ryan queues on the capacity-1 CBT-650 that Carlos took. The
		// engine refuses JoinWaitlist if the session still has room,
		// so Carlos's BookSession above must apply first — events are
		// sorted chronologically so day(5) < (now-2h) keeps the order.
		JoinWaitlist{
			Time:       now.Add(-2 * time.Hour),
			IntendedID: "wl_ryan_cbt_full",
			SessionID:  "sess_cbt_lisburn_full",
			StudentID:  "user_student_ryan",
		},
	}

	// Today PM may or may not be over depending on wall-clock at seed
	// time. If it's over, the instructor's marked Maeve completed.
	if now.After(todayAfternoonEnd) {
		events = append(events, MarkAttendance{
			Time:       todayAfternoonEnd.Add(15 * time.Minute),
			IntendedID: "bk_maeve_today_prac",
			Status:     domain.BookingCompleted,
		})
	}

	return events
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

// boolInt — SQLite booleans live as INTEGER (0/1). Tiny helper to keep
// the insert sites readable.
func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// shortCourseTag turns a course id (e.g. "ct_prac_mod1") into a short
// suffix safe for embedding in a deterministic session id. Just used
// to keep the bulk-generated session ids readable in the DB.
func shortCourseTag(ctID string) string {
	switch ctID {
	case "ct_cbt_125":
		return "cbt125"
	case "ct_cbt_650":
		return "cbt650"
	case "ct_prac_mod1":
		return "mod1"
	case "ct_prac_mod2":
		return "mod2"
	case "ct_test_mod1":
		return "tst1"
	case "ct_test_mod2":
		return "tst2"
	}
	return "misc"
}

// makeLocationBanner builds a 300×120 JPEG: a vertical gradient from
// a darker shade of the location's hue at the top to a lighter shade
// at the bottom, with a soft diagonal highlight band. Each location
// gets a visually distinct header without any external image assets.
func makeLocationBanner(hue int) ([]byte, error) {
	const w, h = 300, 120
	img := image.NewRGBA(image.Rect(0, 0, w, h))

	top := hslToRGBA(float64(hue), 0.55, 0.40)
	bottom := hslToRGBA(float64(hue), 0.55, 0.65)

	for y := 0; y < h; y++ {
		t := float64(y) / float64(h-1)
		r := uint8(float64(top.R)*(1-t) + float64(bottom.R)*t)
		g := uint8(float64(top.G)*(1-t) + float64(bottom.G)*t)
		b := uint8(float64(top.B)*(1-t) + float64(bottom.B)*t)
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{R: r, G: g, B: b, A: 255})
		}
	}

	// Diagonal highlight band — adds a sense of depth so it doesn't
	// look like a flat colour block.
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if math.Abs(float64(x-y*2-40)) < 12 {
				orig := img.RGBAAt(x, y)
				img.Set(x, y, color.RGBA{
					R: uint8(int(orig.R) + 25),
					G: uint8(int(orig.G) + 25),
					B: uint8(int(orig.B) + 25),
					A: 255,
				})
			}
		}
	}

	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 75}); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// makeSyntheticReceipt generates a small JPEG that vaguely resembles a
// receipt (off-white background, faint horizontal "lines of text",
// coloured header bar in the category's hue) and runs it through the
// production processing pipeline. Output mirrors what a real upload
// produces, so the reimbursement screens render exactly as they would
// in real use — without committing binary fixtures to the repo.
func makeSyntheticReceipt(toneHue int) (*media.Processed, error) {
	const w, h = 600, 800
	img := image.NewRGBA(image.Rect(0, 0, w, h))

	// Off-white paper background.
	paper := color.RGBA{R: 250, G: 248, B: 244, A: 255}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, paper)
		}
	}
	// Header bar in the category hue.
	header := hslToRGBA(float64(toneHue), 0.55, 0.55)
	for y := 0; y < 110; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, header)
		}
	}
	// A handful of faint horizontal "text" stripes below the header.
	stripe := color.RGBA{R: 80, G: 80, B: 92, A: 255}
	stripes := []struct{ y, height, padX int }{
		{160, 18, 40}, {200, 12, 60}, {240, 12, 80},
		{300, 16, 40}, {340, 12, 60}, {380, 12, 110},
		{440, 14, 40}, {480, 12, 100}, {520, 12, 80},
		{600, 24, 40},
	}
	for _, s := range stripes {
		for y := s.y; y < s.y+s.height && y < h; y++ {
			for x := s.padX; x < w-s.padX; x++ {
				img.Set(x, y, stripe)
			}
		}
	}

	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 90}); err != nil {
		return nil, err
	}
	return media.ProcessReceipt(&buf)
}

// hslToRGBA converts an HSL triple (matching the JSX prototype's
// tonal palette) to an opaque RGBA colour. Saturation + lightness are
// fixed at 0.55 to mirror the design tokens used in the Flutter app.
func hslToRGBA(h, s, l float64) color.RGBA {
	h = math.Mod(h, 360) / 360.0
	if s == 0 {
		v := uint8(l * 255)
		return color.RGBA{R: v, G: v, B: v, A: 255}
	}
	var q float64
	if l < 0.5 {
		q = l * (1 + s)
	} else {
		q = l + s - l*s
	}
	p := 2*l - q
	r := hueToRGB(p, q, h+1.0/3.0)
	g := hueToRGB(p, q, h)
	b := hueToRGB(p, q, h-1.0/3.0)
	return color.RGBA{R: uint8(r * 255), G: uint8(g * 255), B: uint8(b * 255), A: 255}
}

func hueToRGB(p, q, t float64) float64 {
	if t < 0 {
		t += 1
	}
	if t > 1 {
		t -= 1
	}
	switch {
	case t < 1.0/6.0:
		return p + (q-p)*6*t
	case t < 0.5:
		return q
	case t < 2.0/3.0:
		return p + (q-p)*(2.0/3.0-t)*6
	}
	return p
}
