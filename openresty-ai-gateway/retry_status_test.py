#!/usr/bin/env python3
"""Exercise real proxy retries against the isolated mock upstream."""

import json
import os
import urllib.error
import urllib.request

GATEWAY = os.getenv("GATEWAY", "http://127.0.0.1:38080")
CONTROL = os.getenv("MOCK_CONTROL", "http://127.0.0.1:38081")


def control(path):
    with urllib.request.urlopen(CONTROL + path, timeout=10) as response:
        return json.load(response)


def invoke(model, stream=False):
    request = urllib.request.Request(
        GATEWAY + "/v1/chat/completions",
        data=json.dumps(
            {
                "model": model,
                "stream": stream,
                "messages": [{"role": "user", "content": "保留原始请求正文"}],
            }
        ).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer mock-test",
        },
    )
    try:
        response = urllib.request.urlopen(request, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.read().decode()


def main():
    control("/mock/reset")
    for code in (500, 502, 503, 504, 429):
        for stream in (False, True):
            model = f"status-transient-{code}-stream-{stream}"
            status, body = invoke(model, stream)
            assert status == 200, (model, status, body)
            if stream:
                assert body.count("data: [DONE]") == 1, body
                assert body.count("token-1 ") == 1, body
                assert "injected upstream failure" not in body, body
            else:
                assert json.loads(body)["choices"][0]["message"]["content"], body
            assert control("/mock/metrics")["retry_status_calls"][model] == 2
        model = f"status-persistent-{code}"
        status, _ = invoke(model)
        assert status == code, (model, status)
        assert control("/mock/metrics")["retry_status_calls"][model] == 2
    for code in (400, 401, 403, 404, 501):
        model = f"status-persistent-{code}"
        status, _ = invoke(model)
        assert status == code, (model, status)
        assert control("/mock/metrics")["retry_status_calls"][model] == 1
    print(
        "PASS: transient recovery, bounded retries, status preservation, POST/body/auth, SSE, nonretryable errors"
    )


if __name__ == "__main__":
    main()
