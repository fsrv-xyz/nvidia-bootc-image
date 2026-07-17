# vLLM bound-image Quadlet service — Design

**Date:** 2026-07-16
**Status:** Approved (Design)

## Goal

Run the latest vLLM as a **logically bound image** on the NVIDIA CUDA bootc image,
integrated as a **podman Quadlet** systemd service that serves **Qwen/Qwen3.5-0.8B**
(the "qwen3.5-0.9b" the user asked for; 0.8B name ≈ 0.9B params) over the
OpenAI-compatible API. The model is downloaded by vLLM on first start and cached
**persistently on `/var`** across reboots.

## Decisions

| Topic | Decision |
|---|---|
| vLLM image | `docker.io/vllm/vllm-openai:v0.25.1` (latest stable, pinned) as a bootc logically bound image (LBI) |
| Model | `Qwen/Qwen3.5-0.8B`, served as `qwen3.5-0.8b`, `--max-model-len 16384` |
| Service | podman Quadlet `.container` (+ `.image`), GPU via CDI, port 8000, enabled at boot |
| Model persistence | HF cache bind-mounted from `/var/lib/vllm/hf-cache` (persistent, downloaded on first start) |
| VM disk | grow test VM 110 to 60 GB; `/var` grown to fill the disk |
| Auto-grow | bake `cloud-utils-growpart` + a `grow-var` oneshot so `/var` auto-grows to the disk at boot |

## Architecture

### A. Logically bound image + Quadlet (`/usr/share/containers/systemd/`)

- **`vllm.image`** — declares `docker.io/vllm/vllm-openai:v0.25.1`.
- **`/usr/lib/bootc/bound-images.d/vllm.image`** — symlink to the quadlet; this is
  what makes bootc treat the image as a **logically bound image** and pre-pull it
  into the bootc bound store on `bootc install`/`upgrade` (`bootc image list` then
  shows it with type `logical`, GC'd with the deployment).
- **`vllm.container`** — the service:
  - `Image=vllm.image` (references the image unit)
  - `AddDevice=nvidia.com/gpu=all` (CDI; the driver + CDI spec already exist)
  - `SecurityLabelDisable=true` (SELinux, matches the validated container GPU path)
  - `Network=host` — the container uses the host's systemd-resolved stub + NAT64,
    so HuggingFace resolves (in a bridge netns the `127.0.0.53` stub is unreachable);
    also binds the host port directly. `--host ::` (the host is IPv6-only)
  - `Volume=/var/lib/vllm/hf-cache:/root/.cache/huggingface:Z`, `HF_HOME` set there
  - `ShmSize=1g`
  - `Exec=Qwen/Qwen3.5-0.8B --served-model-name qwen3.5-0.8b --host 0.0.0.0 --port 8000 --max-model-len 16384 --gpu-memory-utilization 0.90`
    (image entrypoint is `vllm serve`; the model is the positional arg)
  - `After=nvidia-cdi-generate.service grow-var.service`; enabled via `[Install] WantedBy=multi-user.target`
  - `Restart=on-failure`, `TimeoutStartSec=3600` (first-start model download)

### B. Persistent model cache

- `/usr/lib/tmpfiles.d/vllm.conf`: create `/var/lib/vllm` + `/var/lib/vllm/hf-cache`.
- `/var` is persistent (not transient) → the model downloaded on first start survives
  reboots; later starts reuse the cache.

### C. Auto-grow `/var` (growfs)

- Install `cloud-utils-growpart`.
- `/usr/libexec/grow-var` + `grow-var.service` (oneshot, `Before=vllm.container`):
  detect the partition backing `/var` (`findmnt -no SOURCE /var`), `growpart` it to
  fill the disk, `resize2fs` online. Idempotent (no-op when already full).
- Makes the image robust to any disk size — grow the disk, boot, done.

### D. Update / deploy flow

1. Add the quadlet/tmpfiles/growfs files + `cloud-utils-growpart` to the image.
2. Push branch → GitLab CI builds and pushes the new image.
3. On VM 110: `qm resize 110 virtio0 60G`, then grow `/var` **before** the upgrade
   (the LBI pull of the ~9 GB vLLM image needs the space).
4. `bootc upgrade` (pulls the new OS image **and** the bound vLLM image), reboot.
5. `vllm.container` starts, downloads `Qwen/Qwen3.5-0.8B` to `/var/lib/vllm/hf-cache`,
   serves the OpenAI API on `:8000`.

### E. Validation (success criteria)

1. `systemctl status vllm.service` active; `bootc status` shows the bound image.
2. `curl http://[<vm-ipv6>]:8000/v1/models` lists `qwen3.5-0.8b`.
3. A chat/completion request returns a valid response from the GPU.
4. The model sits in `/var/lib/vllm/hf-cache`; after a reboot vLLM starts **without**
   re-downloading (cache hit) and serves again.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| LBI pull runs out of disk during upgrade | Grow `/var` to 60 GB **before** `bootc upgrade` |
| `--max-model-len 262144` default exhausts KV cache | Pin `--max-model-len 16384` (tunable) |
| CDI/SELinux denials for GPU in container | `AddDevice=nvidia.com/gpu=all` + `SecurityLabelDisable=true` (validated path) |
| Quadlet not auto-enabled | `[Install] WantedBy=multi-user.target` in `.container` (quadlet honors it) |
| growpart device/partnum hardcoding | Detect dynamically via `findmnt`/`lsblk` |

## Single-copy bound image (implemented)

The vLLM image lives once, in the bootc bound store — no second copy in the podman
r/w store:

- `/usr/share/containers/storage.conf` adds `/usr/lib/bootc/storage` (the bootc
  bound store) as a read-only **additional image store** (this fedora-bootc doesn't
  read `storage.conf.d` drop-ins, so the base file is edited at build time).
- `vllm.container` references the image directly (`Image=docker.io/vllm/vllm-openai:v0.25.1`);
  podman finds it in the additional store and runs it read-only, no pull.
- `vllm.image` has no `[Install]`, so the generated `vllm-image.service` never runs a
  boot-time pull. bootc still pre-pulls the image into its bound store at upgrade via
  the `/usr/lib/bootc/bound-images.d/vllm.image` symlink.

Verified: after boot `podman images` shows only the `R/O=true` bound-store copy,
`vllm-image.service` is inactive, and `/var` usage dropped ~18 GB vs. the two-copy
layout. Default `Pull=missing` still self-heals (pulls into the r/w store) if the
bound store ever lacks the image.

## Out of scope

- Multi-model / model switching, API auth, TLS, autoscaling.
- Pinning vLLM by digest (tag pin is used).
