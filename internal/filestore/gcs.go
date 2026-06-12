package filestore

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"cloud.google.com/go/storage"
	"google.golang.org/api/iterator"
	"google.golang.org/api/option"
)

// GCS is the Firebase Storage / Google Cloud Storage implementation of
// `Store`. Used in production and against the Firebase Storage
// emulator in local dev.
//
// Wire-up:
//
//   - Production: set FIREBASE_STORAGE_BUCKET=<project>.appspot.com
//     (and GOOGLE_APPLICATION_CREDENTIALS to a service-account key).
//   - Emulator: set FIREBASE_STORAGE_EMULATOR_HOST=localhost:9199
//     plus FIREBASE_STORAGE_BUCKET=kickstand-dev.appspot.com. The GCS
//     client library reads STORAGE_EMULATOR_HOST automatically when
//     it's set, so we mirror that.
//
// The bucket is expected to be private — only this process (with its
// service-account credentials) reads or writes objects. Clients fetch
// receipts via `GET /expenses/{id}/receipt`, which checks permissions
// and streams bytes through. There is no signed-URL surface and no
// direct-client SDK usage.
type GCS struct {
	client *storage.Client
	bucket string
}

// NewGCS constructs a GCS-backed store. Returns (nil, nil) when no
// bucket env var is set so main can fall back to a local filestore
// without a special-case check.
func NewGCS(ctx context.Context) (*GCS, error) {
	bucket := os.Getenv("FIREBASE_STORAGE_BUCKET")
	if bucket == "" {
		return nil, nil
	}
	// Emulator: the GCS client library checks STORAGE_EMULATOR_HOST on
	// its own, but we accept the Firebase-style FIREBASE_STORAGE_EMULATOR_HOST
	// so users keep one variable per emulator. Mirror it into the
	// expected GCS env if only the Firebase form is set.
	if os.Getenv("STORAGE_EMULATOR_HOST") == "" {
		if h := os.Getenv("FIREBASE_STORAGE_EMULATOR_HOST"); h != "" {
			_ = os.Setenv("STORAGE_EMULATOR_HOST", h)
		}
	}

	var opts []option.ClientOption
	if host := os.Getenv("STORAGE_EMULATOR_HOST"); host != "" {
		// Belt-and-suspenders for emulator mode. Two things go wrong if
		// you rely on the env var alone:
		//   1. storage.NewClient otherwise tries Application Default
		//      Credentials, which can hang on the metadata service
		//      probe (~30s per attempt) before falling back.
		//   2. Some versions of cloud.google.com/go/storage don't
		//      honour STORAGE_EMULATOR_HOST for every request — pinning
		//      the endpoint forces the issue.
		endpoint := host
		if !strings.HasPrefix(endpoint, "http://") && !strings.HasPrefix(endpoint, "https://") {
			endpoint = "http://" + endpoint
		}
		opts = append(opts,
			option.WithoutAuthentication(),
			option.WithEndpoint(endpoint),
		)
	}
	client, err := storage.NewClient(ctx, opts...)
	if err != nil {
		return nil, fmt.Errorf("filestore: gcs client: %w", err)
	}
	// Deliberately NOT probing the bucket here — keeps server startup
	// non-blocking regardless of emulator/GCS health. Bucket auto-create
	// (emulator-only) happens lazily on the first Put.
	return &GCS{client: client, bucket: bucket}, nil
}

func (g *GCS) Put(key string, r io.Reader) (string, error) {
	ctx := context.Background()
	// No bucket-create probe: real GCS requires the bucket to exist
	// (we don't have create perms in prod) and the Firebase Storage
	// emulator auto-creates on first upload. The standard bucket-
	// create REST endpoint returns 501 against the emulator, which
	// makes the SDK hang on retry — see the gcs_test.go writeup.
	obj := g.client.Bucket(g.bucket).Object(key)
	w := obj.NewWriter(ctx)
	if _, err := io.Copy(w, r); err != nil {
		_ = w.Close()
		return "", fmt.Errorf("filestore: gcs put: %w", err)
	}
	if err := w.Close(); err != nil {
		return "", fmt.Errorf("filestore: gcs put close: %w", err)
	}
	return key, nil
}

func (g *GCS) Open(key string) (io.ReadCloser, error) {
	ctx := context.Background()
	rc, err := g.client.Bucket(g.bucket).Object(key).NewReader(ctx)
	if errors.Is(err, storage.ErrObjectNotExist) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("filestore: gcs open: %w", err)
	}
	return rc, nil
}

func (g *GCS) Delete(key string) error {
	ctx := context.Background()
	err := g.client.Bucket(g.bucket).Object(key).Delete(ctx)
	if errors.Is(err, storage.ErrObjectNotExist) {
		return nil // idempotent
	}
	if err != nil {
		return fmt.Errorf("filestore: gcs delete: %w", err)
	}
	return nil
}

// HouseKeepingDeletePrefix is a test-only helper that nukes every
// object under the given prefix. Exposed to keep the
// emulator clean between fixture runs.
func (g *GCS) HouseKeepingDeletePrefix(ctx context.Context, prefix string) error {
	it := g.client.Bucket(g.bucket).Objects(ctx, &storage.Query{Prefix: prefix})
	for {
		attrs, err := it.Next()
		if errors.Is(err, iterator.Done) {
			return nil
		}
		if err != nil {
			return err
		}
		if err := g.client.Bucket(g.bucket).Object(attrs.Name).Delete(ctx); err != nil &&
			!errors.Is(err, storage.ErrObjectNotExist) {
			return err
		}
	}
}
