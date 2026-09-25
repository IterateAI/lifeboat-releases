# Inference server comparison

- **Host** Darwin arm64
- **Model** `/Users/Arul329/Library/Application Support/Lifeboat/models/Qwen3-4B Instruct (GGUF)/Qwen3-4B-Instruct-2507-UD-Q4_K_XL.gguf` (sha256 `4bbe1f2f8ebe69fa...`)
- **Profile** `default` - every system exactly as it ships
- **Workload** 256 tokens/request, temperature 0, thinking off, concurrency [1, 4, 16, 32]
- **Measured by** the control plane's own benchmark module, so these are the same definitions Lifeboat reports elsewhere

| System | Single-stream tok/s | Peak tok/s | at | TTFT p50 | Failed |
|---|---|---|---|---|---|
| **lifeboat** | 125.7 | 166.3 | c=16 | 13 ms | 0 |
| **llamacpp** | 127.1 | 164.5 | c=4 | 14 ms | 0 |
| **ollama** | 112.3 | 112.3 | c=1 | 18 ms | 0 |

## What each row means

- **lifeboat** (lifeboat 2.2.55) - the system under test
- **llamacpp** (0.00.000.084 I srv  llama_server: initializing ...) - the SAME GGUF engine Lifeboat embeds, run directly -- a difference is the serving layer, not the kernel
- **ollama** (ollama version is 0.33.3) - wraps the same llama.cpp engine Lifeboat embeds -- a difference is the serving layer, not the kernel
  - NOTE: reused an ollama daemon that was already running (on macOS the desktop app supervises it, so it cannot be handed this run's environment)

## Exact launch commands

```
lifeboat: PYTHONPATH=/Users/Arul329/src/Lifeboat/packaging/pypi/src /Users/Arul329/src/Lifeboat/.venv-test/bin/python -m lifeboat serve /Users/Arul329/Library/Application Support/Lifeboat/models/Qwen3-4B Instruct (GGUF)/Qwen3-4B-Instruct-2507-UD-Q4_K_XL.gguf --port 8701 --host 127.0.0.1
llamacpp: /Users/Arul329/Library/Application Support/Lifeboat/engines/llama.cpp/llama-server --model /Users/Arul329/Library/Application Support/Lifeboat/models/Qwen3-4B Instruct (GGUF)/Qwen3-4B-Instruct-2507-UD-Q4_K_XL.gguf --host 127.0.0.1 --port 8702 --n-gpu-layers 99
ollama: ollama serve
```
