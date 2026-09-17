# Changelog

Release notes for each published build. Binaries are on the
[releases page](../../releases).

Both artifact families use the Lifeboat product version, but they are cut
independently and **the two numbers are not expected to match**: the desktop
apps are currently `2.2.44` while the newest container image and Helm chart are
`2.2.40`. A desktop version is not a pullable image tag. Container releases are
listed below; desktop releases have their own notes on each release page.

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
