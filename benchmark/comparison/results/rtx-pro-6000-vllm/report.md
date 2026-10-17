# Lifeboat vs vLLM, out of the box — 2x RTX PRO 6000 Blackwell

Both engines were run exactly as they ship, on the same GPU, from the same model files. On the 30B mixture-of-experts model Lifeboat delivers 1.47x to 3.01x vLLM's throughput at every concurrency level tested. On the 27B model Lifeboat leads by 2.64x for a single user, 1.42x at 16 concurrent requests and 1.09x at 32; at 64, vLLM is ahead, 1,621 tok/s against 1,229.

Time to first token is lower on vLLM at every concurrency level; time per output token is lower on Lifeboat at every level. Measured 17 October 2026. [Download this report as a PDF](https://github.com/IterateAI/lifeboat-releases/raw/main/benchmark/comparison/results/rtx-pro-6000-vllm/Lifeboat_v2.2.61_vLLM_Comparison_RTX-PRO-6000.pdf).

## Qwen3.8-27B-FP8

| Concurrent requests | Lifeboat (tok/s) | vLLM (tok/s) | Lifeboat vs vLLM | Lifeboat ($/1M tokens) | vLLM ($/1M tokens) |
|---|---|---|---|---|---|
| 1 | 126.1 | 47.7 | 2.64x | 5.13 | 13.57 |
| 4 | 411.0 | 172.2 | 2.39x | 1.57 | 3.76 |
| 16 | 935.1 | 657.9 | 1.42x | 0.69 | 0.98 |
| 32 | 1,259.4 | 1,150.7 | 1.09x | 0.51 | 0.56 |
| 64 | 1,228.6 | 1,621.2 | 0.76x | 0.53 | 0.40 |

| Concurrent requests | Lifeboat TTFT (ms) | vLLM TTFT (ms) | Lifeboat TPOT (ms) | vLLM TPOT (ms) |
|---|---|---|---|---|
| 1 | 85 | 39 | 7.5 | 20.9 |
| 4 | 171 | 68 | 8.1 | 22.5 |
| 16 | 575 | 151 | 12.5 | 23.8 |
| 32 | 943 | 222 | 19.5 | 27.0 |
| 64 | 1,620 | 495 | 27.4 | 36.6 |

## Qwen3-30B-A3B-Instruct-2507-FP8

| Concurrent requests | Lifeboat (tok/s) | vLLM (tok/s) | Lifeboat vs vLLM | Lifeboat ($/1M tokens) | vLLM ($/1M tokens) |
|---|---|---|---|---|---|
| 1 | 432.9 | 165.1 | 2.62x | 1.50 | 3.92 |
| 4 | 1,592.1 | 528.5 | 3.01x | 0.41 | 1.22 |
| 16 | 4,330.3 | 1,700.3 | 2.55x | 0.15 | 0.38 |
| 32 | 8,209.1 | 3,100.2 | 2.65x | 0.08 | 0.21 |
| 64 | 7,973.1 | 5,409.8 | 1.47x | 0.08 | 0.12 |

| Concurrent requests | Lifeboat TTFT (ms) | vLLM TTFT (ms) | Lifeboat TPOT (ms) | vLLM TPOT (ms) |
|---|---|---|---|---|
| 1 | 19 | 12 | 2.3 | 6.0 |
| 4 | 32 | 22 | 2.4 | 7.5 |
| 16 | 48 | 35 | 3.5 | 9.3 |
| 32 | 71 | 58 | 3.6 | 10.1 |
| 64 | 134 | 84 | 4.1 | 11.5 |

## Long prompts

One request at a time, 2K to 256K tokens of prompt.

### Qwen3.8-27B-FP8

Lifeboat generates about 2x faster on this model and vLLM starts responding sooner, so Lifeboat returns the full answer first up to 16K tokens and vLLM from 32K up.

| Prompt length | Lifeboat TTFT (s) | vLLM TTFT (s) | Lifeboat full answer (s) | vLLM full answer (s) |
|---|---|---|---|---|
| 2K | 0.63 | 0.34 | 3.0 | 5.7 |
| 4K | 1.27 | 0.60 | 3.7 | 6.1 |
| 8K | 2.31 | 1.22 | 4.9 | 6.7 |
| 16K | 4.74 | 2.53 | 7.3 | 8.1 |
| 32K | 10.1 | 5.60 | 12.9 | 11.3 |
| 64K | 23.0 | 13.0 | 25.6 | 19.1 |
| 128K | 57.1 | 33.9 | 60.1 | 40.8 |
| 256K | 152.5 | 95.3 | 156.0 | 103.4 |

### Qwen3-30B-A3B-Instruct-2507-FP8

Both engines start responding in about the same time. Lifeboat returns the full answer first up to 4K and from 64K up; between 8K and 32K the two are within 0.2 seconds.

| Prompt length | Lifeboat TTFT (s) | vLLM TTFT (s) | Lifeboat full answer (s) | vLLM full answer (s) |
|---|---|---|---|---|
| 2K | 0.08 | 0.07 | 1.0 | 1.7 |
| 4K | 0.16 | 0.13 | 1.5 | 1.8 |
| 8K | 0.38 | 0.33 | 2.0 | 2.0 |
| 16K | 0.98 | 0.90 | 2.9 | 2.7 |
| 32K | 2.88 | 2.80 | 5.1 | 4.9 |
| 64K | 9.50 | 9.70 | 12.2 | 12.4 |
| 128K | 34.0 | 35.7 | 39.0 | 39.5 |
| 256K | 121.4 | 129.9 | 129.8 | 135.9 |

## How each engine was configured

**Lifeboat.** Lifeboat 2.2.61 with each server created from the console's defaults: the model path and the GPU, and nothing else. Memory, concurrency, routing and speculative decoding were all left on their defaults, which Lifeboat sizes for the GPU it finds.

**vLLM.** vLLM with its defaults: the only arguments are the model path and the name it is served under. vLLM's own log lists those as its only non-default arguments. With no context length given it used each model's full 262,144-token window.

```bash
# Qwen3.8-27B-FP8 on GPU 0
docker run -d --gpus "device=0" --ipc=host -v <models-dir>:/models:ro \
  vllm/vllm-openai:latest \
  /models/Qwen/Qwen3.8-27B-FP8 --served-model-name interplay-coder

# Qwen3-30B-A3B-Instruct-2507-FP8 on GPU 1
docker run -d --gpus "device=1" --ipc=host -v <models-dir>:/models:ro \
  vllm/vllm-openai:latest \
  /models/Qwen/Qwen3-30B-A3B-Instruct-2507-FP8 --served-model-name interplay-coder-a3b
```

## Hardware and software

| Item | Value |
|---|---|
| GPUs | 2x NVIDIA RTX PRO 6000 Blackwell Max-Q Workstation Edition, 96 GB each |
| Placement | one model per GPU, the same GPU for both engines |
| NVIDIA driver | 580.173.02 |
| Host | 24 CPU cores, 123 GB RAM |
| Lifeboat | 2.2.61, container image iterateai/lifeboat:2.2.61 |
| vLLM | 0.31.0, official image vllm/vllm-openai:latest (built 2026-10-03) |

## How it was measured

- One client drove both engines: Lifeboat's built-in benchmark, sending requests through Lifeboat's load balancer to Lifeboat and directly to vLLM's own port.
- Concurrency test: a short coding prompt, 256 output tokens, temperature 0 with top_p 1.0 and top_k disabled, thinking off. Levels 1, 4, 16, 32 and 64 ran one at a time in ascending order after an excluded warm-up request. Each engine ran twice; the tables show the mean.
- Sending the sampling settings in every request means both engines do the same work while running their default command lines.
- Tokens are each engine's own reported output count. Time to first token (TTFT) is from sending the request to the first token. Time per output token (TPOT) is decode time divided by the output tokens after the first.
- Long-prompt test: one request at a time for about 60 seconds per prompt length, 256 output tokens, each prompt unique so no cached work could be reused. Full answer = TTFT plus 255 tokens at the measured TPOT. At 128K and 256K each request takes 1 to 2.5 minutes, so those rows rest on 1 to 2 requests.
- Cost = $2.33 per GPU-hour / (throughput x 3,600 s) x 1,000,000: the market median on-demand price for an RTX PRO 6000 on 16 October 2026. It counts output tokens only, assumes the GPU runs at that throughput for the whole hour, and scales linearly with the rate you pay.

