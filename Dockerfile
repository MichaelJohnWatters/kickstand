# syntax=docker/dockerfile:1
#
# Multi-stage build for the Kickstand API. The server uses the pure-Go
# modernc.org/sqlite driver and embeds its migrations, so it compiles to a
# single static CGO-free binary — no runtime system deps, no migrations to
# ship alongside it. The `provision` CLI (create a school + first owner) is
# built into the same image so operators can onboard tenants with
# `docker compose run --rm --entrypoint provision app ...`.

# ---- build ----
FROM golang:1.26-alpine AS build
WORKDIR /src
# Download modules first so the layer caches across source-only changes.
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ENV CGO_ENABLED=0 GOOS=linux
RUN go build -trimpath -ldflags="-s -w" -o /out/server ./cmd/server \
 && go build -trimpath -ldflags="-s -w" -o /out/provision ./cmd/provision \
 && go build -trimpath -ldflags="-s -w" -o /out/backup ./cmd/backup

# ---- runtime ----
FROM alpine:3.20
# ca-certificates: outbound TLS to Firebase/GCS. wget: the compose healthcheck.
# tzdata: correct local-time formatting. Runs as a non-root user; all mutable
# state lives under the /data volume (SQLite db + local receipt uploads).
RUN apk add --no-cache ca-certificates wget tzdata \
 && addgroup -S kickstand && adduser -S -G kickstand kickstand \
 && mkdir -p /data && chown kickstand:kickstand /data
# Litestream: continuous SQLite replication to object storage (active only when
# LITESTREAM_BUCKET is set — see docker-entrypoint.sh).
ARG LITESTREAM_VERSION=0.3.13
ADD https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-v${LITESTREAM_VERSION}-linux-amd64.tar.gz /tmp/ls.tgz
RUN tar -C /usr/local/bin -xzf /tmp/ls.tgz litestream && rm /tmp/ls.tgz
COPY --from=build /out/server /usr/local/bin/server
COPY --from=build /out/provision /usr/local/bin/provision
COPY --from=build /out/backup /usr/local/bin/backup
COPY litestream.yml /etc/litestream.yml
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
USER kickstand
WORKDIR /data
EXPOSE 8765
VOLUME ["/data"]
# The entrypoint migrates-then-serves (wrapped by Litestream when configured).
# Operational CLIs are still reachable by overriding it:
#   docker compose run --rm --entrypoint provision app ...
#   docker compose run --rm --entrypoint backup   app ...
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
