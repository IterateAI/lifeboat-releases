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

### AMD Instinct MI210 (ROCm), Qwen2.5-0.5B Q4_K_M

| System | Single-stream | Peak | at | TTFT p50 |
|---|---|---|---|---|
| **Lifeboat 2.2.56** | 379.7 tok/s | **1483.0 tok/s** | c=32 | 10 ms |
| llama.cpp | 370.2 tok/s | 857.9 tok/s | c=4 | 8 ms |
| ollama 0.34.4 | 368.7 tok/s | 368.9 tok/s | c=32 | 8 ms |

**1.73x llama.cpp and 4.02x ollama** on aggregate throughput, all three on the
same ROCm engine and the same model file. Single-stream the three are within
3%, which is again the correct result for one shared kernel — the entire
difference is how many requests each will run at once. ollama does not rise
with concurrency at all on its defaults.

This row exists because of a gap this comparison found: until 2.2.56 the pip
package had **no GPU path at all** on Instinct cards. The portable engine
reaches GPUs through Vulkan, whose open driver targets graphics parts, and a
CDNA compute card has no graphics engine — so it was never enumerated and
everything ran on the CPU. Lifeboat now ships a ROCm engine and selects it
automatically.

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

## Profile: `default` — the tensor engine, against vLLM

Every table above is the **GGUF engine**: Lifeboat, llama.cpp and ollama all
running the same kernel, where the only thing being compared is the serving
layer. vLLM is a different question. It is not an engine Lifeboat embeds — it
is an alternative to Lifeboat's *tensor* engine, so this is the one comparison
here where a difference is a real engine difference rather than a defaults
difference.

### AMD Instinct MI210 (ROCm 7.2), Qwen2.5-0.5B-Instruct bf16

Both servers measured back to back in a single harness run, on the same card,
same weights, same client, 256-token generations, zero failed requests on
either side.

| System | Single-stream | Peak | at | TTFT p50 |
|---|---|---|---|---|
| **Lifeboat tensor engine 2.2.56** | 544.8 tok/s | **9985.2 tok/s** | c=32 | 20 ms |
| vLLM (`rocm/vllm:latest`) | **584.7 tok/s** | 7513.4 tok/s | c=32 | **10 ms** |

Level by level, because the single number hides a crossover:

| Concurrency | Lifeboat | vLLM | |
|---|---|---|---|
| 1 | 544.8 | **584.7** | vLLM 1.07x |
| 4 | **1593.6** | 1555.7 | Lifeboat 1.02x |
| 16 | **5763.4** | 4079.9 | **Lifeboat 1.41x** |
| 32 | **9985.2** | 7513.4 | **Lifeboat 1.33x** |

**vLLM is ahead on a single request and on time-to-first-token; Lifeboat is
ahead on throughput from concurrency 4 upward.** Both are true and neither is
a rounding error. The shape is visible in per-token latency: vLLM starts lower
and degrades under load (1.68 ms to 4.06 ms across the sweep) while Lifeboat
starts higher and stays flatter (1.77 ms to 2.96 ms). If you are serving one
interactive stream, vLLM's lower TTFT is the number that matters. If you are
serving a fleet, the concurrency columns are.

### This needed a flag that is NOT on by default, and that matters

The row above was measured with **`--enable-torch-compile`**. Without it, on
the identical box and model:

| Lifeboat tensor engine | Single-stream | Peak |
|---|---|---|
| default configuration | 141.4 tok/s | 4626.9 tok/s |
| with `--enable-torch-compile` | **544.8 tok/s** | **9985.2 tok/s** |

**3.9x single-stream and 2.2x peak, from one flag.** The engine's own log
agrees with the harness (`gen throughput: 142.81 tok/s` before, ~565 after),
so this is not a measurement artefact.

It is not on by default because it is not free: decode graph capture goes from
7.5 s to 116.9 s, so the server takes about two extra minutes to become ready.
For a process that then runs for days that is a good trade, and we expect to
make it automatic for small models. It is stated here rather than quietly
folded into the headline because **a Lifeboat tensor server you start today,
with no flags, measures 141 tok/s single-stream against vLLM's 584** — and
publishing only the tuned number would misrepresent what you get out of the
box.

## Where Lifeboat is NOT ahead

Publishing only the wins would make everything above worth less, so:

- **vLLM beats our tensor engine on single-stream and TTFT** (above): 7% on
  throughput for one request, and roughly half the time-to-first-token at every
  concurrency level. We are ahead from concurrency 4 up, by as much as 1.41x.
- **Our tensor engine's default configuration is far behind vLLM**, until
  `--enable-torch-compile` is set — 141 against 584 tok/s single-stream. That
  is a default we intend to fix, not a hardware limit, and it is published here
  in the state you would actually meet it.
- **Lifeboat's default routing mode rejects concurrent requests above 4 per
  server.** `superfast` is the shipped default: it caps each backend at 4
  in-flight requests to minimise time-to-first-token, and the waiter queue is
  off by default, so request 5 gets a 503 rather than waiting. Measured through
  the load balancer at concurrency 32, exactly 4 requests succeeded per level
  and 40 of 53 were rejected. That is deliberate behaviour for interactive
  chat and the wrong default for a throughput benchmark or a busy fleet; set
  `routing_mode` to `max_concurrency` or `queue_all` on the Configuration page
  for those. The tensor-engine figures above are measured against the engine
  directly, so they are unaffected.
- **On a Mac, Lifeboat and llama.cpp are level** (above). Both are at the
  hardware's bandwidth ceiling; there is nothing left to win.
- **On a Jetson, llama.cpp's peak is 8% above ours** on defaults, because we
  give each request 8x the context window. At matched settings the two are
  within 0.3%. We think the bigger default window is the right call for real
  prompts, but it is a trade and it is measurable.
- **The EPYC row is a CPU comparison** on the same host as the MI210 row, taken
  before 2.2.56 gave Instinct cards a GPU path. Both are kept: they are the
  same machine measured on its processor and on its accelerator, which is a
  genuinely useful pair rather than a stale number and a fresh one.

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

**sglang.** An adapter exists in `compare.py` and has not been run against a
published sglang build. It is listed as unproven rather than estimated.

**vLLM beyond one card and one small model.** The row above is a single MI210
and a 0.5B model. A 0.5B is the case most favourable to per-token overhead —
which is exactly why `--enable-torch-compile` is worth 3.9x there — so do not
read the ratio as holding at 30B. Larger models and NVIDIA hardware are the
obvious next runs.
