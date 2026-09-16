# Docker

Full detail on the container images: which tag, what each one contains, and the
host requirements that actually block a start.

## Choose the tag first

The tags are **not** interchangeable, and this is the most common mistake:

| Your hardware | Tag | Size | Engine |
|---|---|---|---|
| NVIDIA GPU | `iterateai/lifeboat:latest` | ~17 GB | tensor + GGUF |
| AMD MI210 / MI250 (CDNA2) | `iterateai/lifeboat:amd` | ~28 GB | tensor + GGUF |
| AMD MI300X / MI325X (CDNA3) | `iterateai/lifeboat:amd-mi300x` | ~28 GB | tensor + GGUF |
| AMD MI350X / MI355X (CDNA4) | `iterateai/lifeboat:amd-mi355x` | ~28 GB | tensor + GGUF |
| No GPU, integrated GPU, or AWS Graviton | `iterateai/lifeboat:lite` | ~720 MB | GGUF only |

Version tags (`:2.2.40`) are immutable. `:latest`, `:latest-rocm`, `:amd` and
`:lite` move with each release.

### Why there is no single tag

A container manifest selects on **CPU architecture**, not on GPU vendor. The
NVIDIA and AMD images are both `linux/amd64`, so they cannot share a tag — the
second push would simply replace the first for every user.

`:latest` and `:lite` are each multi-arch (`linux/amd64` + `linux/arm64`).

### The arm64 trap

`:latest`'s arm64 half is the **CUDA** image, built for NVIDIA arm64 parts —
Grace-Hopper, GB10/DGX Spark. On a CPU-only **AWS Graviton** instance it is
17 GB of CUDA that cannot be used. Use `:lite` there; it dispatches across
Graviton 2, 3 and 4 at runtime (armv8.2 through armv9.2, with SVE, SVE2 and
matrix extensions where the core has them).

---

## Install

```sh
curl -sSL https://license.interplay.iterate.ai/lifeboat/get-lifeboat.sh | bash
```

The installer detects your hardware, picks the tag, checks the host
requirements **before** downloading anything, writes a `.env` and starts the
stack.

Manual, if you prefer:

```sh
curl -sSLO https://license.interplay.iterate.ai/lifeboat/docker-compose.yaml
curl -sSL  https://license.interplay.iterate.ai/lifeboat/.env.example -o .env
$EDITOR .env
docker compose up -d
```

Use `docker-compose.rocm.yaml` for AMD and `docker-compose.cpu.yaml` for Lite.
All three are mirrored in [`install/`](../install/).

---

## Host requirements

### NVIDIA

| | |
|---|---|
| Driver | **580.65.06** or newer — the image ships the CUDA 13 runtime |
| Docker Engine | 25.0+ (native CDI device support) |
| Docker Compose | 2.21+ |
| Container Toolkit | 1.17+ |

A driver older than 580.65.06 fails inside the container with a bare
`CUDA error`, naming neither the driver nor the version — so the installer
checks it up front and refuses with a sentence that names both.

### AMD

ROCm 6.0+, and the container needs `/dev/kfd` plus `/dev/dri`, and the `video`
and `render` groups. `docker-compose.rocm.yaml` sets all of it.

It also sets **`ipc: host`**, which is required and not optional: without it
the engine dies at its first GPU allocation with an HSA-level
`Memory in use` fault that mentions neither IPC nor shared memory. Do not
"harden" it back.

### CPU / Lite

Nothing beyond Docker. Pass `LIFEBOAT_GPU_DEVICE=/dev/dri:/dev/dri` to give an
Intel or AMD integrated GPU to the container for Vulkan offload.

---

## Sizing

Decode is **memory-bandwidth bound**, so the ceiling is roughly
`bandwidth ÷ bytes-per-token` — core count barely matters. A rough guide at
4-bit:

| Memory available to the accelerator | Comfortable | Ceiling |
|---|---|---|
| 8 GB | 1.5B–4B | 8B |
| 24 GB | 8B–14B | 32B |
| 80 GB | 32B–70B | 70B+ / MoE |

`GET /api/hardware/profile` computes this for the actual host, including a
container memory limit if one is set.

---

## Upgrading

```sh
docker compose pull && docker compose up -d
```

The SQLite database carries its own migrations and is upgraded in place. Keep
the `~/.lifeboat` volume: it holds the database, the licence state and the
24-hour grace clock, and losing it means a new `cluster_id` and a re-issued
licence.
