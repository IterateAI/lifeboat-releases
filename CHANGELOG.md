# Changelog

Release notes for each published build. Binaries are on the
[releases page](../../releases).

The version is the Lifeboat product version and is the same number across the
container images, the Helm chart and the desktop apps — an operator comparing a
desktop install against a container can tell at a glance whether they match.

## Unreleased

First public desktop builds.

- **Desktop app for macOS, Windows and Linux.** No container runtime. Serves
  models on whatever the machine has: Metal on Apple Silicon, CUDA on NVIDIA,
  Vulkan on AMD and Intel, and the CPU otherwise.
- **Model-format gating.** The app refuses a download the machine could never
  load — safetensors on macOS or Windows, MLX anywhere but Apple Silicon —
  before the download starts rather than after it.
- **Free tier** for non-commercial and evaluation use.

## 2.2.40

- Container images for NVIDIA (`:latest`), AMD CDNA2/3/4 (`:amd`,
  `:amd-mi300x`, `:amd-mi355x`) and CPU-only or integrated GPUs (`:lite`).
