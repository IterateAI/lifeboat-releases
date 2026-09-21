<div align="center">

<img src="assets/Lifeboat-Logo-Black.png#gh-light-mode-only" alt="Lifeboat" height="72">
<img src="assets/Lifeboat-Logo-White.png#gh-dark-mode-only" alt="Lifeboat" height="72">

**Run language models on your own hardware, behind an OpenAI-compatible API.**

[Download](#download) · [Desktop](docs/desktop.md) · [Docker](#docker) · [Kubernetes](#kubernetes) · [Documentation](#documentation)

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

A native app with a tray icon, on all three platforms. No container runtime
and no root. It serves models on whatever the machine has: **Metal** on Apple
Silicon and **Vulkan** on Windows and Linux, which covers NVIDIA, AMD and
Intel GPUs with one download — and the CPU otherwise.

The macOS and Windows builds are code-signed (macOS also notarized); the Linux
builds are not, and ship a `SHA256SUMS` instead.

Desktop builds are cut **per platform**, so the newest version differs between
them. Take the newest file for yours:

| Platform | File | Notes |
|---|---|---|
| **Windows** 10/11 x64 | `Lifeboat-2.2.50-setup.exe` | signed installer, no admin rights needed |
| **macOS** Apple Silicon (13+) | `Lifeboat-2.2.50-macos-arm64.dmg` | Metal + MLX |
| **macOS** Intel (13+) | `Lifeboat-2.2.50-macos-x86_64.dmg` | GGUF, no MLX |
| **Linux** Debian/Ubuntu x64 | `lifeboat-desktop_2.2.50_amd64.deb` | GPU offload via Vulkan |
| **Linux** Debian/Ubuntu arm64 | `lifeboat-desktop_2.2.50_arm64.deb` | GPU offload via Vulkan |
| **Linux** any distro, x64 | `Lifeboat-2.2.50-linux-x86_64.tar.gz` | GPU offload via Vulkan |
| **Linux** any distro, arm64 | `Lifeboat-2.2.50-linux-aarch64.tar.gz` | GPU offload via Vulkan |

Because the platforms are cut separately, the newest build for yours may not
be on the *latest* release — browse [all releases](../../releases) and take
the newest file bearing your platform's name.

**[`docs/desktop.md`](docs/desktop.md) is the full guide** — requirements,
GPU support, upgrading and uninstalling for each platform.

#### Windows

Download `Lifeboat-<version>-setup.exe` and double-click it. That is the whole
procedure.

It installs **for you rather than for the machine**, so there is no
administrator prompt: the app goes to `%LOCALAPPDATA%\Programs\Lifeboat` and
your models to `%LOCALAPPDATA%\Lifeboat`. *Start at sign-in* and *desktop
shortcut* are separate checkboxes; neither implies the other.

One prerequisite, which the installer checks for but cannot install:

```powershell
winget install --id Microsoft.DotNet.DesktopRuntime.8 -e
```

The tray is a .NET application and does nothing without it. `lifeboat-core.exe`
runs headless and does not need it.

> The `curl … | bash` line in the welcome email is the **Docker** installer and
> is for Linux hosts. PowerShell has no `bash`, so it fails with
> *"The term 'bash' is not recognized"*. On Windows, use `setup.exe`.

#### macOS

Open the `.dmg`, drag **Lifeboat** to **Applications**, and launch it.

The build is signed with a Developer ID, **notarized by Apple and stapled**, so
there is no security warning and no need to right-click → Open — offline too,
since the ticket travels inside the file. Lifeboat lives in the **menu bar**,
not the Dock: there is no Dock icon and no window on launch.

#### Linux

Debian, Ubuntu and derivatives:

```sh
sudo apt install ./lifeboat-desktop_2.2.50_amd64.deb
```

Use `apt install ./file.deb`, not `dpkg -i` — the tray binding and the Vulkan
loader are *recommended* packages and `dpkg` will not pull them in.

Any other distribution — the tarball unpacks to the same layout, rooted at `/`:

```sh
sudo tar -C / -xzf Lifeboat-2.2.50-linux-x86_64.tar.gz
```

Either way you get `/opt/lifeboat` plus two commands on `PATH`:
**`lifeboat-core`** (the server and CLI, runs headless) and **`lifeboat-tray`**.
Needs **glibc 2.31+** (Debian 11+, Ubuntu 20.04+, RHEL 9+). For GPU offload
install `libvulkan1` and your vendor's Vulkan driver; for the tray icon on
GNOME, `gir1.2-ayatanaappindicator3-0.1` — without an AppIndicator it silently
does not render.

```sh
lifeboat-core doctor     # what this machine can actually run, and why
```

#### Verifying a download

macOS and Windows builds are code-signed, so the OS checks them for you — that
is the stronger check. Linux builds are not signed; where a release publishes
a `SHA256SUMS`, check against it:

```sh
sha256sum -c SHA256SUMS --ignore-missing
```

<details>
<summary><b>System requirements</b></summary>

| | Minimum | Recommended |
|---|---|---|
| macOS | 13 Ventura, Apple Silicon or Intel | Apple Silicon, 16 GB+ |
| Windows | 10 build 17763 x64, .NET 8 Desktop Runtime | 16 GB+, any GPU with a Vulkan driver |
| Linux | glibc 2.31+, x64 or arm64 | 16 GB+, `libvulkan1` + vendor driver |
| Disk | 2 GB for the app | plus whatever your models need |

Decode speed is limited by memory bandwidth, not by core count. As a rule of
thumb on a machine with **8 GB** of RAM: a 1.5B–4B model at 4-bit is
comfortable, 8B is the ceiling, and 14B will not fit. The app's **Doctor**
(tray → Show Log, or `lifeboat-core doctor`) reports the limits for your actual
machine.

**NPUs and Intel XPU are not used.** An "AI PC" NPU sits idle under Lifeboat:
there is no inference path to it, and it shares system memory, so it would not
lift the bandwidth ceiling that actually governs decode speed.

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
curl -sSL https://raw.githubusercontent.com/IterateAI/lifeboat-releases/main/install/get-lifeboat.sh | bash
```

It checks your host, picks the right image for your hardware, writes a `.env`,
and starts the stack. Then open <http://localhost:8001>.

<details>
<summary><b>Prefer to read the script first?</b> (Sensible — it is piped to a shell)</summary>

```sh
curl -sSLO https://raw.githubusercontent.com/IterateAI/lifeboat-releases/main/install/get-lifeboat.sh
less get-lifeboat.sh
bash get-lifeboat.sh
```

A copy is mirrored in this repository at [`install/get-lifeboat.sh`](install/get-lifeboat.sh)
so you can review it with history. The canonical copy is the one served from
this repository.

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
curl -sSLO https://raw.githubusercontent.com/IterateAI/lifeboat-releases/main/install/docker-compose.yaml
curl -sSL  https://raw.githubusercontent.com/IterateAI/lifeboat-releases/main/install/.env.example -o .env
$EDITOR .env          # optional: LIFEBOAT_ADMIN_PASSWORD, else the
                      # console asks you to create the account on first visit
docker compose up -d
```

Copies of all three compose files are mirrored in [`install/`](install/),
and [`docs/docker.md`](docs/docker.md) has the full detail — tags, host
requirements, sizing and upgrades.

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
helm repo add lifeboat https://raw.githubusercontent.com/IterateAI/lifeboat-releases/main/helm
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

1. Open the console — <http://localhost:8001> (Docker) or <http://127.0.0.1:30800>
   via the tray's **Open
   Console** (desktop).
2. **Create your administrator account.** Lifeboat ships with no credentials:
   the first visit asks you to choose an email and password, and that account
   is the superadmin. (If you set `LIFEBOAT_ADMIN_PASSWORD` in `.env` before
   the first start, the account is created from that instead and you sign in
   normally.)
3. **Models → Add Model**, pick something that fits your machine.
4. **Servers → New Server**, choose the model, press Start.
5. Point any OpenAI-compatible client at `http://localhost:8001/v1`.

```sh
curl http://localhost:8001/v1/chat/completions \
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

* **Free tier** — for non-commercial and evaluation use. No card. Up to 2
  concurrent inference servers, single node.
* **Paid** — monthly or yearly.
* **Air-gapped** — offline licence files are available; they never contact a
  licence server. Install first, read the **Cluster ID** off the License page,
  and quote it when you ask — the file is bound to that one cluster.

**All of it goes through [iterate.ai/lifeboat](https://iterate.ai/lifeboat)** —
free tier, trial, purchase, upgrades and offline files. That is the only
address you need.

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
| [Desktop](docs/desktop.md) | installing on Windows, macOS and Linux; GPU support; upgrades |
| [Docker](docs/docker.md) | image tags, host requirements, sizing, upgrades |
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
