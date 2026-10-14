package main

import "testing"

func TestProductionBootProblems(t *testing.T) {
	// Helper: build an env getter from a map.
	env := func(m map[string]string) func(string) string {
		return func(k string) string { return m[k] }
	}

	t.Run("non-production: no gate", func(t *testing.T) {
		// Even a totally dev config is fine when APP_ENV isn't production.
		got := productionBootProblems(env(map[string]string{
			"FIREBASE_AUTH_EMULATOR_HOST": "localhost:9099",
		}), false)
		if len(got) != 0 {
			t.Fatalf("expected no problems outside production, got %v", got)
		}
	})

	t.Run("production: clean config passes", func(t *testing.T) {
		got := productionBootProblems(env(map[string]string{
			"APP_ENV":              "production",
			"CORS_ALLOWED_ORIGINS": "https://app.example",
		}), true)
		if len(got) != 0 {
			t.Fatalf("expected clean prod config to pass, got %v", got)
		}
	})

	t.Run("production: flags every dev/insecure setting", func(t *testing.T) {
		got := productionBootProblems(env(map[string]string{
			"APP_ENV":                     "production",
			"FIREBASE_AUTH_EMULATOR_HOST": "localhost:9099",
			"STORAGE_EMULATOR_HOST":       "localhost:9199",
			// CORS unset, firebase not configured
		}), false)
		// Expect: missing CORS, auth emulator, storage emulator, no firebase.
		if len(got) != 4 {
			t.Fatalf("expected 4 problems, got %d: %v", len(got), got)
		}
	})
}
