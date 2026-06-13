package teltonika

import (
	"bytes"
	"encoding/binary"
	"io"
	"math"
	"testing"
	"time"
)

// Tests build wire-format Codec-8 frames via buildFrame and round-
// trip them through DecodeFrame. A hardcoded reference packet from
// Teltonika docs would be ideal but I couldn't reliably verify byte
// counts; the round-trip + error-path tests exercise the same parse
// path. Once we have a real device generating frames we should pin
// one captured packet here as a regression fixture.

// Round-trip: build a frame in code, parse it, get back the records.
// Asserts the parser interprets the wire format we produce. Anchors
// the lat/lng scaling.
func TestDecodeFrame_Roundtrip(t *testing.T) {
	want := []Record{
		{
			At:        time.Date(2026, 6, 13, 14, 30, 0, 0, time.UTC),
			Priority:  1,
			Lat:       54.5825,  // Belfast
			Lng:       -5.9655,
			AltitudeM: 23,
			AngleDeg:  90,
			Sats:      12,
			Speed:     32,
		},
		{
			At:        time.Date(2026, 6, 13, 14, 31, 0, 0, time.UTC),
			Priority:  1,
			Lat:       54.5188,  // Lisburn
			Lng:       -6.0640,
			AltitudeM: 80,
			AngleDeg:  180,
			Sats:      11,
			Speed:     58,
		},
	}
	frame := buildFrame(t, want)
	got, err := DecodeFrame(bytes.NewReader(frame))
	if err != nil {
		t.Fatalf("DecodeFrame: %v", err)
	}
	if len(got) != len(want) {
		t.Fatalf("count: got %d want %d", len(got), len(want))
	}
	for i, w := range want {
		g := got[i]
		if !g.At.Equal(w.At) {
			t.Errorf("rec %d At: got %v want %v", i, g.At, w.At)
		}
		if math.Abs(g.Lat-w.Lat) > 1e-6 {
			t.Errorf("rec %d Lat: got %v want %v", i, g.Lat, w.Lat)
		}
		if math.Abs(g.Lng-w.Lng) > 1e-6 {
			t.Errorf("rec %d Lng: got %v want %v", i, g.Lng, w.Lng)
		}
		if g.AltitudeM != w.AltitudeM {
			t.Errorf("rec %d Altitude: got %v want %v", i, g.AltitudeM, w.AltitudeM)
		}
		if g.AngleDeg != w.AngleDeg {
			t.Errorf("rec %d Angle: got %v want %v", i, g.AngleDeg, w.AngleDeg)
		}
		if g.Speed != w.Speed {
			t.Errorf("rec %d Speed: got %v want %v", i, g.Speed, w.Speed)
		}
		if g.Sats != w.Sats {
			t.Errorf("rec %d Sats: got %v want %v", i, g.Sats, w.Sats)
		}
	}
}

func TestDecodeFrame_RejectsBadPreamble(t *testing.T) {
	body := append([]byte{0xff, 0xff, 0xff, 0xff}, make([]byte, 64)...)
	_, err := DecodeFrame(bytes.NewReader(body))
	if err != ErrBadPreamble {
		t.Errorf("want ErrBadPreamble, got %v", err)
	}
}

func TestDecodeFrame_RejectsUnknownCodec(t *testing.T) {
	// Preamble + length=3 + codec 0x07 + count 0 + trailing 0
	frame := []byte{0, 0, 0, 0, 0, 0, 0, 3, 0x07, 0x00, 0x00, 0, 0, 0, 0}
	_, err := DecodeFrame(bytes.NewReader(frame))
	if err != ErrUnknownCodec {
		t.Errorf("want ErrUnknownCodec, got %v", err)
	}
}

func TestReadIMEI(t *testing.T) {
	// 2-byte length + 15-byte ASCII IMEI
	imei := "350123456789012"
	buf := append([]byte{0x00, byte(len(imei))}, []byte(imei)...)
	got, err := ReadIMEI(bytes.NewReader(buf))
	if err != nil {
		t.Fatalf("ReadIMEI: %v", err)
	}
	if got != imei {
		t.Errorf("got %q want %q", got, imei)
	}
}

func TestReadIMEI_RejectsImplausibleLength(t *testing.T) {
	// Length = 0 — refused.
	if _, err := ReadIMEI(bytes.NewReader([]byte{0x00, 0x00})); err == nil {
		t.Error("expected error for zero-length IMEI, got nil")
	}
	// Length > 32 — refused.
	if _, err := ReadIMEI(bytes.NewReader([]byte{0x00, 0xff})); err == nil {
		t.Error("expected error for huge IMEI length, got nil")
	}
}

func TestReadIMEI_PropagatesShortRead(t *testing.T) {
	// Length says 15 but we hand it 0 bytes.
	_, err := ReadIMEI(bytes.NewReader([]byte{0x00, 0x0f}))
	if err == nil {
		t.Error("expected EOF, got nil")
	}
}

func TestAVLAck(t *testing.T) {
	want := []byte{0, 0, 0, 5}
	if !bytes.Equal(AVLAck(5), want) {
		t.Errorf("AVLAck(5): got %v want %v", AVLAck(5), want)
	}
}

// buildFrame composes a wire-format Codec-8 frame from a record
// slice. No IO elements written (empty IO block).
func buildFrame(t *testing.T, recs []Record) []byte {
	t.Helper()
	var body bytes.Buffer
	body.WriteByte(0x08) // codec id
	body.WriteByte(uint8(len(recs)))
	for _, r := range recs {
		var u8 [8]byte
		binary.BigEndian.PutUint64(u8[:], uint64(r.At.UnixMilli()))
		body.Write(u8[:])
		body.WriteByte(r.Priority)
		// GPS element
		var u4 [4]byte
		binary.BigEndian.PutUint32(u4[:], uint32(int32(r.Lng*1e7)))
		body.Write(u4[:])
		binary.BigEndian.PutUint32(u4[:], uint32(int32(r.Lat*1e7)))
		body.Write(u4[:])
		var u2 [2]byte
		binary.BigEndian.PutUint16(u2[:], uint16(r.AltitudeM))
		body.Write(u2[:])
		binary.BigEndian.PutUint16(u2[:], r.AngleDeg)
		body.Write(u2[:])
		body.WriteByte(r.Sats)
		binary.BigEndian.PutUint16(u2[:], r.Speed)
		body.Write(u2[:])
		// IO element — empty (event_io_id=0, total_io=0, all counts 0)
		body.Write([]byte{0, 0, 0, 0, 0, 0})
	}
	body.WriteByte(uint8(len(recs))) // trailing count
	var out bytes.Buffer
	out.Write([]byte{0, 0, 0, 0}) // preamble
	var ln [4]byte
	binary.BigEndian.PutUint32(ln[:], uint32(body.Len()))
	out.Write(ln[:])
	out.Write(body.Bytes())
	out.Write([]byte{0, 0, 0, 0}) // CRC (unchecked)
	return out.Bytes()
}

// Trip a short-payload error by feeding a length header that
// promises more body than the reader can supply.
func TestDecodeFrame_ShortPayload(t *testing.T) {
	frame := []byte{0, 0, 0, 0, 0, 0, 0, 0xff} // claims 255 bytes; supplies 0
	_, err := DecodeFrame(bytes.NewReader(frame))
	if err == nil || err == io.EOF {
		// EOF is also acceptable here — the spec violation is "ran
		// out of bytes mid-frame," which io.ReadFull surfaces as
		// ErrUnexpectedEOF wrapped via fmt.Errorf in DecodeFrame.
	}
	if err == nil {
		t.Error("expected error, got nil")
	}
}
