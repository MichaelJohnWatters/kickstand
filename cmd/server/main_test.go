package main

import "testing"

func TestProductionBootProblems(t *testing.T) {
	// Helper: build an env getter from a map.
	env := func(m map[string]string) func(string) string {
		return func(k string) string { return m[k] }
	}

	// A valid signing key for the clean-config case (≥32 bytes).
	const signingKey = "0123456789abcdef0123456789abcdef"

	t.Run("non-production: no gate", func(t *testing.T) {
		// Even a totally dev config is fine when APP_ENV isn't production.
		got := productionBootProblems(env(map[string]string{
			"STORAGE_EMULATOR_HOST": "localhost:9199",
		}))
		if len(got) != 0 {
			t.Fatalf("expected no problems outside production, got %v", got)
		}
	})

	t.Run("production: clean config passes", func(t *testing.T) {
		got := productionBootProblems(env(map[string]string{
			"APP_ENV":              "production",
			"CORS_ALLOWED_ORIGINS": "https://app.example",
			"JWT_SIGNING_KEY":      signingKey,
		}))
		if len(got) != 0 {
			t.Fatalf("expected clean prod config to pass, got %v", got)
		}
	})

	t.Run("production: flags every dev/insecure setting", func(t *testing.T) {
		got := productionBootProblems(env(map[string]string{
			"APP_ENV":               "production",
			"STORAGE_EMULATOR_HOST": "localhost:9199",
			// CORS unset, JWT_SIGNING_KEY unset
		}))
		// Expect: missing CORS, missing signing key, storage emulator.
		if len(got) != 3 {
			t.Fatalf("expected 3 problems, got %d: %v", len(got), got)
		}
	})
}
