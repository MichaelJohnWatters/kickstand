package domain

import "github.com/google/uuid"

// Typed string IDs make it a compile error to pass a UserID where a SchoolID
// is expected. The cost is a bit of verbosity at the boundaries; the win is
// that tenant-isolation slip-ups (the highest-stakes mistake in this codebase)
// are caught by `go build` rather than at 2am.

type (
	SchoolID         string
	UserID           string
	LocationID       string
	BikeID           string
	BikeUnavailID    string
	CourseTypeID     string
	CompetencyID     string
	SessionID        string
	BookingID        string
	ProgressID       string
	DisruptionID     string
	ExternalTestID   string
	IncidentID       string
	StudentNoteID    string
	ChargeID         string
	PaymentID        string
	PayModelID       string
	EarningID        string
	InstructorPayID  string
	EventID          string
	NotificationID   string
	AvailabilityID   string
	TimeOffID        string
	ExpenseID        string
	ExpenseCategoryID string
	UserSessionToken string
	WaitlistID       string
)

// NewID returns a fresh UUIDv4 as a string. Kept as a single seam so we can
// swap in ULIDv7 later (better k-sort behaviour) without touching every caller.
func NewID() string {
	return uuid.NewString()
}
