package domain

import "time"

// Money is integer pence. Never floats — accountants and floating-point
// rounding don't mix.
type Money int64

type School struct {
	ID                           SchoolID
	Name                         string
	Region                       Region
	TestBodyLabel                string // 'DVA' or 'DVSA'
	OnboardingMode               string // 'open' | 'approval'
	InstructorsCanRecordPayments bool
	CancelCutoffHours            int
	TravelBufferMinutes          int
	CrossSiteNoticeHours         int
	CreatedAt                    time.Time
}

type User struct {
	ID            UserID
	SchoolID      SchoolID
	Email         string
	Phone         string
	Name          string
	Role          Role
	AccountStatus AccountStatus
	CreatedAt     time.Time
}

type StudentProfile struct {
	UserID                 UserID
	SchoolID               SchoolID
	ProvisionalLicenceNo   string
	LicenceCategoryPursued LicenceCategory
	RiderDateOfBirth       string // YYYY-MM-DD
	TransmissionPreference Transmission
	CBTHeld                bool
	CBTVariant             string
	CBTExpiresOn           string // YYYY-MM-DD
	CBTRegion              Region
	TheoryPassed           bool
	TheoryPassedOn         string // YYYY-MM-DD
}

type Location struct {
	ID        LocationID
	SchoolID  SchoolID
	Name      string
	Address   string
	CreatedAt time.Time
}

type Bike struct {
	ID                BikeID
	SchoolID          SchoolID
	Nickname          string
	Make              string
	Model             string
	Registration      string
	Category          LicenceCategory
	Transmission      Transmission
	EngineCC          int
	Status            BikeStatus
	HomeLocationID    LocationID
	CurrentLocationID LocationID
	CreatedAt         time.Time
}

type CourseType struct {
	ID                      CourseTypeID
	SchoolID                SchoolID
	Code                    string
	Name                    string
	Region                  Region
	RequiredBikeCategory    LicenceCategory // empty for non-bike courses (rare)
	DurationMinutes         int
	MaxRatio                int
	PricePence              Money
	NonTeaching             bool
	CancellationCutoffHours int
}

type Session struct {
	ID           SessionID
	SchoolID     SchoolID
	CourseTypeID CourseTypeID
	InstructorID UserID
	LocationID   LocationID
	StartsAt     time.Time
	EndsAt       time.Time
	Capacity     int
	Status       string // 'scheduled' | 'completed' | 'cancelled'
	Notes        string
	CreatedAt    time.Time
}

type Charge struct {
	ID          ChargeID
	SchoolID    SchoolID
	StudentID   UserID
	BookingID   BookingID // empty if not booking-tied
	AmountPence Money
	Description string
	IncurredAt  time.Time
	CreatedAt   time.Time
	CreatedBy   UserID
	VoidedAt    time.Time // zero if not voided
	VoidedBy    UserID
	VoidReason  string
}

type Payment struct {
	ID          PaymentID
	SchoolID    SchoolID
	StudentID   UserID
	AmountPence Money
	Method      PaymentMethod
	ReceivedAt  time.Time
	RecordedBy  UserID
	Notes       string
	VoidedAt    time.Time // zero if not voided
	VoidedBy    UserID
	VoidReason  string
}

type Booking struct {
	ID                 BookingID
	SchoolID           SchoolID
	SessionID          SessionID
	StudentID          UserID
	BikeID             BikeID // empty if not yet assigned
	Status             BookingStatus
	CancelledBy        CancelledBy
	CancellationReason string
	Notes              string
	CreatedAt          time.Time
	CancelledAt        time.Time // zero if not cancelled
}
