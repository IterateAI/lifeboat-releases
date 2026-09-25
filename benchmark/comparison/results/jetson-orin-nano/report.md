# Inference server comparison

- **Host** Linux aarch64
- **Model** `/home/iterate-jsn-kit/.local/share/lifeboat/models/Qwen__Qwen2.5-0.5B-Instruct-GGUF/qwen2.5-0.5b-instruct-q4_k_m.gguf` (sha256 `74a4da8c9fdbcd15...`)
- **Profile** `default` - every system exactly as it ships
- **Workload** 256 tokens/request, temperature 0, thinking off, concurrency [1, 4, 16]
- **Measured by** the control plane's own benchmark module, so these are the same definitions Lifeboat reports elsewhere

| System | Single-stream tok/s | Peak tok/s | at | TTFT p50 | Failed |
|---|---|---|---|---|---|
| **llamacpp** | 88.1 | 195.3 | c=4 | 40 ms | 0 |
| **lifeboat** | 88.2 | 180.2 | c=4 | 38 ms | 0 |
| **ollama** | 89.5 | 89.5 | c=1 | 44 ms | 0 |

## What each row means

- **lifeboat** (lifeboat 2.2.55) - the system under test
- **llamacpp** (0.00.000.584 I srv  llama_server: initializing ...) - the SAME GGUF engine Lifeboat embeds, run directly -- a difference is the serving layer, not the kernel
- **ollama** (ollama version is 0.34.4) - wraps the same llama.cpp engine Lifeboat embeds -- a difference is the serving layer, not the kernel
  - NOTE: reused an ollama daemon that was already running (on macOS the desktop app supervises it, so it cannot be handed this run's environment)

## Exact launch commands

```
lifeboat: /home/iterate-jsn-kit/lifeboat/bin/lifeboat serve /home/iterate-jsn-kit/.local/share/lifeboat/models/Qwen__Qwen2.5-0.5B-Instruct-GGUF/qwen2.5-0.5b-instruct-q4_k_m.gguf --port 8701 --host 127.0.0.1
llamacpp: /home/iterate-jsn-kit/.local/share/lifeboat/engines/llama.cpp/llama-server --model /home/iterate-jsn-kit/.local/share/lifeboat/models/Qwen__Qwen2.5-0.5B-Instruct-GGUF/qwen2.5-0.5b-instruct-q4_k_m.gguf --host 127.0.0.1 --port 8702 --n-gpu-layers 99
ollama: ollama serve
```
