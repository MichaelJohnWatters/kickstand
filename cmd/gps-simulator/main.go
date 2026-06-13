// gps-simulator drives fake GPS fixes into the Kickstand API so the
// live map demo behaves like real trackers are wired up. Boots by
// pulling the current bike list from `/admin/bikes/gps`, then on
// each tick generates a small random-walk step per bike and POSTs
// it to `/bikes/{id}/gps`.
//
// Why a separate binary: same reason as cmd/teltonika-adapter — the
// API endpoint is provider-agnostic and "fake provider" is just one
// more provider. Run it next to the dev server in a second terminal:
//
//	go run ./cmd/gps-simulator \
//	    --api-base-url http://localhost:8765 \
//	    --token "Bearer $(cat .demo-token)" \
//	    --tick 5s
//
// The walk model: bikes flip between "parked" and "cruising". Parked
// jitters ±~10m to mimic GPS noise around a stationary fix. Cruising
// picks a heading and steps ~200-500m per tick. Bikes flip state ~5%
// of the time per tick — so a 5-second tick gives the rough cadence
// of a school van that moves once every couple minutes.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
)

func main() {
	var (
		apiBase = flag.String("api-base-url", "http://localhost:8765",
			"Kickstand API base URL")
		token = flag.String("token", "",
			"Authorization header value (e.g. \"Bearer …\"). Required.")
		tick = flag.Duration("tick", 5*time.Second,
			"How often to emit a fix per bike")
		bikesCSV = flag.String("bikes", "",
			"Comma-separated bike IDs to simulate. Empty = every bike "+
				"the API lists with an existing fix.")
		seed = flag.Int64("seed", 0,
			"Random seed (0 = wallclock — non-deterministic)")
	)
	flag.Parse()
	if *token == "" {
		log.Fatal("--token is required")
	}

	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	if *seed != 0 {
		rng = rand.New(rand.NewSource(*seed))
	}

	sim := &simulator{
		baseURL: strings.TrimRight(*apiBase, "/"),
		token:   *token,
		client:  &http.Client{Timeout: 10 * time.Second},
		rng:     rng,
	}
	if err := sim.bootstrap(*bikesCSV); err != nil {
		log.Fatalf("bootstrap: %v", err)
	}
	log.Printf("simulator: %d bikes, tick=%s, api=%s",
		len(sim.bikes), *tick, sim.baseURL)

	ctx, stop := signal.NotifyContext(context.Background(),
		syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	sim.run(ctx, *tick)
}

// state carries the current position and "moving" flag for one bike.
type state struct {
	id      string
	lat     float64
	lng     float64
	heading float64 // radians; only relevant while moving
	moving  bool
}

type simulator struct {
	baseURL string
	token   string
	client  *http.Client
	rng     *rand.Rand
	mu      sync.Mutex
	bikes   []*state
}

// bootstrap pulls the current snapshot list from /admin/bikes/gps,
// filters to bikes the user asked for (or all with a fix), and
// seeds the in-memory state.
func (s *simulator) bootstrap(bikesCSV string) error {
	req, err := s.newRequest("GET", "/admin/bikes/gps", nil)
	if err != nil {
		return err
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return fmt.Errorf("GET /admin/bikes/gps: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("GET /admin/bikes/gps: HTTP %d: %s",
			resp.StatusCode, string(body))
	}
	var page struct {
		Bikes []struct {
			ID  string  `json:"id"`
			Lat float64 `json:"lat"`
			Lng float64 `json:"lng"`
		} `json:"bikes"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&page); err != nil {
		return fmt.Errorf("decode: %w", err)
	}
	allowed := make(map[string]bool)
	if bikesCSV != "" {
		for _, id := range strings.Split(bikesCSV, ",") {
			allowed[strings.TrimSpace(id)] = true
		}
	}
	for _, b := range page.Bikes {
		if len(allowed) > 0 && !allowed[b.ID] {
			continue
		}
		// Skip bikes with no existing fix — we'd be planting them at
		// (0,0) which the API's proximity check would refuse anyway.
		if b.Lat == 0 && b.Lng == 0 {
			continue
		}
		s.bikes = append(s.bikes, &state{
			id:  b.ID,
			lat: b.Lat,
			lng: b.Lng,
		})
	}
	if len(s.bikes) == 0 {
		return fmt.Errorf("no bikes to simulate — none with existing fixes" +
			" matched the filter")
	}
	return nil
}

// run drives the tick loop until the context cancels. Per tick:
// step every bike, then POST every fix. Each POST is best-effort —
// a 4xx/5xx for one bike doesn't stop the others.
func (s *simulator) run(ctx context.Context, tick time.Duration) {
	t := time.NewTicker(tick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			log.Print("shutting down")
			return
		case <-t.C:
			s.step()
		}
	}
}

func (s *simulator) step() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, b := range s.bikes {
		stepBike(b, s.rng)
		if err := s.post(b); err != nil {
			log.Printf("%s: %v", b.id, err)
			continue
		}
		log.Printf("%s → %.5f, %.5f (%s)",
			b.id, b.lat, b.lng, modeLabel(b.moving))
	}
}

func modeLabel(moving bool) string {
	if moving {
		return "cruising"
	}
	return "parked"
}

// stepBike mutates a bike's position by one tick of the random-walk
// model. Pulled out so the unit test can drive it with a seeded
// rand and assert the deltas.
func stepBike(b *state, rng *rand.Rand) {
	// 5% chance per tick of flipping mode.
	if rng.Float64() < 0.05 {
		b.moving = !b.moving
		if b.moving {
			b.heading = rng.Float64() * 2 * math.Pi
		}
	}
	if !b.moving {
		// Parked: ±~10m jitter.
		b.lat += (rng.Float64() - 0.5) * 0.0002
		b.lng += (rng.Float64() - 0.5) * 0.0002
		return
	}
	// Cruising: 200-500m step in the current heading, with a small
	// heading drift each tick so the bike isn't on a perfect line.
	stepM := 200 + rng.Float64()*300
	b.heading += (rng.Float64() - 0.5) * 0.3 // ±~17°
	// 1° lat ≈ 111km. 1° lng ≈ 111km × cos(lat). Convert metres → degrees.
	dLat := math.Sin(b.heading) * stepM / 111_000
	dLng := math.Cos(b.heading) * stepM / (111_000 *
		math.Cos(b.lat*math.Pi/180))
	b.lat += dLat
	b.lng += dLng
}

func (s *simulator) post(b *state) error {
	body, _ := json.Marshal(map[string]any{
		"lat": b.lat,
		"lng": b.lng,
	})
	req, err := s.newRequest("POST", "/bikes/"+b.id+"/gps", body)
	if err != nil {
		return err
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

func (s *simulator) newRequest(method, path string, body []byte) (*http.Request, error) {
	var rdr io.Reader
	if body != nil {
		rdr = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, s.baseURL+path, rdr)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Authorization", s.token)
	return req, nil
}

// Touch os to keep imports tidy even if a future build removes
// signal.NotifyContext; cheaper than a build flag.
var _ = os.Stderr
