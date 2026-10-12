package media

import (
	"bytes"
	"encoding/binary"
	"errors"
	"hash/crc32"
	"testing"
)

// pngHeaderOnly builds a valid PNG signature + IHDR chunk declaring the given
// dimensions, with no pixel data. image.DecodeConfig only needs IHDR, so this
// lets us assert the dimension guard WITHOUT allocating a giant buffer — the
// whole point of checking DecodeConfig before Decode.
func pngHeaderOnly(w, h uint32) []byte {
	var b bytes.Buffer
	b.Write([]byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'})
	ihdr := make([]byte, 13)
	binary.BigEndian.PutUint32(ihdr[0:], w)
	binary.BigEndian.PutUint32(ihdr[4:], h)
	ihdr[8] = 8 // bit depth
	ihdr[9] = 2 // colour type: truecolour
	// compression/filter/interlace = 0 (already zeroed)
	_ = binary.Write(&b, binary.BigEndian, uint32(len(ihdr)))
	typ := []byte("IHDR")
	b.Write(typ)
	b.Write(ihdr)
	crc := crc32.NewIEEE()
	crc.Write(typ)
	crc.Write(ihdr)
	_ = binary.Write(&b, binary.BigEndian, crc.Sum32())
	return b.Bytes()
}

func TestProcessReceipt_RejectsPixelBomb(t *testing.T) {
	// 60000 × 60000 = 3.6e9 pixels ≫ MaxPixels. A real decode would try to
	// allocate ~14 GB; the dimension guard must reject it from the header.
	bomb := pngHeaderOnly(60000, 60000)
	if len(bomb) > 1024 {
		t.Fatalf("sanity: bomb header should be tiny, got %d bytes", len(bomb))
	}
	_, err := ProcessReceipt(bytes.NewReader(bomb))
	if !errors.Is(err, ErrTooLarge) {
		t.Fatalf("expected ErrTooLarge for a %d-byte header declaring 60000×60000, got %v", len(bomb), err)
	}
}

func TestProcessReceipt_AllowsReasonableDimensions(t *testing.T) {
	// A normal phone-sized photo (well under MaxPixels) must still process.
	out, err := ProcessReceipt(bytes.NewReader(makeJPEG(t, 2000, 1500)))
	if err != nil {
		t.Fatalf("expected normal image to process, got %v", err)
	}
	if len(out.Main) == 0 || len(out.Thumb) == 0 {
		t.Fatal("expected non-empty main and thumb")
	}
}
