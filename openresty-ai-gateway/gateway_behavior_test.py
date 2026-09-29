#!/usr/bin/env python3
"""Deterministic regression checks for gateway admission and cooldown."""

from __future__ import annotations

import json
import os
import urllib.request
import time
from concurrent.futures import ThreadPoolExecutor


GATEWAY = os.getenv("GATEWAY", "http://127.0.0.1:38080").rstrip("/")
MOCK_CONTROL = os.getenv("MOCK_CONTROL", "http://127.0.0.1:38081").rstrip("/")
MAX_CONCURRENCY = int(os.getenv("MAX_CONCURRENCY", "5"))
COOLDOWN_SECONDS = float(os.getenv("HTTP_ERROR_COOLDOWN_SECONDS", "2"))
MAX_HTTP_ERROR_RETRIES = int(os.getenv("MAX_HTTP_ERROR_RETRIES", "1"))


def get(path: str) -> dict[str, object]:
    with urllib.request.urlopen(f"{MOCK_CONTROL}{path}", timeout=30) as response:
        return json.load(response)


def chat(model: str) -> int:
    return chat_payload(
        {
            "model": model,
            "stream": False,
            "messages": [{"role": "user", "content": "load"}],
        },
    )


def chat_payload(payload: dict[str, object]) -> int:
    request = urllib.request.Request(
        f"{GATEWAY}/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status
    except urllib.error.HTTPError as exc:
        return exc.code


def concurrent(models: list[str]) -> list[int]:
    with ThreadPoolExecutor(max_workers=len(models)) as pool:
        return list(pool.map(chat, models))


def main() -> int:
    get("/mock/reset")
    statuses = concurrent(["slow-model"] * 10)
    metrics = get("/mock/metrics")
    observed = int(metrics["max_inflight"])
    assert statuses == [200] * 10, statuses
    assert observed <= MAX_CONCURRENCY, (
        f"cold-start burst reached {observed}; configured maximum is "
        f"{MAX_CONCURRENCY}"
    )

    get("/mock/reset")
    statuses = concurrent(["cooldown-model"] * 6)
    metrics = get("/mock/metrics")
    gap = metrics["cooldown_gap"]
    assert statuses == [200] * 6, statuses
    assert isinstance(gap, (float, int)), metrics
    assert gap >= COOLDOWN_SECONDS * 0.8, (
        f"same-model request reached upstream after {gap:.3f}s; expected shared "
        f"cooldown near {COOLDOWN_SECONDS:.3f}s"
    )

    get("/mock/reset")
    status = chat("persistent-error-model")
    metrics = get("/mock/metrics")
    upstream_calls = int(metrics["persistent_error_count"])
    assert status == 503, status
    assert upstream_calls == MAX_HTTP_ERROR_RETRIES + 1, (
        f"persistent error caused {upstream_calls} upstream calls; expected "
        f"{MAX_HTTP_ERROR_RETRIES + 1} (initial + bounded retries)"
    )

    # Force nginx to buffer the body to disk, with `model` after 64 KiB. The
    # error must still open only that model's cooldown, not `__global__`.
    get("/mock/reset")
    large_error = {
        "messages": [{"role": "user", "content": "x" * 70000}],
        "stream": False,
        "model": "persistent-large-error-model",
    }
    assert chat_payload(large_error) == 503
    started = time.monotonic()
    assert chat("large-normal-model") == 200
    isolation_elapsed = time.monotonic() - started
    assert isolation_elapsed < COOLDOWN_SECONDS * 0.8, (
        f"large-body model fell into global cooldown; unrelated model waited "
        f"{isolation_elapsed:.3f}s"
    )
    print(
        f"gateway-behavior-ok max_inflight={observed} "
        f"cooldown_gap={gap:.3f}s persistent_calls={upstream_calls} "
        f"large_body_isolation={isolation_elapsed:.3f}s",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
