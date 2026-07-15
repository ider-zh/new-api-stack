-- ===========================================================================
-- rate_limit.lua
-- Two responsibilities:
--   1. Global RPM control via a token bucket. When no token is available the
--      request SLEEPS (queues) instead of returning HTTP 429.
--   2. Transparent retry on upstream HTTP 429, with bounded attempts and
--      linear backoff.
-- Concurrency safety is guaranteed by a single resty.lock so that two worker
-- processes can never hand out the same token, plus atomic shared-dict ops.
-- ===========================================================================

local lock = require "resty.lock"
local config = require "config"

local _M = {}

local dict = ngx.shared[config.shared_dict_name]

local TOKENS_KEY   = "rpm_tokens"
local REFILL_KEY   = "rpm_last_refill"
-- Request-scoped header carrying the 429-retry attempt count. Using a request
-- header (rather than request_id + shared dict) is robust because nginx
-- regenerates request_id on every internal redirect, while request headers
-- persist across error_page internal redirects.
local RETRY_HEADER = "X-Gateway-Retry"

-- ---------------------------------------------------------------------------
-- acquire_token()
-- Token-bucket algorithm.
--   * capacity   = config.rpm_capacity            (e.g. 25)
--   * refill     = capacity / window_seconds      (tokens per second)
-- Returns the number of milliseconds the caller had to queue (0 if immediate).
-- ---------------------------------------------------------------------------
function _M.acquire_token()
    local capacity = config.rpm_capacity
    local rate = capacity / config.rpm_window_seconds   -- tokens / second

    -- Serialise access to the bucket across all workers. A short-lived lock
    -- makes the refill+consume step atomic; the lock is also held while we
    -- sleep, so the bucket capacity is truly reserved for this request.
    local lk = lock:new(config.shared_dict_name, {
        exptime = config.max_queue_wait_seconds + 10,
        timeout = config.max_queue_wait_seconds + 10,
    })
    local _, err = lk:lock("rpm_bucket_lock")
    if err then
        -- Lock unavailable: fail OPEN so we never hard-block traffic.
        ngx.log(ngx.ERR, "rate-limit lock error: ", err)
        return 0
    end

    local now = ngx.now()   -- high-resolution, monotonic-ish wall clock

    -- Read current state (lazy initialisation on first request).
    local tokens = dict:get(TOKENS_KEY)
    local last   = dict:get(REFILL_KEY)
    if tokens == nil then tokens = capacity end
    if last == nil then last = now end

    -- Refill tokens proportional to elapsed time, capped at capacity.
    local elapsed = now - last
    if elapsed > 0 then
        tokens = math.min(capacity, tokens + elapsed * rate)
        last = now
    end

    local wait_ms = 0

    if tokens >= 1 then
        -- Token available -> consume immediately.
        tokens = tokens - 1
    else
        -- No token -> compute how long until one is refilled and queue.
        local needed = 1 - tokens                 -- (0, 1]
        local wait = needed / rate                -- seconds
        if wait > config.max_queue_wait_seconds then
            wait = config.max_queue_wait_seconds
        end
        ngx.sleep(wait)
        -- After sleeping `wait`, exactly `needed` tokens have been refilled;
        -- consume one, leaving (needed - 1) which we round to a clean 0 here.
        tokens = 0
        last = ngx.now()
        wait_ms = wait * 1000
    end

    dict:set(TOKENS_KEY, tokens)
    dict:set(REFILL_KEY, last)

    lk:unlock()
    return wait_ms
end

-- ---------------------------------------------------------------------------
-- handle_429_retry()
-- Called from the @retry location's access phase when the upstream returned
-- 429. Reads/increments the retry attempt count carried in the X-Gateway-Retry
-- request header (which survives internal redirects), applies linear backoff,
-- and returns:
--   true  -> retry allowed, caller should proxy_pass again
--   false -> retries exhausted, caller should pass the upstream 429 through
--            unchanged (ngx.exec to a non-intercepting location).
-- ---------------------------------------------------------------------------
function _M.handle_429_retry()
    local attempt = tonumber(ngx.req.get_headers()[RETRY_HEADER]) or 0
    attempt = attempt + 1

    if attempt > config.max_429_retries then
        -- Out of attempts: let the real 429 reach the client.
        return false
    end

    -- Persist the incremented count for the next internal redirect.
    ngx.req.set_header(RETRY_HEADER, attempt)
    ngx.log(ngx.WARN, "429 retry attempt ", attempt, "/", config.max_429_retries)

    -- Linear backoff: 1*backoff, 2*backoff, ... before the n-th retry.
    local backoff = config.retry_backoff_seconds * attempt
    if backoff > 0 then
        ngx.sleep(backoff)
    end
    return true
end

return _M
