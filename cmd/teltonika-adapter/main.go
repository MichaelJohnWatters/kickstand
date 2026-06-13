// teltonika-adapter terminates a TCP connection from a Teltonika
// FMB/FMC tracker, decodes Codec-8 frames via internal/teltonika,
// looks up the bike id for the device's IMEI in a small JSON config
// file, and forwards each GPS record to the Kickstand API as a
// `POST /bikes/{id}/gps {lat, lng}` call.
//
// This binary stays decoupled from the rest of the Kickstand code —
// it doesn't know about the Kickstand DB schema, just the public
// HTTP shape. A school can run it on the same box as the API, or on
// a cheap VPS the trackers can reach (LTE-M devices need a public
// host:port). It scales by horizontal duplication.
//
// Config (JSON):
//
//	{
//	  "apiBaseUrl": "https://api.example.com",
//	  "apiToken":   "Bearer …",
//	  "listenAddr": ":5027",
//	  "bindings":   { "350123456789012": "bike_a1m1_belfast" }
//	}
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/teltonika"
)

type config struct {
	APIBaseURL string            `json:"apiBaseUrl"`
	APIToken   string            `json:"apiToken"`
	ListenAddr string            `json:"listenAddr"`
	Bindings   map[string]string `json:"bindings"` // imei -> bike id
}

func main() {
	cfgPath := flag.String("config", "config.json", "path to JSON config file")
	flag.Parse()

	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	if cfg.ListenAddr == "" {
		cfg.ListenAddr = ":5027"
	}
	if cfg.APIBaseURL == "" {
		log.Fatal("config: apiBaseUrl required")
	}

	srv := &server{
		cfg: cfg,
		client: &http.Client{
			Timeout: 10 * time.Second,
		},
	}
	log.Printf("teltonika-adapter listening on %s — forwarding to %s",
		cfg.ListenAddr, cfg.APIBaseURL)
	if err := srv.listen(context.Background()); err != nil {
		log.Fatalf("listen: %v", err)
	}
}

func loadConfig(path string) (*config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	return &c, nil
}

type server struct {
	cfg    *config
	client *http.Client
	mu     sync.RWMutex // guards bindings hot-reload (not wired yet)
}

func (s *server) listen(ctx context.Context) error {
	ln, err := net.Listen("tcp", s.cfg.ListenAddr)
	if err != nil {
		return err
	}
	defer ln.Close()
	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			log.Printf("accept: %v", err)
			continue
		}
		go s.handle(ctx, conn)
	}
}

// handle drives one tracker connection through its lifetime: IMEI
// handshake → ACK → loop reading data frames → ACK each with the
// record count. Drops the connection on any malformed input; the
// device will reconnect and resend, which is exactly how Teltonika
// devices recover from a bad server.
func (s *server) handle(ctx context.Context, conn net.Conn) {
	defer conn.Close()
	// Conservative deadline — devices send a heartbeat at most every
	// few minutes. If nothing's coming for an hour the device is
	// probably gone.
	_ = conn.SetReadDeadline(time.Now().Add(time.Hour))

	imei, err := teltonika.ReadIMEI(conn)
	if err != nil {
		log.Printf("imei read: %v", err)
		return
	}
	bikeID, known := s.lookupBinding(imei)
	if _, err := conn.Write(teltonika.IMEIAck(known)); err != nil {
		log.Printf("imei ack write: %v", err)
		return
	}
	if !known {
		log.Printf("unknown IMEI %q — rejecting", imei)
		return
	}
	log.Printf("device %q connected → bike %s", imei, bikeID)

	for {
		records, err := teltonika.DecodeFrame(conn)
		if err != nil {
			if !errors.Is(err, io.EOF) {
				log.Printf("frame for %s: %v", bikeID, err)
			}
			return
		}
		// Forward every record — order matters because the Kickstand
		// snapshot always reflects the latest fix. The history table
		// records all of them.
		for _, r := range records {
			if err := s.forward(ctx, bikeID, r); err != nil {
				log.Printf("forward bike=%s at=%s: %v",
					bikeID, r.At.Format(time.RFC3339), err)
				// Don't drop the connection on forward failure — the
				// upstream API hiccuping shouldn't make the tracker
				// resend hundreds of historical fixes.
			}
		}
		// ACK every record the device sent, regardless of forward
		// outcome. See note above.
		if _, err := conn.Write(teltonika.AVLAck(uint32(len(records)))); err != nil {
			log.Printf("avl ack write: %v", err)
			return
		}
		// Sliding deadline for the next frame.
		_ = conn.SetReadDeadline(time.Now().Add(time.Hour))
	}
}

func (s *server) lookupBinding(imei string) (string, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	id, ok := s.cfg.Bindings[imei]
	return id, ok
}

// forward POSTs one record to the Kickstand API. Body matches the
// /bikes/{id}/gps contract. Auth header is taken verbatim from
// config so the operator can pre-mint a long-lived service token.
func (s *server) forward(ctx context.Context, bikeID string, r teltonika.Record) error {
	body, err := json.Marshal(map[string]any{
		"lat": r.Lat,
		"lng": r.Lng,
	})
	if err != nil {
		return err
	}
	url := s.cfg.APIBaseURL + "/bikes/" + bikeID + "/gps"
	req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if s.cfg.APIToken != "" {
		req.Header.Set("Authorization", s.cfg.APIToken)
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		buf, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("HTTP %d: %s", resp.StatusCode, string(buf))
	}
	return nil
}
