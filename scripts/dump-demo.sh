#!/usr/bin/env bash
# Dump every endpoint the demo build needs into app/assets/demo/*.json.
#
# Prerequisites:
#   1. `make emulator`     — Firebase Auth + Storage emulators running.
#   2. `make backend`      — fresh seed + Go server on :8765.
#
# What it does:
#   - Mints an Owner ID token (owen@lagan.test → user_owen).
#   - Mints an Instructor token (user_instr — Dave).
#   - Mints a Student token (user_stu — Alex).
#   - GETs every list-style endpoint with the relevant token, writes
#     the response body verbatim to app/assets/demo/<name>.json.
#
# MockApiClient on the Flutter side loads these assets at startup —
# they're the exact same JSON shapes ApiClient.fromJson already knows
# how to decode, so no parsing forks.

set -euo pipefail

API="${KS_API:-http://localhost:8765}"
OUT="${KS_DEMO_OUT:-app/assets/demo}"
mkdir -p "$OUT"

export FIREBASE_AUTH_EMULATOR_HOST="${FIREBASE_AUTH_EMULATOR_HOST:-localhost:19099}"
export FIREBASE_PROJECT_ID="${FIREBASE_PROJECT_ID:-kickstand-dev}"

# Sanity check the backend's up.
if ! curl -fsS "$API/health" > /dev/null; then
  echo "Backend at $API isn't responding. Start with: make backend"
  exit 1
fi

echo "Minting demo tokens via the Auth emulator..."
go build -o bin/mintdemotoken ./cmd/mintdemotoken
OWEN_TOKEN=$(./bin/mintdemotoken -uid user_owen)
DAVE_TOKEN=$(./bin/mintdemotoken -uid user_instr_dave)
ALEX_TOKEN=$(./bin/mintdemotoken -uid user_student_alex)

dump() {
  # usage: dump <role-label> <bearer> <path> <output-name>
  local label="$1" bearer="$2" path="$3" name="$4"
  echo "  [$label]  GET $path  →  $name.json"
  curl -fsS -H "Authorization: Bearer $bearer" "$API$path" \
    | jq . > "$OUT/$name.json"
}

echo "Dumping owner-visible endpoints..."
dump owen "$OWEN_TOKEN" "/me" "owen_me"
dump owen "$OWEN_TOKEN" "/school" "school"
dump owen "$OWEN_TOKEN" "/schools" "schools"
dump owen "$OWEN_TOKEN" "/locations" "locations"
dump owen "$OWEN_TOKEN" "/travel-times" "travel_times"
dump owen "$OWEN_TOKEN" "/bikes" "bikes"
dump owen "$OWEN_TOKEN" "/admin/bikes/gps" "bike_gps"
dump owen "$OWEN_TOKEN" "/admin/analytics/bike-utilisation" "analytics_bike_utilisation"
dump owen "$OWEN_TOKEN" "/admin/analytics/instructor-utilisation" "analytics_instructor_utilisation"
dump owen "$OWEN_TOKEN" "/admin/analytics/funnel" "analytics_funnel"
dump owen "$OWEN_TOKEN" "/course-types" "course_types"
dump owen "$OWEN_TOKEN" "/instructors" "instructors"
dump owen "$OWEN_TOKEN" "/students" "students"
dump owen "$OWEN_TOKEN" "/signups/pending" "signups_pending"
dump owen "$OWEN_TOKEN" "/disruptions" "disruptions"
dump owen "$OWEN_TOKEN" "/logistics" "logistics"
# Master calendar — `from` is required as RFC3339; the handler defaults
# `to` to from+14d which is plenty for the demo.
NOW_RFC3339=$(date -u +%Y-%m-%dT%H:%M:%SZ)
dump owen "$OWEN_TOKEN" "/calendar?from=$NOW_RFC3339" "calendar"
dump owen "$OWEN_TOKEN" "/instructor-pay/outstanding" "instructor_pay_outstanding"
dump owen "$OWEN_TOKEN" "/expense-categories" "expense_categories"
dump owen "$OWEN_TOKEN" "/expenses?status=pending" "expenses_review_pending"
dump owen "$OWEN_TOKEN" "/expenses?status=approved" "expenses_review_approved"
dump owen "$OWEN_TOKEN" "/expenses?status=reimbursed" "expenses_review_reimbursed"

echo "Dumping per-bike maintenance logs..."
# Extract every bike id from the bikes.json dump and grab its log.
mkdir -p "$OUT/bike_expenses"
jq -r '.bikes[].id' "$OUT/bikes.json" | while read -r bike_id; do
  dump owen "$OWEN_TOKEN" "/bikes/$bike_id/expenses" "bike_expenses/$bike_id"
done

echo "Dumping instructor-visible endpoints (Dave)..."
dump dave "$DAVE_TOKEN" "/me" "dave_me"
dump dave "$DAVE_TOKEN" "/sessions?from=$NOW_RFC3339" "dave_sessions"
dump dave "$DAVE_TOKEN" "/me/expenses" "dave_me_expenses"
dump dave "$DAVE_TOKEN" "/instructors/user_instr_dave/availability" "dave_availability"
dump dave "$DAVE_TOKEN" "/instructors/user_instr_dave/time-off" "dave_time_off"

echo "Dumping student-visible endpoints (Alex)..."
dump alex "$ALEX_TOKEN" "/me" "alex_me"
dump alex "$ALEX_TOKEN" "/me/student-profile" "alex_profile"
dump alex "$ALEX_TOKEN" "/me/bookings" "alex_bookings"
dump alex "$ALEX_TOKEN" "/me/notifications" "alex_notifications"
dump alex "$ALEX_TOKEN" "/me/notification-prefs" "notification_prefs"
dump alex "$ALEX_TOKEN" "/sessions?from=$NOW_RFC3339" "alex_sessions"
dump alex "$ALEX_TOKEN" "/students/user_student_alex/progress" "alex_progress"
dump alex "$ALEX_TOKEN" "/students/user_student_alex/ledger" "alex_ledger"

echo "Done — $OUT now contains the demo seed payloads."
