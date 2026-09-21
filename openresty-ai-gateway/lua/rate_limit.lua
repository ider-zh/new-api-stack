-- Shared admission control for the OpenResty AI gateway.
--
-- Guarantees:
--   * no more than max_concurrency requests are active upstream;
--   * RPM overflow waits instead of returning a local 429;
--   * an upstream 429/500/502/503/504 opens a cooldown shared by the same model queue;
--   * retries remain inside the original concurrency slot.

local cjson = require "cjson.safe"
local lock = require "resty.lock"
local config = require "config"

local _M = {}
local dict = ngx.shared[config.shared_dict_name]

local TOKENS_KEY = "rpm_tokens"
local REFILL_KEY = "rpm_last_refill"
local SLOT_PREFIX = "concurrency_slot:"
local COOLDOWN_PREFIX = "model_cooldown:"
local FAILURE_PREFIX = "model_failures:"
local FAILURE_AT_PREFIX = "model_failure_at:"
local RETRY_HEADER = "X-Gateway-Retry"
local MODEL_HEADER = "X-Gateway-Model"
local ADMISSION_HEADER = "X-Gateway-Admission"
local SLOT_HEADER = "X-Gateway-Slot"
local READY_HEADER = "X-Gateway-Ready-At"

local function body_model()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if body then
        local payload = cjson.decode(body)
        if payload and type(payload.model) == "string" and payload.model ~= "" then
            return payload.model
        end
        return body:match('"model"%s*:%s*"([^"\\]+)"')
    end
    local path = ngx.req.get_body_file()
    if not path then
        return nil
    end
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local carry = ""
    local model
    while true do
        local chunk = file:read(65536)
        if not chunk then
            break
        end
        local data = carry .. chunk
        model = data:match('"model"%s*:%s*"([^"\\]+)"')
        if model then
            break
        end
        carry = data:sub(-256)
    end
    file:close()
    return model
end

function _M.request_model()
    local existing = ngx.req.get_headers()[MODEL_HEADER]
    if existing and existing ~= "" then
        return tostring(existing):sub(1, 200)
    end

    local model = body_model()
    if not model or model == "" then
        model = "__global__"
    end
    model = tostring(model):sub(1, 200)
    ngx.req.set_header(MODEL_HEADER, model)
    return model
end

function _M.wait_for_model(model)
    local waited = 0
    local key = COOLDOWN_PREFIX .. model
    while true do
        local until_at = tonumber(dict:get(key)) or 0
        local remaining = until_at - ngx.now()
        if remaining <= 0 then
            if until_at > 0 then
                dict:delete(key)
            end
            return waited
        end
        ngx.sleep(remaining)
        waited = waited + remaining
    end
end

local function acquire_concurrency()
    local started = ngx.now()
    local admission = ngx.var.request_id
    while true do
        for slot = 1, config.max_concurrency do
            local key = SLOT_PREFIX .. slot
            if dict:add(key, admission, config.concurrency_slot_ttl_seconds) then
                ngx.req.set_header(ADMISSION_HEADER, admission)
                ngx.req.set_header(SLOT_HEADER, tostring(slot))
                return ngx.now() - started
            end
        end
        if ngx.now() - started >= config.concurrency_queue_timeout_seconds then
            return nil, "concurrency queue timeout"
        end
        ngx.sleep(config.concurrency_poll_seconds)
    end
end

local function release_slot()
    local headers = ngx.req.get_headers()
    local admission = headers[ADMISSION_HEADER]
    local slot = tonumber(headers[SLOT_HEADER])
    if not admission or not slot or slot < 1 or slot > config.max_concurrency then
        return
    end
    local key = SLOT_PREFIX .. slot
    if dict:get(key) == admission then
        dict:delete(key)
    end
end

function _M.release_request()
    release_slot()
end

function _M.finish_request()
    local headers = ngx.req.get_headers()
    local model = headers[MODEL_HEADER]
    local ready_at = tonumber(headers[READY_HEADER]) or 0
    local failure_at = model and tonumber(dict:get(FAILURE_AT_PREFIX .. model)) or 0
    -- A success that was already in flight when another request failed must
    -- not cancel the newly-opened cooldown. Only a request admitted/retried
    -- after that failure proves that the model has recovered.
    if model and ngx.status < 400 and ready_at > failure_at then
        dict:delete(COOLDOWN_PREFIX .. model)
        dict:delete(FAILURE_PREFIX .. model)
        dict:delete(FAILURE_AT_PREFIX .. model)
    end
    release_slot()
end

function _M.acquire_token()
    local capacity = config.rpm_capacity
    local rate = capacity / config.rpm_window_seconds
    local lk = lock:new(config.shared_dict_name, {
        exptime = config.max_queue_wait_seconds + 10,
        timeout = config.max_queue_wait_seconds + 10,
    })
    local _, err = lk:lock("rpm_bucket_lock")
    if err then
        return nil, "rate-limit lock error: " .. err
    end

    local now = ngx.now()
    local tokens = dict:get(TOKENS_KEY)
    local last = dict:get(REFILL_KEY)
    if tokens == nil then tokens = capacity end
    if last == nil then last = now end
    local elapsed = now - last
    if elapsed > 0 then
        tokens = math.min(capacity, tokens + elapsed * rate)
        last = now
    end

    local waited = 0
    if tokens >= 1 then
        tokens = tokens - 1
    else
        local wait = math.min((1 - tokens) / rate, config.max_queue_wait_seconds)
        ngx.sleep(wait)
        tokens = 0
        last = ngx.now()
        waited = wait
    end
    dict:set(TOKENS_KEY, tokens)
    dict:set(REFILL_KEY, last)
    lk:unlock()
    return waited
end

function _M.acquire_request()
    local model = _M.request_model()
    local waited = _M.wait_for_model(model)
    local concurrency_wait, err = acquire_concurrency()
    if not concurrency_wait then
        return nil, err
    end
    waited = waited + concurrency_wait
    -- A failure may have opened a cooldown while this request waited for a
    -- slot, so check the same-model gate again immediately before admission.
    waited = waited + _M.wait_for_model(model)
    local rpm_wait, rpm_err = _M.acquire_token()
    if not rpm_wait then
        _M.release_request()
        return nil, rpm_err
    end
    ngx.req.set_header(READY_HEADER, tostring(ngx.now()))
    return (waited + rpm_wait) * 1000
end

local function upstream_status()
    local value = tostring(ngx.var.upstream_status or "")
    return tonumber(value:match("(%d%d%d)%s*$")) or 0
end

function _M.handle_http_error_retry()
    local status = upstream_status()
    local model = _M.request_model()
    local attempt = tonumber(ngx.req.get_headers()[RETRY_HEADER]) or 0
    local failures = tonumber(dict:get(FAILURE_PREFIX .. model)) or 0
    if attempt == 0 then
        failures = dict:incr(FAILURE_PREFIX .. model, 1, 0) or (failures + 1)
    end
    failures = math.max(1, failures)
    local cooldown = math.min(
        config.http_error_max_cooldown_seconds,
        config.http_error_cooldown_seconds * (2 ^ math.min(failures - 1, 10))
    )
    dict:set(
        COOLDOWN_PREFIX .. model,
        ngx.now() + cooldown
    )
    dict:set(FAILURE_AT_PREFIX .. model, ngx.now())

    attempt = attempt + 1
    if attempt > config.max_http_error_retries then
        ngx.log(
            ngx.WARN,
            "upstream ", status, " retries exhausted model=", model,
            " cooldown=", cooldown, "s failures=", failures
        )
        return false, status
    end
    ngx.req.set_header(RETRY_HEADER, attempt)
    ngx.log(
        ngx.WARN,
        "upstream ", status, " retry attempt ", attempt, "/",
        config.max_http_error_retries, " model=", model,
        " cooldown=", cooldown, "s failures=", failures
    )

    local linear = config.retry_backoff_seconds * attempt
    local delay = math.max(cooldown, linear)
    if delay > 0 then
        ngx.sleep(delay)
    end
    local _, token_err = _M.acquire_token()
    if token_err then
        ngx.log(ngx.ERR, token_err)
    end
    ngx.req.set_header(READY_HEADER, tostring(ngx.now()))
    return true
end

return _M
