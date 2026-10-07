# rigma-runpod

Runpod deployment for [Rigma](https://github.com/IxMxAMAR/rigma) — a local-first
LLM agent app. One GPU pod, one port, the Rigma UI behind Runpod's proxy:

```
https://<pod-id>-11500.proxy.runpod.net
```

This repo holds the container startup, the Dockerfile for an optional prebuilt
image, and the Runpod template definition. Rigma itself lives in
[IxMxAMAR/rigma](https://github.com/IxMxAMAR/rigma).

## Two ways to deploy

| | **A — stock image + start command** (default) | **B — prebuilt image** |
| --- | --- | --- |
| Base | Runpod's own PyTorch image, which Runpod pre-caches on its hosts | the image this repo builds |
| Rigma | `pip install` at boot, ~1–2 min per pod start | baked in |
| Needs | nothing to build, no registry | a build (or the GHCR image from a `v*` tag) |
| Use when | you want to test now, or iterate on Rigma | you want fast, pinned, reproducible starts |

Path A is what `template.json` describes. Path B is the same template with
`image` replaced and `args` removed — the image's `CMD` is already `start.sh`.

## Deploy (path A)

Everything the service needs is set **at creation**. Ports and env cannot be
added to a running pod without a reset.

```bash
export RUNPOD_API_KEY=...                      # https://console.runpod.io/user/settings

# 1. a network volume for the models — it is DC-LOCKED, so pick a DC that has
#    both your GPU and room for the volume
runpodctl datacenter list
runpodctl network-volume create --name rigma-models --size 100 --data-center-id <dc>

# 2. the pod. --terminate-after is the real cost guard (--stop-after only stops
#    it, and disk + volume keep billing).
runpodctl pod create \
  --name rigma \
  --template-id <the template created from template.json> \
  --gpu-id "NVIDIA GeForce RTX 4090" \
  --ports "11500/http,22/tcp" \
  --env '{"RIGMA_UI_PORT":"11500","RIGMA_HOST":"0.0.0.0","RIGMA_RUNPOD_BACKEND":"vulkan","NVIDIA_DRIVER_CAPABILITIES":"all"}' \
  --network-volume-id <volume-id> \
  --volume-mount-path /workspace \
  --terminate-after 2026-10-06T00:00:00Z

runpodctl ssh info <pod-id>                    # prints the ssh command
```

Then watch the pod log — `start.sh` prints a loud pre-flight before it execs
Rigma, so a broken driver is visible in the log instead of surfacing as a 502:

```bash
runpodctl pod logs <pod-id> --follow
```

The proxy returns **502 for the first 30–60 s** while the UI comes up. That is
normal; keep polling rather than assuming failure:

```bash
for i in $(seq 1 120); do curl -sf https://<pod-id>-11500.proxy.runpod.net/ >/dev/null && echo up && break; sleep 5; done
```

## What to check in the log

`start.sh` answers the two questions that decide whether this pod is useful:

1. **Does the container see the GPU?** It prints `nvidia-smi`, then the Vulkan
   loader entries, then the ICD directory, then Rigma's *own* probe —
   `enumerate_vulkan()` and `_nvml_gpus()` with device names and VRAM.
2. **Is `/workspace` really a network volume?** It prints the filesystem type.
   `fuse`/`nfs` means the volume; `overlayfs` means container disk, which is
   **wiped when the pod stops**.

## The one thing most likely to go wrong

Rigma's default backend on an NVIDIA Linux card is **Vulkan**, and the NVIDIA
Vulkan ICD ships with the *host* driver — it is mounted into the container only
when the container is granted the `graphics` driver capability. That is what
`NVIDIA_DRIVER_CAPABILITIES=all` in the template env is for.

**This is unverified on a real pod.** What is verified is the negative: no stock
Runpod template sets it (checked against the live catalog — every GPU template
has `env {}`), so the platform does not do it for you. If `start.sh` reports
that Vulkan enumerates nothing while NVML sees the card, you have three options,
in order:

1. set `NVIDIA_DRIVER_CAPABILITIES=all` and restart the pod;
2. `RIGMA_ENGINE=vllm` with `RIGMA_MODEL=<hf repo id>` on a CUDA image — vLLM is
   the only CUDA path Rigma has on Linux today;
3. `RIGMA_RUNPOD_BACKEND=cpu` for a deliberate CPU-only bench — slow, but honest.

Note that Rigma's pinned engine manifest has **no `linux/cuda` asset**: on Linux
the pinned builds are `linux/vulkan` and `linux/cpu`. There is no configuration
in which llama.cpp uses CUDA on this platform today.

## Environment

| Variable | Default | What it does |
| --- | --- | --- |
| `RIGMA_UI_PORT` | `11500` | the port the UI binds *and* the port the proxy reaches. The engine takes `UI_PORT - 1` on loopback |
| `RIGMA_HOST` | `0.0.0.0` | the interface the UI binds. `0.0.0.0` is required for the proxy; `127.0.0.1` makes the port 502 |
| `RIGMA_RUNPOD_BACKEND` | `vulkan` | `vulkan` \| `cpu` \| `off`. Rewrites the registry overlay so the backend is *pinned* rather than inferred, and adds a catch-all row for cards absent from the packaged table (A100, H100, L40S). `off` reproduces unshimmed behaviour |
| `RIGMA_ENGINE` | `llamacpp` | `llamacpp` \| `vllm`. vLLM needs `RIGMA_MODEL` and a non-GGUF model, and refuses rather than falling back |
| `RIGMA_MODEL` | *(empty)* | empty starts the UI with no model; pick one in the Models tab and it downloads, tunes and loads on demand. Otherwise a registry slug (llamacpp) or a HuggingFace repo id (vllm) |
| `RIGMA_MODELS_DIR` | `/workspace/rigma/models` | where weights go. `start.sh` symlinks `$RIGMA_HOME/models` here |
| `RIGMA_AUTO_CALIBRATE` | `0` in the template | `0` disables the hardware auto-tune sweep on first load; `1` lets it tune, which adds minutes on a cold volume |
| `RIGMA_VERSION` | `0.12.2` | path A only: the Rigma release to install |
| `RIGMA_RUNPOD_REF` | `main` | path A only: the ref `bootstrap.sh` fetches `start.sh` from |
| `NVIDIA_DRIVER_CAPABILITIES` | `all` | see above — the ICD question |

## Why one port

Until `rigma up --host` existed, the UI was loopback-only, so reaching it from
outside meant a raw-TCP `socat` bridge on a second port, with a third left free
because a `0.0.0.0` bind and a `127.0.0.1` bind on the *same* port collide.
`rigma up --host 0.0.0.0` removes both: the UI binds the public port directly and
the engine stays on loopback at `P-1`, a different port, so nothing collides.
This is also the shape Runpod's own pod workflow asks for.

## Security

The proxy URL is public to anyone who knows the pod id, and Rigma's UI has **no
login of its own**. Treat the URL as a secret, and terminate the pod when you
are done. `22/tcp` is SSH, keyed by the SSH keys registered on your Runpod
account.

## Building the image (path B)

```bash
docker build -t rigma-runpod:0.12.2 .
docker run --rm -p 11500:11500 -e RIGMA_RUNPOD_BACKEND=cpu rigma-runpod:0.12.2
```

`.github/workflows/image.yml` does this on every push and, on a `v*` tag, pushes
to `ghcr.io/ixmxamar/rigma-runpod`. It also **boots the container and polls the
UI**, because a green build that never ran the container proves only that the
Dockerfile parses. The runner has no NVIDIA device, so the GPU paths are
verified on a real pod, not in CI.

## Provenance

- `start.sh` is kept in sync with `deploy/runpod/start.sh` in the Rigma repo;
  that copy is what Rigma's own CI and tests cover.
- Every field name in `template.json` was read from the live spec at
  `https://api.runpod.io/v2/openapi.json` while writing it. `_field_notes` there
  records which claims are verified and which are documented-not-observed.
- The deploy steps and the gotchas they encode (ports and env at creation, the
  PID 1 vs SSH-login-shell env split, `--terminate-after` over `--stop-after`,
  the DC-locked volume, the 100 s proxy cap) come from Runpod's own
  live-verified pod walkthrough.

## License

Apache-2.0, same as Rigma.
