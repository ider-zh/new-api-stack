# OpenResty AI Gateway

A thin **reverse-proxy / rate-limiting gateway** deployed in front of
[new-api](https://github.com/Calcium-Ion/new-api). It protects the backend from
RPM overruns and upstream `429` errors **without ever returning `429` to your
clients** for local rate limiting — instead it **queues** requests.

```
Client / Agent
      |
      v
OpenResty Gateway   <-- RPM + concurrency queue, per-model 429/500/502/503/504 cooldown
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
| Configurable global concurrency limit | ✅ |
| Over-RPM ⇒ queue + wait (no `429`) | ✅ |
| Shared per-model cooldown on upstream `429`/`500`/`502`/`503`/`504` | ✅ |
| Transparent retry on upstream `429`/`500`/`502`/`503`/`504` | ✅ |
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
├── test.sh                     # validation script (mock + real backend)
├── rpm_test.py                  # RPM verification: free /v1/models load test
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
export MAX_CONCURRENCY=5
export HTTP_ERROR_COOLDOWN_SECONDS=5
export HTTP_ERROR_MAX_COOLDOWN_SECONDS=60
export MAX_HTTP_ERROR_RETRIES=1
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
| `MAX_CONCURRENCY` | `5` | Maximum requests simultaneously active upstream |
| `HTTP_ERROR_COOLDOWN_SECONDS` | `5` | Shared delay for the same model after `429`/`500`/`502`/`503`/`504` |
| `HTTP_ERROR_MAX_COOLDOWN_SECONDS` | `60` | Cap for exponential same-model cooldown |
| `MAX_HTTP_ERROR_RETRIES` | `1` | Max transparent retries on upstream `429`/`500`/`502`/`503`/`504` |
| `MAX_429_RETRIES` | `5` | Backward-compatible retry default |
| `RETRY_BACKOFF_SECONDS` | `1` | Linear per-request retry backoff; cooldown is the minimum |
| `CONCURRENCY_QUEUE_TIMEOUT_SECONDS` | `3600` | Maximum wait for an upstream concurrency slot |

All values are read **at container start** (port) or **per request** (Lua env
reads), so nothing is hard-coded.

---

## How it works

### Concurrency and cold-start admission
At most `MAX_CONCURRENCY` requests hold an upstream slot. Additional requests
sleep in OpenResty and are admitted as slots are released, including for SSE
requests and upstream errors. Consequently a full RPM bucket cannot send all
of its initial tokens upstream at once after a cold start.

### RPM (token bucket)
`lua/rate_limit.lua` keeps `tokens` and `last_refill` in an `ngx.shared.DICT`.
A single `resty.lock` makes the *refill + consume* step atomic across all
worker processes, so two workers can never spend the same token.

* token available → consume and continue immediately (`queue_wait_ms = 0`).
* no token → `wait = (1 - tokens) / refill_rate`, `ngx.sleep(wait)`, then
  continue. The client is **queued**, never rejected with `429`.

### Per-model cooldown and transparent retry
`proxy_intercept_errors on` intercepts initial upstream `429`, `500`, `502`, `503`, and `504`
responses. The gateway records a shared cooldown keyed by the request's model,
so newly admitted requests for that same model wait before reaching new-api;
other models remain independent. The failing request retries within its
existing concurrency slot using the larger of the shared cooldown and linear
per-attempt backoff.

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

`gateway_behavior_test.py` additionally sends concurrent mock requests and
asserts that cold-start upstream concurrency never exceeds the configured
limit and that a `503` delays the next queued request for the same model.

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

### RPM verification experiment (free, no LLM cost)
`rpm_test.py` proves the RPM cap actually works **without spending a single token**
— it hammers the free `/v1/models` endpoint with several concurrent clients for a
fixed duration and measures per-request latency. Because the gateway *queues*
( sleeps in the token bucket ) instead of returning `429`, an over-rate request
is **delayed**, not rejected, so the signature of a working RPM is:

* the first `RPM_CAPACITY` requests return instantly (the initial token burst);
* every request after the bucket is empty is spaced out by
  `RPM_WINDOW_SECONDS / RPM_CAPACITY` seconds (≈ 2.4 s at the default 25/60);
* total throughput is capped near `RPM_CAPACITY`/min instead of unbounded.

```bash
# defaults: GATEWAY=http://localhost:30082, DURATION=60, N_WORKERS=8
python3 rpm_test.py

# tune if you changed the limit
GATEWAY=http://localhost:30082 RPM_CAPACITY=25 RPM_WINDOW_SECONDS=60 \
  DURATION=60 N_WORKERS=8 python3 rpm_test.py
```

Key env vars: `GATEWAY`, `API_KEY`, `DURATION` (test length, s),
`RPM_CAPACITY`, `RPM_WINDOW_SECONDS`, `N_WORKERS` (concurrent clients),
`FAST_THRESHOLD` (s; requests slower than this count as "queued").

**Sample run** (`RPM_CAPACITY=25`, `RPM_WINDOW_SECONDS=60`, 8 workers, 60 s):

```
 完成请求总数     : 57
   - 瞬间完成(<1.0s): 24
   - 被排队延迟(>=1.0s): 33

 每秒完成请求数 (时间线):
   t+ 0s: ################################ (32)   <- 初始令牌被瞬间消耗
   t+ 1s: . (0)
   t+ 2s: # (1)                               <- 之后每 ~2.4s 才放行 1 个
   t+ 4s: # (1)
   t+ 7s: # (1)
   ... (稳定 1 个 / 2.4s) ...
   t+59s: # (1)

 前 32 个请求响应耗时(s): 1:0.07 ... 24:2.30  25:0.03  26:64.70  27:67.09 ...

 60s 内平均速率 : ~44.5 请求/分钟
 桶耗尽后稳态速率 : ~32.1 请求/分钟 (期望≈25)
 若无限流, 上界约 : ~30720 请求/分钟
 [结论] RPM 限流 **生效**
```

Interpretation: ~32 requests in the first second (burst), then a steady
**one request every ≈ 2.4 s** — exactly the configured refill interval. The
long per-request delays on later requests (45–72 s) are the queue depth under
concurrency: each over-rate request sleeps behind the single admission lock
until its token is refilled. Average steady-state throughput collapses to the
`RPM_CAPACITY`/min ceiling, confirming the limit is enforced.

---

## Known limitations

* **Single instance.** State lives in one `ngx.shared.DICT`; multiple gateway
  replicas would each have their own bucket and the RPM limit would multiply.
  Use a sticky/consistent upstream or move to Redis for horizontal scale.
* **Single gateway instance.** Concurrency, RPM, and cooldown state are local to
  one shared-memory zone and are not coordinated across replicas.
* **Model extraction** reads the JSON body in memory or the first 64 KiB of a
  buffered body. Requests without a detectable model share the `__global__`
  cooldown key.
* **Mid-stream upstream errors** cannot be retried transparently (the SSE
  stream has already started); only *initial* `429`s before any token is sent
  are retried. This matches normal provider behaviour (rate-limit `429`s
  arrive before the stream begins).
* **Queue wait blocks a worker.** While a request sleeps in the bucket it holds
  a Lua lock; under sustained overload this serialises admission. This is the
  intended back-pressure, but very high burst rates may need a bigger capacity
  or more workers.

### Retry boundaries and regression tests

The default budget is one additional attempt (two upstream requests total),
shared across 429, 500, 502, 503 and 504. Persistent failures return the final
status. Other errors such as 400, 401, 403 and 501 pass through without retry.
Only errors detected before sending response headers to the client are retried;
SSE responses are never restarted after output begins. Nginx implicit upstream
retries are disabled so the Lua budget is the only retry budget.

Run `retry_status_test.py` against the mock compose with `RPM_CAPACITY=1000`,
`HTTP_ERROR_COOLDOWN_SECONDS=0`, `HTTP_ERROR_MAX_COOLDOWN_SECONDS=0`, and
`RETRY_BACKOFF_SECONDS=0`. It covers transient recovery, persistent failures,
nonretryable statuses, preservation of POST/body/authentication, and SSE.

For Dify, point the selected New API model credential's API base URL at
`http://<gateway-host>:30082/v1`, keeping its API key and model name unchanged.
Port 30080 bypasses this gateway. This is a runtime credential setting in Dify,
not a workflow node change; do not commit credentials to this repository.
