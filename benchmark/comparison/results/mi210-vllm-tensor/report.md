# Inference server comparison

- **Host** Linux x86_64
- **Model** `/home/amd/hf-models/Qwen2.5-0.5B-Instruct`
- **Profile** `default` - every system exactly as it ships
- **Workload** 256 tokens/request, temperature 0, thinking off, concurrency [1, 4, 16, 32]
- **Measured by** the control plane's own benchmark module, so these are the same definitions Lifeboat reports elsewhere

| System | Single-stream tok/s | Peak tok/s | at | TTFT p50 | Failed |
|---|---|---|---|---|---|
| **lifeboat** | 544.8 | 9985.2 | c=32 | 20 ms | 0 |
| **vllm** | 584.7 | 7513.4 | c=32 | 10 ms | 0 |

## What each row means

- **lifeboat** (external at http://172.17.0.2:30222) - Lifeboat tensor engine (ROCm, triton attention, torch.compile)
  - NOTE: started outside this harness; its configuration is whatever the operator gave it
- **vllm** (external at http://127.0.0.1:8000) - vLLM (rocm/vllm:latest), the system under comparison
  - NOTE: started outside this harness; its configuration is whatever the operator gave it

## Exact launch commands

```
lifeboat: <already running> http://172.17.0.2:30222
vllm: <already running> http://127.0.0.1:8000
```
