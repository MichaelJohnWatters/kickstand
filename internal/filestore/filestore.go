// Package filestore is a tiny abstraction over "put a blob, get it back
// later". Today there's one implementation (`Local`) writing to a
// directory on disk. At Firebase cutover we add a GCS implementation that
// satisfies the same interface — see firebase-auth-migration.md.
//
// Receipts are the only blob type today (instructor expense photos). The
// engine writes them under `expenses/{id}/{filename}` so a future S3/GCS
// inventory listing has a predictable prefix.
package filestore

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Store is the seam swapped at deploy time. Methods take a `key` which
// is a forward-slash separated logical path (e.g. `expenses/abc/receipt.jpg`);
// implementations map it onto whatever underlying namespace they use.
type Store interface {
	// Put copies `r` into the store at `key`. Returns the same key for
	// convenience (so callers can chain). Overwrites any existing object.
	Put(key string, r io.Reader) (string, error)
	// Open returns a reader for the blob at `key`. Caller closes it.
	Open(key string) (io.ReadCloser, error)
	// Delete removes the blob. No-op if it doesn't exist.
	Delete(key string) error
}

var ErrNotFound = errors.New("filestore: object not found")

// Local stores objects under a base directory on the local filesystem.
// Suitable for dev and single-instance prod; in production behind a load
// balancer use the GCS implementation instead.
type Local struct {
	BaseDir string
}

func NewLocal(baseDir string) (*Local, error) {
	abs, err := filepath.Abs(baseDir)
	if err != nil {
		return nil, fmt.Errorf("filestore: abs %s: %w", baseDir, err)
	}
	if err := os.MkdirAll(abs, 0o755); err != nil {
		return nil, fmt.Errorf("filestore: mkdir %s: %w", abs, err)
	}
	return &Local{BaseDir: abs}, nil
}

func (l *Local) path(key string) (string, error) {
	clean := filepath.Clean("/" + key)         // forbids `..` traversal
	clean = strings.TrimPrefix(clean, "/")
	if clean == "" || clean == "." {
		return "", fmt.Errorf("filestore: empty key")
	}
	return filepath.Join(l.BaseDir, clean), nil
}

func (l *Local) Put(key string, r io.Reader) (string, error) {
	dst, err := l.path(key)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return "", fmt.Errorf("filestore: mkdir: %w", err)
	}
	f, err := os.Create(dst)
	if err != nil {
		return "", fmt.Errorf("filestore: create: %w", err)
	}
	defer f.Close()
	if _, err := io.Copy(f, r); err != nil {
		_ = os.Remove(dst)
		return "", fmt.Errorf("filestore: write: %w", err)
	}
	return key, nil
}

func (l *Local) Open(key string) (io.ReadCloser, error) {
	src, err := l.path(key)
	if err != nil {
		return nil, err
	}
	f, err := os.Open(src)
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotFound
	}
	return f, err
}

func (l *Local) Delete(key string) error {
	src, err := l.path(key)
	if err != nil {
		return err
	}
	if err := os.Remove(src); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("filestore: remove: %w", err)
	}
	return nil
}
