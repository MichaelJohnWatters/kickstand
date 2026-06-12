// Package media handles receipt-image processing on the upload path.
//
// Phones submit anything from a 200 KB JPEG to an 8 MB raw camera dump.
// We normalise everything to:
//
//   - main image: max 1600 px on the longest edge, JPEG quality 80.
//     Typically lands at 200–500 KB. Text on a receipt stays legible.
//   - thumbnail: 50×50 JPEG quality 60. ~1–2 KB. Returned inline in
//     list responses (base64-encoded) so the manager review queue
//     shows real previews without an extra fetch per row.
//
// Decoded via the stdlib decoders (JPEG / PNG / GIF). HEIC/HEIF (iPhone
// default) isn't covered — the Flutter image_picker plugin transcodes
// to JPEG before upload, so it doesn't reach us.
package media

import (
	"bytes"
	"fmt"
	"image"
	_ "image/gif" // register decoder
	"image/jpeg"
	_ "image/png" // register decoder
	"io"

	"golang.org/x/image/draw"
)

// MaxLongEdge is the bound the main image is resized to on its longest
// side. Picked to keep handwritten receipts legible at the modal view
// resolution while shrinking phone dumps ~10×.
const MaxLongEdge = 1600

// ThumbEdge is the size of both width and height of the inline preview
// — the manager list paints a small square chip per row.
const ThumbEdge = 50

// MainQuality / ThumbQuality are the JPEG encoder qualities. 80 is the
// "no visible artefacts at typical screen DPI" sweet spot; 60 is the
// thumb sweet spot (the visible cell is tiny so artefacts blend in).
const (
	MainQuality  = 80
	ThumbQuality = 60
)

// Processed is the output of ProcessReceipt: a resized main image
// re-encoded as JPEG, and a tiny thumbnail also as JPEG.
type Processed struct {
	Main      []byte
	MainBytes int
	Thumb     []byte
}

// ProcessReceipt decodes the raw upload, resizes the main image to fit
// MaxLongEdge while preserving aspect ratio, generates a square thumb,
// and re-encodes both as JPEG. Returns ErrUnsupported when the upload
// isn't a format we can decode.
func ProcessReceipt(r io.Reader) (*Processed, error) {
	src, _, err := image.Decode(r)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnsupported, err)
	}

	main := resizeFit(src, MaxLongEdge)
	thumb := resizeCrop(src, ThumbEdge)

	var mainBuf bytes.Buffer
	if err := jpeg.Encode(&mainBuf, main, &jpeg.Options{Quality: MainQuality}); err != nil {
		return nil, fmt.Errorf("encode main: %w", err)
	}
	var thumbBuf bytes.Buffer
	if err := jpeg.Encode(&thumbBuf, thumb, &jpeg.Options{Quality: ThumbQuality}); err != nil {
		return nil, fmt.Errorf("encode thumb: %w", err)
	}
	return &Processed{
		Main:      mainBuf.Bytes(),
		MainBytes: mainBuf.Len(),
		Thumb:     thumbBuf.Bytes(),
	}, nil
}

// resizeFit scales the image so its longest edge is `edge`, preserving
// the aspect ratio. No-op when the source is already smaller — never
// upscale.
func resizeFit(src image.Image, edge int) image.Image {
	b := src.Bounds()
	srcW, srcH := b.Dx(), b.Dy()
	longest := srcW
	if srcH > longest {
		longest = srcH
	}
	if longest <= edge {
		return src
	}
	var dstW, dstH int
	if srcW >= srcH {
		dstW = edge
		dstH = srcH * edge / srcW
	} else {
		dstH = edge
		dstW = srcW * edge / srcH
	}
	dst := image.NewRGBA(image.Rect(0, 0, dstW, dstH))
	draw.CatmullRom.Scale(dst, dst.Bounds(), src, b, draw.Over, nil)
	return dst
}

// resizeCrop produces a square `edge×edge` thumbnail by centre-cropping
// the source to a square then scaling. This is the standard "tile"
// thumb pattern — no letterboxing, no aspect distortion.
func resizeCrop(src image.Image, edge int) image.Image {
	b := src.Bounds()
	srcW, srcH := b.Dx(), b.Dy()
	side := srcW
	if srcH < side {
		side = srcH
	}
	offX := (srcW - side) / 2
	offY := (srcH - side) / 2
	cropRect := image.Rect(b.Min.X+offX, b.Min.Y+offY, b.Min.X+offX+side, b.Min.Y+offY+side)
	dst := image.NewRGBA(image.Rect(0, 0, edge, edge))
	draw.CatmullRom.Scale(dst, dst.Bounds(), src, cropRect, draw.Over, nil)
	return dst
}
