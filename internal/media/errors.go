package media

import "errors"

// ErrUnsupported signals the upload couldn't be decoded. Surfaced to
// the HTTP layer as a 400 — most often the user picked a HEIC or
// other format the stdlib doesn't decode.
var ErrUnsupported = errors.New("media: unsupported image format")
