# Lifeboat vs other inference servers

Our other published figures compare Lifeboat to **itself** — optimizations on
versus off. That is the right way to catch a regression and the wrong way to
answer *"how does it compare to what I'm already running"*. This directory is
that comparison: same machine, same model bytes, same workload, one client that
cannot favour either side.

Everything here is meant to be **re-run rather than believed**. The harness is
`compare.py`, the raw results are in `results/`, and every report prints the
exact launch command given to every system so you can argue with it.

## What is being compared, and what that means

Lifeboat is a serving **platform that embeds engines**, not a kernel that
replaces them. It ships llama.cpp as its GGUF engine — so "Lifeboat is faster
than llama.cpp" would be a category error, and we do not claim it. What a
difference between these rows actually means:

| Row | Relationship | A difference means |
|---|---|---|
| **llama.cpp** | the same engine Lifeboat embeds, run directly | the **serving layer** — slot sizing, context split, thread sizing. Never the kernel. |
| **ollama** | wraps the same engine | the serving layer, plus each project's defaults |

Both are run against the **identical model file** (sha256 recorded in each
`result.json`). `ollama pull` is deliberately not used: it fetches ollama's own
build of a similarly-named model, usually at a different quantization, and a
4-bit-versus-5-bit difference alone would show up as an engine difference.

## Profile: `default` — every system exactly as it ships

These are out-of-the-box numbers. Nothing is tuned, on any side. That is the
comparison that matches what you get on day one, and it is the only one where
"Lifeboat's defaults are better" is a meaningful claim rather than a statement
about who spent longer reading flags.

### 64-core server CPU (AMD EPYC 9555P), Qwen2.5-0.5B Q4_K_M

| System | Single-stream | Peak | at | TTFT p50 |
|---|---|---|---|---|
| **Lifeboat 2.2.55** | 198.2 tok/s | **1330.0 tok/s** | c=32 | 11 ms |
| llama.cpp | 193.1 tok/s | 685.7 tok/s | c=32 | 13 ms |

**1.94x the aggregate throughput of the engine it embeds**, on the same
hardware and the same model bytes, with neither side tuned. The whole
difference is one decision: Lifeboat sizes its concurrent slots from the host
(16 here), while a bare engine takes a fixed default because it has no way to
reason about the machine it was launched on. That is the difference between a
serving platform and a launcher, and it is worth 2x on a large box.

### NVIDIA Jetson Orin Nano (8 GB, JetPack 6), Qwen2.5-0.5B Q4_K_M

| System | Single-stream | Peak | at | TTFT p50 |
|---|---|---|---|---|
| **Lifeboat 2.2.55** | 88.2 tok/s | 180.2 tok/s | c=4 | **38 ms** |
| llama.cpp | 88.1 tok/s | **195.3 tok/s** | c=4 | 40 ms |
| ollama 0.34.4 | 89.5 tok/s | 89.5 tok/s | c=1 | 44 ms |

Against ollama: **2.01x the peak throughput** and the best time-to-first-token
on the board, with single-stream level across all three.

Against llama.cpp we are **8% behind on peak here, and the reason is a
deliberate default rather than overhead**: Lifeboat gives each request an
8192-token context window, while llama.cpp's default is 4096 *total* across
four slots — 1024 tokens per request, which is too small for real prompts. On
a memory-tight board that window costs throughput. Given the same slots and
the same context, the two are identical:

| Matched: 4 slots, 2048-token window | Single-stream | Peak |
|---|---|---|
| Lifeboat | 88.3 tok/s | 180.0 tok/s |
| llama.cpp | 88.6 tok/s | 180.6 tok/s |

0.3% apart — which is the correct answer for one shared kernel, and is the
cleanest evidence in this directory that the harness is not tilted.

**This board needed a fix to get here, and it is worth stating what it was.**
Lifeboat's general Linux engine uses Vulkan, which works everywhere; ollama
ships a CUDA build for JetPack. Measured before the fix, ollama was **2.1x
ahead of us** on single-stream (89.1 vs 42.5 tok/s) — a backend difference, not
a serving one. Lifeboat now publishes a CUDA build of its engine for Tegra
boards and `lifeboat engine install` selects it automatically, which is what
the numbers above are taken on. Nothing to configure.

### Apple M4 Max (Metal), Qwen3-4B-Instruct Q4_K_XL

| System | Single-stream | Peak | at | TTFT p50 |
|---|---|---|---|---|
| **Lifeboat 2.2.55** | 125.7 tok/s | **166.3 tok/s** | c=16 | **13 ms** |
| llama.cpp | 127.1 tok/s | 164.5 tok/s | c=4 | 14 ms |
| ollama 0.33.3 | 112.3 tok/s | 112.3 tok/s | c=1 | 18 ms |

Against ollama: **1.48x the peak throughput**, 12% faster single-stream and 28%
lower time-to-first-token. Against llama.cpp the two are **level** — within
~1%, which is the correct result and worth stating plainly: it is the same
kernel, and on this model both saturate the Mac's memory bandwidth at about
165 tok/s. No serving layer can exceed that ceiling, and a large gap here
would have meant the harness was broken rather than that an engine was fast.

The ollama row is the one that shows the shape difference: it does not rise at
all with concurrency, because its default parallelism serializes requests.

## Where Lifeboat is NOT ahead

Publishing only the wins would make everything above worth less, so:

- **On a Mac, Lifeboat and llama.cpp are level** (above). Both are at the
  hardware's bandwidth ceiling; there is nothing left to win.
- **On a Jetson, llama.cpp's peak is 8% above ours** on defaults, because we
  give each request 8x the context window. At matched settings the two are
  within 0.3%. We think the bigger default window is the right call for real
  prompts, but it is a trade and it is measurable.
- **The EPYC row above is a CPU comparison**, and was taken when the pip
  package had no GPU path on AMD data-center cards at all. That gap is now
  closed — as of 2.2.56 an Instinct card gets a ROCm engine automatically — but
  the numbers above predate it and are left as measured rather than restated.

  The cause is worth knowing if you run Instinct hardware: the portable engine
  reaches GPUs through Vulkan, whose open driver targets *graphics* parts, and
  a CDNA compute card has no graphics engine, so it was never enumerated at
  all. Measured on that MI210, the ROCm engine is **1.89x** faster on a single
  request (375.4 against 198.2 tok/s). But at high concurrency the 64-core CPU
  was still **higher** in aggregate (1330 against 883 tok/s) for a 0.5B model —
  a small model parallelises extremely well across many cores, and the GPU's
  advantage there is latency. Its margin grows with model size.
- **Single-stream decode is bounded by memory bandwidth**, not by any software
  here. Where two rows are close on a single request, that is physics, and no
  amount of serving-layer work changes it. The place a serving layer earns its
  keep is concurrency, which is why every table reports both.

## Reproducing this

```sh
pip install 'lifeboat[hub]'
lifeboat engine install
python3 compare.py --model /path/to/model.gguf \
    --systems lifeboat,llamacpp,ollama --profile default \
    --concurrency 1,4,16,32 --max-tokens 256
```

The harness needs `httpx`. It writes `result.json` (every level, every
percentile, the model's sha256, each system's version and launch command) and
a `report.md`. `--profile matched` gives every system the same slot count and
context window instead, which isolates the engine from its defaults.

Guard rails that are enforced rather than described, because a comparison
nobody can trust is worth nothing:

- A system that **could not be configured on the run's terms is dropped from
  the ranking** and reported separately with the reason. On macOS the Ollama
  desktop app supervises its own daemon, so under `--profile matched` it keeps
  its defaults while everything else is matched — ranking that would show a
  config difference as an engine difference.
- A sweep that produces **no tokens is a failure, not a zero**. Building this
  found that ollama carries generated tokens on a `reasoning` field with
  `content` empty; a client that did not know that spelling scored a server
  generating 38 tokens as 0 tok/s with no errors — which reads as the other
  system being immeasurably slow. Fixed, and guarded so the next unknown
  spelling surfaces loudly instead of silently.
- Measurement is **imported from the control plane's own benchmark module**,
  not reimplemented, so these figures use the same definitions Lifeboat reports
  in its own console. TTFT is to the first token; throughput excludes a warm-up
  request; thinking is disabled so two models are comparable.

## Not measured yet

**vLLM and sglang.** Adapters exist in `compare.py` and have not been run —
both need a Linux host with a working GPU and enough disk, and we do not have
one free. They are listed as unproven rather than estimated.
