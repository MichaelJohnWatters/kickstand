package domain

// Region — the country whose licensing pathway applies. NI ≠ GB; course types
// and test names differ. Don't hardcode GB's Mod 1/2 anywhere.
type Region string

const (
	RegionNI Region = "NI"
	RegionGB Region = "GB"
)

// Role — a person's primary capacity in the school. The plan acknowledges a
// person could hold multiple roles; we start with one to keep the auth simple
// and add a join table later if it bites.
type Role string

const (
	RoleStudent    Role = "student"
	RoleInstructor Role = "instructor"
	RoleAdmin      Role = "admin"
	RoleOwner      Role = "owner"
)

// AccountStatus — gates whether a student may book. Pending users can browse
// but not confirm. See plan §3 "Student onboarding".
type AccountStatus string

const (
	AccountActive          AccountStatus = "active"
	AccountPendingApproval AccountStatus = "pending_approval"
	AccountDisabled        AccountStatus = "disabled"
)

// LicenceCategory — shared across regions; only test/course naming differs.
type LicenceCategory string

const (
	CategoryAM LicenceCategory = "AM"
	CategoryA1 LicenceCategory = "A1"
	CategoryA2 LicenceCategory = "A2"
	CategoryA  LicenceCategory = "A"
)

type Transmission string

const (
	TransmissionManual Transmission = "manual"
	TransmissionAuto   Transmission = "auto"
)

type BikeStatus string

const (
	BikeReady   BikeStatus = "ready"
	BikeOffline BikeStatus = "offline"
	BikeInUse   BikeStatus = "in_use"
)

type BookingStatus string

const (
	BookingBooked            BookingStatus = "booked"
	BookingCompleted         BookingStatus = "completed"
	BookingNoShow            BookingStatus = "no_show"
	BookingCancelled         BookingStatus = "cancelled"
	BookingNeedsReassignment BookingStatus = "needs_reassignment"
)

type CancelledBy string

const (
	CancelledByStudent CancelledBy = "student"
	CancelledBySchool  CancelledBy = "school"
)

type PaymentMethod string

const (
	PayCash         PaymentMethod = "cash"
	PayBankTransfer PaymentMethod = "bank_transfer"
	PayCardInPerson PaymentMethod = "card_in_person"
	PayOther        PaymentMethod = "other"
)

type PayBasis string

const (
	BasisPercentage PayBasis = "percentage"
	BasisPerDay     PayBasis = "per_day"
	BasisPerSession PayBasis = "per_session"
	BasisPerHour    PayBasis = "per_hour"
	BasisPerStudent PayBasis = "per_student"
	BasisSalary     PayBasis = "salary"
)
