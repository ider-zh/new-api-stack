# New-API Stack

A self-hosted deployment of [New-API](https://github.com/Calcium-Ion/new-api) — an
OpenAI-compatible API management & relay gateway — with its datastore, cache, a
model-aggregation proxy, and an OpenResty rate-limiting gateway, all wired
together with Docker Compose.

```
                ┌─────────────┐
   Client ─────▶│ OpenResty   │  global RPM limit + 429 retry (queues, no 429)
                │ AI Gateway  │  host :30082  →  new-api:3000
                └──────┬──────┘
                       ▼
                ┌─────────────┐
                │   new-api   │  :3000  (also exposed on host :30080)
                └──┬──────┬───┘
                   ▼      ▼
             ┌────────┐ ┌────────┐
             │Postgres│ │ Redis  │   datastore / cache
             └────────┘ └────────┘

   Bifrost (model proxy) runs alongside on host :30081.
```

---

## What's inside

| Service              | Image                          | Host port | Role                                            |
| -------------------- | ------------------------------ | --------- | ----------------------------------------------- |
| `new-api`            | `calciumion/new-api:latest`    | `30080`   | The core API management / relay application     |
| `new-postgres`       | `postgres:15`                  | —         | Primary datastore (named volume `pg-data`)      |
| `new-redis`          | `redis:latest`                 | —         | Cache / rate-limit / session store              |
| `bifrost`            | `maximhq/bifrost`              | `30081`   | Model aggregation / proxy service               |
| `openresty-ai-gateway` | `openresty/openresty:alpine` | `30082`   | Reverse proxy + global RPM limiter (see below)  |

All services share a single **external** Docker network called `web` (already
created on the host), so Traefik can route to them and the gateway can reach
`new-api` by service name.

> **Note:** the `web` network must exist before you start the stack:
> `docker network create web`

---

## Quick start

```bash
# 1. Create the shared network (once, on the host)
docker network create web

# 2. Provide secrets via environment
cp .env.example .env
# edit .env and set a real POSTGRES_PASSWORD

# 3. Start everything
docker compose up -d

# 4. Check health
docker compose ps
curl -s http://localhost:30082/health   # gateway
curl -s http://localhost:30080/api/status   # new-api
```

Visit `http://localhost:30080` to open the New-API admin UI (or the Traefik
route `ai-api.quearo.lan.9992099.xyz` if Traefik + Cloudflare are configured).

---

## Configuration

Secrets and tunables live in a `.env` file (git-ignored). Copy
[`.env.example`](.env.example) and adjust. Highlights:

| Variable                | Default          | Used by            | Meaning                                  |
| ----------------------- | ---------------- | ------------------ | ---------------------------------------- |
| `POSTGRES_USER`         | `root`           | postgres, new-api  | DB user                                  |
| `POSTGRES_PASSWORD`     | `CHANGE_ME`      | postgres, new-api  | DB password (feeds `SQL_DSN`)            |
| `POSTGRES_DB`           | `new-api`        | postgres, new-api  | DB name                                  |
| `REDIS_CONN_STRING`     | `redis://new-redis` | new-api         | Redis connection string                  |
| `RPM_CAPACITY`          | `25`             | gateway            | Token-bucket capacity (= max burst/min)  |
| `RPM_WINDOW_SECONDS`    | `60`             | gateway            | Refill window for `RPM_CAPACITY` tokens  |
| `MAX_429_RETRIES`       | `5`              | gateway            | Transparent retries on upstream `429`    |
| `RETRY_BACKOFF_SECONDS` | `1`              | gateway            | Base backoff (linear) between retries    |
| `GATEWAY_HOST_PORT`     | `30082`          | gateway            | Host port the gateway is published on    |

The gateway's full configuration reference lives in
[`openresty-ai-gateway/README.md`](openresty-ai-gateway/README.md).

---

## OpenResty AI Gateway

The `openresty-ai-gateway` service sits in front of `new-api` and:

* enforces a **global RPM limit** using a token bucket — when over limit it
  **queues** the request and waits, instead of returning `429` to your clients;
* performs **transparent retries** on upstream `429` responses;
* passes SSE streams through in real time (unbuffered);
* exposes a `/health` endpoint and structured JSON access logs (incl.
  `queue_wait_ms`).

See [`openresty-ai-gateway/`](openresty-ai-gateway/) for the full design,
configuration reference, and a mock-backend test harness (`test.sh`).

---

## Data & logs

* `./data` and `./logs` are bind-mounted from the host (git-ignored) — they hold
  New-API's application data and logs respectively.
* PostgreSQL and Redis use Docker **named volumes** (`pg-data`, `redis-data`), so
  their data survives container recreation.

---

## Notes

* Container logs are rotated (`json-file`, max-size / max-file) so the host disk
  doesn't fill up.
* `new-api` and the gateway are labelled for **Watchtower** auto-update and
  **Traefik** routing.
* Resource caps (1 GB / 1 CPU for `new-api`) protect the host under load.
