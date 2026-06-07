// Package admin holds the CRUD operations behind the manager screens —
// locations, fleet, course catalogue, staff, and school settings.
//
// Permissions are enforced in the HTTP layer (admin/owner for write,
// often broader for read). The engine functions are pure data access.
//
// Conventions:
//   - Every function takes *tenant.Scope as its first arg after ctx.
//   - Errors map to a stable code at the HTTP boundary (see admin_handlers).
package admin

import "errors"

var (
	ErrNotFound         = errors.New("admin: not found in this school")
	ErrConflict         = errors.New("admin: conflict (duplicate code or in-use reference)")
	ErrInvalidInput     = errors.New("admin: invalid input")
	ErrCannotDeleteUsed = errors.New("admin: cannot delete — record is referenced elsewhere")
)
