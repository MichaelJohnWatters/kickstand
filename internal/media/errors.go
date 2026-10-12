package media

import "errors"

// ErrUnsupported signals the upload couldn't be decoded. Surfaced to
// the HTTP layer as a 400 — most often the user picked a HEIC or
// other format the stdlib doesn't decode.
var ErrUnsupported = errors.New("media: unsupported image format")

// ErrTooLarge signals the upload declares more pixels than MaxPixels — a
// likely decompression bomb (tiny file, enormous dimensions, OOM on decode).
// Surfaced to the HTTP layer as a 413.
var ErrTooLarge = errors.New("media: image dimensions too large")
