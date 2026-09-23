#!/usr/bin/env python3
"""Lifeboat vs SGLang Benchmark Suite.

Measures concurrent session capacity, throughput, TTFT, and TBT
at various concurrency levels.

Usage:
    # Run full benchmark (both Lifeboat and SGLang)
    python benchmark/lifeboat_benchmark.py --model-path /path/to/model

    # Run only against a running server
    python benchmark/lifeboat_benchmark.py --server-url http://localhost:30000 --concurrency 1,4,16,64,128,256

    # Quick test
    python benchmark/lifeboat_benchmark.py --model-path /path/to/model --quick
"""

import argparse
import asyncio
import json
import os
import signal
import subprocess
import sys
import time
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import aiohttp
import numpy as np


@dataclass
class RequestResult:
    """Result of a single request."""
    request_id: int
    concurrency_level: int
    prompt_tokens: int = 0
    completion_tokens: int = 0
    ttft_ms: float = 0.0       # time to first token
    tbt_ms: float = 0.0        # average time between tokens
    total_time_ms: float = 0.0
    success: bool = True
    error: str = ""


@dataclass
class BenchmarkResult:
    """Aggregated results for one concurrency level."""
    concurrency: int
    num_requests: int
    successful_requests: int = 0
    failed_requests: int = 0

    # Throughput
    total_prompt_tokens: int = 0
    total_completion_tokens: int = 0
    total_time_seconds: float = 0.0
    requests_per_second: float = 0.0
    prompt_tokens_per_second: float = 0.0
    completion_tokens_per_second: float = 0.0

    # Latency
    ttft_p50_ms: float = 0.0
    ttft_p90_ms: float = 0.0
    ttft_p99_ms: float = 0.0
    ttft_mean_ms: float = 0.0

    tbt_p50_ms: float = 0.0
    tbt_p90_ms: float = 0.0
    tbt_p99_ms: float = 0.0
    tbt_mean_ms: float = 0.0

    total_latency_p50_ms: float = 0.0
    total_latency_p90_ms: float = 0.0
    total_latency_mean_ms: float = 0.0


# Sample prompts of varying lengths for realistic benchmarking
BENCHMARK_PROMPTS = [
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


async def send_request(
    session: aiohttp.ClientSession,
    url: str,
    prompt: str,
    request_id: int,
    concurrency: int,
    max_tokens: int = 256,
) -> RequestResult:
    """Send a single request and measure timing."""
    result = RequestResult(
        request_id=request_id,
        concurrency_level=concurrency,
    )

    payload = {
        "model": "default",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.7,
        "stream": True,
    }

    start_time = time.monotonic()
    first_token_time = None
    token_times = []
    completion_tokens = 0

    try:
        async with session.post(
            f"{url}/v1/chat/completions",
            json=payload,
            timeout=aiohttp.ClientTimeout(total=120),
        ) as response:
            if response.status != 200:
                result.success = False
                result.error = f"HTTP {response.status}"
                return result

            async for line in response.content:
                line = line.decode("utf-8").strip()
                if not line or not line.startswith("data: "):
                    continue

                data_str = line[6:]  # strip "data: "
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
        result.success = False
        result.error = "timeout"
        return result
    except Exception as e:
        result.success = False
        result.error = str(e)
        return result

    end_time = time.monotonic()

    # Calculate metrics
    result.total_time_ms = (end_time - start_time) * 1000
    result.prompt_tokens = len(prompt.split()) * 2  # rough estimate
    result.completion_tokens = completion_tokens

    if first_token_time is not None:
        result.ttft_ms = (first_token_time - start_time) * 1000

    if len(token_times) > 1:
        inter_token_delays = [
            (token_times[i] - token_times[i-1]) * 1000
            for i in range(1, len(token_times))
        ]
        result.tbt_ms = np.mean(inter_token_delays) if inter_token_delays else 0.0

    return result


async def run_concurrency_level(
    url: str,
    concurrency: int,
    num_requests: int,
    max_tokens: int = 256,
) -> BenchmarkResult:
    """Run benchmark at a specific concurrency level."""
    print(f"\n  Concurrency {concurrency}: sending {num_requests} requests...")

    connector = aiohttp.TCPConnector(limit=concurrency + 10)
    async with aiohttp.ClientSession(connector=connector) as session:
        # Create tasks
        tasks = []
        for i in range(num_requests):
            prompt = BENCHMARK_PROMPTS[i % len(BENCHMARK_PROMPTS)]
            tasks.append(
                send_request(session, url, prompt, i, concurrency, max_tokens)
            )

        # Run with concurrency limit using semaphore
        semaphore = asyncio.Semaphore(concurrency)

        async def bounded_request(task):
            async with semaphore:
                return await task

        start_time = time.monotonic()
        results = await asyncio.gather(*[bounded_request(t) for t in tasks])
        total_time = time.monotonic() - start_time

    # Aggregate results
    bench = BenchmarkResult(
        concurrency=concurrency,
        num_requests=num_requests,
        total_time_seconds=total_time,
    )

    successful = [r for r in results if r.success]
    failed = [r for r in results if not r.success]

    bench.successful_requests = len(successful)
    bench.failed_requests = len(failed)

    if not successful:
        print(f"    ALL FAILED! Errors: {set(r.error for r in failed)}")
        return bench

    bench.total_prompt_tokens = sum(r.prompt_tokens for r in successful)
    bench.total_completion_tokens = sum(r.completion_tokens for r in successful)

    # Throughput
    bench.requests_per_second = len(successful) / total_time
    bench.prompt_tokens_per_second = bench.total_prompt_tokens / total_time
    bench.completion_tokens_per_second = bench.total_completion_tokens / total_time

    # TTFT latency
    ttfts = [r.ttft_ms for r in successful if r.ttft_ms > 0]
    if ttfts:
        bench.ttft_mean_ms = np.mean(ttfts)
        bench.ttft_p50_ms = np.percentile(ttfts, 50)
        bench.ttft_p90_ms = np.percentile(ttfts, 90)
        bench.ttft_p99_ms = np.percentile(ttfts, 99)

    # TBT latency
    tbts = [r.tbt_ms for r in successful if r.tbt_ms > 0]
    if tbts:
        bench.tbt_mean_ms = np.mean(tbts)
        bench.tbt_p50_ms = np.percentile(tbts, 50)
        bench.tbt_p90_ms = np.percentile(tbts, 90)
        bench.tbt_p99_ms = np.percentile(tbts, 99)

    # Total latency
    totals = [r.total_time_ms for r in successful]
    if totals:
        bench.total_latency_mean_ms = np.mean(totals)
        bench.total_latency_p50_ms = np.percentile(totals, 50)
        bench.total_latency_p90_ms = np.percentile(totals, 90)

    print(f"    OK: {bench.successful_requests}/{num_requests} succeeded, "
          f"{bench.completion_tokens_per_second:.1f} tok/s, "
          f"TTFT p50={bench.ttft_p50_ms:.0f}ms, "
          f"TBT p50={bench.tbt_p50_ms:.1f}ms")

    return bench


def start_server(
    venv_path: str,
    model_path: str,
    port: int,
    extra_args: List[str] = None,
    label: str = "server",
) -> subprocess.Popen:
    """Start an SGLang/Lifeboat server."""
    cmd = [
        f"{venv_path}/bin/python", "-m", "sglang.launch_server",
        "--model-path", model_path,
        "--port", str(port),
        "--mem-fraction-static", "0.88",
        "--disable-radix-cache",  # for fair comparison
    ]
    if extra_args:
        cmd.extend(extra_args)

    print(f"\nStarting {label} server: {' '.join(cmd)}")

    log_path = os.path.join(os.environ.get("BENCH_OUTPUT_DIR", "results"), f"{label}_server.log")
    log_file = open(log_path, "w")

    proc = subprocess.Popen(
        cmd,
        stdout=log_file,
        stderr=subprocess.STDOUT,
        preexec_fn=os.setsid,
    )

    return proc


async def wait_for_server(url: str, timeout: int = 300) -> bool:
    """Wait for server to be ready."""
    start = time.monotonic()
    while time.monotonic() - start < timeout:
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(f"{url}/health", timeout=aiohttp.ClientTimeout(total=5)) as resp:
                    if resp.status == 200:
                        return True
        except Exception:
            pass
        await asyncio.sleep(2)
    return False


def kill_server(proc: subprocess.Popen):
    """Kill server process and all children."""
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        proc.wait(timeout=10)
    except Exception:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            pass


def print_comparison(lifeboat_results: List[BenchmarkResult],
                     sglang_results: List[BenchmarkResult]):
    """Print side-by-side comparison table."""
    print("\n" + "=" * 100)
    print("BENCHMARK COMPARISON: Lifeboat vs SGLang")
    print("=" * 100)

    # Header
    print(f"\n{'Concurrency':>12} | {'Metric':>20} | {'Lifeboat':>12} | {'SGLang':>12} | {'Speedup':>10}")
    print("-" * 75)

    lb_map = {r.concurrency: r for r in lifeboat_results}
    sg_map = {r.concurrency: r for r in sglang_results}

    for conc in sorted(set(list(lb_map.keys()) + list(sg_map.keys()))):
        lb = lb_map.get(conc)
        sg = sg_map.get(conc)

        if lb and sg:
            metrics = [
                ("Throughput tok/s", lb.completion_tokens_per_second, sg.completion_tokens_per_second),
                ("Requests/s", lb.requests_per_second, sg.requests_per_second),
                ("TTFT p50 ms", lb.ttft_p50_ms, sg.ttft_p50_ms),
                ("TTFT p90 ms", lb.ttft_p90_ms, sg.ttft_p90_ms),
                ("TBT p50 ms", lb.tbt_p50_ms, sg.tbt_p50_ms),
                ("Success rate %", lb.successful_requests/max(1,lb.num_requests)*100,
                 sg.successful_requests/max(1,sg.num_requests)*100),
            ]

            for i, (name, lb_val, sg_val) in enumerate(metrics):
                conc_str = str(conc) if i == 0 else ""

                if "ms" in name.lower() or "latency" in name.lower():
                    # Lower is better for latency
                    speedup = sg_val / max(lb_val, 0.001)
                    speedup_str = f"{speedup:.2f}x"
                else:
                    # Higher is better for throughput
                    speedup = lb_val / max(sg_val, 0.001)
                    speedup_str = f"{speedup:.2f}x"

                print(f"{conc_str:>12} | {name:>20} | {lb_val:>12.1f} | {sg_val:>12.1f} | {speedup_str:>10}")

            print("-" * 75)

    # Summary
    print("\nSUMMARY:")
    if lifeboat_results and sglang_results:
        # Find max concurrency where both succeed
        for conc in sorted(set(lb_map.keys()) & set(sg_map.keys()), reverse=True):
            lb = lb_map[conc]
            sg = sg_map[conc]
            if lb.successful_requests > 0 and sg.successful_requests > 0:
                throughput_ratio = lb.completion_tokens_per_second / max(sg.completion_tokens_per_second, 0.001)
                print(f"  At concurrency {conc}: Lifeboat is {throughput_ratio:.2f}x throughput vs SGLang")
                ttft_ratio = lb.ttft_p50_ms / max(sg.ttft_p50_ms, 0.001)
                print(f"  TTFT impact: {ttft_ratio:.2f}x (target: <1.15x)")
                break


async def run_benchmark_suite(
    url: str,
    concurrency_levels: List[int],
    requests_per_level: int,
    max_tokens: int,
    label: str = "server",
) -> List[BenchmarkResult]:
    """Run the full benchmark suite against a server."""
    print(f"\n{'='*60}")
    print(f"BENCHMARKING: {label}")
    print(f"URL: {url}")
    print(f"Concurrency levels: {concurrency_levels}")
    print(f"Requests per level: {requests_per_level}")
    print(f"{'='*60}")

    results = []
    for conc in concurrency_levels:
        num_requests = max(conc, requests_per_level)
        result = await run_concurrency_level(url, conc, num_requests, max_tokens)
        results.append(result)

        # Brief pause between levels
        await asyncio.sleep(2)

    return results


def save_results(results: Dict[str, List[BenchmarkResult]], output_path: str):
    """Save benchmark results to JSON."""
    data = {}
    for label, bench_results in results.items():
        data[label] = []
        for r in bench_results:
            data[label].append({
                "concurrency": r.concurrency,
                "num_requests": r.num_requests,
                "successful_requests": r.successful_requests,
                "failed_requests": r.failed_requests,
                "total_time_seconds": r.total_time_seconds,
                "completion_tokens_per_second": r.completion_tokens_per_second,
                "requests_per_second": r.requests_per_second,
                "ttft_p50_ms": r.ttft_p50_ms,
                "ttft_p90_ms": r.ttft_p90_ms,
                "ttft_p99_ms": r.ttft_p99_ms,
                "ttft_mean_ms": r.ttft_mean_ms,
                "tbt_p50_ms": r.tbt_p50_ms,
                "tbt_p90_ms": r.tbt_p90_ms,
                "tbt_mean_ms": r.tbt_mean_ms,
            })

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"\nResults saved to: {output_path}")


async def main():
    parser = argparse.ArgumentParser(description="Lifeboat vs SGLang Benchmark")
    parser.add_argument("--model-path", type=str, help="Path to model for server launch")
    parser.add_argument("--server-url", type=str, help="URL of already-running server")
    parser.add_argument("--concurrency", type=str, default="1,4,16,32,64,128",
                        help="Comma-separated concurrency levels")
    parser.add_argument("--requests-per-level", type=int, default=64,
                        help="Minimum requests per concurrency level")
    parser.add_argument("--max-tokens", type=int, default=256,
                        help="Max tokens per request")
    parser.add_argument("--quick", action="store_true",
                        help="Quick test with fewer requests")
    parser.add_argument("--lifeboat-only", action="store_true",
                        help="Only benchmark Lifeboat")
    parser.add_argument("--sglang-only", action="store_true",
                        help="Only benchmark vanilla SGLang")
    parser.add_argument("--output", type=str,
                        default=os.path.join("results", "benchmark_results.json"))
    parser.add_argument("--lifeboat-port", type=int, default=30000)
    parser.add_argument("--lifeboat-venv", type=str, default="",
                        help="venv containing the Lifeboat engine (for --model-path launches)")
    parser.add_argument("--sglang-venv", type=str, default="",
                        help="venv containing the baseline engine (for --model-path launches)")
    parser.add_argument("--sglang-port", type=int, default=30001)

    args = parser.parse_args()

    concurrency_levels = [int(x) for x in args.concurrency.split(",")]

    if args.quick:
        concurrency_levels = [1, 4, 16, 32]
        args.requests_per_level = 16
        args.max_tokens = 128

    all_results = {}
    servers_to_kill = []

    try:
        if args.server_url:
            # Benchmark against already-running server
            print(f"Benchmarking server at {args.server_url}")
            if not await wait_for_server(args.server_url, timeout=10):
                print(f"ERROR: Server not available at {args.server_url}")
                sys.exit(1)

            results = await run_benchmark_suite(
                args.server_url, concurrency_levels,
                args.requests_per_level, args.max_tokens, "server"
            )
            all_results["server"] = results

        else:
            if not args.model_path:
                print("ERROR: --model-path is required when not using --server-url")
                sys.exit(1)

            # Benchmark Lifeboat
            if not args.sglang_only:
                lifeboat_url = f"http://127.0.0.1:{args.lifeboat_port}"
                lifeboat_proc = start_server(
                    args.lifeboat_venv,
                    args.model_path,
                    args.lifeboat_port,
                    extra_args=[
                        "--lifeboat-enabled",
                        "--lifeboat-admission-control",
                        "--lifeboat-fair-scheduling",
                        "--lifeboat-kv-compress", "adaptive",
                        "--lifeboat-kv-eviction", "adaptive",
                        "--lifeboat-moe-dynamic-quant",
                    ],
                    label="lifeboat",
                )
                servers_to_kill.append(lifeboat_proc)

                print("Waiting for Lifeboat server to start...")
                if not await wait_for_server(lifeboat_url, timeout=300):
                    print("ERROR: Lifeboat server failed to start. Check results/lifeboat_server.log")
                    sys.exit(1)

                all_results["lifeboat"] = await run_benchmark_suite(
                    lifeboat_url, concurrency_levels,
                    args.requests_per_level, args.max_tokens, "Lifeboat"
                )

                # Kill Lifeboat server before starting SGLang
                print("\nStopping Lifeboat server...")
                kill_server(lifeboat_proc)
                servers_to_kill.remove(lifeboat_proc)
                await asyncio.sleep(5)  # Wait for GPU memory to be freed

            # Benchmark vanilla SGLang
            if not args.lifeboat_only:
                sglang_url = f"http://127.0.0.1:{args.sglang_port}"
                sglang_proc = start_server(
                    args.sglang_venv,
                    args.model_path,
                    args.sglang_port,
                    label="sglang",
                )
                servers_to_kill.append(sglang_proc)

                print("Waiting for SGLang server to start...")
                if not await wait_for_server(sglang_url, timeout=300):
                    print("ERROR: SGLang server failed to start. Check results/sglang_server.log")
                    sys.exit(1)

                all_results["sglang"] = await run_benchmark_suite(
                    sglang_url, concurrency_levels,
                    args.requests_per_level, args.max_tokens, "SGLang (vanilla)"
                )

        # Save results
        save_results(all_results, args.output)

        # Print comparison
        if "lifeboat" in all_results and "sglang" in all_results:
            print_comparison(all_results["lifeboat"], all_results["sglang"])
        elif len(all_results) == 1:
            label, results = list(all_results.items())[0]
            print(f"\n{'='*60}")
            print(f"RESULTS: {label}")
            print(f"{'='*60}")
            for r in results:
                print(f"  Concurrency {r.concurrency}: "
                      f"{r.completion_tokens_per_second:.1f} tok/s, "
                      f"TTFT p50={r.ttft_p50_ms:.0f}ms, "
                      f"TBT p50={r.tbt_p50_ms:.1f}ms, "
                      f"Success: {r.successful_requests}/{r.num_requests}")

    finally:
        for proc in servers_to_kill:
            kill_server(proc)


if __name__ == "__main__":
    asyncio.run(main())
