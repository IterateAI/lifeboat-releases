# Lifeboat benchmarks

> Comparing Lifeboat against **other inference servers** on the same
> hardware — llama.cpp and ollama, on a Mac, a 64-core server and a
> Jetson — is in [`comparison/`](comparison/).

The harness behind the concurrency and throughput figures we publish, plus the
raw result files those figures were read out of. Everything here is meant to be
checked rather than taken on trust, so this README is explicit about what the
data shows and what it does not.

## The published numbers, and where they come from

| Metric | Baseline | Lifeboat + FP8 KV | |
|---|---|---|---|
| Max concurrency at 100% success | 1,024 | 2,048 | 2.0x |
| Throughput @ 1,024 concurrent | 6,304 tok/s | 9,611 tok/s | 1.52x |
| Throughput @ 2,048 concurrent | 4,965 tok/s | 8,714 tok/s | 1.76x |
| Success rate @ 2,048 concurrent | 1282/2048 (62%) | 2048/2048 (100%) | baseline fails |

Every one of those cells is in `results/`, at the `concurrency: 1024` and
`concurrency: 2048` rows of `sglang_bf16_benchmark.json` and
`lifeboat_fp8_benchmark.json`. Nothing is rounded or re-derived:

```sh
python3 -c "
import json
for f in ['results/sglang_bf16_benchmark.json','results/lifeboat_fp8_benchmark.json']:
    for r in json.load(open(f))['server']:
        if r['concurrency'] in (1024, 2048):
            print(f, r['concurrency'], round(r['completion_tokens_per_second']),
                  f\"{r['successful_requests']}/{r['num_requests']}\")"
```

Hardware: one NVIDIA RTX PRO 6000 Blackwell (96 GB), Intel i9-14900K, 128 GB
RAM. Model: Qwen3-30B-A3B (MoE, 128 experts, ~57 GB of BF16 weights, 4 KV
heads). **Model weights are BF16 in both runs** — the Lifeboat run quantizes
KV cache *values* to FP8 E4M3 and does not touch the weights, so this is not a
quantized model being compared against an unquantized one.

## What these runs do not record, and why you should care

The result files carry per-level measurements only. They do **not** embed the
launch flags, so the configuration below is documented rather than captured,
and we would rather say that than imply a byte-exact replay:

- The runs are dated **2026-03-13**, against the engine generation Lifeboat
  shipped at the time. Current releases are several engine versions on. A fresh
  A/B on today's build is the right way to check the claim, and is more useful
  than reproducing a six-month-old number.
- The baseline was a **separate upstream engine install**, not the Lifeboat
  build with its flags switched off. Materially that is a cleaner comparison,
  but it is a different claim from "same binary, flags off" and some of our
  older copy states it the other way round. Treat this README as correct.
- `--disable-radix-cache` was set on **both** sides so prefix-cache hits could
  not favour one run over the other.
- The exact `--mem-fraction-static` used in March is not recorded. The harness
  in this directory defaults to `0.88`. The size of the KV pool relative to the
  weights is the single biggest lever on the result: give the card enough
  headroom and both configurations converge, because there is no memory
  pressure for the KV work to relieve. The gap above is from the regime where
  the model only just fits, which is the regime these optimizations exist for.

If you run this on a small model with plenty of VRAM and see no difference,
that is the expected result, not a contradiction.

## Running it

Both scripts need `aiohttp` and `numpy`; `lifeboat_benchmark.py` also needs
`httpx` if you let it launch servers.

Against a server you already have running, which is the reliable path:

```sh
python3 lifeboat_benchmark.py \
    --server-url http://127.0.0.1:30000 \
    --concurrency 1,4,16,32,64,128,256,512,1024,2048 \
    --output results/mine.json
```

Run it once per configuration and compare the two files. Requests per level
default to the concurrency level; `--max-tokens` defaults to 256.

`throughput_benchmark.py` is a sustained-throughput sweep against one running
server, reporting tok/s, TTFT p50/p99, time-between-tokens and success rate per
level:

```sh
python3 throughput_benchmark.py \
    --server-url http://127.0.0.1:30000 \
    --concurrency 1,4,16,32,64,128,256,512,1024,2048 \
    --label mine
```

`lifeboat_benchmark.py` can also launch both servers itself with `--model-path`
plus `--lifeboat-venv` / `--sglang-venv`. That path is specific to a
source checkout with two virtualenvs; against released builds, start the
servers yourself and use `--server-url`.

The optimizations under test are engine flags — `--lifeboat-enabled`,
`--lifeboat-admission-control`, `--lifeboat-fair-scheduling`,
`--lifeboat-kv-compress adaptive`, `--lifeboat-kv-eviction adaptive`,
`--lifeboat-kv-cache-fp8`, `--lifeboat-moe-dynamic-quant` — and they apply to
the tensor engine only. Lifeboat's GGUF engine does not have them, so an A/B
there compares a flag against itself.

## Measurement caveats in the harness itself

- Completion tokens are counted as one per streamed content delta. A model that
  emits reasoning into a separate field will be undercounted; both sides of an
  A/B use the same counter, so the ratio holds even where the absolute number
  is low.
- Prompt tokens are estimated from whitespace, so `total_tokens_per_second` is
  approximate. `completion_tokens_per_second` — the headline metric — is
  counted from actual deltas.
- A request that returns non-200 or times out counts as a failure, which is
  what makes the success-rate column meaningful at high concurrency.

Questions, or a result that disagrees with ours: please open an issue with the
JSON your run produced.
