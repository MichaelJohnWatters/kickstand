package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/teltonika"
)

// End-to-end-ish: stand up the adapter on a free port, point it at
// a stub HTTP server, drive a fake tracker session through it, and
// assert the stub received the expected POST bodies.
func TestAdapter_ForwardsRecordsToAPI(t *testing.T) {
	var (
		mu       sync.Mutex
		received []map[string]any
	)
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/bikes/bike_belfast/gps" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer test-token" {
			t.Errorf("auth header: got %q", got)
		}
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		mu.Lock()
		received = append(received, body)
		mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	}))
	defer api.Close()

	srv := &server{
		cfg: &config{
			APIBaseURL: api.URL,
			APIToken:   "Bearer test-token",
			ListenAddr: "127.0.0.1:0",
			Bindings:   map[string]string{"350000000000001": "bike_belfast"},
		},
		client: api.Client(),
	}
	ln, err := net.Listen("tcp", srv.cfg.ListenAddr)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		srv.handle(ctx, conn)
	}()

	// Tracker side of the conversation.
	conn, err := net.DialTimeout("tcp", ln.Addr().String(), 2*time.Second)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	// 1. IMEI handshake.
	imei := "350000000000001"
	if _, err := conn.Write(append([]byte{0x00, byte(len(imei))}, []byte(imei)...)); err != nil {
		t.Fatalf("write imei: %v", err)
	}
	ack := make([]byte, 1)
	if _, err := io.ReadFull(conn, ack); err != nil {
		t.Fatalf("read ack: %v", err)
	}
	if ack[0] != 0x01 {
		t.Fatalf("expected IMEI accept, got 0x%02x", ack[0])
	}

	// 2. One data frame with two records (Belfast + Lisburn).
	frame := buildAdapterFrame(t, []teltonika.Record{
		{
			At:        time.Date(2026, 6, 13, 14, 0, 0, 0, time.UTC),
			Priority:  1,
			Lat:       54.5825,
			Lng:       -5.9655,
			AltitudeM: 23, AngleDeg: 90, Sats: 12, Speed: 30,
		},
		{
			At:        time.Date(2026, 6, 13, 14, 5, 0, 0, time.UTC),
			Priority:  1,
			Lat:       54.5188,
			Lng:       -6.0640,
			AltitudeM: 80, AngleDeg: 180, Sats: 11, Speed: 55,
		},
	})
	if _, err := conn.Write(frame); err != nil {
		t.Fatalf("write frame: %v", err)
	}
	// 3. Read the 4-byte AVL ack — must equal the record count.
	avlAck := make([]byte, 4)
	if _, err := io.ReadFull(conn, avlAck); err != nil {
		t.Fatalf("read avl ack: %v", err)
	}
	if got := binary.BigEndian.Uint32(avlAck); got != 2 {
		t.Errorf("avl ack: got %d want 2", got)
	}

	// 4. Stub must have received both records.
	conn.Close()
	// Allow the goroutine a moment to finish its last forward.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		n := len(received)
		mu.Unlock()
		if n >= 2 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(received) != 2 {
		t.Fatalf("forwarded %d records, want 2", len(received))
	}
	if got, want := received[0]["lat"].(float64), 54.5825; got != want {
		t.Errorf("first lat: got %v want %v", got, want)
	}
	if got, want := received[1]["lng"].(float64), -6.0640; got != want {
		t.Errorf("second lng: got %v want %v", got, want)
	}
}

// Unknown IMEI: device gets 0x00 ack and the connection drops with
// no records forwarded.
func TestAdapter_RejectsUnknownIMEI(t *testing.T) {
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("API should not be called for unknown IMEI")
	}))
	defer api.Close()
	srv := &server{
		cfg: &config{
			APIBaseURL: api.URL,
			ListenAddr: "127.0.0.1:0",
			Bindings:   map[string]string{}, // empty — every IMEI is unknown
		},
		client: api.Client(),
	}
	ln, err := net.Listen("tcp", srv.cfg.ListenAddr)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	go func() {
		conn, _ := ln.Accept()
		srv.handle(context.Background(), conn)
	}()

	conn, err := net.DialTimeout("tcp", ln.Addr().String(), time.Second)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte{0x00, 0x0f, '3', '5', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0'}); err != nil {
		t.Fatalf("write imei: %v", err)
	}
	ack := make([]byte, 1)
	_ = conn.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := io.ReadFull(conn, ack); err != nil {
		t.Fatalf("read ack: %v", err)
	}
	if ack[0] != 0x00 {
		t.Errorf("expected reject ack 0x00, got 0x%02x", ack[0])
	}
}

// buildAdapterFrame mirrors the test helper in internal/teltonika
// (kept local here to avoid widening that package's exports).
func buildAdapterFrame(t *testing.T, recs []teltonika.Record) []byte {
	t.Helper()
	var body bytes.Buffer
	body.WriteByte(0x08)
	body.WriteByte(uint8(len(recs)))
	for _, r := range recs {
		var u8 [8]byte
		binary.BigEndian.PutUint64(u8[:], uint64(r.At.UnixMilli()))
		body.Write(u8[:])
		body.WriteByte(r.Priority)
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
		body.Write([]byte{0, 0, 0, 0, 0, 0}) // empty IO block
	}
	body.WriteByte(uint8(len(recs)))
	var out bytes.Buffer
	out.Write([]byte{0, 0, 0, 0})
	var ln [4]byte
	binary.BigEndian.PutUint32(ln[:], uint32(body.Len()))
	out.Write(ln[:])
	out.Write(body.Bytes())
	out.Write([]byte{0, 0, 0, 0}) // CRC
	return out.Bytes()
}
