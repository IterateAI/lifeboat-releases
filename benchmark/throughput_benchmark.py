#!/usr/bin/env python3
"""Throughput Benchmark — measures peak tokens/sec at various concurrency levels.

Unlike the latency benchmark, this focuses on:
1. Sustained throughput (tokens generated per second)
2. Finding the saturation point (peak throughput concurrency)
3. Request success rate under load

Usage:
    python benchmark/throughput_benchmark.py --server-url http://localhost:30000
    python benchmark/throughput_benchmark.py --server-url http://localhost:30000 --concurrency 64,128,256,512,1024
    python benchmark/throughput_benchmark.py --server-url http://localhost:30000 --max-tokens 512 --duration 60
"""

import argparse
import asyncio
import json
import os
import time
from dataclasses import dataclass, field
from typing import List

import aiohttp
import numpy as np


PROMPTS = [
    "Explain the theory of relativity in simple terms.",
    "Write a Python function to find the longest common subsequence of two strings. Include detailed comments.",
    "What are the main differences between TCP and UDP protocols? Provide examples of when each is used.",
    "Describe the process of photosynthesis step by step, including the light and dark reactions.",
    "Write a short story about a robot learning to paint. Make it exactly 200 words.",
    "Explain how neural networks learn through backpropagation. Use mathematical notation where appropriate.",
    "Compare and contrast the economic systems of capitalism and socialism. Discuss advantages and disadvantages of each.",
    "Design a REST API for a library management system. Include endpoints, request/response formats, and error handling.",
    "Explain the concept of quantum entanglement and its potential applications in computing and communication.",
    "Write a recursive implementation of merge sort in Python and analyze its time and space complexity.",
    "Discuss the environmental impact of cryptocurrency mining and potential solutions to reduce energy consumption.",
    "Explain the CAP theorem in distributed systems and how different databases make trade-offs.",
    "Describe the architecture of a modern web browser, from URL input to page rendering.",
    "What are the key principles of functional programming? Give examples in Python or JavaScript.",
    "Explain how HTTPS works, including the TLS handshake, certificate validation, and encryption.",
    "Write a detailed guide on optimizing SQL queries for large datasets. Include indexing strategies.",
]


@dataclass
class ThroughputResult:
    concurrency: int
    total_requests: int = 0
    successful_requests: int = 0
    failed_requests: int = 0
    timed_out_requests: int = 0
    total_prompt_tokens: int = 0
    total_completion_tokens: int = 0
    wall_clock_seconds: float = 0.0

    # Derived
    requests_per_second: float = 0.0
    completion_tokens_per_second: float = 0.0
    prompt_tokens_per_second: float = 0.0
    total_tokens_per_second: float = 0.0
    success_rate: float = 0.0

    # Latency summary
    ttft_p50_ms: float = 0.0
    ttft_p99_ms: float = 0.0
    tbt_p50_ms: float = 0.0
    total_latency_p50_ms: float = 0.0


async def send_request(
    session: aiohttp.ClientSession,
    url: str,
    prompt: str,
    max_tokens: int,
    timeout_sec: int,
) -> dict:
    """Send one streaming request and return raw metrics."""
    payload = {
        "model": "default",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.7,
        "stream": True,
    }

    start = time.monotonic()
    first_token_time = None
    token_times = []
    completion_tokens = 0
    prompt_tokens_est = len(prompt.split()) * 2

    try:
        async with session.post(
            f"{url}/v1/chat/completions",
            json=payload,
            timeout=aiohttp.ClientTimeout(total=timeout_sec),
        ) as resp:
            if resp.status != 200:
                return {"success": False, "error": f"HTTP {resp.status}",
                        "prompt_tokens": prompt_tokens_est, "completion_tokens": 0}

            async for line in resp.content:
                line = line.decode("utf-8").strip()
                if not line or not line.startswith("data: "):
                    continue
                data_str = line[6:]
                if data_str == "[DONE]":
                    break
                try:
                    data = json.loads(data_str)
                    choices = data.get("choices", [])
                    if choices and choices[0].get("delta", {}).get("content"):
                        now = time.monotonic()
                        if first_token_time is None:
                            first_token_time = now
                        token_times.append(now)
                        completion_tokens += 1
                except json.JSONDecodeError:
                    continue

    except asyncio.TimeoutError:
        return {"success": False, "error": "timeout",
                "prompt_tokens": prompt_tokens_est, "completion_tokens": 0}
    except Exception as e:
        return {"success": False, "error": str(e),
                "prompt_tokens": prompt_tokens_est, "completion_tokens": 0}

    end = time.monotonic()
    ttft_ms = (first_token_time - start) * 1000 if first_token_time else 0
    tbt_ms = 0.0
    if len(token_times) > 1:
        delays = [(token_times[i] - token_times[i - 1]) * 1000 for i in range(1, len(token_times))]
        tbt_ms = float(np.mean(delays))

    return {
        "success": True,
        "prompt_tokens": prompt_tokens_est,
        "completion_tokens": completion_tokens,
        "total_ms": (end - start) * 1000,
        "ttft_ms": ttft_ms,
        "tbt_ms": tbt_ms,
    }


async def run_level(
    url: str,
    concurrency: int,
    num_requests: int,
    max_tokens: int,
    timeout_sec: int,
) -> ThroughputResult:
    """Run all requests at a given concurrency and return aggregated result."""
    result = ThroughputResult(concurrency=concurrency, total_requests=num_requests)
    semaphore = asyncio.Semaphore(concurrency)
    connector = aiohttp.TCPConnector(limit=concurrency + 10)

    async with aiohttp.ClientSession(connector=connector) as session:
        async def bounded(idx):
            prompt = PROMPTS[idx % len(PROMPTS)]
            async with semaphore:
                return await send_request(session, url, prompt, max_tokens, timeout_sec)

        wall_start = time.monotonic()
        raw = await asyncio.gather(*[bounded(i) for i in range(num_requests)])
        result.wall_clock_seconds = time.monotonic() - wall_start

    # Aggregate
    ttfts = []
    tbts = []
    totals = []
    for r in raw:
        if r["success"]:
            result.successful_requests += 1
            result.total_prompt_tokens += r["prompt_tokens"]
            result.total_completion_tokens += r["completion_tokens"]
            if r.get("ttft_ms", 0) > 0:
                ttfts.append(r["ttft_ms"])
            if r.get("tbt_ms", 0) > 0:
                tbts.append(r["tbt_ms"])
            if r.get("total_ms", 0) > 0:
                totals.append(r["total_ms"])
        else:
            result.failed_requests += 1
            if r.get("error") == "timeout":
                result.timed_out_requests += 1

    t = result.wall_clock_seconds
    if t > 0:
        result.requests_per_second = result.successful_requests / t
        result.completion_tokens_per_second = result.total_completion_tokens / t
        result.prompt_tokens_per_second = result.total_prompt_tokens / t
        result.total_tokens_per_second = (result.total_prompt_tokens + result.total_completion_tokens) / t
    result.success_rate = result.successful_requests / max(result.total_requests, 1) * 100

    if ttfts:
        result.ttft_p50_ms = float(np.percentile(ttfts, 50))
        result.ttft_p99_ms = float(np.percentile(ttfts, 99))
    if tbts:
        result.tbt_p50_ms = float(np.percentile(tbts, 50))
    if totals:
        result.total_latency_p50_ms = float(np.percentile(totals, 50))

    return result


def print_table(results: List[ThroughputResult], label: str):
    """Print a formatted throughput table."""
    print(f"\n{'=' * 95}")
    print(f"  THROUGHPUT BENCHMARK: {label}")
    print(f"{'=' * 95}")
    print(f"{'Conc':>6} | {'Reqs':>6} | {'OK':>6} | {'Fail':>5} | {'Tok/s':>10} | "
          f"{'Req/s':>8} | {'TTFT p50':>10} | {'TBT p50':>9} | {'Success':>8}")
    print(f"{'-' * 95}")

    peak_throughput = 0.0
    peak_conc = 0
    for r in results:
        if r.completion_tokens_per_second > peak_throughput:
            peak_throughput = r.completion_tokens_per_second
            peak_conc = r.concurrency

        fail_str = str(r.failed_requests)
        if r.timed_out_requests > 0:
            fail_str = f"{r.failed_requests} ({r.timed_out_requests}T)"

        print(f"{r.concurrency:>6} | {r.total_requests:>6} | {r.successful_requests:>6} | "
              f"{fail_str:>5} | {r.completion_tokens_per_second:>10.1f} | "
              f"{r.requests_per_second:>8.1f} | {r.ttft_p50_ms:>8.0f}ms | "
              f"{r.tbt_p50_ms:>7.1f}ms | {r.success_rate:>6.1f}%")

    print(f"{'-' * 95}")
    print(f"  Peak throughput: {peak_throughput:,.0f} tok/s at concurrency {peak_conc}")
    print(f"{'=' * 95}\n")


def save_results(results: List[ThroughputResult], path: str, label: str):
    """Save results to JSON."""
    data = {
        "label": label,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "results": [],
    }
    for r in results:
        data["results"].append({
            "concurrency": r.concurrency,
            "total_requests": r.total_requests,
            "successful_requests": r.successful_requests,
            "failed_requests": r.failed_requests,
            "timed_out_requests": r.timed_out_requests,
            "wall_clock_seconds": r.wall_clock_seconds,
            "completion_tokens_per_second": r.completion_tokens_per_second,
            "total_tokens_per_second": r.total_tokens_per_second,
            "requests_per_second": r.requests_per_second,
            "success_rate": r.success_rate,
            "ttft_p50_ms": r.ttft_p50_ms,
            "ttft_p99_ms": r.ttft_p99_ms,
            "tbt_p50_ms": r.tbt_p50_ms,
            "total_latency_p50_ms": r.total_latency_p50_ms,
            "total_completion_tokens": r.total_completion_tokens,
            "total_prompt_tokens": r.total_prompt_tokens,
        })
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"Results saved to {path}")


async def main():
    parser = argparse.ArgumentParser(description="Throughput Benchmark")
    parser.add_argument("--server-url", type=str, required=True,
                        help="URL of running server (e.g. http://localhost:30000)")
    parser.add_argument("--concurrency", type=str,
                        default="1,4,16,32,64,128,256,512,1024,2048",
                        help="Comma-separated concurrency levels")
    parser.add_argument("--requests-per-level", type=int, default=0,
                        help="Requests per level (0 = auto: max(concurrency*2, 64))")
    parser.add_argument("--max-tokens", type=int, default=256,
                        help="Max output tokens per request")
    parser.add_argument("--timeout", type=int, default=180,
                        help="Per-request timeout in seconds")
    parser.add_argument("--label", type=str, default="server",
                        help="Label for this run")
    parser.add_argument("--output", type=str, default="",
                        help="Output JSON path (default: results/<label>_throughput.json)")
    parser.add_argument("--warmup", type=int, default=4,
                        help="Number of warmup requests before benchmarking")

    args = parser.parse_args()
    concurrency_levels = [int(x) for x in args.concurrency.split(",")]

    # Check server health
    print(f"Checking server at {args.server_url} ...")
    try:
        async with aiohttp.ClientSession() as s:
            async with s.get(f"{args.server_url}/health",
                             timeout=aiohttp.ClientTimeout(total=10)) as r:
                if r.status != 200:
                    print(f"ERROR: Server returned {r.status}")
                    return
    except Exception as e:
        print(f"ERROR: Cannot reach server: {e}")
        return
    print("Server is healthy.\n")

    # Warmup
    if args.warmup > 0:
        print(f"Warming up with {args.warmup} requests...")
        connector = aiohttp.TCPConnector(limit=10)
        async with aiohttp.ClientSession(connector=connector) as session:
            tasks = [
                send_request(session, args.server_url, PROMPTS[i % len(PROMPTS)],
                             args.max_tokens, args.timeout)
                for i in range(args.warmup)
            ]
            warmup_results = await asyncio.gather(*tasks)
            ok = sum(1 for r in warmup_results if r["success"])
            print(f"Warmup done: {ok}/{args.warmup} succeeded\n")

    # Run benchmark
    results = []
    for conc in concurrency_levels:
        if args.requests_per_level > 0:
            num_req = args.requests_per_level
        else:
            num_req = max(conc * 2, 64)

        print(f"[Concurrency {conc:>5}] Sending {num_req} requests (max_tokens={args.max_tokens}) ...")
        r = await run_level(args.server_url, conc, num_req, args.max_tokens, args.timeout)
        results.append(r)

        print(f"  -> {r.completion_tokens_per_second:,.0f} tok/s | "
              f"{r.successful_requests}/{r.total_requests} OK | "
              f"TTFT p50={r.ttft_p50_ms:.0f}ms | TBT p50={r.tbt_p50_ms:.1f}ms")

        await asyncio.sleep(3)  # cooldown between levels

    # Output
    print_table(results, args.label)

    output_path = args.output or os.path.join("results", f"{args.label}_throughput.json")
    save_results(results, output_path, args.label)


if __name__ == "__main__":
    asyncio.run(main())
