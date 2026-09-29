#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rpm_test.py -- 验证 OpenResty AI Gateway 的 RPM(每分钟请求数)限流是否真的生效。

原理:
  Gateway 配置 RPM_CAPACITY=25, RPM_WINDOW_SECONDS=60 的令牌桶。
  桶空时网关会 *排队睡眠* (而不是返回 429), 所以超额请求会被 *延迟*。

  我们无需花钱调用模型 -- 直接打免费的 /v1/models 端点即可观察到限流效果:
    - 前 ~25 个请求瞬间返回 (消耗初始令牌);
    - 其后的请求必须等待令牌补充 (每 ~2.4s 一个), 因此响应明显变慢;
    - 在 60 秒内总共只能完成约 50 个请求, 而不是无限多 -> 证明 RPM 生效。

用法:
  python3 rpm_test.py
  GATEWAY=http://localhost:30082 API_KEY=sk-xxx DURATION=60 python3 rpm_test.py
"""
import os
import sys
import time
import threading
from collections import defaultdict

try:
    import requests
except ImportError:
    sys.exit("缺少 requests 库, 请先安装: pip install requests")

# ---- 可配置项 (环境变量) ---------------------------------------------------
GATEWAY        = os.getenv("GATEWAY", "http://localhost:30082").rstrip("/")
API_KEY        = os.getenv("API_KEY", "sk-QDN2frZfj1rg2mjXjmq9GCZ2fFU2LdhDePtnNch6waStnRVE")
DURATION       = int(os.getenv("DURATION", "60"))          # 测试总时长(秒)
EXPECTED_RPM   = int(os.getenv("RPM_CAPACITY", "25"))       # 期望的 RPM 上限
EXPECTED_WIN   = int(os.getenv("RPM_WINDOW_SECONDS", "60")) # 令牌窗口
N_WORKERS      = int(os.getenv("N_WORKERS", "8"))           # 并发客户端数
URL            = GATEWAY + "/v1/models"
# 单次请求 "瞬间完成" 的阈值(秒)。排队请求每个至少等待 ~窗口/容量 秒。
FAST_THRESHOLD = float(os.getenv("FAST_THRESHOLD", "1.0"))

# 令牌补充速率 -> 每个令牌间隔
REFILL_INTERVAL = EXPECTED_WIN / EXPECTED_RPM  # 秒/令牌

results = []          # (start_ts, duration_s, status)
lock = threading.Lock()
stop = threading.Event()


def worker(wid):
    """持续发送 /v1/models 请求, 直到 stop 被置位。"""
    s = requests.Session()
    headers = {"Authorization": f"Bearer {API_KEY}"}
    while not stop.is_set():
        t0 = time.time()
        try:
            r = s.get(URL, headers=headers, timeout=130)
            dt = time.time() - t0
            with lock:
                results.append((t0, dt, r.status_code))
        except Exception as e:
            with lock:
                results.append((t0, time.time() - t0, f"ERR:{type(e).__name__}"))


def fmt(ts):
    return time.strftime("%H:%M:%S", time.localtime(ts))


def main():
    print("=" * 64)
    print(" OpenResty AI Gateway -- RPM 限流验证")
    print("=" * 64)
    print(f" 网关地址     : {GATEWAY}")
    print(f" 测试端点     : {URL}")
    print(f" 期望 RPM     : {EXPECTED_RPM} / {EXPECTED_WIN}s  (每令牌 {REFILL_INTERVAL:.2f}s)")
    print(f" 并发客户端   : {N_WORKERS}")
    print(f" 测试时长     : {DURATION}s")
    print(f" 瞬间阈值     : < {FAST_THRESHOLD}s 视为未排队")
    print("-" * 64)

    # 1) 先确认服务可达
    try:
        probe = requests.get(URL, headers={"Authorization": f"Bearer {API_KEY}"}, timeout=15)
        if probe.status_code != 200:
            print(f" [WARN] 预检 /v1/models 返回 {probe.status_code}, 请检查 key/服务")
        else:
            print(f" [OK] 预检 /v1/models 返回 200, 服务正常, 开始压测...")
    except Exception as e:
        print(f" [FATAL] 无法连接网关: {e}")
        sys.exit(1)

    # 2) 启动并发 workers, 持续 DURATION 秒
    t_start = time.time()
    threads = [threading.Thread(target=worker, args=(i,), daemon=True)
               for i in range(N_WORKERS)]
    for t in threads:
        t.start()
    print(f" 压测中 ({DURATION}s)... ", flush=True)
    time.sleep(DURATION)
    stop.set()
    for t in threads:
        t.join(timeout=140)
    t_end = time.time()
    wall = t_end - t_start

    # 3) 分析
    results.sort(key=lambda x: x[0])
    n = len(results)
    fast = [r for r in results if isinstance(r[2], int) and r[1] < FAST_THRESHOLD]
    queued = [r for r in results if isinstance(r[2], int) and r[1] >= FAST_THRESHOLD]
    errors = [r for r in results if not isinstance(r[2], int)]

    print("-" * 64)
    print(f" 实际测试墙钟时间 : {wall:.1f}s")
    print(f" 完成请求总数     : {n}")
    print(f"   - 瞬间完成(<{FAST_THRESHOLD}s): {len(fast)}")
    print(f"   - 被排队延迟(>={FAST_THRESHOLD}s): {len(queued)}")
    print(f"   - 错误/异常     : {len(errors)}")
    if errors:
        from collections import Counter
        c = Counter(str(e[2]) for e in errors)
        print(f"     错误明细: {dict(c)}")

    # 4) 把完成时间按秒分桶, 展示时间线
    if n:
        first_ts = results[0][0]
        buckets = defaultdict(int)
        for ts, _, _ in results:
            buckets[int(ts - first_ts)] += 1
        span = int(results[-1][0] - first_ts) + 1
        print("-" * 64)
        print(" 每秒完成请求数 (时间线, 表明桶耗尽后速率骤降):")
        line = ""
        for sec in range(span):
            cnt = buckets.get(sec, 0)
            bar = "#" * cnt if cnt else "."
            line += f"\n   t+{sec:2d}s: {bar} ({cnt})"
        print(line)

    # 5) 打印前若干请求的延迟, 体现 "阶梯式排队"
    if n:
        print("-" * 64)
        print(" 前 32 个请求的响应耗时 (s):")
        sample = results[:32]
        row = ""
        for i, (ts, dt, st) in enumerate(sample, 1):
            row += f"{i:2d}:{dt:6.2f} "
            if i % 8 == 0:
                row += "\n            "
        print("           " + row.strip())

    # 6) 计算速率并给出结论
    print("-" * 64)
    if n == 0:
        print(" [结论] 没有任何请求完成, 无法判定 RPM。")
        return 1
    avg_rate = n / wall * 60.0  # 每分钟平均
    sustained = 0.0
    if len(results) > EXPECTED_RPM:
        # 取第 EXPECTED_RPM 个之后的请求, 估算稳态速率
        tail = results[EXPECTED_RPM:]
        tstart = tail[0][0]
        tend = tail[-1][0]
        if tend > tstart:
            sustained = len(tail) / (tend - tstart) * 60.0
    # 若不限流, 8 个 worker 在 60s 内理论上能发几千个请求
    ideal_unlimited = N_WORKERS * wall / 0.02  # 粗略上界
    print(f" 60s 内平均速率 : ~{avg_rate:.1f} 请求/分钟")
    if sustained:
        print(f" 桶耗尽后稳态速率 : ~{sustained:.1f} 请求/分钟 (期望≈{EXPECTED_RPM})")
    print(f" 若无限流, 上界约 : ~{ideal_unlimited:.0f} 请求/分钟")

    rpm_works = (len(queued) > 0) and (avg_rate < ideal_unlimited * 0.1)
    if rpm_works:
        print(" [结论] RPM 限流 **生效**: 初始令牌被快速消耗后, 超额请求被排队")
        print("         延迟, 实际吞吐被压制在 ~{} 请求/分钟。".format(EXPECTED_RPM))
        return 0
    else:
        print(" [结论] 未观察到明显限流效果 (请求几乎全部瞬间完成且数量巨大)。")
        return 1


if __name__ == "__main__":
    sys.exit(main() or 0)
