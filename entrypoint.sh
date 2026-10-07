#!/usr/bin/env bash
# Rigma's own entrypoint, so the base image cannot decide what runs.
#
# Two bases are in play and they disagree:
#
#   runpod/pytorch          ENTRYPOINT /opt/nvidia/nvidia_entrypoint.sh — prints
#                           the CUDA banner, runs ldconfig over the driver libs
#                           the container toolkit mounted, then execs its
#                           argument. This image already worked that way, so the
#                           chain must be preserved.
#   vllm/vllm-openai        ENTRYPOINT `vllm serve` — which would ignore
#                           start.sh completely and serve a bare vLLM on the
#                           UI port.
#
# Chain the NVIDIA entrypoint when it exists, skip it when it does not. `set -e`
# is deliberately absent: nvidia_entrypoint.sh is allowed to be a no-op wrapper
# and a failure inside it must not stop the pod from coming up.
set -uo pipefail

if [ -x /opt/nvidia/nvidia_entrypoint.sh ]; then
  exec /opt/nvidia/nvidia_entrypoint.sh "$@"
fi

exec "$@"
