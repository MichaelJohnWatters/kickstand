// Command mintdemotoken mints a Firebase ID token for the demo-data
// dump pipeline. Connects to the running Auth emulator, asks for a
// custom token for the requested UID (`user_owen` by default — the
// owner role sees the full API surface), then exchanges it for an ID
// token via the emulator REST endpoint.
//
// Used by scripts/dump-demo.sh as part of `make demo-data`. Not shipped
// to production — Firebase clients run this dance in-app.
//
// Usage:
//
//	mintdemotoken -uid user_owen
//
// Requires FIREBASE_AUTH_EMULATOR_HOST + FIREBASE_PROJECT_ID env vars.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
)

func main() {
	uid := flag.String("uid", "user_owen", "Firebase UID to mint a token for")
	flag.Parse()

	emuHost := os.Getenv("FIREBASE_AUTH_EMULATOR_HOST")
	if emuHost == "" {
		fmt.Fprintln(os.Stderr, "FIREBASE_AUTH_EMULATOR_HOST not set — start `make emulator` first")
		os.Exit(1)
	}

	ctx := context.Background()
	fb, err := auth.NewFirebaseClient(ctx)
	if err != nil || fb == nil {
		fmt.Fprintf(os.Stderr, "firebase init: %v\n", err)
		os.Exit(1)
	}

	customToken, err := fb.Auth.CustomToken(ctx, *uid)
	if err != nil {
		fmt.Fprintf(os.Stderr, "custom token: %v\n", err)
		os.Exit(1)
	}

	body, _ := json.Marshal(map[string]any{
		"token":             customToken,
		"returnSecureToken": true,
	})
	url := "http://" + emuHost +
		"/identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=emulator"
	req, _ := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "exchange: %v\n", err)
		os.Exit(1)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		fmt.Fprintf(os.Stderr, "exchange status=%d body=%s\n", resp.StatusCode, raw)
		os.Exit(1)
	}
	var out struct {
		IDToken string `json:"idToken"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		fmt.Fprintf(os.Stderr, "decode: %v\n", err)
		os.Exit(1)
	}
	fmt.Print(out.IDToken)
}
