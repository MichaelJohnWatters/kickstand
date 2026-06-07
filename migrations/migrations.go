// Package migrations embeds the schema migration SQL files so they ship inside
// the compiled binary. The db package reads from FS via fs.ReadDir at startup.
package migrations

import "embed"

//go:embed *.sql
var FS embed.FS
