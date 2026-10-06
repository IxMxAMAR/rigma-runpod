#!/usr/bin/env bash
# Rigma on a Runpod GPU pod — bootstrap, for a template that uses the STOCK
# Runpod PyTorch image instead of the prebuilt one in this repo.
#
# WHY THIS EXISTS. A Runpod template's `args` field IS the container's start
# command — the console calls it "Container start command". Verified against the
# live spec, not inferred: `BaseContainerConfig.args` is documented as "The
# container's command, as a single raw string ... A bare shell string is treated
# as CMD and split into arguments, which is what the console's 'Container start
# command' field writes", and it accepts the exec form
# `{"entrypoint":[...],"cmd":[...]}` as well.
#
# So a template can install Rigma at boot: no custom image, no registry, no
# credentials to hand Runpod. The trade is one `pip install` per pod start
# (~1-2 min) and a dependency on PyPI being reachable from the pod. The
# prebuilt image (Dockerfile + .github/workflows/image.yml) removes both, at
# the cost of a build.
#
# It is deliberately thin: install, seed the registry overlay the baked image
# would have seeded at build time, then hand over to start.sh — the SAME script
# the image uses, fetched at the same ref so the two can never skew. Two
# deployment paths, one startup implementation.

set -euo pipefail

log() { printf '[rigma-bootstrap] %s\n' "$*"; }
die() { printf '[rigma-bootstrap] FATAL: %s\n' "$*" >&2; exit 2; }

RIGMA_VERSION="${RIGMA_VERSION:-0.12.1}"
RIGMA_RUNPOD_REF="${RIGMA_RUNPOD_REF:-main}"
RAW="https://raw.githubusercontent.com/IxMxAMAR/rigma-runpod/${RIGMA_RUNPOD_REF}"

log "Rigma ${RIGMA_VERSION} from PyPI, start.sh from ${RIGMA_RUNPOD_REF}"

# --- 1. system deps ----------------------------------------------------------
# libvulkan1 : the Vulkan LOADER. src/rigma/probe.py dlopen()s
#              "libvulkan.so.1" to enumerate GPUs. Deliberately NOT
#              mesa-vulkan-drivers — that is lavapipe, a CPU software
#              implementation, and probe.py filters VK_DEVICE_TYPE_CPU, so it
#              would only add a decoy ICD. The NVIDIA ICD comes from the host
#              driver via nvidia-container-toolkit, and only when the container
#              has the `graphics` driver capability (see the README).
# curl/ca-certificates : the engine + model downloads, and this script's own
#              fetch of start.sh.
if ! command -v curl >/dev/null 2>&1 || ! ldconfig -p 2>/dev/null | grep -q 'libvulkan\.so\.1'; then
  log "installing system deps (ca-certificates curl libvulkan1)"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl libvulkan1
  rm -rf /var/lib/apt/lists/*
else
  log "system deps already present"
fi

# --- 2. Rigma, pinned --------------------------------------------------------
# The [nvidia] extra is NOT optional here: probe.py falls back to _nvml_gpus()
# when Vulkan enumeration returns nothing, and it imports pynvml lazily and
# returns [] on ImportError. Without it a pod with no working Vulkan ICD
# reports ZERO GPUs and Rigma plans for CPU.
log "installing rigma[nvidia]==${RIGMA_VERSION}"
python3 -m pip install --no-cache-dir --upgrade pip
python3 -m pip install --no-cache-dir "rigma[nvidia]==${RIGMA_VERSION}"
python3 -c "import rigma; print('[rigma-bootstrap] rigma', rigma.__version__, 'from', rigma.__file__)"

# --- 3. the registry overlay source -----------------------------------------
# start.sh rewrites this per $RIGMA_RUNPOD_BACKEND and points RIGMA_REGISTRY_DIR
# at it. Seeding it here (rather than generating at boot) means the only thing
# that changes at runtime is the one field being overridden. See start.sh's
# header for why the overlay is kept even though resolve._backend no longer
# needs it to pick a workable backend.
python3 - <<'PY'
import os, shutil, rigma
src = os.path.join(os.path.dirname(rigma.__file__), "data", "registry")
shutil.rmtree("/opt/rigma-registry", ignore_errors=True)
shutil.copytree(src, "/opt/rigma-registry")
print("[rigma-bootstrap] registry overlay seeded from", src)
PY

# --- 4. hand over ------------------------------------------------------------
mkdir -p /opt/rigma-runpod
curl -fsSL "$RAW/start.sh" -o /opt/rigma-runpod/start.sh
chmod +x /opt/rigma-runpod/start.sh
log "start.sh fetched; handing over (this process becomes the pod's PID 1)"
exec /opt/rigma-runpod/start.sh
