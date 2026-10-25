# Deploying Kickstand

> **Recommended path: Fly.io** (`../fly.toml`), per the portfolio deploy
> standard (`toolkit/docs/deploy-standard.md`). Fly gives TLS, health-gated
> rollouts, volumes, and secrets with minimal ops, and the image bundles
> Litestream for continuous SQLite backup. This doc covers the **Docker
> Compose + Caddy** path, which stays supported as the portable self-host
> alternative (any VPS/Pi, or Cloud Run with a volume) — the same image runs
> both ways.

A portable Docker deployment of the Go API behind Caddy (automatic HTTPS).
The API is a single static binary using SQLite on a persistent volume; migrate
to Postgres when concurrency/scale demands it.

## Tenancy: one deployment, or one per customer?

Kickstand is **shared multi-tenant** by default — one deployment + one
database serves every training school, isolated by `school_id` (the
`tenant.Scope` guard on every query). A new customer is a new `school` row,
not a new server.

A customer who wants their **own dedicated instance** gets the *same* image
deployed in isolation: its own volume (DB), its own domain, and
`KS_SINGLE_TENANT_SCHOOL_ID` set to pin every signup to its one school. No
code fork — just configuration.

## Prerequisites

- A Docker host with ports 80/443 open and a domain pointed at it.
- An HS256 signing secret for auth. Generate one with
  `openssl rand -base64 48` and put it in `.env` as `JWT_SIGNING_KEY`.
- (Optional) an SMTP relay for password-reset / notification email.

## First deploy (shared multi-tenant)

```bash
cd deploy
cp .env.example .env            # edit: KS_DOMAIN, CORS_ALLOWED_ORIGINS, JWT_SIGNING_KEY

docker compose up -d --build
docker compose logs -f app      # look for "auth: password login enabled" + "tenancy: shared multi-tenant"
```

Caddy obtains a Let's Encrypt cert for `KS_DOMAIN` automatically. The API is
then live at `https://<KS_DOMAIN>/` (e.g. `GET /healthz` returns 200).

### Onboard the first school

There is no self-serve "create a school" — provisioning is deliberate. Run the
bundled `provision` CLI against the same volume:

```bash
docker compose run --rm --entrypoint provision app \
  -dsn /data/kickstand.db \
  -name "Acme Rider Training" -region NI \
  -owner-email owner@acme.example -owner-name "Acme Owner" \
  -owner-password 'change-me-immediately'
```

It creates the school + its owner account with the bcrypt-hashed
`-owner-password`. The owner signs in with that email/password and can change
it later. Region `NI`→DVA, `GB`→DVSA. Repeat per school for a shared deployment.

## Dedicated single-tenant instance

Stand up a separate deployment (own host/volume/domain), provision its one
school, then pin to it:

```bash
# 1. provision prints the school id — copy it:
docker compose run --rm --entrypoint provision app -dsn /data/kickstand.db \
  -name "Big Customer Co" -region GB \
  -owner-email owner@bigco.example -owner-name "Owner" -owner-password '...'
#    → school id : 2d41...efd2

# 2. put it in .env and restart:
echo 'KS_SINGLE_TENANT_SCHOOL_ID=2d41...efd2' >> .env
docker compose up -d
```

Now every signup on that instance attaches to that school, `GET /schools`
advertises only it, and the client needs no school picker. Boot logs
`tenancy: single-tenant (pinned)`.

## The web app

The Flutter web build (`make app-web`, output `app/build/web/`) is a static
bundle — host it on any static host (Cloudflare Pages, Netlify) or serve it
from Caddy with a `file_server`. **Its origin must be listed in
`CORS_ALLOWED_ORIGINS`** or the browser will block API calls.

## Data & backups

All state is the `kickstand-data` volume (`/data/kickstand.db` + uploads).

**Backup** — use the `backup` tool, not a raw `cp`: it runs `VACUUM INTO`, a
consistent snapshot that's safe to take while the server is running (a file
copy can catch a half-written DB).

```bash
docker compose run --rm --entrypoint backup app \
  -dsn /data/kickstand.db -out /data/backups/kickstand-$(date +%F-%H%M%S).db
# then copy the snapshot OFF the host (the point of a backup):
docker compose cp app:/data/backups/. ./backups/
```

Run it on a schedule (host cron calling the command above). `-out` must be a
fresh path each time — `VACUUM INTO` refuses to overwrite.

**Restore** — a file swap while the server is stopped:

```bash
docker compose stop app
docker compose run --rm --entrypoint sh app -c \
  'cp /data/backups/kickstand-2026-10-14-0300.db /data/kickstand.db'
docker compose start app
```

Receipt images live on the same `/data` volume as the DB, so the volume is the
whole backup surface.

## Config reference

See `.env.example`. Server flags (overridable in `docker-compose.yml`'s
`command`): `-addr`, `-dsn`, `-uploads-dir`, `-max-body-bytes`,
`-signup-rate-per-min`, `-signup-burst`, `-reminders-interval`,
`-email-interval`, `-log-level`.

**Auth:** `JWT_SIGNING_KEY` (≥32 bytes) is required in production — it signs
the HS256 access + refresh tokens. The boot-gate refuses to start without it
when `APP_ENV=production`. `WEB_APP_URL` is the base of the emailed
password-reset link.

**Email:** set `SMTP_HOST` (+ `SMTP_PORT`/`USERNAME`/`PASSWORD`, `EMAIL_FROM`)
to send booking confirmations, reminders, cancellations, and password-reset
links via any SMTP relay. Without it, email queues but isn't sent (in-app
still works; password reset returns 204 but no link goes out); `EMAIL_LOG=1`
logs them for dev. The worker drains the outbox every `-email-interval`.

**Health & monitoring:** `GET /healthz` is liveness (process up); `GET /readyz`
is readiness (DB reachable — point uptime checks / load balancers here);
`GET /metrics` is minimal Prometheus-text request counters (aggregate only, no
PII — firewall it off if you don't want request volume public). Set
`ERROR_WEBHOOK` to a Slack/Discord-style webhook to get a `{"text":...}`
alert whenever a handler panics.
