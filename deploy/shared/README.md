# Shared-host deployment (Kickstand + yoga-school on one box)

One Caddy terminating TLS for both apps, routing by hostname to two containers,
each with its own volume. Right-sized for two small apps on a single VPS — no
Kubernetes. (For a *dedicated* single-tenant Kickstand instance on its own box,
use the single-app compose one level up in `deploy/`.)

```
 one VPS
 └─ Docker
    ├─ caddy        :80/:443  →  KS_DOMAIN   → kickstand:8765
    │                            YOGA_DOMAIN → {YOGA_UPSTREAM}
    ├─ kickstand    (built from this repo; volume: kickstand-data)
    └─ yoga-school  (your image;          volume: yoga-school-data)
```

## What's wired vs. what you fill in

- **kickstand** is concrete — built from this repo's `Dockerfile`, same env as
  the single-app deploy (CORS, Firebase, email, tenancy). See `../README.md`
  and `../firebase-setup.md`.
- **yoga-school** is a template. Its source lives in its own project, so the
  compose references a prebuilt image rather than building it here. You set:
  - `YOGA_IMAGE` — the image to run (build/push it from its own repo, or a
    local tag).
  - `YOGA_UPSTREAM` — `service:port` Caddy proxies its domain to (default
    `yoga-school:8080`); change the port to whatever it listens on.
  - its own env + data-volume path in `docker-compose.yml`.

## Run it

```bash
cd deploy/shared
cp .env.example .env          # set both domains + each app's env
mkdir -p ../secrets           # drop firebase-sa.json here (shared with ../; gitignored)
docker compose up -d --build
docker compose logs -f caddy  # watch both certs get issued
```

Point `KS_DOMAIN` and `YOGA_DOMAIN` DNS at the host first; Caddy issues a
Let's Encrypt cert per domain automatically.

Onboard a Kickstand school (yoga-school has its own flow):

```bash
docker compose run --rm --entrypoint provision kickstand \
  -dsn /data/kickstand.db -name "Acme Rider" -region NI \
  -owner-email owner@acme.example -owner-name "Owner" -owner-password '...'
```

## Trade-offs (be aware)

- **Shared blast radius** — one box down takes both apps down. Fine for pilots;
  split onto separate hosts once one app is revenue-critical.
- **Backups are per-app** — back up each volume separately (Kickstand: the
  `backup` tool, see `../README.md`; yoga-school: its own mechanism).
- **Resources** — two small apps fit comfortably on 2–4 GB; add Docker memory
  limits if one misbehaves.

## Why not k8s?

Two small apps don't need it, and Kickstand's SQLite (single-writer, one
volume) fights k8s's stateless/reschedulable model until it moves to Postgres.
Reach for k8s when you have many services, real horizontal-scaling needs, and
externalized state — not before. If the goal is *learning* k8s, run single-node
k3s as a sandbox, but keep the thing you're piloting with real customers here.
