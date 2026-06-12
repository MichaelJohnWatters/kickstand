package media

import (
	"bytes"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"strings"
	"testing"
)

// makeJPEG produces a JPEG of size w×h filled with a deterministic
// pattern. Used to feed ProcessReceipt without committing binary
// fixtures to the repo.
func makeJPEG(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{
				R: uint8(x % 256),
				G: uint8(y % 256),
				B: uint8((x + y) % 256),
				A: 255,
			})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 95}); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestProcessReceipt_LargeJPEG_IsShrunkAndCompressed(t *testing.T) {
	// 3000×2000 is a realistic phone-camera size.
	src := makeJPEG(t, 3000, 2000)
	out, err := ProcessReceipt(bytes.NewReader(src))
	if err != nil {
		t.Fatalf("process: %v", err)
	}

	mainImg, _, err := image.Decode(bytes.NewReader(out.Main))
	if err != nil {
		t.Fatalf("decode main: %v", err)
	}
	b := mainImg.Bounds()
	if b.Dx() > MaxLongEdge || b.Dy() > MaxLongEdge {
		t.Errorf("main %dx%d exceeds max %d", b.Dx(), b.Dy(), MaxLongEdge)
	}
	// Longest edge should be at MaxLongEdge (not under, since input is
	// bigger).
	longest := b.Dx()
	if b.Dy() > longest {
		longest = b.Dy()
	}
	if longest != MaxLongEdge {
		t.Errorf("expected longest edge %d, got %d", MaxLongEdge, longest)
	}
	if len(out.Main) >= len(src) {
		t.Errorf("compression made it bigger: %d → %d", len(src), len(out.Main))
	}
}

func TestProcessReceipt_SmallImage_NotUpscaled(t *testing.T) {
	src := makeJPEG(t, 800, 600)
	out, err := ProcessReceipt(bytes.NewReader(src))
	if err != nil {
		t.Fatal(err)
	}
	mainImg, _, err := image.Decode(bytes.NewReader(out.Main))
	if err != nil {
		t.Fatal(err)
	}
	b := mainImg.Bounds()
	if b.Dx() != 800 || b.Dy() != 600 {
		t.Errorf("small image got resized: %dx%d", b.Dx(), b.Dy())
	}
}

func TestProcessReceipt_Thumb_Is50x50(t *testing.T) {
	src := makeJPEG(t, 1024, 768)
	out, err := ProcessReceipt(bytes.NewReader(src))
	if err != nil {
		t.Fatal(err)
	}
	thumb, _, err := image.Decode(bytes.NewReader(out.Thumb))
	if err != nil {
		t.Fatal(err)
	}
	b := thumb.Bounds()
	if b.Dx() != ThumbEdge || b.Dy() != ThumbEdge {
		t.Errorf("thumb size: got %dx%d want %dx%d",
			b.Dx(), b.Dy(), ThumbEdge, ThumbEdge)
	}
	if len(out.Thumb) > 4096 {
		t.Errorf("thumb too large: %d bytes (expected <4KB)", len(out.Thumb))
	}
}

func TestProcessReceipt_AspectRatioPreserved(t *testing.T) {
	// Tall portrait — height should be MaxLongEdge, width scaled down.
	src := makeJPEG(t, 1500, 3000)
	out, err := ProcessReceipt(bytes.NewReader(src))
	if err != nil {
		t.Fatal(err)
	}
	mainImg, _, err := image.Decode(bytes.NewReader(out.Main))
	if err != nil {
		t.Fatal(err)
	}
	b := mainImg.Bounds()
	if b.Dy() != MaxLongEdge {
		t.Errorf("expected height %d, got %d", MaxLongEdge, b.Dy())
	}
	// Allow ±1 px for integer rounding.
	expectedW := 1500 * MaxLongEdge / 3000
	if abs(b.Dx()-expectedW) > 1 {
		t.Errorf("width: got %d want ~%d", b.Dx(), expectedW)
	}
}

func TestProcessReceipt_PNG_Works(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 600, 400))
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	out, err := ProcessReceipt(&buf)
	if err != nil {
		t.Fatalf("PNG input rejected: %v", err)
	}
	if len(out.Main) == 0 || len(out.Thumb) == 0 {
		t.Errorf("empty output")
	}
}

func TestProcessReceipt_Garbage_ReturnsUnsupported(t *testing.T) {
	_, err := ProcessReceipt(strings.NewReader("not an image at all"))
	if !errors.Is(err, ErrUnsupported) {
		t.Errorf("expected ErrUnsupported, got %v", err)
	}
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}
