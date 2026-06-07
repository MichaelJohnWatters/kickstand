package httpapi_test

import "github.com/michaeljohnwatters/kickstand/internal/auth"

// authHashPassword exposes auth.HashPassword to test files inside this
// package without each file needing to import auth.
func authHashPassword(plain string) (string, error) {
	return auth.HashPassword(plain)
}
