package main

import (
	"math"
	"math/rand"
	"testing"
)

// A single parked-jitter step must stay in the ±~10m band. We run
// many trials and only count those that didn't flip to cruising —
// otherwise the 5% mode-flip pollutes the sample with cruising
// steps (which are intentionally much larger).
func TestStepBike_ParkedJitterStaysSmall(t *testing.T) {
	rng := rand.New(rand.NewSource(42))
	parkedTrials := 0
	for i := 0; i < 200 && parkedTrials < 30; i++ {
		b := &state{id: "x", lat: 54.5825, lng: -5.9655, moving: false}
		stepBike(b, rng)
		if b.moving {
			continue // flipped this trial — not what we're measuring
		}
		parkedTrials++
		dLatM := math.Abs(b.lat-54.5825) * 111_000
		dLngM := math.Abs(b.lng - -5.9655) * 111_000 * math.Cos(54.5825*math.Pi/180)
		// ±~10m model + a little slack for rng.
		if dLatM > 30 || dLngM > 30 {
			t.Errorf("parked step too big: %.1fm lat, %.1fm lng", dLatM, dLngM)
		}
	}
	if parkedTrials < 10 {
		t.Fatalf("too few parked trials to be meaningful: %d", parkedTrials)
	}
}

// A cruising bike must actually move — net distance over 20 ticks
// has to exceed the parked-noise band.
func TestStepBike_CruisingMovesNontrivially(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	b := &state{
		id: "y", lat: 54.5825, lng: -5.9655,
		moving: true, heading: 0, // north
	}
	startLat, startLng := b.lat, b.lng
	for i := 0; i < 20; i++ {
		stepBike(b, rng)
	}
	dLat := b.lat - startLat
	dLng := b.lng - startLng
	distM := math.Sqrt(dLat*dLat+dLng*dLng) * 111_000
	if distM < 500 {
		t.Errorf("cruising bike moved only %.0fm in 20 ticks; want > 500m", distM)
	}
}

// Coords must stay within sane bounds — a buggy degree/metre
// conversion could drift past 90°/180° and the API would reject.
func TestStepBike_StaysWithinValidRange(t *testing.T) {
	rng := rand.New(rand.NewSource(1234))
	b := &state{
		id: "z", lat: 54.5, lng: -6.0, moving: true, heading: 1.0,
	}
	for i := 0; i < 200; i++ {
		stepBike(b, rng)
		if b.lat < -90 || b.lat > 90 {
			t.Fatalf("lat out of range after %d steps: %v", i, b.lat)
		}
		if b.lng < -180 || b.lng > 180 {
			t.Fatalf("lng out of range after %d steps: %v", i, b.lng)
		}
	}
}
