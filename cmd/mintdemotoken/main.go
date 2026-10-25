// Command mintdemotoken mints a hand-rolled access token for the demo-data
// dump pipeline. It signs a short-lived JWT for the requested user id using
// the same JWT_SIGNING_KEY the running server verifies against, so the dump
// script can call the API as that user.
//
// Used by scripts/dump-demo.sh as part of `make demo-data`. Not shipped to
// production.
//
// Usage:
//
//	JWT_SIGNING_KEY=... mintdemotoken -uid user_owen
//
// Requires JWT_SIGNING_KEY (≥32 bytes) — the same value the server uses.
package main

import (
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

func main() {
	uid := flag.String("uid", "user_owen", "local user id to mint a token for")
	flag.Parse()

	key := os.Getenv("JWT_SIGNING_KEY")
	if key == "" {
		fmt.Fprintln(os.Stderr, "JWT_SIGNING_KEY not set — use the same value the server runs with")
		os.Exit(1)
	}
	ts, err := auth.NewTokenService([]byte(key))
	if err != nil {
		fmt.Fprintf(os.Stderr, "token service: %v\n", err)
		os.Exit(1)
	}
	token, err := ts.IssueAccess(domain.UserID(*uid), time.Hour, time.Now())
	if err != nil {
		fmt.Fprintf(os.Stderr, "issue token: %v\n", err)
		os.Exit(1)
	}
	fmt.Print(token)
}
