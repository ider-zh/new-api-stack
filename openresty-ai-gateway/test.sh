#!/usr/bin/env bash
# ===========================================================================
# test.sh -- validate the OpenResty AI gateway.
#
# Covers:
#   1. /health
#   2. a normal (non-stream) request
#   3. over-RPM behaviour: 30 rapid requests must NOT yield any 429, and the
#      tail requests must be delayed (queued) instead.
#   4. SSE streaming: data chunks must arrive progressively, not buffered.
#   5. transparent 429 retry: with the mock emitting a few 429s first, a single
#      streaming request still ends with `data: [DONE]`.
#
# Usage:
#   GATEWAY=http://localhost:38080 ./test.sh        # against the mock stack
#   GATEWAY=http://localhost:30082 ./test.sh        # against real new-api
# ===========================================================================

set -u

GATEWAY="${GATEWAY:-http://localhost:38080}"
N_OVER_RPM=30

PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
info() { echo "$1"; }

# ---------------------------------------------------------------------------
# 1. health
# ---------------------------------------------------------------------------
info "== 1. health check =="
HEALTH=$(curl -s -o /tmp/h.txt -w '%{http_code}' "$GATEWAY/health")
if [ "$HEALTH" = "200" ] && grep -q OK /tmp/h.txt; then
  ok "/health returned 200 OK"
else
  bad "/health returned $HEALTH (body: $(cat /tmp/h.txt 2>/dev/null))"
fi

# ---------------------------------------------------------------------------
# 2. normal request
# ---------------------------------------------------------------------------
info "== 2. normal (non-stream) request =="
NORM=$(curl -s -o /tmp/n.txt -w '%{http_code}' -X POST "$GATEWAY/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"mock-model","stream":false,"messages":[{"role":"user","content":"hi"}]}')
if [ "$NORM" = "200" ]; then
  ok "non-stream request returned 200"
else
  bad "non-stream request returned $NORM"
fi

# ---------------------------------------------------------------------------
# 3. over-RPM: 30 concurrent requests, expect zero 429 and some queued
# ---------------------------------------------------------------------------
info "== 3. over-RPM queue (no 429) -- $N_OVER_RPM requests =="
TMPDIR_OVER=$(mktemp -d)
MAX_TOTAL=0
ANY_429=0
for i in $(seq 1 $N_OVER_RPM); do
  (
    code=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' -X POST \
      "$GATEWAY/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d '{"model":"mock-model","stream":false,"messages":[{"role":"user","content":"load"}]}')
    echo "$code" > "$TMPDIR_OVER/$i"
  ) &
done
wait

SLOW=0
while read -r line; do
  code=${line%% *}
  t=${line##* }
  if [ "$code" = "429" ]; then ANY_429=$((ANY_429+1)); fi
  # A request slower than 1s indicates it was queued behind the bucket.
  awk -v t="$t" 'BEGIN{ if (t+0 > 1.0) exit 1 }' && : || SLOW=$((SLOW+1))
  awk -v t="$t" -v m="$MAX_TOTAL" 'BEGIN{ if (t+0>m+0) exit 0; exit 1 }' && MAX_TOTAL="$t"
done < <(cat "$TMPDIR_OVER"/*)

if [ "$ANY_429" -eq 0 ]; then
  ok "no 429 returned (0/$N_OVER_RPM)"
else
  bad "$ANY_429 requests returned 429"
fi

if [ "$SLOW" -gt 0 ]; then
  ok "$SLOW request(s) were queued (slow > 1s); longest=${MAX_TOTAL}s"
else
  bad "no request was delayed -- queueing not observed"
fi
rm -rf "$TMPDIR_OVER"

# ---------------------------------------------------------------------------
# 4. SSE streaming real-time
# ---------------------------------------------------------------------------
info "== 4. SSE streaming (must be real-time, not buffered) =="
TMP_SSE=$(mktemp)
# Timestamp each incoming line; first and last data/DONE timestamps tell us if
# the response was streamed progressively.
curl -N -s -X POST "$GATEWAY/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"mock-model","stream":true,"messages":[{"role":"user","content":"stream"}]}' \
  | while IFS= read -r l; do
      [ -z "$l" ] && continue
      printf '%s %.3f\n' "$l" "$(date +%s.%N)" >> "$TMP_SSE"
    done

FIRST=$(head -1 "$TMP_SSE" | awk '{print $NF}')
LAST=$(grep '\[DONE\]' "$TMP_SSE" | tail -1 | awk '{print $NF}')
CHUNKS=$(grep -c '^data: {' "$TMP_SSE")
if [ -n "$FIRST" ] && [ -n "$LAST" ]; then
  SPAN=$(awk -v a="$FIRST" -v b="$LAST" 'BEGIN{printf "%.3f", b-a}')
  info "     stream span=${SPAN}s, data chunks=${CHUNKS}"
  # With 5 chunks @0.15s the span should be well above 0.3s -> proves streaming.
  awk -v s="$SPAN" 'BEGIN{ if (s+0 > 0.3) exit 0; exit 1 }' \
    && ok "chunks arrived progressively (span ${SPAN}s > 0.3s)" \
    || bad "response looks buffered (span ${SPAN}s)"
  grep -q 'data: \[DONE\]' "$TMP_SSE" \
    && ok "stream terminated with data: [DONE]" \
    || bad "missing data: [DONE]"
else
  bad "no SSE data captured"
fi
rm -f "$TMP_SSE"

# ---------------------------------------------------------------------------
# 5. transparent 429 retry
#    The mock (MOCK_429_COUNT) returns 429 a few times before 200. The gateway
#    must silently retry and still deliver a full stream to the client.
# ---------------------------------------------------------------------------
info "== 5. transparent 429 retry (mock emits 429 first) =="
TMP_429=$(mktemp)
HTTP_CODE=$(curl -s -o "$TMP_429" -w '%{http_code}' -N -X POST \
  "$GATEWAY/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"mock-model","stream":true,"messages":[{"role":"user","content":"retry"}]}')
if [ "$HTTP_CODE" = "200" ] && grep -q 'data: \[DONE\]' "$TMP_429"; then
  ok "transparent retry succeeded: client got 200 + data: [DONE] despite upstream 429s"
else
  bad "429 retry failed: http=$HTTP_CODE (body head: $(head -c 200 "$TMP_429"))"
fi
rm -f "$TMP_429"

# ---------------------------------------------------------------------------
echo
echo "=================================================="
echo "  RESULT: $PASS passed, $FAIL failed"
echo "=================================================="
[ "$FAIL" -eq 0 ]
