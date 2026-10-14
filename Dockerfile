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
COPY --from=build /out/server /usr/local/bin/server
COPY --from=build /out/provision /usr/local/bin/provision
COPY --from=build /out/backup /usr/local/bin/backup
USER kickstand
WORKDIR /data
EXPOSE 8765
VOLUME ["/data"]
ENTRYPOINT ["server"]
CMD ["-addr", ":8765", "-dsn", "/data/kickstand.db", "-uploads-dir", "/data/uploads"]
