<div align="center">

<img src="assets/Lifeboat-Logo-Black.png#gh-light-mode-only" alt="Lifeboat" height="72">
<img src="assets/Lifeboat-Logo-White.png#gh-dark-mode-only" alt="Lifeboat" height="72">

**Run language models on your own hardware, behind an OpenAI-compatible API.**

[Download](#download) · [Docker](#docker) · [Kubernetes](#kubernetes) · [Documentation](#documentation)

</div>

---

Lifeboat serves open-weight models on machines you control — a laptop, a
workstation, a GPU server, or a cluster — and puts an OpenAI- and
Anthropic-compatible API in front of them, with a load balancer, a web console
and no data leaving your network.

This repository is **downloads and install instructions only**. The source is
not public.

---

## Download

### Desktop — no Docker required

A signed native app with a tray icon. It serves models on whatever the machine
has: Metal on Apple Silicon, CUDA on NVIDIA, Vulkan on AMD and Intel, and the
CPU otherwise.

| Platform | Download |
|---|---|
| **macOS** (Apple Silicon) | [Lifeboat-macos-arm64.dmg](../../releases/latest) |
| **macOS** (Intel) | [Lifeboat-macos-x64.dmg](../../releases/latest) |
| **Windows** (x64) | [Lifeboat-setup.exe](../../releases/latest) |
| **Linux** (x64 / arm64) | [.deb and .tar.gz](../../releases/latest) |

All builds are on the [releases page](../../releases/latest), with SHA-256
checksums in `SHA256SUMS`.

**Verify what you downloaded.** macOS and Windows builds are code-signed, so
the OS checks them for you. On Linux, check the signature yourself:

```sh
sha256sum -c SHA256SUMS --ignore-missing
gpg --verify lifeboat-desktop_*.deb.asc            # key: see SECURITY.md
```

<details>
<summary><b>System requirements</b></summary>

| | Minimum | Recommended |
|---|---|---|
| macOS | 13 Ventura, Apple Silicon or Intel | Apple Silicon, 16 GB+ |
| Windows | 10 (build 17763) x64, .NET 8 Desktop Runtime | 16 GB+, any GPU |
| Linux | glibc 2.31+, x64 or arm64 | 16 GB+, Vulkan drivers for GPU offload |
| Disk | 2 GB for the app | plus whatever your models need |

Decode speed is limited by memory bandwidth, not by core count. As a rule of
thumb on a machine with **8 GB** of RAM: a 1.5B–4B model at 4-bit is
comfortable, 8B is the ceiling, and 14B will not fit. The app's **Doctor**
(tray → Show Log, or `lifeboat-core doctor`) reports the limits for your actual
machine.

</details>

<details>
<summary><b>Which model format do I download?</b></summary>

Lifeboat picks for you and tells you why. The short version:

| Your machine | Use |
|---|---|
| Apple Silicon Mac | **GGUF** (default) or MLX — both run on the GPU |
| Windows / Linux desktop | **GGUF** |
| Linux + NVIDIA/AMD server with the tensor engine | **Safetensors** |

Safetensors needs the tensor engine, which runs on Linux with CUDA or ROCm
only. The desktop app will refuse a safetensors download on macOS or Windows
*before* it starts, rather than after an hour — the model would never load.

</details>

---

## Docker

The fastest path on a Linux GPU host. One command:

```sh
curl -sSL https://license.interplay.iterate.ai/lifeboat/get-lifeboat.sh | bash
```

It checks your host, picks the right image for your hardware, writes a `.env`,
and starts the stack. Then open <http://localhost:30000>.

<details>
<summary><b>Prefer to read the script first?</b> (Sensible — it is piped to a shell)</summary>

```sh
curl -sSLO https://license.interplay.iterate.ai/lifeboat/get-lifeboat.sh
less get-lifeboat.sh
bash get-lifeboat.sh
```

A copy is mirrored in this repository at [`install/get-lifeboat.sh`](install/get-lifeboat.sh)
so you can review it with history. The canonical copy is the one served from
`license.interplay.iterate.ai`.

</details>

### Pick the right image

The tags are **not** interchangeable — this is the single most common mistake:

| Your hardware | Tag | Size |
|---|---|---|
| NVIDIA GPU | `iterateai/lifeboat:latest` | ~17 GB |
| AMD Instinct MI210 / MI250 | `iterateai/lifeboat:amd` | ~28 GB |
| AMD MI300X / MI325X | `iterateai/lifeboat:amd-mi300x` | ~28 GB |
| AMD MI350X / MI355X | `iterateai/lifeboat:amd-mi355x` | ~28 GB |
| **No GPU**, Intel/AMD integrated, or AWS Graviton | `iterateai/lifeboat:lite` | ~720 MB |

`:latest` is the **NVIDIA** image and is multi-arch (amd64 + arm64). The arm64
half is built for NVIDIA arm64 parts such as Grace-Hopper and DGX Spark — on a
CPU-only Graviton instance it is 17 GB of CUDA that cannot be used. Use `:lite`
there.

An AMD customer pulling `:latest` gets a CUDA image that will not run on their
GPU. There is no tag that serves both: a container manifest selects on CPU
architecture, and both images are `linux/amd64`.

### Manual Compose

```sh
curl -sSLO https://license.interplay.iterate.ai/lifeboat/docker-compose.yaml
curl -sSL  https://license.interplay.iterate.ai/lifeboat/.env.example -o .env
$EDITOR .env          # set LIFEBOAT_ADMIN_PASSWORD at minimum
docker compose up -d
```

Copies of all three compose files are mirrored in [`install/`](install/).

<details>
<summary><b>NVIDIA host requirements</b></summary>

* Driver **580.65.06** or newer — the image ships the CUDA 13 runtime
* Docker Engine 25.0+, Compose 2.21+
* NVIDIA Container Toolkit 1.17+

`get-lifeboat.sh` checks all of these before downloading anything and tells you
exactly which one is missing.

</details>

<details>
<summary><b>AMD host requirements</b></summary>

ROCm 6.0+, and the container needs `/dev/kfd` and `/dev/dri` plus the `video`
and `render` groups. Use `docker-compose.rocm.yaml`, which sets all of it —
including `ipc: host`, which ROCm requires and without which the engine dies at
its first GPU allocation with an error that mentions neither.

</details>

---

## Kubernetes

```sh
helm repo add lifeboat https://license.interplay.iterate.ai/lifeboat
helm repo update
helm install lifeboat lifeboat/lifeboat \
  --set admin.password='<choose-one>' \
  --set gpu.vendor=nvidia            # nvidia | amd | lite
```

`admin.password` is required and the install fails without it. `gpu.vendor`
switches the image, the device resource and the runtime class together — set it
to `lite` for CPU-only nodes.

---

## First run

1. Open the console — <http://localhost:30000> (Docker) or the tray's **Open
   Console** (desktop).
2. Sign in. Docker: the credentials you set in `.env`. Desktop: the tray's
   **Copy Console Login** has them.
3. **Models → Add Model**, pick something that fits your machine.
4. **Servers → New Server**, choose the model, press Start.
5. Point any OpenAI-compatible client at `http://localhost:30000/v1`.

```sh
curl http://localhost:30000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <your-api-key>' \
  -d '{"model":"<your-model>","messages":[{"role":"user","content":"Hello"}]}'
```

The Anthropic-compatible surface is at `/v1/messages`, so SDKs pointed at
either vendor work unchanged.

---

## Licensing

Every install runs for **24 hours** with no key, so you can evaluate before
deciding anything. After that an activation key is required to start inference
servers — the console and the API stay reachable either way, so you can always
activate from the same page that asked you to.

* **Free tier** — for non-commercial and evaluation use, at
  [`/lifeboat/free`](https://license.interplay.iterate.ai/lifeboat/free). No
  card. Up to 2 concurrent inference servers, single node.
* **Paid** — monthly or yearly, at the
  [customer portal](https://license.interplay.iterate.ai/lifeboat/portal).
* **Air-gapped** — offline licence files are available; they never contact a
  licence server.

---

## What Lifeboat reports back

A licensed install sends a heartbeat every 6 hours: the licence key, a cluster
id, a pod count, a version, and a hardware description sent **once**. An
unlicensed install sends a smaller daily message so support can see an
evaluation exists.

**No model names, no prompts, no completions, no token counts.** That is
enforced in code, not just intended. `LIFEBOAT_TELEMETRY=off` disables the
hardware and census reporting; an air-gapped licence sends nothing at all, ever.

The full payload, byte for byte, is documented in
[`docs/telemetry.md`](docs/telemetry.md).

---

## Documentation

| | |
|---|---|
| [User Guide](docs/) | installation, configuration, every console page |
| [API Reference](docs/) | the full `/v1/*` surface, OpenAPI and Postman |
| [Telemetry](docs/telemetry.md) | exactly what is sent, and what never is |
| [Security](SECURITY.md) | reporting a vulnerability, signing keys |
| [Changelog](CHANGELOG.md) | what changed in each release |

---

## Support

* **Issues with a download or an install** — open an issue here.
* **Anything involving your licence, your data or your account** — email
  <support@iterate.ai> rather than filing a public issue.
* **Security vulnerabilities** — see [SECURITY.md](SECURITY.md). Please do not
  open a public issue for these.

---

<div align="center">
<sub>Lifeboat is built by <a href="https://iterate.ai">iterate.ai</a>.
Source is not public; this repository carries releases and install
instructions.</sub>
</div>
