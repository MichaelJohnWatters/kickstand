package filestore_test

import (
	"bytes"
	"context"
	"io"
	"os"
	"testing"

	"github.com/michaeljohnwatters/kickstand/internal/filestore"
)

// TestGCS_Roundtrip exercises Put / Open / Delete against the Firebase
// Storage emulator. Skipped when the emulator env vars aren't set —
// `make emulator-test` exports both so CI/local runs against the
// emulator run this test, while plain `go test` skips silently.
func TestGCS_Roundtrip(t *testing.T) {
	if os.Getenv("STORAGE_EMULATOR_HOST") == "" &&
		os.Getenv("FIREBASE_STORAGE_EMULATOR_HOST") == "" {
		t.Skip("STORAGE_EMULATOR_HOST not set; run with `make emulator` + the storage env")
	}
	if os.Getenv("FIREBASE_STORAGE_BUCKET") == "" {
		// Default the bucket name to the dev project so the test runs
		// without requiring extra setup once the emulator is up.
		t.Setenv("FIREBASE_STORAGE_BUCKET", "kickstand-dev.appspot.com")
	}

	ctx := context.Background()
	g, err := filestore.NewGCS(ctx)
	if err != nil {
		t.Fatalf("init: %v", err)
	}
	if g == nil {
		t.Fatal("gcs nil — bucket env not picked up?")
	}

	key := "expenses/test-roundtrip/receipt.jpg"
	payload := []byte("hello receipt")

	if _, err := g.Put(key, bytes.NewReader(payload)); err != nil {
		t.Fatalf("put: %v", err)
	}
	t.Cleanup(func() { _ = g.Delete(key) })

	rc, err := g.Open(key)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	got, _ := io.ReadAll(rc)
	rc.Close()
	if !bytes.Equal(got, payload) {
		t.Errorf("payload mismatch: got %q want %q", got, payload)
	}

	if err := g.Delete(key); err != nil {
		t.Errorf("delete: %v", err)
	}
	if _, err := g.Open(key); err == nil {
		t.Errorf("expected ErrNotFound after delete, got nil")
	}
}
