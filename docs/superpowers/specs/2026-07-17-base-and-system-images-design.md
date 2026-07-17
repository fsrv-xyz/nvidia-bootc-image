# Base image + per-system overlay images — Design

**Date:** 2026-07-17
**Status:** Approved (Design)

## Goal

Split the monolithic image into a generic **base image** (GPU-compute host, no vLLM)
and thin, self-contained **system images** that build on top of it and add their own
vLLM configuration. This makes the base reusable for other workloads later (e.g.
ollama) and lets each target system diverge independently.

## Decisions

| Topic | Decision |
|---|---|
| Base image | current image **minus** the 4 vLLM files; keeps driver/CUDA/toolkit, networking, root SSH, growfs, bound-image storage config, nvtop |
| System images | `systems/rtx3080ti/` and `systems/rtx4000ada/`, each **self-contained** (own `Containerfile` + own `files/` with its own vLLM config). No shared overlay. |
| vLLM config | identical between the two systems for now; independent copies, free to diverge |
| Registry naming | base = `.../nvidia-bootc-image/base`; systems = `.../nvidia-bootc-image/rtx3080ti`, `.../rtx4000ada` |
| CI | always build; stage `build-base` then stage `build-systems` (systems `FROM` the base built in stage 1); no rules; existing `container` component only |
| CI tags | `tag: $CI_COMMIT_REF_SLUG` on all includes → deterministic shared tag per pipeline (`main`, `feat-x`, `0-1-0`); no `:latest` / dotted-version tags |

## Architecture

### Repository layout

```
Containerfile                      # base (files/ without vLLM)
files/…                            # generic base config (nvidia, network, ssh, growfs, storage, cuda-check)
systems/rtx3080ti/
  Containerfile                    # FROM ${BASE}; COPY files/ /; bootc container lint
  files/usr/share/containers/systemd/vllm.image
  files/usr/share/containers/systemd/vllm.container
  files/usr/lib/tmpfiles.d/vllm.conf
  files/usr/lib/bootc/bound-images.d/vllm.image
systems/rtx4000ada/                # own independent copy of the above
  Containerfile
  files/…
```

### Base image (`Containerfile`)

Unchanged except: the 4 vLLM files are removed from `files/`, and vLLM-specific
comments are reworded to generic. Kept because they are generic and useful for any
GPU/bound-image workload:
- NVIDIA driver + CUDA runtime + `nvidia-container-toolkit` + precompiled kmod
- IPv6-only systemd-networkd, root-only SSH
- `grow-var.service` + `cloud-utils-growpart`
- `/usr/lib/bootc/storage` added as podman additional image store (for bound images)
- `nvtop`, `cuda-container-check`

The base is independently bootable — a generic GPU-compute host.

### System image (`systems/<name>/Containerfile`)

```dockerfile
ARG BASE=registry.fsrv.services/fsrvcorp/images/nvidia-bootc-image/base:main
FROM ${BASE}
COPY files/ /
RUN bootc container lint
```

- Build context is the system directory, so `COPY files/ /` copies that system's own
  vLLM files (bound image quadlet, container quadlet, tmpfiles, bound-images.d symlink).
- `ARG BASE` lets CI and local builds point at the right base tag; the default is the
  `main` base for ad-hoc use.

### CI (`.gitlab-ci.yml`)

```yaml
stages: [build-base, build-systems]
include:
  - component: $CI_SERVER_FQDN/fsrvcorp/ci-components/container@0.1.0
    inputs:
      stage: build-base
      image_name: base
      containerfile_location: ./Containerfile
      tag: $CI_COMMIT_REF_SLUG
  - component: $CI_SERVER_FQDN/fsrvcorp/ci-components/container@0.1.0
    inputs:
      stage: build-systems
      image_name: rtx3080ti
      containerfile_location: systems/rtx3080ti/Containerfile
      context_path: systems/rtx3080ti
      tag: $CI_COMMIT_REF_SLUG
      additional_build_args: --build-arg BASE=$CI_REGISTRY_IMAGE/base:$CI_COMMIT_REF_SLUG
  - component: $CI_SERVER_FQDN/fsrvcorp/ci-components/container@0.1.0
    inputs:
      stage: build-systems
      image_name: rtx4000ada
      containerfile_location: systems/rtx4000ada/Containerfile
      context_path: systems/rtx4000ada
      tag: $CI_COMMIT_REF_SLUG
      additional_build_args: --build-arg BASE=$CI_REGISTRY_IMAGE/base:$CI_COMMIT_REF_SLUG
  - component: $CI_SERVER_FQDN/fsrvcorp/ci-components/semver@0.1.0
```

`stages` ordering guarantees `build-base` pushes `base:$CI_COMMIT_REF_SLUG` before
`build-systems` pulls it via the `BASE` build-arg. Always builds, no rules, only the
existing component.

### Local build/test

- `build.sh` builds the base and also tags it locally as
  `registry.fsrv.services/fsrvcorp/images/nvidia-bootc-image/base:main` so the system
  Containerfiles' `FROM ${BASE}` default resolves locally.
- `build-system.sh <name>` builds `systems/<name>` FROM the local base.
- `make-disk.sh` takes an image ref (defaults to the rtx3080ti system image) to build
  a qcow2 for VM testing.

## Validation

1. Base builds + `bootc container lint` passes + contains **no** vLLM files, still has
   nvidia/cuda/growfs/nvtop.
2. `rtx3080ti` builds `FROM` the base + lints + **has** the vLLM files.
3. Deploy the `rtx3080ti` image to VM 110 (via registry, branch tag), reboot, verify
   vLLM serves `qwen3.5-0.8b` — regression check that the split preserves behavior.
4. VM migrates from the monolithic `nvidia-bootc-image:0.1.0` to
   `nvidia-bootc-image/rtx3080ti:<tag>`.

## Notes / out of scope

- No `:latest` or dotted-version image tags (consequence of the uniform
  `$CI_COMMIT_REF_SLUG` tag scheme); consumers pin `:main` or a release slug.
- Per-GPU vLLM tuning (e.g. larger `--max-model-len` on the 20 GB RTX 4000 Ada) is a
  later divergence; the two system images start identical.
- The old monolithic `nvidia-bootc-image:{latest,0.1.0,branch-*}` tags remain in the
  registry as history.
