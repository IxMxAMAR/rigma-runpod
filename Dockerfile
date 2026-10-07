# syntax=docker/dockerfile:1
#
# Rigma on a Runpod GPU pod — prebuilt image.
#
# This is the OPTIONAL path. The template in template.json does not need this
# image: it starts from Runpod's own PyTorch image and runs bootstrap.sh, which
# installs Rigma at boot. Build this image when you want pod starts to be fast
# and reproducible (nothing resolved at boot, nothing fetched from PyPI while
# you wait), or when you want to pin the whole stack by digest.
#
# WHY A PREBUILT RUNPOD BASE INSTEAD OF BUILDING CUDA
# ---------------------------------------------------
# FROM is an official Runpod PyTorch image, pinned to an exact tag. Two reasons:
#   * torch/CUDA already match Runpod's hosts, so there is no driver/toolkit
#     mismatch to debug, and nothing compiles CUDA here;
#   * Runpod pre-caches its official base images on its hosts, so the base
#     layers are effectively already on the machine and only the layers added
#     below are pulled. A hand-built CUDA base throws both away.
# The tag is pinned (never `latest`) so a rebuild is reproducible.
#
# The base also ships /start.sh, which is what makes a pod usable (sshd + web
# terminal). start.sh below chains it — do not clobber the base image's startup.
#
# WHY THIS IMAGE BAKES IN NO ENGINE AND NO MODEL
# ----------------------------------------------
# Rigma downloads its pinned llama.cpp build into $RIGMA_HOME/engines/<pin>/
# <backend>/ with a `.ready` sentinel and a trust-on-first-use sha256 lock
# (src/rigma/runtime.py). Pre-seeding that layout means forging the lock file,
# and the pinned Linux GPU asset is only ~30 MiB. Not worth the fragility.
# Models are GB-scale and are the case a network volume is for — start.sh
# symlinks $RIGMA_HOME/models onto it.

ARG BASE_IMAGE=runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04
FROM ${BASE_IMAGE}

# The Rigma release to install. Override to test an unreleased build:
#   --build-arg RIGMA_SPEC="rigma[nvidia] @ git+https://github.com/IxMxAMAR/rigma@<ref>"
ARG RIGMA_SPEC=rigma[nvidia]==0.12.2

# Set to 1 to add vLLM — the only honest CUDA path for Rigma on Linux today.
# Costs several GB of image.
ARG INSTALL_VLLM=0

# Set to 1 when BASE_IMAGE is the vendor's own vLLM image, which already carries
# vLLM and — this is the point — a CUDA toolkit that matches it.
#
# `pip install vllm` on the PyTorch base pulled torch 2.13.0+cu130 and vLLM
# 0.31.0 into a container whose CUDA is 12.4.1. On an RTX 5090 the engine core
# then died inside its memory-profiling pass (`self.measure()`, core.py:1433)
# while torch itself was perfectly healthy in the same container — capability
# (12, 0), cuda available, 32 GB visible. The wheels and the toolkit disagreed.
# The vendor builds vllm/vllm-openai:v0.31.0 on CUDA 13.0.2 with
# CUDA_HOME=/usr/local/cuda, so on that base they agree by construction.
ARG VLLM_BASE=0

ENV PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    HF_HUB_DISABLE_XET=1

# --- system deps -------------------------------------------------------------
# libvulkan1 : the Vulkan LOADER, dlopen()ed by src/rigma/probe.py to enumerate
#              GPUs. Deliberately NOT mesa-vulkan-drivers: that is lavapipe (a
#              CPU software implementation) and probe.py filters
#              VK_DEVICE_TYPE_CPU, so it would only add a decoy ICD. The NVIDIA
#              ICD must come from the host driver via nvidia-container-toolkit,
#              and only when the container has the `graphics` driver capability.
# curl/ca-certificates : TLS for the engine and model downloads.
# No socat: it used to bridge 0.0.0.0:11500 -> 127.0.0.1:11502 because the UI was
# loopback-only. `rigma up --host 0.0.0.0` binds the public port directly, which
# is also the shape Runpod's own pod workflow asks for.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl libvulkan1 \
 && rm -rf /var/lib/apt/lists/*

# --- python ------------------------------------------------------------------
# Layer order (system deps, then python deps, then code) so editing the last
# layer does not reinstall dependencies.
RUN python3 -c "import sys; assert sys.version_info[:2] >= (3, 11), sys.version" \
 && (python3 -m pip --version >/dev/null 2>&1 \
     || python3 -m ensurepip --upgrade \
     || { command -v uv >/dev/null 2>&1 && uv pip install --system pip; }) \
 && python3 -m pip install --no-cache-dir --upgrade pip \
 && python3 -m pip install --no-cache-dir "${RIGMA_SPEC}" \
 && python3 -c "import rigma; print('rigma', rigma.__version__, 'from', rigma.__file__)"

RUN if [ "${INSTALL_VLLM}" = "1" ] && [ "${VLLM_BASE}" != "1" ]; then \
      python3 -m pip install --no-cache-dir vllm; \
    fi

# Say out loud which CUDA stack this image ended up with, whichever way it got
# here. The mismatch above was invisible in a green build.
RUN if [ "${INSTALL_VLLM}" = "1" ] || [ "${VLLM_BASE}" = "1" ]; then \
      python3 -c "import vllm, torch; print('vllm', vllm.__version__, \
'| torch', torch.__version__, '| cuda', torch.version.cuda)"; \
    fi

# The vendor image has no /start.sh, and start.sh chains one for sshd. Without
# this, `startSsh: true` on the template would silently do nothing. The PyTorch
# base ships its own, so only provide one when there is not already one.
RUN if [ "${VLLM_BASE}" = "1" ] && [ ! -x /start.sh ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends openssh-server \
      && rm -rf /var/lib/apt/lists/* \
      && mkdir -p /run/sshd \
      && printf '%s\n' \
           '#!/usr/bin/env bash' \
           'mkdir -p /run/sshd' \
           'if [ -n "${PUBLIC_KEY:-}" ]; then' \
           '  mkdir -p /root/.ssh' \
           '  printf "%s\n" "$PUBLIC_KEY" > /root/.ssh/authorized_keys' \
           '  chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys' \
           '  /usr/sbin/sshd' \
           'fi' \
           'sleep infinity' > /start.sh \
      && chmod +x /start.sh; \
    fi

# --- the registry overlay source --------------------------------------------
# start.sh rewrites this per $RIGMA_RUNPOD_BACKEND. Kept for the catch-all row
# (cards absent from the packaged gpus.json — A100, H100, L40S — would
# otherwise get probe.py's generic ["cuda","vulkan"] list) and so a benchmark
# can PIN the backend rather than infer it.
RUN python3 -c "\
import os, shutil, rigma; \
src = os.path.join(os.path.dirname(rigma.__file__), 'data', 'registry'); \
shutil.rmtree('/opt/rigma-registry', ignore_errors=True); \
shutil.copytree(src, '/opt/rigma-registry'); \
print('registry overlay seeded from', src)"

# --- entrypoint --------------------------------------------------------------
# A custom CMD on a runpod/pytorch base MUST invoke /start.sh, or the pod comes
# up with no SSH and no web terminal. start.sh chains it itself (step 0), so
# this CMD is the only entrypoint needed.
COPY start.sh /opt/rigma-runpod/start.sh
RUN chmod +x /opt/rigma-runpod/start.sh

# Documentation only — Runpod takes the exposed ports from the template/pod
# creation call, not from EXPOSE.
EXPOSE 11500 22

COPY entrypoint.sh /opt/rigma-runpod/entrypoint.sh
RUN chmod +x /opt/rigma-runpod/entrypoint.sh

# Ours, not the base's: the vendor vLLM image's ENTRYPOINT is `vllm serve`, which
# would ignore start.sh entirely. entrypoint.sh chains the NVIDIA entrypoint when
# the base has one, so the PyTorch image keeps the behaviour it already had.
ENTRYPOINT ["/opt/rigma-runpod/entrypoint.sh"]
CMD ["/opt/rigma-runpod/start.sh"]
