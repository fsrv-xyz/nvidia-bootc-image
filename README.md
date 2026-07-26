# vllm-bootc — Fedora bootc image with NVIDIA driver + CUDA

A minimal, immutable (**transient-root**) Fedora 42 **bootc** image for AMD64 with
the proprietary NVIDIA driver (RPM Fusion `akmod-nvidia`, kernel module precompiled
**at build time**) and `nvidia-container-toolkit`. Goal: GPU workloads (vllm, later)
as containers. CUDA is deliberately **not** installed as a host toolkit — containers
bring their own CUDA runtime, and the CUDA driver library (`libcuda.so`) is injected
into every GPU container via CDI.

The host is **IPv6-only** (SLAAC, no DHCP), managed by **systemd-networkd** (no
NetworkManager). Login is **root only**, SSH key based.

Verified on a Proxmox VM with PCIe passthrough (RTX 3080 Ti): `nvidia-smi` detects
the GPU on the host, and CUDA detects the GPU inside a container.

## Base image + system images

The build is split in two layers:

- **Base image** (`Containerfile` → `.../nvidia-bootc-image/base`): a generic
  GPU-compute host — driver, CUDA runtime, container toolkit, networking, root SSH,
  growfs, bound-image storage config, nvtop. No workload. Independently bootable and
  reusable (e.g. for ollama later).
- **System images** (`systems/<name>/` → `.../nvidia-bootc-image/<name>`): thin,
  self-contained overlays that `FROM` the base and add their own workload config.
  `systems/rtx3080ti` and `systems/rtx4000ada` each ship their own vLLM configuration
  (currently identical; free to diverge per GPU).

## Layout

| Path | Purpose |
|---|---|
| `Containerfile` | **Base** image (driver, CUDA, toolkit, networking, growfs, storage) |
| `files/` | Base content copied into `/` (kargs, modules-load, transient-root, CDI, networkd, sshd, CUDA check, growfs) |
| `systems/rtx3080ti/`, `systems/rtx4000ada/` | Self-contained system images: own `Containerfile` (`FROM base`) + own `files/` (vLLM config) |
| `build.sh` | Build the **base** on the remote Docker host (amd64) |
| `build-system.sh <name>` | Build a **system** image `FROM` the local base |
| `make-disk.sh` | Produce a `qcow2` via `bootc-image-builder` (defaults to the rtx3080ti system image) |
| `bib/config.toml` | bootc-image-builder config (minimal; provisioning is in the image) |
| `sshkeys/root.keys` | Public key for root (baked into `/usr/share/sshkeys`) |
| `test/provision-vm.sh` | Create Proxmox VM 110 with GPU passthrough and start it |
| `test/validate.sh` | Check the success criteria inside the VM (via SSH over IPv6) |

## Build

**Builds run primarily in CI** (`.gitlab-ci.yml`) — every push builds the **system**
images. The **base** image rebuilds only when its build inputs change (`Containerfile`,
`files/`, `sshkeys/`, `.dockerignore`, `bib/config.toml`); the installer **ISO** builds
only when the base was rebuilt or the kickstart (`bib/iso-config.toml`) changed. See the
CI section below.

The scripts below are optional local helpers. They use your **local Docker**; to build
on a remote engine, set `DOCKER_HOST` yourself (`export DOCKER_HOST=ssh://user@builder`).

    ./build.sh                     # base -> .../base:main (+ localhost/nvidia-bootc-base:42)
    ./build-system.sh rtx3080ti    # system FROM local base -> localhost/nvidia-bootc-rtx3080ti:42

The proprietary driver comes from RPM Fusion. The kernel module (`akmods`) is
precompiled against the exact kernel included in the image, so it is immutable and
available on first boot. `install_weak_deps=False` keeps the image headless-lean.
`build.sh` also tags the base as the registry base ref so a system image's
`FROM ${BASE}` resolves against the freshly built local base.

## Create the disk (qcow2) — optional, local

    ./make-disk.sh          # output: <docker-host>:/root/bib-output/qcow2/disk.qcow2

`bootc-image-builder` needs an initialized `containers-storage`. `make-disk.sh` bridges
Docker -> BIB via a temporary local `registry:2` and populates the Docker host's
`containers-storage` with podman-in-docker. Fedora bootc declares no default root
filesystem type, so `--rootfs ext4` is set. For a VM, deploying the registry image via
`bootc switch`/`upgrade` (see below) is usually simpler than building a disk.

## Test (Proxmox VM with GPU passthrough)

The normal path is to deploy a registry image to a bootc VM and reboot (see
*Update capability*). `test/provision-vm.sh` / `test/validate.sh` create and check a
Proxmox test VM; adjust the host/VM IDs in them for your environment.

The VM mirrors reference VM 100 (q35, `cpu host`, SeaBIOS -> no Secure Boot, so the
unsigned kernel module is unproblematic).

## Success criteria (verified)

- `nvidia-smi` detects the GPU on the host (RTX 3080 Ti, driver 580.159.03).
- CUDA detects the GPU inside a container: `cuDeviceGetCount = 1`, correct device
  name, CUDA driver version 13.0 — via CDI (`nvidia.com/gpu=all`).

For the classic `nvcc` `deviceQuery` (large CUDA devel image, ~4 GB pull):

    CUDA_FULL=1 /usr/libexec/cuda-container-check   # in the VM; needs enough /var space

## Networking (IPv6-only, systemd-networkd)

The host obtains exactly one **stable EUI-64** global address via SLAAC:

- `files/usr/lib/systemd/network/10-ethernet-ipv6.network`: `IPv6Token=eui64`,
  `IPv6PrivacyExtensions=no` (no temporary addresses), `DHCP=no`,
  `LinkLocalAddressing=ipv6` (no IPv4 at all).
- NetworkManager is removed/masked; `systemd-networkd` + `systemd-resolved` are
  enabled. DNS comes from RA (RDNSS).

The EUI-64 address is deterministic from the NIC MAC, e.g. MAC `bc:24:11:7a:a1:5b`
on prefix `2001:67c:828:42::/64` -> `2001:67c:828:42:be24:11ff:fe7a:a15b`.

## Access to the test VM

- **SSH:** key only. `PermitRootLogin prohibit-password` + `PasswordAuthentication no`
  disable password login over SSH entirely. The key is baked at
  `/usr/share/sshkeys/root.keys`; the private test key lives in the repo under
  `sshkeys/vllm_bootc_test` (gitignored).
- **Console / serial:** root has the local password `root` (baked into the image) for
  `qm terminal` / serial login only. It is intentionally weak, is not usable over SSH,
  and — since the image is public — is not a secret; it is a local-console convenience.

Because the host is IPv6-only, connect via SSH to its global SLAAC address (ProxyJump
through the Proxmox host):

    ssh -J root@node2.dro1.pve.fsrv.cloud -i sshkeys/vllm_bootc_test root@<vm-ipv6>

Find the address: `ssh root@node2... 'qm guest cmd 110 network-get-interfaces'`.
Console access (no network needed) is available via `qm terminal 110` (serial0).

## vLLM service (bound image + Quadlet)

vLLM runs as a podman **Quadlet** systemd service (`vllm.service`) serving
**Qwen/Qwen3.5-0.8B** on the OpenAI-compatible API, port 8000 (bound on IPv6):

- `files/usr/share/containers/systemd/vllm.image` + a symlink under
  `/usr/lib/bootc/bound-images.d/` make `docker.io/vllm/vllm-openai:v0.25.1` a bootc
  **logically bound image** (`bootc image list` shows it as `logical`).
- `files/usr/share/containers/systemd/vllm.container` runs it with the GPU (CDI),
  `Network=host` (so HuggingFace resolves via the host resolver/NAT64) and `--host ::`.
- The model is downloaded on first start to `/var/lib/vllm/hf-cache` (persistent),
  so it survives reboots without re-downloading.
- `grow-var.service` + `cloud-utils-growpart` grow `/var` to the disk on boot, so a
  larger disk needs no manual resize (the vLLM image is ~19 GB).
- Single copy: `/usr/lib/bootc/storage` is added as a podman additional image store,
  so the container runs the bootc-bound image read-only (no duplicate in the podman
  r/w store). `nvtop` is included for GPU monitoring.

Use it (from the host or over the VM's IPv6):

    curl http://[::1]:8000/v1/models
    curl http://[::1]:8000/v1/chat/completions -H 'Content-Type: application/json' \
      -d '{"model":"qwen3.5-0.8b","messages":[{"role":"user","content":"Hi"}],"max_tokens":32}'

Note: for a VM the disk must be large enough for the ~19 GB vLLM image (+ model).
The test VM (110) was grown to 60 GB.

## CI / GitLab

`.gitlab-ci.yml` uses the shared `fsrvcorp/ci-components`:

- `container@0.1.0` (×3) — builds with `docker buildx` on the remote Docker host and
  pushes to the project registry. Stage `build-base` builds the base (`.../base`) **only
  when its inputs change** (a `rules:changes` override on the generated base job, matching
  `Containerfile`, `files/`, `sshkeys/`, `.dockerignore`, `bib/config.toml`); stage
  `build-systems` builds the system images (`.../rtx3080ti`, `.../rtx4000ada`) `FROM` the
  base **on every push**. All jobs tag with `$CI_COMMIT_REF_SLUG`; when the base is
  skipped, `base:<ref>` still exists from the prior pipeline on that ref (a new branch's
  first push has an "all changed" delta, so the base is built). The base tag is passed to
  the system builds via `--build-arg BASE=...`.
- `build-iso` — a custom job (not a component) that validates the Anaconda ISO builds from
  the current base. It runs only when the base inputs **or** `bib/iso-config.toml` change
  (`rules:changes`).
- `semver@0.1.0` — on the default branch, derives the next version from conventional
  commits and creates a git tag, which triggers a versioned build.

Image tags follow the ref slug: `:main` on the default branch, `:<branch-slug>` on
branches, `:<tag-slug>` on git tags (e.g. `0.1.0` → `0-1-0`). There is no `:latest`.

Update base for a machine (pick the matching system image):

    registry.fsrv.services/fsrvcorp/images/nvidia-bootc-image/rtx3080ti:<tag>
    registry.fsrv.services/fsrvcorp/images/nvidia-bootc-image/rtx4000ada:<tag>

## CI / GitHub (ghcr.io mirror)

The repo is push-mirrored to `github.com/fsrv-xyz/nvidia-bootc-image`, where
`.github/workflows/build-images.yml` builds and publishes the same images to GitHub
Container Registry, **independently of the private registry**:

- Job `changes` diffs the push (`event.before → sha`; a new branch/tag counts as "all
  changed") and decides what to build: `base` runs only when the base inputs changed;
  `systems` runs on **every** push, even when `base` was skipped (`base:<ref>` still
  exists from a prior pipeline); `iso` runs only when `base` was rebuilt **or**
  `bib/iso-config.toml` changed.
- Job `base` builds `ghcr.io/fsrv-xyz/nvidia-bootc-image/base:<ref>`.
- Job `systems` (matrix `rtx3080ti`/`rtx4000ada`, `needs: [changes, base]`) builds each
  system **`FROM` the ghcr base** (`--build-arg BASE=ghcr.io/.../base:<ref>`) → pushes
  `.../rtx3080ti`, `.../rtx4000ada`. GitHub images never reference ref.ci; the ref.ci
  images build from the ref.ci base. This split works because the system Containerfiles
  take the base as `ARG BASE`.

GitHub tags use the git ref name directly (`:main`, `:0.3.0`, `:<branch>`); ghcr images:

    ghcr.io/fsrv-xyz/nvidia-bootc-image/rtx3080ti:<tag>
    ghcr.io/fsrv-xyz/nvidia-bootc-image/rtx4000ada:<tag>

## Update capability

This is a bootc system; it updates transactionally. Point the booted deployment at
the matching system image once, then upgrades pull from there:

    # point the running VM at its system image (pulls + stages)
    sudo bootc switch registry.fsrv.services/fsrvcorp/images/nvidia-bootc-image/rtx3080ti:main
    sudo systemctl reboot

    sudo bootc upgrade      # pull a newer image + activate on next boot
    sudo bootc status       # show deployments
    sudo bootc rollback     # roll back to the previous deployment

Because the kernel module is recompiled against the included kernel on every base
build, the driver
stays consistent across kernel updates.

## Immutability

- **Transient root** (`root.transient=true`): `/` is a read-only composefs with a
  tmpfs overlay — changes outside `/var` are ephemeral per boot. Persistent data
  belongs under `/var`.
- `/usr` is read-only (composefs/fs-verity).
- Provisioning (root SSH key, sshd config, networking) is baked into the image so it
  is transient-root safe. The CDI service regenerates `/etc/cdi/nvidia.yaml` on each
  boot.

## Scope / open items

- Running the vllm container (separate). Note: the test VM has only a 10 GB disk; it
  should be grown for vllm images.
- Secure Boot / MOK signing (only needed with UEFI + Secure Boot; the test uses SeaBIOS).
- Final registry choice + CI push.
