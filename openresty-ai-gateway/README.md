# OpenResty AI Gateway

A thin **reverse-proxy / rate-limiting gateway** deployed in front of
[new-api](https://github.com/Calcium-Ion/new-api). It protects the backend from
RPM overruns and upstream `429` errors **without ever returning `429` to your
clients** for local rate limiting — instead it **queues** requests.

```
Client / Agent
      |
      v
OpenResty Gateway   <-- RPM token-bucket, queue, 429 transparent retry
      |
      v
new-api
      |
      v
LLM Provider
```

---

## Features

| Requirement | Status |
| --- | --- |
| HTTP reverse proxy | ✅ |
| SSE streaming passthrough (real-time, unbuffered) | ✅ |
| Global RPM limit (token bucket) | ✅ |
| Over-RPM ⇒ queue + wait (no `429`) | ✅ |
| Transparent retry on upstream `429` | ✅ |
| Docker Compose deployment | ✅ |
| `/health` endpoint | ✅ |
| Structured JSON access log (incl. `queue_wait_ms`) | ✅ |
| Configurable via environment | ✅ |

**Not implemented (by design, phase 1):** multi-instance, Redis, per-user
quotas, TPM limits, model routing, fallback, web UI.

---

## Directory layout

```
openresty-ai-gateway/
├── docker-compose.yml          # production: gateway -> new-api:3000 (external `web` net)
├── docker-compose.mock.yml     # validation: gateway + mock backend
├── nginx.conf                  # OpenResty config (SSE, RPM, retry, logging)
├── docker-entrypoint.sh        # renders listen port from $PORT
├── lua/
│   ├── config.lua              # all tunables, read from env
│   └── rate_limit.lua          # token-bucket + 429 retry logic
├── mock-server/                # mock OpenAI backend for tests only
│   └── mock-nginx.conf         # OpenResty/Lua mock (no extra image to pull)
├── test.sh                     # validation script
└── README.md
```

---

## Deployment (in front of new-api)

The production compose attaches to the **same external `web` network** that
new-api already uses, so the gateway reaches it as `new-api:3000`.

```bash
cd openresty-ai-gateway

# optional overrides
export NEW_API_UPSTREAM=new-api:3000
export PORT=8080
export GATEWAY_HOST_PORT=30082      # host port the gateway is published on
export RPM_CAPACITY=25
export RPM_WINDOW_SECONDS=60
export MAX_429_RETRIES=5
export RETRY_BACKOFF_SECONDS=1

docker compose up -d
```

The gateway then listens on host port `30082` (container `8080`) and forwards
to `new-api:3000`.

> If your new-api lives in a different compose project, make sure the `web`
> network is shared (it is `external: true` here) or change
> `NEW_API_UPSTREAM` to the resolvable service name / IP.

### Changing the new-api address

Set `NEW_API_UPSTREAM` to `host:port` (resolved by Docker's embedded DNS at
request time, so it works even if new-api starts after the gateway):

```bash
NEW_API_UPSTREAM=new-api:3000 docker compose up -d
```

### Changing the RPM limit

```bash
RPM_CAPACITY=50 RPM_WINDOW_SECONDS=60 docker compose up -d   # 50 req/min
```

The refill rate is `RPM_CAPACITY / RPM_WINDOW_SECONDS` tokens per second.

---

## Configuration reference

| Env var | Default | Meaning |
| --- | --- | --- |
| `NEW_API_UPSTREAM` | `new-api:3000` | Backend host:port |
| `PORT` | `8080` | Container listen port (entrypoint renders it) |
| `GATEWAY_HOST_PORT` | `30082` | Host port published by compose |
| `RPM_CAPACITY` | `25` | Token-bucket capacity (= max burst) |
| `RPM_WINDOW_SECONDS` | `60` | Window for `RPM_CAPACITY` tokens |
| `MAX_429_RETRIES` | `5` | Max transparent retries on upstream `429` |
| `RETRY_BACKOFF_SECONDS` | `1` | Base backoff (linear: attempt × base) before each retry |

All values are read **at container start** (port) or **per request** (Lua env
reads), so nothing is hard-coded.

---

## How it works

### RPM (token bucket)
`lua/rate_limit.lua` keeps `tokens` and `last_refill` in an `ngx.shared.DICT`.
A single `resty.lock` makes the *refill + consume* step atomic across all
worker processes, so two workers can never spend the same token.

* token available → consume and continue immediately (`queue_wait_ms = 0`).
* no token → `wait = (1 - tokens) / refill_rate`, `ngx.sleep(wait)`, then
  continue. The client is **queued**, never rejected with `429`.

### 429 transparent retry
`proxy_intercept_errors on` + `error_page 429 = @retry` intercepts an upstream
`429`. The `@retry` location increments a per-request counter (keyed by
`request_id`, stable across internal redirects), sleeps a linear backoff, and
re-proxies. When the budget is exhausted it delegates to `@passthrough`, which
has `proxy_intercept_errors off` so the real `429` reaches the client unchanged.

### Streaming
`proxy_buffering off`, `proxy_cache off`, `proxy_http_version 1.1`,
`proxy_read_timeout 3600s`. Responses are forwarded chunk-by-chunk, so SSE
`data:` frames appear at the client as soon as new-api emits them. The request
body is never fully buffered by Lua (only the response status is inspected).

### Logging
JSON access log to stdout, one line per request:

```json
{"time":"14/Jul/2026:...","remote_addr":"172.x","method":"POST",
 "uri":"/v1/chat/completions","status":200,"queue_wait_ms":2400,
 "request_time":10.231,"upstream_time":"10.2","bytes":1234}
```

`queue_wait_ms` is the time a request spent waiting in the RPM queue.

---

## Testing

### With the mock backend (recommended for validation)
```bash
docker compose -f docker-compose.mock.yml up -d --build
GATEWAY=http://localhost:38080 ./test.sh
docker compose -f docker-compose.mock.yml down
```

`test.sh` verifies:
1. `/health` → `200 OK`
2. normal request → `200`
3. **30 rapid requests → zero `429`**, later ones delayed (queued)
4. SSE stream arrives progressively (not buffered), ends with `data: [DONE]`
5. transparent `429` retry: client still gets a full response despite the
   mock's initial `429`s (and gives up with a real `429` once retries exhaust)

The mock (`mock-server/mock-nginx.conf`, served by the already-present
`openresty/openresty:alpine` image) returns `429` for its first `MOCK_429_COUNT`
chat requests, then `200` — so the retry path is exercised without any real LLM.

### Against the real new-api
```bash
# after deploying with docker-compose.yml
GATEWAY=http://localhost:30082 ./test.sh
```

For a quick manual SSE check:
```bash
curl -N http://localhost:30082/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $NEW_API_TOKEN" \
  -d '{"model":"<your-model>","stream":true,"messages":[{"role":"user","content":"hi"}]}'
```

---

## Known limitations

* **Single instance.** State lives in one `ngx.shared.DICT`; multiple gateway
  replicas would each have their own bucket and the RPM limit would multiply.
  Use a sticky/consistent upstream or move to Redis for horizontal scale.
* **Per-request 429 budget** is keyed by `request_id`; a client that triggers
  many 429s will eventually receive a real `429` once `MAX_429_RETRIES` is hit.
* **Mid-stream upstream errors** cannot be retried transparently (the SSE
  stream has already started); only *initial* `429`s before any token is sent
  are retried. This matches normal provider behaviour (rate-limit `429`s
  arrive before the stream begins).
* **Queue wait blocks a worker.** While a request sleeps in the bucket it holds
  a Lua lock; under sustained overload this serialises admission. This is the
  intended back-pressure, but very high burst rates may need a bigger capacity
  or more workers.
