# Inference server comparison

- **Host** Linux x86_64
- **Model** `/home/amd/lifeboat-models/qwen25-05b-gguf/qwen2.5-0.5b-instruct-q4_k_m.gguf` (sha256 `74a4da8c9fdbcd15...`)
- **Profile** `default` - every system exactly as it ships
- **Workload** 256 tokens/request, temperature 0, thinking off, concurrency [1, 4, 16, 32]
- **Measured by** the control plane's own benchmark module, so these are the same definitions Lifeboat reports elsewhere

| System | Single-stream tok/s | Peak tok/s | at | TTFT p50 | Failed |
|---|---|---|---|---|---|
| **lifeboat** | 198.2 | 1330.0 | c=32 | 11 ms | 0 |
| **llamacpp** | 193.1 | 685.7 | c=32 | 13 ms | 0 |

## What each row means

- **lifeboat** (lifeboat 2.2.55) - the system under test
- **llamacpp** (0.00.000.260 I srv  llama_server: initializing ...) - the SAME GGUF engine Lifeboat embeds, run directly -- a difference is the serving layer, not the kernel

## Exact launch commands

```
lifeboat: /home/amd/lbcmp/bin/lifeboat serve /home/amd/lifeboat-models/qwen25-05b-gguf/qwen2.5-0.5b-instruct-q4_k_m.gguf --port 8701 --host 127.0.0.1
llamacpp: /home/amd/.local/share/lifeboat/engines/llama.cpp/llama-server --model /home/amd/lifeboat-models/qwen25-05b-gguf/qwen2.5-0.5b-instruct-q4_k_m.gguf --host 127.0.0.1 --port 8702 --n-gpu-layers 99
```
