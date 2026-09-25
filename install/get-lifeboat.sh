#!/usr/bin/env bash
# Lifeboat — one-command preflight + installer.
#
# Designed to be the *easy path* for new customers. Detects everything
# Lifeboat needs (arch, NVIDIA GPU, driver, Docker, Compose, container
# toolkit), prints a concrete fix command for every failed check, and
# only proceeds to install once preflight is green.
#
# Curl-pipe-bash entry point (set GIT_REF=<tag> to pin a release):
#
#   curl -sSL https://raw.githubusercontent.com/IterateAI/lifeboat-releases/main/install/get-lifeboat.sh | bash
#
# In-repo / interactive flags:
#
#   ./scripts/get-lifeboat.sh                              # preflight + interactive install
#   ./scripts/get-lifeboat.sh --check                      # preflight only, no install
#   ./scripts/get-lifeboat.sh --non-interactive \
#       --admin-password 'CorrectHorseBatteryStaple' \
#       --models-dir /home/models \
#       --license-key LB-A1B2-C3D4-E5F6-G7H8
#
# What it does (in order):
#   1. Preflight every host requirement (Section A below).
#   2. Download docker-compose.yaml + .env.example from the lifeboat-releases repo (install/)
#   3. Write .env with the customer's admin creds + models path by copying .env.example to .env and editing it.
#   4. ``docker compose up -d``.
#   5. Wait until ``/api/version`` returns 200 (up to 120 s).
#   6. If --license-key was passed, POST /api/license/activate.
#   7. Print URL + login + activation status.
#
# Exits:
#   0  — preflight green (--check) or install succeeded.
#   2  — preflight failed; nothing was installed.
#   3  — install step failed after preflight passed.
#   4  — license activation failed but the install is otherwise running.

set -euo pipefail

# --- Windows is a different product, and saying so beats failing oddly ------
# On Windows this script is either unreachable (PowerShell has no `bash`, so
# the documented curl-pipe-bash one-liner dies with "The term 'bash' is not
# recognized") or it runs under Git Bash / MSYS and fails later on docker,
# systemd and /proc in ways that read as a broken installer. The supported
# Windows path is the native desktop app, so name it. WSL is NOT caught here:
# it reports Linux and genuinely works.
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        cat >&2 <<'WINEOF'
[X] This installer is for Linux. It cannot install Lifeboat on Windows.

    Windows has a native app instead -- no Docker, no WSL:

      https://github.com/IterateAI/lifeboat-releases/releases/latest
      -> Lifeboat-<version>-setup.exe

    Download it and run it. It is a signed installer: Start-menu entry,
    optional start-at-sign-in, and an uninstaller. It also checks for the free
    .NET 8 Desktop Runtime (https://dotnet.microsoft.com/download/dotnet/8.0)
    and tells you if it is missing, rather than installing an app that then
    never appears.

    Activate from the console's License page -- the desktop app has no
    --license-key flag.

    (Running under WSL2? That reports as Linux and this installer works
    there; you are seeing this because the shell is Git Bash or MSYS.)
WINEOF
        exit 1
        ;;
esac


# ---------------------------------------------------------------------
# Config / defaults
# ---------------------------------------------------------------------

# GitHub, not the licence server. Three reasons, in order of how much they
# matter to somebody running this:
#
#   * AVAILABILITY. Every new install fetches four files from here. Pointing
#     that at a single Node-RED host means the licence server being down stops
#     new installs, which is a much larger blast radius than licensing.
#   * REVIEWABILITY. This is a curl-pipe-bash. People are right to want to read
#     it first, and a public repo gives them history and blame rather than an
#     opaque URL.
#   * The licence server is infrastructure the PRODUCT talks to, not an address
#     customers should be handed -- the same reason every licensing route now
#     goes through iterate.ai/lifeboat.
#
# The licence server keeps serving these files, so an old URL in somebody's
# runbook still works; this changes the default, not the availability.
LIFEBOAT_RAW_BASE="${LIFEBOAT_RAW_BASE:-https://raw.githubusercontent.com/IterateAI/lifeboat-releases/main/install}"
LIFEBOAT_INSTALL_DIR="${LIFEBOAT_INSTALL_DIR:-$HOME/lifeboat}"
LIFEBOAT_PORT_DEFAULT="8001"
LIFEBOAT_MODELS_DIR_DEFAULT="/home/models"
LIFEBOAT_ADMIN_EMAIL_DEFAULT="admin@iterate.ai"

# The published image. Two tags, one per accelerator: an OCI manifest list
# selects on os/arch only, so there is no GPU-vendor dimension a single tag
# could carry — :latest can never serve AMD. Kept here rather than inline so
# the reachability preflight and the closing summary cannot disagree.
IMAGE_REPO="iterateai/lifeboat"
IMAGE_TAG_NVIDIA="latest"
IMAGE_TAG_AMD="latest-rocm"
# Lite: the universal-hardware image. Control plane + GGUF engine, no
# accelerator runtime, ~720 MB against the accelerator images' 17-28 GB. It is
# what a host with no data-center GPU installs -- and pulling :latest there
# would fetch 17.5 GB of CUDA onto a box chosen for having 8 GB of storage.
IMAGE_TAG_LITE="lite"

# Minimum versions (advisory — script fails if below).
MIN_DOCKER_MAJOR=25
MIN_COMPOSE_MAJOR=2
MIN_COMPOSE_MINOR=21
MIN_DRIVER_MAJOR=580
MIN_GPU_VRAM_GB=8
GPU_VENDOR=""            # nvidia | amd | lite — auto-detected, or forced by a flag
GPU_VENDOR_FORCED=""     # set when --nvidia/--amd/--lite was given, so the edge
                         # routing below advises and never overrides

# CLI flags (mutated by parse_args)
DO_CHECK_ONLY="false"
DO_INTERACTIVE="true"
SKIP_HOST_SETUP="false"
ADMIN_EMAIL=""
ADMIN_PASSWORD=""
MODELS_DIR=""
LICENSE_KEY=""
# Set to "true" by activate_license on a confirmed 200 so the summary reports
# the real outcome instead of "activated" whenever a key was merely supplied.
LICENSE_ACTIVATED="false"
LIFEBOAT_PORT="$LIFEBOAT_PORT_DEFAULT"
# Confidential computing: "" = let the control plane auto-detect (default
# behavior). Set explicitly via --confidential-computing {auto|off|require}.
# Auto-bumped to "auto" (written explicitly) when preflight detects a TEE.
CONFIDENTIAL_COMPUTING=""
CC_HOST_SUPPORTED="false"

# ---------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'
  C_BLUE='\033[34m'; C_BOLD='\033[1m'; C_DIM='\033[2m'; C_OFF='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_DIM=''; C_OFF=''
fi

log_info()  { printf '%b\n' "${C_BLUE}${C_BOLD}==>${C_OFF} $*"; }
log_ok()    { printf '%b\n' "  ${C_GREEN}✓${C_OFF} $*"; }
log_warn()  { printf '%b\n' "  ${C_YELLOW}!${C_OFF} $*"; }
log_fail()  { printf '%b\n' "  ${C_RED}✗${C_OFF} $*"; }
log_hint()  { printf '%b\n' "    ${C_DIM}→ $*${C_OFF}"; }
log_step()  { printf '\n%b\n' "${C_BOLD}$*${C_OFF}"; }

# ---------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------

usage() {
  cat <<USAGE
Lifeboat installer — preflight + bring-up in one command.

Usage: $(basename "$0") [OPTIONS]

  --check                      Run preflight only; do not install.
  --non-interactive            Fail rather than prompt for missing values.
  --admin-email EMAIL          Admin bootstrap email
                               (default: ${LIFEBOAT_ADMIN_EMAIL_DEFAULT}).
  --admin-password PWD         Admin bootstrap password.
                               If omitted in interactive mode, you'll be
                               prompted. In --non-interactive a strong
                               random password is generated and printed
                               at the end.
  --models-dir DIR             Host directory to mount at /models in the
                               container (default: ${LIFEBOAT_MODELS_DIR_DEFAULT}).
                               Created if missing.
  --port PORT                  Control-plane port (default: ${LIFEBOAT_PORT_DEFAULT}).
  --license-key LB-XXXX-...    Pre-activate this Lifeboat license after
                               the service comes up. Optional — the
                               24h grace covers first boot if omitted.
                               Online licenses only; for an offline
                               (air-gapped) license, install without this
                               flag, read the Cluster ID off the UI's
                               License page, buy the offline license with
                               that ID, then upload the signed .lic file
                               on the License page's Upload File tab.
  --confidential-computing M   Confidential-computing mode: auto (default),
                               off, or require. 'require' blocks inference-
                               server start unless the host is an attested
                               TEE (SEV-SNP/TDX + GPU CC mode). If omitted,
                               the control plane auto-detects and enables it
                               when the host supports it.
  --amd, --rocm                Install the AMD/ROCm variant (Instinct MI210/MI250,
                               MI300X/MI325X, MI350X/MI355X). Auto-detected from
                               /dev/kfd when nvidia-smi is absent; this forces it.
  --nvidia, --cuda             Force the NVIDIA/CUDA variant (the default).
                               Also overrides the edge-device routing below.
  --lite, --cpu                Install the Lite image: CPU-only hosts,
                               integrated or older GPUs, mini-PCs and NUCs.
                               No data-center GPU required. Auto-selected when
                               no supported GPU is detected.
  --install-dir DIR            Where to write docker-compose.yaml + .env
                               (default: \$LIFEBOAT_INSTALL_DIR or ~/lifeboat).
  --skip-host-setup            Skip the CDI bootstrap. Only pass this if
                               you've already run install-host-deps.sh
                               or know your host has a persistent CDI spec.
  --kubernetes, --helm         Print Kubernetes/Helm install instructions
                               and exit (this installer itself is Docker
                               Compose only; k8s installs use Helm directly).
  -h, --help                   Show this message.

Edge devices:
  On a Jetson, a Raspberry Pi class board, or any host with 8 GB or less and
  few cores, this installer prints the pip route and stops rather than pulling
  a container image the board cannot use well. Any of --nvidia/--amd/--lite
  overrides that and installs the image you name. Measured throughput and
  sizing per board: https://docs.iterate.ai/lifeboat/platform/performance/

Environment:
  GIT_REF=<branch|tag>         Pull docker-compose.yaml + .env.example
                               from this Git ref (default: main).
  LIFEBOAT_INSTALL_DIR=<path>  Same as --install-dir.
  NO_COLOR=1                   Disable ANSI colors.
USAGE
}

# Kubernetes path is intentionally NOT orchestrated by this Docker-Compose
# installer (it can't drive a cluster). Instead we print the two supported
# Helm install flows against the hosted, rolling chart. Operators run these
# themselves with their kubeconfig active.
print_kubernetes_help() {
  # A SEPARATE base from LIFEBOAT_RAW_BASE, because a Helm repository is its
  # own thing: index.yaml plus the tarball at the URL index.yaml NAMES. The
  # url is baked into index.yaml at package time, so the two must be published
  # together and the base cannot simply be swapped after the fact.
  local chart_url="${LIFEBOAT_CHART_BASE:-https://raw.githubusercontent.com/IterateAI/lifeboat-releases/main/helm}/lifeboat-latest.tgz"
  cat <<HELP
Lifeboat on Kubernetes (Helm)
=============================

This get-lifeboat.sh installer is for Docker Compose. For Kubernetes, install
the Helm chart directly (kubeconfig pointed at your GPU cluster, with the
NVIDIA GPU Operator / device plugin already present).

The chart is published as a single rolling tarball:
  ${chart_url}

It deploys the public image iterateai/lifeboat:latest.

A) Direct tarball (simplest — no repo to add)
   helm install lifeboat ${chart_url} \\
     --namespace lifeboat --create-namespace \\
     --set admin.password='CHANGE-ME' \\
     --set gpu.count=1

B) As a Helm repo (lets you 'helm upgrade' later)
   helm repo add lifeboat ${LIFEBOAT_RAW_BASE}
   helm repo update
   helm install lifeboat lifeboat/lifeboat \\
     --namespace lifeboat --create-namespace \\
     --set admin.password='CHANGE-ME' \\
     --set gpu.count=1

admin.password is REQUIRED (or admin.existingSecret) — the chart refuses to
render without one. There is no licensing.licenseKey value: activate the
license in the dashboard (or POST /api/license/activate) once the pod is up,
and upload an offline .lic through the same dialog on air-gapped clusters.

On an AMD/ROCm cluster add --set gpu.vendor=amd (switches the image to
:latest-rocm, the resource to amd.com/gpu, and turns off the NVIDIA-only
runtime class and CDI annotation).

Common --set overrides: admin.email, admin.password, models.hostPath,
gpu.count, gpu.vendor, gpu.runtimeClassName, service.type. See values.yaml
(helm show values ${chart_url}) for everything.

To upgrade to the latest build, re-run the same 'helm install' with
'helm upgrade --install', or 'helm repo update && helm upgrade lifeboat lifeboat/lifeboat'.
HELP
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --check)              DO_CHECK_ONLY="true"; shift ;;
      --non-interactive)    DO_INTERACTIVE="false"; shift ;;
      --skip-host-setup)    SKIP_HOST_SETUP="true"; shift ;;
      --admin-email)        ADMIN_EMAIL="$2"; shift 2 ;;
      --admin-password)     ADMIN_PASSWORD="$2"; shift 2 ;;
      --models-dir)         MODELS_DIR="$2"; shift 2 ;;
      --port)               LIFEBOAT_PORT="$2"; shift 2 ;;
      --license-key)        LICENSE_KEY="$2"; shift 2 ;;
      --confidential-computing) CONFIDENTIAL_COMPUTING="$2"; shift 2 ;;
      --install-dir)        LIFEBOAT_INSTALL_DIR="$2"; shift 2 ;;
      --amd|--rocm)         GPU_VENDOR="amd";    GPU_VENDOR_FORCED=1; shift ;;
      --lite|--cpu)         GPU_VENDOR="lite";   GPU_VENDOR_FORCED=1; shift ;;
      --nvidia|--cuda)      GPU_VENDOR="nvidia"; GPU_VENDOR_FORCED=1; shift ;;
      --kubernetes|--helm)  print_kubernetes_help; exit 0 ;;
      -h|--help)            usage; exit 0 ;;
      *)
        log_fail "Unknown flag: $1"
        usage
        exit 64
        ;;
    esac
  done
}

# ---------------------------------------------------------------------
# Distro detection (used to print apt vs dnf install hints)
# ---------------------------------------------------------------------

DISTRO_FAMILY="unknown"
DISTRO_NAME="unknown"
detect_distro() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_NAME="${ID:-unknown}"
    case "${ID:-}" in
      ubuntu|debian)         DISTRO_FAMILY="debian" ;;
      rhel|centos|rocky|almalinux|fedora|amzn)  DISTRO_FAMILY="rhel" ;;
      sles|opensuse*)        DISTRO_FAMILY="suse" ;;
      *)                     DISTRO_FAMILY="${ID_LIKE:-unknown}" ;;
    esac
  fi
}

# Per-distro install hint for a missing tool.
hint_install() {
  local pkg="$1"
  case "$DISTRO_FAMILY" in
    debian)  echo "sudo apt-get update && sudo apt-get install -y ${pkg}" ;;
    rhel)    echo "sudo dnf install -y ${pkg} || sudo yum install -y ${pkg}" ;;
    suse)    echo "sudo zypper install -y ${pkg}" ;;
    *)       echo "Install ${pkg} via your distro's package manager." ;;
  esac
}

# ---------------------------------------------------------------------
# Preflight checks (Section A)
# ---------------------------------------------------------------------

PREFLIGHT_FAILED=0

fail_check() {
  PREFLIGHT_FAILED=$((PREFLIGHT_FAILED + 1))
}

check_os() {
  if [ "$(uname -s)" != "Linux" ]; then
    log_fail "Operating system: $(uname -s) — Lifeboat runs on Linux only"
    log_hint "Use a Linux host with NVIDIA GPUs (Ubuntu 22.04+, RHEL 9+, etc.)"
    fail_check
    return
  fi
  log_ok "Operating system: Linux ($DISTRO_NAME)"
}

# ---------------------------------------------------------------------
# Edge / small-device detection. MUST run before detect_gpu_vendor.
#
# THE BUG THIS FIXES, measured on a Jetson Orin Nano (JetPack 6):
# `nvidia-smi -L` SUCCEEDS on a Jetson, so vendor detection called it NVIDIA
# and headed for the 17 GB CUDA container -- on a 7 GB device. It never got
# that far: the driver reads 540.4.0 against this script's 580.65.06 floor,
# so preflight FAILED and told the operator to upgrade an NVIDIA driver. On
# JetPack the driver ships inside L4T and is not upgradable that way, so the
# advice is impossible to follow.
#
# A dead end on hardware Lifeboat serves perfectly well -- the same machine
# measured 47 tok/s through the pip package. Tegra is checked FIRST because
# every signal the NVIDIA branch keys on is present and misleading.
#
# EDGE_CLASS is advisory: it changes what we RECOMMEND, never what an
# explicit --nvidia/--amd/--lite does.
# ---------------------------------------------------------------------
EDGE_CLASS=""
EDGE_REASON=""

detect_edge_profile() {
  local model="" ram_gb=0 cores=0
  [ -r /proc/device-tree/model ] && model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
  ram_gb="$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)"
  cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"

  if [ -f /etc/nv_tegra_release ] || printf '%s' "$model" | grep -qiE 'jetson|tegra'; then
    EDGE_CLASS="jetson"
    EDGE_REASON="NVIDIA Jetson (${model:-Tegra}), ${ram_gb} GB shared memory"
    return
  fi
  if printf '%s' "$model" | grep -qi 'raspberry pi'; then
    EDGE_CLASS="pi"
    EDGE_REASON="${model}, ${ram_gb} GB RAM"
    return
  fi
  # A generic small box: not enough memory for a comfortable container
  # deployment, and the multi-gigabyte images are the wrong shape for it.
  if [ "$ram_gb" -gt 0 ] && [ "$ram_gb" -le 8 ] && [ "$cores" -le 8 ]; then
    EDGE_CLASS="tiny"
    EDGE_REASON="${ram_gb} GB RAM, ${cores} cores"
  fi
}

# Print the pip route and stop. Returns 0 when it handled the install, so the
# caller can exit cleanly rather than treating an unsuitable host as a
# failure -- this machine is supported, just not by a container image.
recommend_edge_path() {
  [ -n "$EDGE_CLASS" ] || return 1
  [ -n "$GPU_VENDOR_FORCED" ] && return 1

  log_step "This looks like an edge device"
  log_ok "Detected: ${EDGE_REASON}"
  case "$EDGE_CLASS" in
    jetson)
      log_hint "Jetson reports an NVIDIA GPU, but the CUDA container image is ~17 GB"
      log_hint "and targets data-center drivers. JetPack ships its driver inside L4T,"
      log_hint "so that image is the wrong shape for this board." ;;
    pi)
      log_hint "No discrete GPU and limited memory: the container images are far"
      log_hint "larger than this board needs." ;;
    tiny)
      log_hint "Small memory and core count: the pip package is ~80 MB installed"
      log_hint "against ~720 MB for the smallest container image." ;;
  esac

  printf '\n%b\n' "${C_BOLD}Install Lifeboat with pip instead:${C_OFF}"
  cat <<'EOS'

    sudo apt install -y python3-venv        # Debian/Ubuntu/JetPack only
    python3 -m venv ~/lifeboat && ~/lifeboat/bin/pip install -U pip
    ~/lifeboat/bin/pip install 'lifeboat[hub]'
    ~/lifeboat/bin/lifeboat engine install
    ~/lifeboat/bin/lifeboat up              # console on http://127.0.0.1:8001

EOS
  log_hint "Needs Python 3.10+. Check what the board can run: lifeboat doctor"
  log_hint "Sizing and measured throughput: https://docs.iterate.ai/lifeboat/platform/performance/"
  printf '\n'
  log_hint "To install a container image here anyway: re-run with --lite"
  return 0
}

# ---------------------------------------------------------------------
# GPU vendor. Lifeboat ships TWO images and TWO compose files, because
# CUDA and ROCm cannot coexist in one image (torch is built for one or the
# other) and GPU access works completely differently: CDI devices on
# NVIDIA, /dev/kfd + /dev/dri on AMD.
#
# Detection order mirrors the control plane's own probe: an explicit flag
# wins, then a WORKING nvidia-smi, then /dev/kfd — the ROCm compute node,
# which is present exactly when ROCm can actually run something.
# ---------------------------------------------------------------------
detect_gpu_vendor() {
  # Tegra FIRST. Every NVIDIA signal below is present on a Jetson and all of
  # them are misleading there.
  if [ "$EDGE_CLASS" = "jetson" ] && [ -z "$GPU_VENDOR_FORCED" ]; then
    GPU_VENDOR="lite"
    log_ok "GPU vendor: NVIDIA Jetson — using the Lite image, not the CUDA image"
    log_hint "The CUDA image wants a data-center driver; JetPack's lives in L4T."
    log_hint "Lite offloads to the Orin GPU through Vulkan."
    return
  fi
  if [ -n "$GPU_VENDOR" ]; then
    log_ok "GPU vendor: $GPU_VENDOR (forced by flag)"
    return
  fi
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    GPU_VENDOR="nvidia"
    log_ok "GPU vendor: NVIDIA (nvidia-smi lists devices)"
    return
  fi
  if [ -e /dev/kfd ] && { command -v rocm-smi >/dev/null 2>&1 || command -v amd-smi >/dev/null 2>&1; }; then
    GPU_VENDOR="amd"
    log_ok "GPU vendor: AMD ROCm (/dev/kfd present)"
    return
  fi
  # No supported GPU. Previously this assumed NVIDIA, which on a CPU-only host
  # meant pulling a 17.5 GB CUDA image and then failing the driver preflight --
  # a confusing dead end on a machine Lifeboat can now serve perfectly well.
  # The Lite image is the correct answer for such a host, so select it.
  GPU_VENDOR="lite"
  log_ok "No data-center GPU detected — installing the Lite image"
  log_hint "Lite runs on CPU, and uses an integrated or older GPU when one is present."
  log_hint "Force a variant with --nvidia, --amd, or --lite."
}

# ---------------------------------------------------------------------
# Lite: report the accelerator situation, never fail on it.
#
# Informational by design. Lite runs on the CPU and OPTIONALLY offloads to an
# integrated or older GPU through Vulkan, so "no GPU" is a supported
# configuration rather than a missing prerequisite. The one thing worth
# telling the operator is that passing the device through is a separate,
# explicit step -- Docker refuses to start a container whose devices: entry is
# absent on the host, so the compose default is a no-op and an iGPU sits idle
# until LIFEBOAT_GPU_DEVICE is set.
# ---------------------------------------------------------------------
check_lite_accelerator() {
  local found=""
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    found="an NVIDIA GPU"
  elif [ -e /dev/kfd ]; then
    found="an AMD GPU"
  elif [ -d /dev/dri ] && ls /dev/dri/renderD* >/dev/null 2>&1; then
    found="an integrated or older GPU (/dev/dri render node)"
  fi
  if [ -n "$found" ]; then
    log_ok "Accelerator: $found detected — Lite can offload to it via Vulkan"
    log_hint "Enable it by setting in .env:  LIFEBOAT_GPU_DEVICE=/dev/dri:/dev/dri"
    log_hint "Without that the container gets no GPU device and serves on the CPU."
  else
    log_ok "Accelerator: none detected — Lite will serve on the CPU"
    log_hint "This is a supported configuration, not a missing prerequisite."
  fi
  local cores
  cores="$(nproc 2>/dev/null || echo '?')"
  log_info "CPU cores: $cores  (the hardware report sizes models for this host:"
  log_info "  curl -s localhost:${LIFEBOAT_PORT}/api/hardware/profile )"
  return 0
}

check_rocm_smi() {
  if ! command -v rocm-smi >/dev/null 2>&1 && ! command -v amd-smi >/dev/null 2>&1; then
    log_fail "rocm-smi/amd-smi: not found — ROCm is not installed"
    log_hint "Install ROCm >= 6.3 for your distro: https://rocm.docs.amd.com/"
    fail_check
    return 1
  fi
  log_ok "ROCm tools: present at $(command -v amd-smi 2>/dev/null || command -v rocm-smi)"
  return 0
}

check_rocm_devices() {
  # /dev/kfd is the compute node; /dev/dri/renderD* are the per-GPU render
  # nodes. BOTH are passed into the container, and the container's
  # unprivileged user must be able to open them — hence the group check.
  if [ ! -e /dev/kfd ]; then
    log_fail "/dev/kfd: missing — the amdgpu kernel driver is not loaded"
    log_hint "Check 'lsmod | grep amdgpu' and that this host has an AMD GPU."
    fail_check
    return
  fi
  log_ok "/dev/kfd: present"
  if ! ls /dev/dri/renderD* >/dev/null 2>&1; then
    log_fail "/dev/dri/renderD*: missing — no render node for the GPU"
    fail_check
    return
  fi
  log_ok "/dev/dri: render node(s) present"

  # World-accessible device nodes are common on ROCm hosts; when they are
  # not, group membership is what makes the container work.
  if [ ! -r /dev/kfd ] || [ ! -w /dev/kfd ]; then
    if id -nG 2>/dev/null | tr " " "\n" | grep -qxE "video|render"; then
      log_ok "device access: via video/render group membership"
    else
      log_warn "device access: /dev/kfd is not world-accessible and you are not in video/render"
      log_hint "sudo usermod -aG video,render \$USER   (then log out and back in)"
    fi
  else
    log_ok "device access: /dev/kfd is world-accessible"
  fi
}

check_amd_gpu_count_and_vram() {
  local count vram_mb
  if command -v amd-smi >/dev/null 2>&1; then
    count="$(amd-smi list --csv 2>/dev/null | grep -c "^[0-9]" || echo 0)"
  else
    count="$(rocm-smi --showid 2>/dev/null | grep -cE "^GPU\[[0-9]+\]" || echo 0)"
  fi
  if [ "${count:-0}" -lt 1 ]; then
    log_warn "GPU count: could not determine from ROCm tools"
    log_hint "Run 'rocm-smi' by hand — if it lists no devices, the driver is not seeing the GPU."
    return
  fi
  log_ok "GPU count: $count"
  vram_mb="$(rocm-smi --showmeminfo vram 2>/dev/null | grep -oE "VRAM Total Memory \(B\): [0-9]+" | head -1 | grep -oE "[0-9]+$")"
  if [ -n "$vram_mb" ]; then
    local vram_gb=$(( vram_mb / 1024 / 1024 / 1024 ))
    if [ "$vram_gb" -lt "$MIN_GPU_VRAM_GB" ]; then
      log_fail "GPU VRAM: ${vram_gb} GB — need >= ${MIN_GPU_VRAM_GB} GB"
      fail_check
      return
    fi
    log_ok "GPU VRAM: ${vram_gb} GB"
  fi
}

check_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      log_ok "CPU architecture: x86_64"
      ;;
    aarch64|arm64)
      # arm64 IS supported on NVIDIA — the CUDA image is a multi-arch
      # manifest list covering GB10 / DGX Spark, GH200 and Grace. It is NOT
      # supported on AMD, and that is upstream's constraint: the ROCm base
      # images are amd64-only and PyTorch publishes no aarch64 ROCm wheels.
      if [ "$GPU_VENDOR" = "lite" ]; then
        log_ok "CPU architecture: $arch (Lite is published for amd64 and arm64)"
        return
      fi
      if [ "$GPU_VENDOR" = "amd" ]; then
        log_fail "CPU architecture: $arch — the AMD/ROCm image is x86_64 only"
        log_hint "ROCm has no arm64 build: the base images are amd64-only and there are no aarch64 ROCm PyTorch wheels."
        fail_check
        return
      fi
      log_ok "CPU architecture: $arch (NVIDIA arm64 — GB10 / GH200 / Grace)"
      ;;
    *)
      log_fail "CPU architecture: $arch — not supported"
      log_hint "Use x86_64, or arm64 on an NVIDIA Grace-class host."
      fail_check
      return
      ;;
  esac
}

check_nvidia_smi() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    log_fail "nvidia-smi: not found — NVIDIA driver is not installed"
    log_hint "Install the NVIDIA driver (>= ${MIN_DRIVER_MAJOR}.x) for your distro."
    log_hint "Ubuntu/Debian: $(hint_install nvidia-driver-580)"
    log_hint "RHEL/Rocky:    follow https://docs.nvidia.com/datacenter/tesla/tesla-installation-notes/"
    fail_check
    return 1
  fi
  log_ok "nvidia-smi: present at $(command -v nvidia-smi)"
  return 0
}

check_nvidia_driver_version() {
  local driver
  if ! driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"; then
    log_fail "nvidia-smi: present but failed to query driver version"
    log_hint "Try 'sudo nvidia-smi' or reboot the host."
    fail_check
    return
  fi
  local major
  major="${driver%%.*}"
  if [ "$major" -lt "$MIN_DRIVER_MAJOR" ]; then
    log_fail "NVIDIA driver: ${driver} — need >= ${MIN_DRIVER_MAJOR}.x"
    log_hint "The image ships the CUDA 13 runtime (torch cu130); NVIDIA's"
    log_hint "documented minimum for it is 580.65.06."
    fail_check
    return
  fi
  log_ok "NVIDIA driver: ${driver}"
}

check_gpu_count_and_vram() {
  local count vram_csv
  count="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${count:-0}" -lt 1 ]; then
    log_fail "GPU count: 0 — nvidia-smi runs but no devices are visible"
    log_hint "Check that the kernel module is loaded ('lsmod | grep nvidia') and the host has at least one GPU."
    fail_check
    return
  fi
  # nvidia-smi reports memory in MiB. Convert to GB for the threshold check.
  #
  # UNIFIED MEMORY: on GB10 / DGX Spark / Grace-Hopper the GPU has no discrete
  # VRAM — it shares system LPDDR — and nvidia-smi prints `[N/A]` here. Parsed
  # naively that is a shell error ("integer expression expected") followed by
  # "0 GB", and the installer then REFUSES to install on hardware Lifeboat
  # explicitly supports and ships arm64 images for. Same `[N/A]` discipline the
  # control plane applies: treat it as "ask /proc/meminfo instead", never as 0.
  vram_csv="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null)"
  local biggest_mib=0 saw_na="false"
  while IFS= read -r line; do
    line="$(echo "$line" | tr -d ' ')"
    [ -z "$line" ] && continue
    case "$line" in
      *[!0-9]*) saw_na="true"; continue ;;   # [N/A], [Not Supported], etc.
    esac
    if [ "$line" -gt "$biggest_mib" ]; then biggest_mib="$line"; fi
  done <<< "$vram_csv"

  if [ "$biggest_mib" -eq 0 ] && [ "$saw_na" = "true" ]; then
    local mem_kb
    mem_kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
    if [ -n "$mem_kb" ]; then
      biggest_mib=$(( mem_kb / 1024 ))
      log_ok "GPU memory: unified with system RAM (nvidia-smi reports [N/A]) — using MemTotal"
    fi
  fi

  local biggest_gb=$(( biggest_mib / 1024 ))
  if [ "$biggest_gb" -lt "$MIN_GPU_VRAM_GB" ]; then
    log_fail "GPU VRAM: largest GPU has ${biggest_gb} GB — need >= ${MIN_GPU_VRAM_GB} GB to host a useful model"
    log_hint "Lifeboat will run, but even small models (Qwen2.5-0.5B) need ~2 GB and most production models need >= 16 GB."
    log_hint "If you really do have <8 GB, override with: MIN_GPU_VRAM_GB=4 $(basename "$0")"
    fail_check
    return
  fi
  log_ok "GPUs: ${count} (largest: ${biggest_gb} GB VRAM)"
}

check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log_fail "docker: not installed"
    log_hint "Install Docker Engine >= ${MIN_DOCKER_MAJOR}.0 from https://docs.docker.com/engine/install/"
    fail_check
    return 1
  fi
  local docker_v docker_major
  docker_v="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
  if [ -z "$docker_v" ]; then
    log_fail "docker: installed but daemon is not reachable"
    log_hint "Start the daemon: sudo systemctl start docker"
    log_hint "Or add your user to the docker group: sudo usermod -aG docker \$USER && newgrp docker"
    fail_check
    return 1
  fi
  docker_major="${docker_v%%.*}"
  if [ "$docker_major" -lt "$MIN_DOCKER_MAJOR" ]; then
    log_fail "Docker Engine: ${docker_v} — need >= ${MIN_DOCKER_MAJOR}.0 (for native CDI device support)"
    log_hint "Upgrade Docker: https://docs.docker.com/engine/install/"
    fail_check
    return 1
  fi
  log_ok "Docker Engine: ${docker_v}"
  return 0
}

check_docker_compose() {
  local cv major minor
  if ! cv="$(docker compose version --short 2>/dev/null)"; then
    log_fail "Docker Compose v2: not available"
    log_hint "Install the compose plugin: $(hint_install docker-compose-plugin)"
    fail_check
    return
  fi
  major="${cv%%.*}"; minor="${cv#*.}"; minor="${minor%%.*}"
  if [ "$major" -lt "$MIN_COMPOSE_MAJOR" ] \
     || { [ "$major" -eq "$MIN_COMPOSE_MAJOR" ] && [ "$minor" -lt "$MIN_COMPOSE_MINOR" ]; }; then
    log_fail "Docker Compose: ${cv} — need >= ${MIN_COMPOSE_MAJOR}.${MIN_COMPOSE_MINOR}"
    log_hint "Upgrade the compose plugin: $(hint_install docker-compose-plugin)"
    fail_check
    return
  fi
  log_ok "Docker Compose: ${cv}"
}

check_nvidia_container_toolkit() {
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    log_fail "nvidia-container-toolkit: not installed (nvidia-ctk not on PATH)"
    log_hint "Install the toolkit: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
    log_hint "Ubuntu/Debian quick path: $(hint_install nvidia-container-toolkit)"
    fail_check
    return
  fi
  log_ok "nvidia-container-toolkit: $(nvidia-ctk --version 2>/dev/null | head -1 | awk '{print $NF}')"
}

# Can this host actually FETCH the image? Preflight it, because the failure
# otherwise arrives from `docker compose up -d` as a bare
#     Error response from daemon: pull access denied for iterateai/lifeboat
# after the installer has already written .env and reported success on every
# other check — which reads as "the installer worked, Docker is broken".
#
# Two distinct causes produce the same daemon error, and the fix differs:
#   * the repository requires authentication  -> `docker login` with the PAT
#     from the welcome email;
#   * the tag does not exist for this vendor  -> wrong tag (e.g. `:latest` on
#     an AMD host, which is the NVIDIA image).
# So the check reports which one it is. Anonymous registry auth is used
# deliberately: it answers "could a customer with no credentials pull this?",
# which is the question the install docs assume the answer to is yes.
#
# Never fatal on a network problem — a proxy or an air-gapped mirror is a
# legitimate deployment, and an installer that refuses to proceed because it
# could not reach Docker Hub is worse than one that lets the pull speak.
check_image_pullable() {
  local tag="$1" tok code
  if ! command -v curl >/dev/null 2>&1; then
    log_warn "Image reachability: skipped (curl not available)"
    return
  fi
  tok="$(curl -fsSL --max-time 20 \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${IMAGE_REPO}:pull" \
    2>/dev/null | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
  if [ -z "$tok" ]; then
    log_warn "Image reachability: could not reach Docker Hub auth (offline or proxied?)"
    log_hint "Not fatal. If the pull fails, check egress to auth.docker.io and registry-1.docker.io."
    return
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 \
    -H "Authorization: Bearer ${tok}" \
    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
    "https://registry-1.docker.io/v2/${IMAGE_REPO}/manifests/${tag}" 2>/dev/null)"
  case "$code" in
    200)
      log_ok "Image reachable: ${IMAGE_REPO}:${tag}"
      ;;
    401|403)
      if docker image inspect "${IMAGE_REPO}:${tag}" >/dev/null 2>&1; then
        log_warn "Image ${IMAGE_REPO}:${tag} needs authentication, but a local copy is present"
        log_hint "The install will use the local image. To pull updates later, run: docker login"
        return
      fi
      log_fail "Image ${IMAGE_REPO}:${tag}: authentication required (HTTP ${code})"
      log_hint "Run: docker login    (your Docker Hub credentials for ${IMAGE_REPO})"
      log_hint "Then re-run this installer. Nothing has been downloaded yet."
      log_hint "No credentials? Contact support@iterate.ai quoting your license key."
      fail_check
      ;;
    404)
      log_fail "Image ${IMAGE_REPO}:${tag}: no such tag (HTTP 404)"
      if [ "$GPU_VENDOR" = "amd" ]; then
        log_hint "AMD hosts use :latest-rocm — :latest is the NVIDIA image."
      elif [ "$GPU_VENDOR" = "lite" ]; then
        log_hint "Lite hosts use :lite — :latest is the NVIDIA accelerator image."
      fi
      log_hint "See https://hub.docker.com/r/${IMAGE_REPO}/tags for published tags."
      fail_check
      ;;
    *)
      log_warn "Image reachability: inconclusive (HTTP ${code:-none})"
      log_hint "Not fatal — the pull itself will report the real error."
      ;;
  esac
}

check_docker_access() {
  if ! docker info >/dev/null 2>&1; then
    log_fail "docker info: failed (permission or daemon issue)"
    log_hint "Run: sudo usermod -aG docker \$USER && newgrp docker"
    log_hint "Or re-run this installer with sudo."
    fail_check
    return
  fi
  log_ok "Docker socket: reachable as $(id -un)"
}

check_systemd() {
  # Not strictly required — only matters if customer wants the
  # nvidia-cdi-refresh systemd oneshot from install-host-deps.sh.
  if [ ! -d /run/systemd/system ]; then
    log_warn "systemd: not the active init — install-host-deps.sh won't install the boot-refresh oneshot"
    log_hint "Lifeboat will still run; just regenerate /etc/cdi/nvidia.yaml manually after driver upgrades."
  fi
}

# Informational only: detect whether this host is a confidential-VM
# guest (AMD SEV-SNP / Intel TDX) with the NVIDIA GPU in CC mode. Never
# fails preflight — Lifeboat runs fine on a normal host; this just lets
# the installer write LIFEBOAT_CONFIDENTIAL_COMPUTING=auto explicitly and
# tell the operator the TEE was detected.
check_confidential_computing() {
  # GPU confidential computing needs an NVIDIA CC-mode GPU inside a CVM.
  # On AMD it cannot exist, and the control plane auto-disables it — so say
  # that instead of probing for a TEE the GPU could never join. Note the
  # trap: an EPYC SEV-SNP host satisfies the CPU half, which is NOT enough.
  if [ "$GPU_VENDOR" = "lite" ]; then
    log_info "Confidential computing: not applicable to the Lite image (no GPU CC path)"
    CC_HOST_SUPPORTED="false"
    return 0
  fi
  if [ "$GPU_VENDOR" = "amd" ]; then
    log_info "Confidential computing: not available on AMD GPUs (auto-disabled by Lifeboat)"
    log_hint "GPU CC requires an NVIDIA CC-mode GPU in a CVM; an EPYC SEV-SNP CPU alone is not sufficient."
    CC_HOST_SUPPORTED="false"
    return 0
  fi
  local cpu_tee="" gpu_cc=""
  if [ -e /dev/sev-guest ]; then cpu_tee="SEV-SNP"
  elif [ -e /dev/tdx_guest ]; then cpu_tee="TDX"; fi
  if command -v nvidia-smi >/dev/null 2>&1; then
    local cc_out
    cc_out="$(nvidia-smi conf-compute -f 2>/dev/null || true)"
    if echo "$cc_out" | grep -qiE 'CC status\s*:?\s*(ON|DevTools)'; then
      gpu_cc="on"
    fi
  fi
  if [ -n "$cpu_tee" ] && [ -n "$gpu_cc" ]; then
    CC_HOST_SUPPORTED="true"
    log_ok "Confidential computing: host is a ${cpu_tee} TEE with GPU CC mode ON"
    log_hint "Lifeboat will enable confidential computing (attestation) automatically."
  elif [ -n "$cpu_tee" ] || [ -n "$gpu_cc" ]; then
    log_warn "Confidential computing: partially configured (cpu='${cpu_tee:-none}', gpu_cc='${gpu_cc:-off}') — not a full TEE"
    log_hint "Need BOTH a confidential VM (SEV-SNP/TDX) AND the GPU in CC mode. Lifeboat will still run."
  else
    log_ok "Confidential computing: host is not a TEE (normal host) — feature stays dormant"
  fi
}

run_preflight() {
  log_step "Preflight checks"
  detect_distro
  detect_edge_profile
  detect_gpu_vendor
  check_os
  check_arch
  if [ "$GPU_VENDOR" = "amd" ]; then
    # ROCm needs no container toolkit and no CDI spec: the GPU arrives as
    # ordinary device nodes, which removes a whole class of first-boot
    # failure compared with the NVIDIA path.
    if check_rocm_smi; then
      check_rocm_devices
      check_amd_gpu_count_and_vram
    fi
  elif [ "$GPU_VENDOR" = "lite" ]; then
    # Lite requires NO accelerator, so this reports what it finds and NEVER
    # fails. Routing it into the NVIDIA branch was the bug: check_nvidia_smi
    # calls fail_check when nvidia-smi is absent, so a CPU-only host -- the
    # exact host Lite exists for -- failed preflight with "NVIDIA driver is
    # not installed" and was told to install one. A dead end on a machine
    # Lifeboat serves perfectly well, and the second half of the same defect
    # as the old "assume NVIDIA" fallback.
    check_lite_accelerator
  else
    if check_nvidia_smi; then
      check_nvidia_driver_version
      check_gpu_count_and_vram
    fi
  fi
  if check_docker; then
    check_docker_access
    check_docker_compose
    case "$GPU_VENDOR" in
      amd)  check_image_pullable "$IMAGE_TAG_AMD" ;;
      lite) check_image_pullable "$IMAGE_TAG_LITE" ;;
      *)    check_image_pullable "$IMAGE_TAG_NVIDIA" ;;
    esac
  fi
  # Keyed on nvidia, NOT on "not amd": Lite needs no container toolkit, no CDI
  # spec and no driver, so demanding them would fail a host it supports.
  if [ "$GPU_VENDOR" = "nvidia" ]; then
    check_nvidia_container_toolkit
  fi
  check_confidential_computing
  check_systemd

  echo
  if [ "$PREFLIGHT_FAILED" -gt 0 ]; then
    log_fail "$PREFLIGHT_FAILED preflight check(s) failed. Fix the issues above and re-run."
    return 1
  fi
  log_ok "All preflight checks passed."
  return 0
}

# ---------------------------------------------------------------------
# Install (Section B)
# ---------------------------------------------------------------------

generate_password() {
  # 24-char random password, alphanumeric + a couple of safe specials.
  # Avoid characters that need quoting (' " \ $ ` /) so .env parsing
  # and docker exec output stay clean.
  LC_ALL=C tr -dc 'A-Za-z0-9!@#%^*+=_-' </dev/urandom | head -c 24
}

prompt_or_default() {
  local prompt="$1" default_val="$2" out
  if [ "$DO_INTERACTIVE" = "false" ]; then
    echo "$default_val"
    return
  fi
  printf '  %s [%s]: ' "$prompt" "$default_val" > /dev/tty
  read -r out < /dev/tty
  echo "${out:-$default_val}"
}

prompt_secret() {
  local prompt="$1" out
  printf '  %s (leave blank to auto-generate): ' "$prompt" > /dev/tty
  stty -echo < /dev/tty
  read -r out < /dev/tty
  stty echo < /dev/tty
  printf '\n' > /dev/tty
  echo "$out"
}

resolve_admin_email() {
  if [ -n "$ADMIN_EMAIL" ]; then return; fi
  if [ "$DO_INTERACTIVE" = "true" ]; then
    ADMIN_EMAIL="$(prompt_or_default 'Admin email' "$LIFEBOAT_ADMIN_EMAIL_DEFAULT")"
  else
    ADMIN_EMAIL="$LIFEBOAT_ADMIN_EMAIL_DEFAULT"
  fi
}

ADMIN_PASSWORD_GENERATED="false"
resolve_admin_password() {
  if [ -n "$ADMIN_PASSWORD" ]; then return; fi
  if [ "$DO_INTERACTIVE" = "true" ]; then
    ADMIN_PASSWORD="$(prompt_secret 'Admin password')"
  fi
  if [ -z "$ADMIN_PASSWORD" ]; then
    ADMIN_PASSWORD="$(generate_password)"
    ADMIN_PASSWORD_GENERATED="true"
  fi
}

resolve_models_dir() {
  if [ -n "$MODELS_DIR" ]; then return; fi
  if [ "$DO_INTERACTIVE" = "true" ]; then
    MODELS_DIR="$(prompt_or_default 'Host directory to mount at /models' "$LIFEBOAT_MODELS_DIR_DEFAULT")"
  else
    MODELS_DIR="$LIFEBOAT_MODELS_DIR_DEFAULT"
  fi
}

download_compose_files() {
  log_step "Downloading docker-compose.yaml and .env.example from ${LIFEBOAT_RAW_BASE}"
  mkdir -p "$LIFEBOAT_INSTALL_DIR"
  cd "$LIFEBOAT_INSTALL_DIR"

  if [ -e docker-compose.yaml ] && [ "$DO_INTERACTIVE" = "true" ]; then
    log_warn "docker-compose.yaml already exists in $LIFEBOAT_INSTALL_DIR"
    printf '  Overwrite? [y/N]: ' > /dev/tty
    local ans; read -r ans < /dev/tty
    case "$ans" in y|Y|yes|YES) ;; *) log_info "Keeping existing docker-compose.yaml"; return ;; esac
  fi

  # AMD and NVIDIA need DIFFERENT compose files — not different values in
  # one file. GPU access is CDI device requests on NVIDIA versus /dev/kfd +
  # /dev/dri on AMD, the AMD file needs `ipc: host` (without it the engine
  # dies at its first GPU allocation), and there is no host-setup service
  # to run. The ROCm file is saved AS docker-compose.yaml so every later
  # `docker compose` command in this script and in the customer's runbook
  # works unchanged.
  if [ "$GPU_VENDOR" = "lite" ]; then
    curl -fsSL -o docker-compose.yaml "${LIFEBOAT_RAW_BASE}/docker-compose.cpu.yaml"
    log_ok "Using the Lite compose file (saved as docker-compose.yaml)"
  elif [ "$GPU_VENDOR" = "amd" ]; then
    curl -fsSL -o docker-compose.yaml "${LIFEBOAT_RAW_BASE}/docker-compose.rocm.yaml"
    log_ok "Using the AMD/ROCm compose file (saved as docker-compose.yaml)"
  else
    curl -fsSL -o docker-compose.yaml "${LIFEBOAT_RAW_BASE}/docker-compose.yaml"
  fi
  curl -fsSL -o .env.example "${LIFEBOAT_RAW_BASE}/.env.example"
  log_ok "Files in $LIFEBOAT_INSTALL_DIR/"
}

write_env_file() {
  log_step "Writing .env"
  # Build .env from .env.example, replacing the admin block. Keep all
  # other defaults intact so the customer can tune later.
  local env_path="$LIFEBOAT_INSTALL_DIR/.env"
  cp "$LIFEBOAT_INSTALL_DIR/.env.example" "$env_path"

  # Use sed -i with a portable backup suffix (GNU and BSD compatible)
  # to set the admin creds. The .env.example uses LIFEBOAT_ADMIN_EMAIL
  # and LIFEBOAT_ADMIN_PASSWORD keys.
  # Resolve the effective confidential-computing mode: an explicit
  # --confidential-computing wins; otherwise auto-enable (write it
  # explicitly) when preflight detected a TEE; else leave the .env.example
  # default commented so the in-code default ('auto') governs.
  local cc_mode="$CONFIDENTIAL_COMPUTING"
  if [ -z "$cc_mode" ] && [ "$CC_HOST_SUPPORTED" = "true" ]; then
    cc_mode="auto"
  fi

  local tmp_env="${env_path}.tmp"
  awk -v email="$ADMIN_EMAIL" \
      -v pwd="$ADMIN_PASSWORD" \
      -v models="$MODELS_DIR" \
      -v port="$LIFEBOAT_PORT" \
      -v cc="$cc_mode" \
      -v vendor="$GPU_VENDOR" '
    BEGIN { saw_email=0; saw_pwd=0; saw_models=0; saw_port=0; saw_cc=0; saw_vendor=0 }
    # Pin the accelerator. Detection works on its own (it keys on /dev/kfd),
    # but pinning makes a broken devices: mapping fail as "AMD expected,
    # none visible" instead of quietly reporting a CPU-only host.
    /^[#[:space:]]*LIFEBOAT_GPU_VENDOR=/ {
      # amd is pinned so a misconfigured devices: fails loudly as "AMD GPU
      # expected, none visible" rather than silently reporting a CPU host.
      # lite is deliberately NOT pinned: it is the one variant that runs
      # CPU-only OR on an integrated GPU, and detection is what chooses.
      if (vendor == "amd") { print "LIFEBOAT_GPU_VENDOR=amd"; saw_vendor=1 } else { print }
      next
    }
    /^[#[:space:]]*LIFEBOAT_ADMIN_EMAIL=/      { print "LIFEBOAT_ADMIN_EMAIL=" email; saw_email=1; next }
    /^[#[:space:]]*LIFEBOAT_ADMIN_PASSWORD=/   { print "LIFEBOAT_ADMIN_PASSWORD=" pwd;  saw_pwd=1;   next }
    /^[#[:space:]]*MODELS_DIR=/                { print "MODELS_DIR=" models;            saw_models=1; next }
    /^[#[:space:]]*LIFEBOAT_CONTROL_PORT=/     { print "LIFEBOAT_CONTROL_PORT=" port;   saw_port=1;  next }
    /^[#[:space:]]*LIFEBOAT_CONFIDENTIAL_COMPUTING=/ {
      if (cc != "") { print "LIFEBOAT_CONFIDENTIAL_COMPUTING=" cc; saw_cc=1 } else { print }
      next
    }
    { print }
    END {
      if (!saw_email)  print "LIFEBOAT_ADMIN_EMAIL=" email
      if (!saw_pwd)    print "LIFEBOAT_ADMIN_PASSWORD=" pwd
      if (!saw_models) print "MODELS_DIR=" models
      if (!saw_port)   print "LIFEBOAT_CONTROL_PORT=" port
      if (!saw_cc && cc != "") print "LIFEBOAT_CONFIDENTIAL_COMPUTING=" cc
      if (!saw_vendor && vendor == "amd") print "LIFEBOAT_GPU_VENDOR=amd"
    }
  ' "$env_path" > "$tmp_env"
  mv "$tmp_env" "$env_path"
  chmod 600 "$env_path"   # contains the admin password
  log_ok ".env written ($env_path, 0600)"
  log_ok "Models dir: $MODELS_DIR"
  if [ ! -d "$MODELS_DIR" ]; then
    log_info "Creating $MODELS_DIR (it didn't exist)"
    sudo mkdir -p "$MODELS_DIR"
    sudo chmod 0755 "$MODELS_DIR"
  fi
}

compose_up() {
  log_step "Starting Lifeboat (docker compose up -d)"
  cd "$LIFEBOAT_INSTALL_DIR"
  # The compose file has a one-shot host-setup service that needs to
  # run before the main control-plane container. compose up handles
  # the dependency ordering via depends_on.condition: service_completed_successfully.
  if [ "$GPU_VENDOR" = "lite" ] || [ "$GPU_VENDOR" = "amd" ]; then
    # Neither the Lite nor the ROCm compose file has a host-setup service --
    # there is no CDI spec to generate -- so --skip-host-setup is moot here.
    docker compose up -d
  elif [ "$SKIP_HOST_SETUP" = "true" ]; then
    log_info "Skipping host-setup service per --skip-host-setup"
    docker compose --profile main up -d 2>/dev/null \
      || docker compose up -d --scale host-setup=0
  else
    docker compose up -d
  fi
  log_ok "Compose stack started"
}

wait_for_up() {
  log_step "Waiting for control plane to become healthy"
  local url="http://localhost:${LIFEBOAT_PORT}/api/version"
  local deadline=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
      log_ok "Control plane is up: ${url}"
      return 0
    fi
    sleep 2
  done
  log_fail "Control plane did not return 200 on $url within 120 s"
  log_hint "Inspect logs: (cd $LIFEBOAT_INSTALL_DIR && docker compose logs --tail=200)"
  return 1
}

grant_models_dir_access() {
  # The container runs as a non-root 'lifeboat' user (useradd -r, so the
  # UID is assigned dynamically and isn't knowable until the image runs).
  # The host models dir was created root-owned above, so the container
  # can't create download subdirectories in it — model downloads fail with
  # "[Errno 13] Permission denied: '/models/...'". Match host ownership to
  # the container's UID now that it's running.
  log_step "Granting the container write access to $MODELS_DIR"
  cd "$LIFEBOAT_INSTALL_DIR"
  local cid uid gid
  cid="$(docker compose ps -q lifeboat 2>/dev/null | head -n1)"
  if [ -z "$cid" ]; then
    log_warn "Couldn't resolve the lifeboat container; skipping models-dir chown"
    log_hint "If downloads fail with 'Permission denied: /models/...', run:"
    log_hint "sudo chown -R \$(docker exec lifeboat id -u):\$(docker exec lifeboat id -g) $MODELS_DIR"
    return 0
  fi
  uid="$(docker exec "$cid" id -u 2>/dev/null || true)"
  gid="$(docker exec "$cid" id -g 2>/dev/null || true)"
  if [ -n "$uid" ] && [ -n "$gid" ]; then
    sudo chown -R "$uid:$gid" "$MODELS_DIR" \
      && log_ok "chown $uid:$gid $MODELS_DIR" \
      || log_warn "chown of $MODELS_DIR failed — fix manually if downloads 403"
  else
    log_warn "Couldn't read container UID; skipping models-dir chown"
  fi
}

activate_license() {
  [ -z "$LICENSE_KEY" ] && return 0
  log_step "Activating license"
  local url="http://localhost:${LIFEBOAT_PORT}/api/license/activate"
  local body http_code resp_body
  body="$(printf '{"license_key":"%s"}' "$LICENSE_KEY")"
  # Capture HTTP status + body in one shot.
  resp_body="$(mktemp)"
  http_code="$(curl -sS -o "$resp_body" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -X POST "$url" -d "$body" || echo "000")"
  if [ "$http_code" = "200" ]; then
    local edition
    edition="$(grep -o '"edition":"[^"]*"' "$resp_body" | head -1 | cut -d'"' -f4)"
    log_ok "License activated (edition: ${edition:-unknown})"
    LICENSE_ACTIVATED="true"
    rm -f "$resp_body"
    return 0
  fi
  log_fail "License activation failed (HTTP $http_code)"
  log_hint "Server response:"
  sed 's/^/      /' "$resp_body" || true
  log_hint "You can activate manually from the UI: http://localhost:${LIFEBOAT_PORT}/#/license"
  rm -f "$resp_body"
  return 1
}

print_summary() {
  if [ "$GPU_VENDOR" = "lite" ]; then
    echo
    log_info "Lite deployment notes:"
    log_info "  Image:   iterateai/lifeboat:lite  (NOT :latest — that is the 17.5 GB GPU image)"
    log_info "  Report:  curl -s localhost:${LIFEBOAT_PORT}/api/hardware/profile   (what this host can run)"
    log_info "  GPU:     to use an integrated or older GPU, set in .env:"
    log_info "             LIFEBOAT_GPU_DEVICE=/dev/dri:/dev/dri"
    log_info "           then: docker compose up -d"
    log_info "  Models:  quantized GGUF. On an 8 GB host, 1.5B-4B is comfortable and 8B is"
    log_info "           the ceiling; 14B does not fit. The hardware report sizes it for you."
    log_info "  Absent by design, not omission: this image has no tensor engine, so the"
    log_info "           lifeboat_* optimization suite does not apply. The load balancer,"
    log_info "           routing modes, API surface, licensing and audit all work unchanged."
    log_info "  Expect time-to-first-token, rather than generation speed, to dominate on a"
    log_info "           low-core host — smaller models improve it disproportionately."
    echo
  fi
  if [ "$GPU_VENDOR" = "amd" ]; then
    echo
    log_info "AMD / ROCm deployment notes:"
    log_info "  Image:   iterateai/lifeboat:latest-rocm  (NOT :latest — that is the NVIDIA image)"
    log_info "  Verify:  docker compose exec lifeboat rocm-smi"
    log_info "  Absent by hardware, not by omission: FP8 KV cache needs CDNA3+ (MI300X),"
    log_info "           FP4 needs CDNA4 (MI350), and GPU confidential computing does not"
    log_info "           exist on AMD (auto-disabled — an EPYC SEV-SNP CPU is only half of it)."
    echo
  fi
  local url="http://localhost:${LIFEBOAT_PORT}"
  printf '\n%b\n' "${C_GREEN}${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_OFF}"
  printf '%b\n' "${C_GREEN}${C_BOLD}║  Lifeboat is up and running${C_OFF}"
  printf '%b\n' "${C_GREEN}${C_BOLD}╠══════════════════════════════════════════════════════════════╣${C_OFF}"
  printf '%b\n' "  URL:        ${C_BOLD}${url}${C_OFF}"
  printf '%b\n' "  Admin user: ${C_BOLD}${ADMIN_EMAIL}${C_OFF}"
  if [ "$ADMIN_PASSWORD_GENERATED" = "true" ]; then
    printf '%b\n' "  Password:   ${C_BOLD}${ADMIN_PASSWORD}${C_OFF}  ${C_YELLOW}(generated — change on first login)${C_OFF}"
  else
    printf '%b\n' "  Password:   ${C_DIM}(the one you set; not echoed)${C_OFF}"
  fi
  printf '%b\n' "  Install dir: ${C_BOLD}${LIFEBOAT_INSTALL_DIR}${C_OFF}"
  if [ "$LICENSE_ACTIVATED" = "true" ]; then
    printf '%b\n' "  License:    ${C_BOLD}activated${C_OFF}"
  elif [ -n "$LICENSE_KEY" ]; then
    printf '%b\n' "  License:    ${C_RED}activation FAILED${C_OFF} — see the error above; activate at ${url}/#/license"
  else
    printf '%b\n' "  License:    ${C_YELLOW}24h grace${C_OFF} — activate at ${url}/#/license before it expires"
    printf '%b\n' "              ${C_DIM}Buying an OFFLINE (air-gapped) license? Copy the Cluster ID${C_OFF}"
    printf '%b\n' "              ${C_DIM}from that page, then enter it at checkout - the signed .lic${C_OFF}"
    printf '%b\n' "              ${C_DIM}you get back is bound to it. Upload it on the same page.${C_OFF}"
  fi
  printf '%b\n' "${C_GREEN}${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_OFF}"
  printf '\n%b\n' "Next steps:"
  printf '  • Open %s in a browser and log in.\n' "$url"
  printf '  • Add a model: Models page → \"Download from HuggingFace\".\n'
  printf '  • Inspect logs: (cd %s && docker compose logs -f).\n' "$LIFEBOAT_INSTALL_DIR"
  printf '  • Upgrade later: (cd %s && docker compose pull && docker compose up -d).\n' "$LIFEBOAT_INSTALL_DIR"
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------

main() {
  parse_args "$@"

  # An edge device is offered the pip route BEFORE preflight, because
  # preflight is where a Jetson used to die on a driver check it can never
  # satisfy. Returns 0 only when it printed guidance and the operator forced
  # nothing, in which case there is nothing left for this script to do.
  detect_edge_profile
  if recommend_edge_path; then
    exit 0
  fi

  if ! run_preflight; then
    exit 2
  fi

  if [ "$DO_CHECK_ONLY" = "true" ]; then
    log_info "Preflight only (--check). Not installing."
    exit 0
  fi

  log_step "Install settings"
  resolve_admin_email
  resolve_admin_password
  resolve_models_dir
  log_ok "Admin email:    ${ADMIN_EMAIL}"
  if [ "$ADMIN_PASSWORD_GENERATED" = "true" ]; then
    log_ok "Admin password: (generated; shown in the final summary)"
  else
    log_ok "Admin password: (provided)"
  fi
  log_ok "Models dir:     ${MODELS_DIR}"
  log_ok "Install dir:    ${LIFEBOAT_INSTALL_DIR}"
  log_ok "Control port:   ${LIFEBOAT_PORT}"
  [ -n "$LICENSE_KEY" ] && log_ok "License key:    ${LICENSE_KEY} (will activate after up)"
  if [ -n "$CONFIDENTIAL_COMPUTING" ]; then
    log_ok "Confidential:   ${CONFIDENTIAL_COMPUTING} (explicit)"
  elif [ "$CC_HOST_SUPPORTED" = "true" ]; then
    log_ok "Confidential:   auto (TEE detected — attestation will be enabled)"
  fi

  if ! download_compose_files; then exit 3; fi
  if ! write_env_file;        then exit 3; fi
  if ! compose_up;            then exit 3; fi
  if ! wait_for_up;           then exit 3; fi

  grant_models_dir_access

  local lic_rc=0
  activate_license || lic_rc=$?

  print_summary

  [ "$lic_rc" -ne 0 ] && exit 4
  exit 0
}

main "$@"
