// Package teltonika decodes the Teltonika "Codec 8" TCP framing used
// by the FMB/FMC tracker family. It exists because Teltonika devices
// can be configured with a custom server URL but speak their own
// binary protocol, not HTTP — so an adapter binary (`cmd/teltonika-
// adapter`) terminates the TCP connection, decodes Codec-8 frames
// here, and forwards each GPS record as a `POST /bikes/{id}/gps`
// call to the main Kickstand API.
//
// Scope: GPS records only. The full Codec 8 spec has an "IO element
// block" carrying ignition / fuel / digital inputs etc; we count
// past those bytes without decoding them. If a school later wants
// "engine on/off" or "harsh braking" surfaced, that extends the
// decoder, not the API.
//
// Spec: https://wiki.teltonika-gps.com/view/Codec#Codec_8
package teltonika

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"time"
)

// Record is the decoded form of one AVL data record — a single GPS
// fix with its tracker-stamped timestamp. Lat/lng are decimal
// degrees (Codec 8 stores them scaled by 1e7; we convert here so
// callers don't need to think about the wire format).
type Record struct {
	At        time.Time
	Lat       float64
	Lng       float64
	AltitudeM int16  // metres above sea level; spec is int16 signed
	AngleDeg  uint16 // heading 0-360
	Speed     uint16 // km/h
	Sats      uint8
	Priority  uint8 // 0=low, 1=high, 2=panic per Teltonika
}

// Errors surfaced for malformed frames. Callers (the adapter) drop
// the connection on any of these — the device will reconnect and
// re-send.
var (
	ErrBadPreamble   = errors.New("teltonika: data frame preamble != 00000000")
	ErrUnknownCodec  = errors.New("teltonika: only Codec 8 (id 0x08) supported")
	ErrTrailingMatch = errors.New("teltonika: trailing record count != leading record count")
	ErrShortPayload  = errors.New("teltonika: payload shorter than declared length")
)

// ReadIMEI consumes the device handshake — 2-byte length-prefixed
// ASCII IMEI sent right after TCP connect. Returns the IMEI string
// the adapter uses to look up the bike binding.
func ReadIMEI(r io.Reader) (string, error) {
	var lenBuf [2]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return "", fmt.Errorf("read imei length: %w", err)
	}
	n := int(binary.BigEndian.Uint16(lenBuf[:]))
	if n == 0 || n > 32 {
		return "", fmt.Errorf("implausible imei length: %d", n)
	}
	imei := make([]byte, n)
	if _, err := io.ReadFull(r, imei); err != nil {
		return "", fmt.Errorf("read imei: %w", err)
	}
	return string(imei), nil
}

// IMEIAck is the single-byte reply the device expects after sending
// its IMEI. 0x01 = accept, 0x00 = reject. Exposed so callers can
// reject by IMEI (e.g. unknown tracker) without a separate helper.
func IMEIAck(accept bool) []byte {
	if accept {
		return []byte{0x01}
	}
	return []byte{0x00}
}

// AVLAck is the 4-byte uint32 reply the device expects after a data
// frame — the count of accepted records. We always ack the count
// the device sent (no per-record validation here; the upstream
// HTTP POST is allowed to fail without un-acking, and the device
// won't retry already-acked records).
func AVLAck(count uint32) []byte {
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], count)
	return b[:]
}

// DecodeFrame parses one Codec-8 data frame from r. Returns the
// records carried by the frame. The frame layout is:
//
//	[4]  preamble (0x00000000)
//	[4]  data field length, N (uint32 BE)
//	[N]  codec id (0x08) + record count (uint8) + records + record count (uint8)
//	[4]  CRC-16 (high two bytes zero, low two bytes IBM CRC)
//
// We read the preamble + length first, then exactly N bytes for
// the body, then 4 CRC bytes. We do not verify the CRC — the wire
// is TCP, and Teltonika's own decoder treats CRC as belt-and-braces.
func DecodeFrame(r io.Reader) ([]Record, error) {
	var preamble [4]byte
	if _, err := io.ReadFull(r, preamble[:]); err != nil {
		return nil, fmt.Errorf("read preamble: %w", err)
	}
	if preamble != [4]byte{0, 0, 0, 0} {
		return nil, ErrBadPreamble
	}
	var lenBuf [4]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return nil, fmt.Errorf("read length: %w", err)
	}
	bodyLen := binary.BigEndian.Uint32(lenBuf[:])
	body := make([]byte, bodyLen)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, fmt.Errorf("read body: %w", err)
	}
	var crc [4]byte
	if _, err := io.ReadFull(r, crc[:]); err != nil {
		return nil, fmt.Errorf("read crc: %w", err)
	}
	return decodeBody(body)
}

// decodeBody is the inner parse — operating on the N body bytes
// only. Split out so tests can exercise body parsing without
// having to construct the outer frame header.
func decodeBody(body []byte) ([]Record, error) {
	if len(body) < 3 {
		return nil, ErrShortPayload
	}
	codec := body[0]
	if codec != 0x08 {
		return nil, ErrUnknownCodec
	}
	count := body[1]
	rec, n, err := decodeRecords(body[2:], int(count))
	if err != nil {
		return nil, err
	}
	tail := body[2+n:]
	if len(tail) < 1 {
		return nil, ErrShortPayload
	}
	if tail[0] != count {
		return nil, ErrTrailingMatch
	}
	return rec, nil
}

// decodeRecords reads `count` records from b. Returns the records
// and how many bytes were consumed.
func decodeRecords(b []byte, count int) ([]Record, int, error) {
	out := make([]Record, 0, count)
	off := 0
	for i := 0; i < count; i++ {
		if len(b)-off < 24 { // 8 ts + 1 prio + 15 gps
			return nil, 0, ErrShortPayload
		}
		var rec Record
		rec.At = time.UnixMilli(int64(binary.BigEndian.Uint64(b[off : off+8]))).UTC()
		off += 8
		rec.Priority = b[off]
		off++
		// GPS element — 15 bytes total.
		lng := int32(binary.BigEndian.Uint32(b[off : off+4]))
		off += 4
		lat := int32(binary.BigEndian.Uint32(b[off : off+4]))
		off += 4
		rec.AltitudeM = int16(binary.BigEndian.Uint16(b[off : off+2]))
		off += 2
		rec.AngleDeg = binary.BigEndian.Uint16(b[off : off+2])
		off += 2
		rec.Sats = b[off]
		off++
		rec.Speed = binary.BigEndian.Uint16(b[off : off+2])
		off += 2
		rec.Lat = float64(lat) / 1e7
		rec.Lng = float64(lng) / 1e7
		// IO element block — we don't surface any of these fields,
		// just skip past them so the next record (or the trailing
		// count byte) lines up.
		skipped, err := skipIO(b[off:])
		if err != nil {
			return nil, 0, err
		}
		off += skipped
		out = append(out, rec)
	}
	return out, off, nil
}

// skipIO advances past one IO element block without decoding it.
// Layout: event_io_id (1) + total_io (1) + [for k in 1,2,4,8: count (1) + count*(id+value)]
// Returns how many bytes were consumed.
func skipIO(b []byte) (int, error) {
	if len(b) < 2 {
		return 0, ErrShortPayload
	}
	off := 2 // event_io_id + total_io
	for _, w := range []int{1, 2, 4, 8} {
		if len(b)-off < 1 {
			return 0, ErrShortPayload
		}
		n := int(b[off])
		off++
		need := n * (1 + w)
		if len(b)-off < need {
			return 0, ErrShortPayload
		}
		off += need
	}
	return off, nil
}
