# Changelog

Release notes for each published build. Binaries are on the
[releases page](../../releases).

Both artifact families use the Lifeboat product version, but they are cut
independently and **the numbers are not expected to match** — a desktop
version is not a pullable image tag. Desktop builds are cut **per platform**
as well, so they differ from each other too. As of this writing: container
images are `2.2.48`; the newest desktop builds are `2.2.50` on Windows,
`2.2.49` on Apple Silicon and `2.2.46` on Intel macOS and Linux. Container
releases are listed below; desktop releases have their own notes on each
release page.

## Desktop 2.2.50 — Linux (x64)

**The Linux build now uses the GPU.** Every previous Linux desktop artifact
ran every model on the CPU, on any hardware — the build produced no GPU
backend at all, and said so in two lines of an otherwise successful build log.
Unpacking the published 2.2.46 tarball shows fourteen CPU backends and no
Vulkan one.

- **Vulkan offload**, which covers NVIDIA, AMD and Intel with one download —
  the same choice the Windows build makes. Verified on a box with both an
  Intel iGPU and an NVIDIA RTX PRO 6000: the shipped artifact enumerates both.
- The package now **recommends `libvulkan1` and `mesa-vulkan-drivers`**.
  Install with `apt install ./…deb` rather than `dpkg -i` so they are pulled
  in; `dpkg` ignores recommends.
- No GPU, or no Vulkan driver? Nothing breaks. The backend is loaded at
  runtime, so the CPU backends take over exactly as before.
- The package description claimed "CUDA on NVIDIA, Vulkan on AMD and Intel".
  It never shipped CUDA and, until now, no GPU support at all. It now says
  what the package does.

arm64 is still at 2.2.46 and does not yet have this; it is built on separate
hardware.

## Desktop 2.2.50 — Windows

**Windows now ships a signed installer.** Previous Windows builds were a
`.zip` you unpacked by hand; `Lifeboat-2.2.50-setup.exe` installs the app,
registers it for sign-in start if you ask, and gives you an entry in
*Settings → Apps* to remove it again.

- **Per-user, so there is no administrator prompt.** The app installs to
  `%LOCALAPPDATA%\Programs\Lifeboat` and never needs elevation, at install
  time or afterwards. Models and the database go to `%LOCALAPPDATA%\Lifeboat`
  and an uninstall asks separately before deleting them.
- **The installer and both executables are Authenticode-signed**, so
  SmartScreen has a publisher to show.
- **Auto-start and the desktop shortcut are separate checkboxes.** They were
  one: declining auto-start silently also declined the desktop icon, and
  wanting the icon forced auto-start on.
- GPU offload uses **Vulkan**, which covers NVIDIA, AMD and Intel with one
  download. The CPU backends are selected at runtime, so the same build runs
  from an old Xeon to a current Ryzen.
- The .NET 8 Desktop Runtime is still required for the tray, and the
  installer now says so plainly rather than installing an app that appears to
  do nothing. `lifeboat-core.exe` runs headless without it.

See [`docs/desktop.md`](docs/desktop.md) for the full procedure.

## 2.2.48 — container images

Published as `:latest` / `:2.2.48` (NVIDIA, amd64 + arm64), `:lite` /
`:latest-lite` / `:2.2.48-lite` (CPU and integrated GPUs, amd64 + arm64),
`:2.2.48-rocm` / `:latest-rocm` / `:amd` (AMD CDNA2, gfx90a), `:amd-mi300x`
(CDNA3, gfx942) and `:amd-mi355x` (CDNA4, gfx950).

- **Conversation-cache sizing on unified-memory hosts.** Lifeboat could reserve
  more cache than the machine can give the GPU, so a model started, reported
  healthy and then failed every request. It now sizes against the memory
  actually available and reduces concurrency rather than the context window.
- **Cache-cost arithmetic corrected.** A per-model figure was derived where the
  model file states it outright, under-counting the cache cost of many current
  models by half.
- **Capacity rejections are counted** in `/metrics`. When every backend is busy
  and the queue is off, the resulting 503 was the one rejection the counters
  missed.
- The model listing reports a context window for models served by engines that
  expose no introspection endpoint, instead of leaving it blank.

## Desktop 2.2.46

Three first-run defects, all reported from one Mac.

- **MLX models could not be downloaded at all.** An MLX checkpoint *is*
  safetensors, so the gate that refuses unservable safetensors matched an
  `mlx-community` repository exactly and disabled Download — while its own
  message advised looking for "an mlx-community build".
- **An MLX download was allowed where MLX cannot run** — an Intel Mac, Windows,
  or the Lite image would start a download that could never load. Both the
  browser and server gates now require MLX to actually be present. GGUF keeps
  no such condition; that engine ships in every shape.
- **A recommended model pointed at a repository that does not exist.**
  `Qwen/Qwen3-4B-Instruct-2507-GGUF` returns *Repository Not Found*, which
  reads as a token problem because the dialog has a token selector under the
  error. Every repository Lifeboat recommends is now existence-checked before
  release, and checked against its own format tag.

## Desktop 2.2.45

- **Help on every console page now opens the page that answers that page's
  questions** — Servers to the server lifecycle, Configuration to the
  configuration reference, Alerts to alerts and health, and so on, rather than
  a broad entry page. 2.2.44's links all resolved; this closes the extra click.
- **The documentation behind it went from 15 pages to 70**, rewritten as
  operator documentation with troubleshooting organised by symptom — a server
  that will not start, slow responses, failing requests, downloads, tool calls,
  nodes and clusters, and the desktop app.

## Desktop 2.2.44

- **An unservable model is refused in the picker, not after the click.** A
  safetensors-only repository on a machine with no tensor engine (every Mac,
  and any Linux box without CUDA or ROCm) previously let you press **Download**
  and failed afterwards with `format_not_servable`. The variant picker now
  decides from the file listing it already fetches, explains why, and disables
  the button. Mixed repositories still offer their GGUF variants, and if the
  listing cannot be read the check fails open rather than blocking a download
  it cannot judge.

## Desktop 2.2.43

- **Start** no longer flickers `Starting -> Stopped -> Starting`, and an open
  log panel survives the transition with its scroll position. The engine takes
  longer to come up than one poll interval, so the console was showing stale
  `stopped` rows over the top of an optimistic `starting`.

## Desktop 2.2.42

- The recommended-model list is filtered to formats the host can actually
  serve, in preference order — MLX first on Apple Silicon, then GGUF.
- Apple GPU, CPU model and installed memory are reported correctly on macOS.

## Desktop 2.2.41

- First notarized builds for **both** Mac architectures. The Intel build in
  2.2.40 could not start; it was withdrawn.
- The disk image carries an **Applications** shortcut for drag-and-drop.
- **Check for Updates...** in the tray menu.

## Desktop 2.2.40

First public desktop builds, for macOS and Linux. Windows is in progress.

- **Desktop app.** No container runtime. Serves models on whatever the machine
  has: Metal and MLX on Apple Silicon, Vulkan on AMD and Intel GPUs, and the
  CPU otherwise.
- **Free tier** for non-commercial and evaluation use.

## 2.2.40

- Container images for NVIDIA (`:latest`), AMD CDNA2/3/4 (`:amd`,
  `:amd-mi300x`, `:amd-mi355x`) and CPU-only or integrated GPUs (`:lite`).
