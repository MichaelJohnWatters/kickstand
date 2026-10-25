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
  the single-app deploy (CORS, `JWT_SIGNING_KEY`, email, tenancy). See
  `../README.md`.
- **yoga-school** is a template. Its source lives in its own project, so the
  compose references a prebuilt image rather than building it here. You set:
  - `YOGA_IMAGE` — the image to run (build/push it from its own repo, or a
    local tag).
  - `YOGA_UPSTREAM` — `service:port` Caddy proxies its domain to (default
    `yoga-school:8080`); change the port to whatever it listens on.
  - its own env + data-volume path in `docker-compose.yml`.

## Provisioning the box (from scratch)

A ~€5/mo VPS hosts both apps comfortably. Use an **EU/UK provider** for data
residency (Hetzner CX22 is the usual pick; a UK host like Mythic Beasts/Krystal
if data must sit on UK soil). Debian 12 / Ubuntu 24.04.

**1. Create the server** in an EU/UK region. Add your SSH key at create time.

**2. Harden + firewall** (SSH in as root first):
```bash
adduser deploy && usermod -aG sudo deploy          # non-root user
rsync --archive --chown=deploy:deploy ~/.ssh /home/deploy   # copy your key
# /etc/ssh/sshd_config: PermitRootLogin no, PasswordAuthentication no; then:
systemctl restart ssh
apt update && apt install -y ufw unattended-upgrades
ufw allow OpenSSH && ufw allow 80 && ufw allow 443 && ufw --force enable
```
From here on, SSH as `deploy`.

**3. Install Docker** (official convenience script, run on the box):
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker deploy      # log out/in so `docker` works without sudo
```

**4. Clone both repos** onto the box (read-only deploy keys recommended):
```bash
mkdir ~/apps && cd ~/apps
git clone git@github.com:MichaelJohnWatters/kickstand.git
git clone git@github.com:MichaelJohnWatters/yoga-school.git
```

**5. Build yoga-school's image** (its source is its own repo; the shared compose
runs it as a prebuilt image):
```bash
cd ~/apps/yoga-school
docker build -f server/Dockerfile -t yoga-school:latest .
```

**6. DNS** — point both domains' `A` records at the box's public IP
(`KS_DOMAIN` and `YOGA_DOMAIN`). Caddy needs these resolving before it can
issue certs.

Then run it (below). Kickstand is built by the compose; yoga runs the image
from step 5.

## Run it

```bash
cd ~/apps/kickstand/deploy/shared
cp .env.example .env          # set both domains + each app's env + JWT_SIGNING_KEY + YOGA_IMAGE
docker compose up -d --build
docker compose logs -f caddy  # watch both certs get issued
```

Verify: `curl -fsS https://$KS_DOMAIN/healthz` → `ok`, and `/readyz` → `ready`.

## Updating + firewall notes

```bash
cd ~/apps/kickstand && git pull        # (and ~/apps/yoga-school; rebuild its image)
cd deploy/shared && docker compose up -d --build   # recreates changed services
```
`/metrics` is unauthenticated — it's only reachable on the public domain via
Caddy, so put it behind an allowlist in the Caddyfile (or a private network) if
you don't want request volume public.

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
