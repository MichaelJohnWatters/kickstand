package calendar

import (
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

func ts(hour int) time.Time {
	return time.Date(2026, 6, 6, hour, 0, 0, 0, time.UTC)
}

// Two sessions at different sites with a gap shorter than travel+buffer, but
// NO assigned instructor. They must not generate a travel warning — nobody is
// driving between them. (Regression: both bucketed under instructor "".)
func TestComputeTravelWarnings_SkipsUnstaffedSessions(t *testing.T) {
	sessions := []SessionRow{
		{SessionID: "s1", InstructorID: "", LocationID: "belfast", LocationName: "Belfast",
			StartsAt: ts(9), EndsAt: ts(10)},
		{SessionID: "s2", InstructorID: "", LocationID: "lisburn", LocationName: "Lisburn",
			StartsAt: ts(10), EndsAt: ts(11)},
	}
	matrix := map[travelKey]int{{"belfast", "lisburn"}: 25}

	if got := computeTravelWarnings(sessions, matrix, 15); len(got) != 0 {
		t.Fatalf("expected 0 warnings for unstaffed sessions, got %d: %+v", len(got), got)
	}
}

// Positive control: the exact same tight cross-site pair, but assigned to one
// instructor, MUST warn — otherwise the skip above would be hiding a real one.
func TestComputeTravelWarnings_WarnsForStaffedTightTransfer(t *testing.T) {
	const dave = domain.UserID("dave")
	sessions := []SessionRow{
		{SessionID: "s1", InstructorID: dave, LocationID: "belfast", LocationName: "Belfast",
			StartsAt: ts(9), EndsAt: ts(10)},
		{SessionID: "s2", InstructorID: dave, LocationID: "lisburn", LocationName: "Lisburn",
			StartsAt: ts(10), EndsAt: ts(11)},
	}
	matrix := map[travelKey]int{{"belfast", "lisburn"}: 25}

	got := computeTravelWarnings(sessions, matrix, 15)
	if len(got) != 1 {
		t.Fatalf("expected 1 warning for staffed tight transfer, got %d", len(got))
	}
	if got[0].InstructorID != dave {
		t.Errorf("warning instructor = %q, want %q", got[0].InstructorID, dave)
	}
}

// Two instructors each teaching once must never be compared to each other,
// even when both lack travel-feasible gaps between their respective sites.
func TestComputeTravelWarnings_DoesNotCrossInstructors(t *testing.T) {
	sessions := []SessionRow{
		{SessionID: "s1", InstructorID: "dave", LocationID: "belfast", StartsAt: ts(9), EndsAt: ts(10)},
		{SessionID: "s2", InstructorID: "priya", LocationID: "lisburn", StartsAt: ts(10), EndsAt: ts(11)},
	}
	matrix := map[travelKey]int{{"belfast", "lisburn"}: 25}
	if got := computeTravelWarnings(sessions, matrix, 15); len(got) != 0 {
		t.Fatalf("expected 0 warnings across different instructors, got %d", len(got))
	}
}
