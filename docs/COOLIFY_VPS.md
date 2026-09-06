# QUOTE Coolify VPS runbook

This runbook prepares QUOTE for a single 6-core / 9 GB VPS. It does not deploy, push, sign, or
broadcast anything.

## Services

- `frontend`: Vinext production server on port `3000`.
- `api`: QUOTE REST/SSE/WebSocket/media API on port `8787`.
- `indexer`: BSC WSS wake-up plus HTTP RPC proof reader. It has no public port.
- `migrate`: one-shot PostgreSQL migration job, safe to rerun.
- `postgres`: private PostgreSQL 16 volume-backed database.

Redis is intentionally absent. The current codebase uses PostgreSQL for cursors, outbox, media
cache and read models; no live Redis client or queue runtime is present.

## Coolify setup

1. Create a Docker Compose resource that points at `docker-compose.coolify.yml`.
2. Add environment variables from `.env.coolify.example` in Coolify, not in committed files.
3. Generate strong values for `POSTGRES_PASSWORD` and `DATABASE_URL`. URL-encode the database
   password inside `DATABASE_URL`, for example:

   ```text
   postgresql://quote:<url-encoded-password>@postgres:5432/quote?sslmode=disable
   ```

4. Set `NEXT_PUBLIC_QUOTE_API_URL` to the public HTTPS origin that Coolify routes to `api`.
5. Set `QUOTE_WEB_ORIGINS` to the public frontend origin, comma-separated if there is more than
   one. This is the API CORS allowlist.
6. Keep `QUOTE_BACKEND_URL=http://api:8787` unless the internal service name changes.
7. Put `BSC_HTTP_RPC_URL`, `BSC_WSS_RPC_URL`, optional provider credentials and the complete
   `QUOTE_INDEXER_REGISTRY_JSON` in Coolify secrets/env only.

The `NEXT_PUBLIC_*` values are baked into the browser bundle during image build. Changing them
requires a frontend rebuild.

## Sizing for 6 cores / 9 GB

The compose file caps the steady-state services at about 6.3 GB:

- PostgreSQL: `3g`, `2.00` CPUs, `shared_buffers=1GB`, `effective_cache_size=6GB`.
- API: `1g`, `1.25` CPUs, `NODE_OPTIONS=--max-old-space-size=768`.
- Indexer: `1g`, `1.25` CPUs, `NODE_OPTIONS=--max-old-space-size=768`.
- Frontend: `768m`, `1.00` CPU, `NODE_OPTIONS=--max-old-space-size=512`.
- Migration job: `512m`, `0.50` CPU.

Leave the remaining memory for the OS, Coolify, Docker, reverse proxy and image build spikes. For
manual builds on the VPS, build serially:

```sh
COMPOSE_PARALLEL_LIMIT=1 docker compose -f docker-compose.coolify.yml build --pull=false
```

## Runtime hardening

The Node images run as an unprivileged `quote` user, with `no-new-privileges`, dropped Linux
capabilities, read-only root filesystems and a small `/tmp` tmpfs. PostgreSQL is not exposed with a
host port. All services use bounded JSON-file logs (`10m`, 5 files) and `stop_grace_period: 30s`.

Healthchecks:

- `frontend`: internal HTTP `GET /`.
- `api`: internal HTTP `GET /v1/health`.
- `indexer`: verifies the latest migration checksum is applied. RPC liveness should be monitored
  from indexer logs and cursor freshness; the healthcheck deliberately does not make external RPC
  calls.

The migration job creates `schema_migrations`, applies `backend/migrations/*.sql` in lexical order
inside transactions and rejects checksum drift for already-applied files.
