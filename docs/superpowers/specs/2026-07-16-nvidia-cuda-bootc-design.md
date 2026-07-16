# Fedora bootc image with NVIDIA driver + CUDA — Design

**Date:** 2026-07-16
**Status:** Implemented

## Goal

A Fedora-based **bootc** image for **AMD64** that provides an NVIDIA GPU (target:
RTX 4000 Ada) with the **latest proprietary driver** and **CUDA**. The image should
be as **minimal**, **immutable**, and **read-only** as bootc allows, and remain
**update-capable**. Later (out of scope) vllm runs as a container on top.

**Success criterion:** the image boots in a Proxmox test VM (with PCIe passthrough of
an RTX 3080 Ti); `nvidia-smi` detects the GPU on the host and a CUDA program detects
the GPU inside a container.

## Decisions

| Topic | Decision |
|---|---|
| CUDA scope | **No** CUDA dev toolkit on the host. Host = driver (`nvidia-smi`/`libcuda`) + `nvidia-container-toolkit`. CUDA is validated **inside a container** (the real vllm path). |
| Driver source | RPM Fusion `akmod-nvidia`, kernel module precompiled **at build time** |
| Fedora base | Fedora 42 (`quay.io/fedora/fedora-bootc:42`) |
| Registry / updates | Registry reference parameterized, final choice later; tested via a qcow2 disk |
| Container runtime | `nvidia-container-toolkit` from the start (target: vllm container) |
| Immutability | **Transient root** (tmpfs overlay, fresh each boot outside `/var`) as the default |
| Networking | **IPv6-only via SLAAC** with a single stable **EUI-64** address; **systemd-networkd** (no NetworkManager); no DHCP |
| Users | **root only**, SSH key based; no additional human users |

## Architecture

### A. Image build (`Containerfile`)

Base: `quay.io/fedora/fedora-bootc:42`

1. **Enable repos**
   - RPM Fusion free + nonfree (for `akmod-nvidia` / `xorg-x11-drv-nvidia-cuda`)
   - NVIDIA Container Toolkit repo (for `nvidia-container-toolkit`)

2. **Driver (RPM Fusion)**
   - `akmod-nvidia` (proprietary)
   - `xorg-x11-drv-nvidia-cuda` (provides `nvidia-smi`, `libcuda`, CUDA runtime libs —
     **no** `nvcc`/dev toolkit; enough for containers to use CUDA)
   - `install_weak_deps=False` to avoid desktop/audio bloat on a headless image.

3. **Container GPU support**
   - `nvidia-container-toolkit`
   - Generate the CDI spec for `nvidia.com/gpu` at boot (`nvidia-ctk cdi generate`),
     so `podman run --device nvidia.com/gpu=all` works.

4. **Precompile the kernel module (critical step)**
   - Pin `kernel-devel` to the exact kernel version present in the base image.
   - `akmods --force --kernels <image-kernel>` -> the `.ko` sits immutable in the
     image. No runtime module build; available on first boot.
   - **Fallback** if the akmod build fails against the image kernel: upgrade the
     kernel to the latest available and recompute the pin.

5. **Networking (IPv6-only, systemd-networkd)**
   - Install `systemd-networkd` + `systemd-resolved`; remove/mask NetworkManager.
   - `.network` drop-in matching ethernet: `DHCP=no`, `LinkLocalAddressing=ipv6`
     (no IPv4), `IPv6AcceptRA=yes`, `IPv6Token=eui64` +
     `IPv6LinkLocalAddressGenerationMode=eui64` (deterministic MAC-based identifier),
     `IPv6PrivacyExtensions=no` (no temporary addresses). Result: exactly one stable
     global EUI-64 address plus the mandatory (EUI-64) link-local. DNS from RA (RDNSS).

6. **Users / SSH (root only)**
   - No additional human user. Root login via SSH key only
     (`PermitRootLogin prohibit-password`), `AuthorizedKeysFile /usr/share/sshkeys/%u.keys`
     with `root.keys` baked into read-only `/usr` (transient-root safe).

7. **Configuration / immutability**
   - Blacklist nouveau via a `/usr/lib/bootc/kargs.d/` drop-in.
   - Load `nvidia`, `nvidia_uvm`, `nvidia_modeset`, `nvidia_drm` (modules-load.d).
   - Enable `nvidia-persistenced`.
   - Keep composefs/fs-verity (F42 default); `/usr` read-only.
   - **Enable transient root**: `/usr/lib/ostree/prepare-root.conf` with
     `[root] transient = true`. `/var` stays persistent.
   - Mask `akmods.service` + `akmods-keygen@.service` (runtime module builds and MOK
     keygen are pointless on an immutable/prebuilt image and fail on read-only `/etc`).

8. **Finalize**
   - Clean caches, `bootc container lint`.

### B. Update capability

- Image reference parameterized via a build arg/env; default local.
- `bootc upgrade` later pulls a newer image from the same reference.
- Kernel update = new image with a freshly precompiled, matching module -> no broken
  modules after an update (advantage over runtime DKMS).

### C. Build & test flow

1. **Build** on the remote Docker host (amd64) via `docker build`.
2. **Create the disk** with `bootc-image-builder` -> `qcow2`.
3. **Upload** the qcow2 to `node2.dro1.pve.fsrv.cloud` and `qm importdisk` into a new VM.
4. **Test VM (new, VMID 110)** like VM 100: q35, `cpu host`, ~12G RAM,
   `hostpci mapping=rtx3080ti`, SeaBIOS (no Secure Boot -> unsigned module OK),
   plus `serial0 socket` (matches `console=ttyS0`; enables `qm terminal`).
   **VM 100 is left untouched.**
5. **Boot with GPU passthrough**, then validate.

### D. Validation (success criteria)

1. `nvidia-smi` on the host detects the RTX 3080 Ti.
2. CUDA detected **inside a container**: `podman run --device nvidia.com/gpu=all`
   runs nvidia-smi and a CUDA driver-API check (`cuDeviceGetCount > 0`, device name)
   via libcuda injected by CDI.
3. `bootc status` shows a clean, update-capable deployment; transient root active.
4. Networking: exactly one global EUI-64 IPv6 address, no IPv4, networkd active.

Access uses SSH over the host's IPv6 address (the qemu-guest-agent runs in a confined
SELinux domain `virt_qemu_ga_t` and may not run nvidia-smi).

## Out of scope (for now)

- Running the vllm container.
- Secure Boot / MOK signing (only needed with UEFI + Secure Boot; the test uses SeaBIOS).
- Final registry choice and CI/CD push.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| akmod build against the wrong kernel | Pin `kernel-devel` to `kernel-core`; check the build log; fallback: kernel upgrade |
| nvidia-container-toolkit can't find libs (CDI) | Generate CDI at runtime (`nvidia-ctk cdi generate`) via a oneshot service after module load |
| Transient root breaks provisioning/login | Bake root/SSH key into `/usr` (not runtime `/etc`); persistent data only under `/var` |
| Passthrough/boot firmware mismatch | Test VM mirrors VM 100 (SeaBIOS); BIB qcow2 is BIOS-capable |
| IPv6-only container pulls fail (Docker Hub) | Use a v6-reachable registry (quay.io) for the CUDA check |

## Test infrastructure (verified)

- **Build:** remote Docker host, linux/amd64.
- **Test:** Proxmox node2 (pve 9.2.4), RTX 3080 Ti `41:00.0` (+audio `41:00.1`),
  resource mapping `rtx3080ti`, `local` storage, `vmpool` (zfs).
  vmbr0 provides an IPv6 RA prefix `2001:67c:828:42::/64` (SLAAC).
- **Reference VM 100** (`ollama-test1`, stopped, `protection: 1`): q35, cpu host,
  `hostpci1: mapping=rtx3080ti`, SeaBIOS, 100G virtio disk on vmpool.
