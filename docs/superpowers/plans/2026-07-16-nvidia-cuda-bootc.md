# NVIDIA CUDA Fedora bootc image — Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan
> task by task. The concrete artifacts (Containerfile, scripts, drop-ins) live in the
> repository; this plan documents the steps and their verification.

**Goal:** A minimal, immutable (transient-root), IPv6-only Fedora 42 bootc image for
AMD64 that provides the proprietary NVIDIA driver (RPM Fusion akmod, precompiled at
build time) plus `nvidia-container-toolkit`, boots in a Proxmox VM with GPU
passthrough where `nvidia-smi` detects the GPU and CUDA works inside a container.

**Architecture:** `Containerfile` on `quay.io/fedora/fedora-bootc:42` installs the
driver + container toolkit + guest agent + systemd-networkd, precompiles the kernel
module via `akmods`, and lays down system config (nouveau-blacklist kargs,
modules-load, transient root, CDI generate service, IPv6-only networkd, root SSH).
The build runs via Docker on the remote host; a temporary `registry:2` bridges the
image to `bootc-image-builder` (qcow2). The qcow2 is transferred to Proxmox node2,
imported as VM 110 with `rtx3080ti` passthrough, and booted. Validation is via SSH
over the host's IPv6 SLAAC address.

**Tech Stack:** Fedora bootc, RPM Fusion, dnf5, akmods, nvidia-container-toolkit
(CDI), podman, systemd-networkd/resolved, bootc-image-builder, Docker (remote),
Proxmox VE (`qm`), qemu-guest-agent.

## Global Constraints

- Target architecture: **linux/amd64**.
- Base image: **`quay.io/fedora/fedora-bootc:42`**.
- Driver from **RPM Fusion** only (`akmod-nvidia` + `xorg-x11-drv-nvidia-cuda`). No
  CUDA dev toolkit (`nvcc`) on the host.
- Kernel module precompiled **at build time** (no runtime DKMS/akmods).
- Root filesystem **transient** (`root.transient = true`); only `/var` persistent.
  All provisioning baked into the image under `/usr` (transient-root safe).
- **IPv6-only** via SLAAC, single stable EUI-64 address, systemd-networkd, no DHCP,
  no NetworkManager.
- **root only**, SSH key based; no additional human users.
- All repository content in English.
- Build host (remote Docker): `DOCKER_HOST="ssh://root@docker-remote-environment.drudge.systems:222"`.
- Test host (Proxmox): `node2.dro1.pve.fsrv.cloud`, GPU mapping `rtx3080ti`, storage
  `vmpool` (VM disks) / `local` (files). **New VM ID: 110.** VM 100 stays untouched.
- Image reference parameterized via `IMAGE_REF` (default `localhost/vllm-bootc:42`).

## Tasks

### Task 1: Base Containerfile + build.sh
Base image + RPM Fusion + NVIDIA Container Toolkit repo; install `akmod-nvidia`,
`xorg-x11-drv-nvidia-cuda`, `nvidia-persistenced`, `nvidia-container-toolkit`,
`qemu-guest-agent`, `systemd-networkd`, `systemd-resolved` with
`install_weak_deps=False`. `build.sh` builds on the remote Docker host.
**Verify:** build succeeds; `rpm -q` lists all packages; `nvidia-smi` present.

### Task 2: Precompile the NVIDIA kernel module
Add the akmods build-time compile to the Containerfile, pinning `kernel-devel` to the
image kernel with an automatic fallback to a kernel upgrade.
**Verify:** `modinfo` finds `nvidia` in the built image; `.ko.xz` files present.

### Task 3: System configuration drop-ins
`files/`: nouveau-blacklist kargs, modules-load, `prepare-root.conf`
(`transient = true`), CDI generate service, IPv6-only `.network`, root sshd config,
`cuda-container-check`. Containerfile copies `files/`, bakes `root.keys`, configures
networking (remove/mask NetworkManager, enable networkd/resolved, resolv.conf symlink),
enables services, masks `akmods*`, runs `bootc container lint`.
**Verify:** lint passes; config present in the image (`transient = true`, kargs, root
key, services enabled, networkd enabled, NetworkManager masked/removed).

### Task 4: qcow2 via bootc-image-builder
`make-disk.sh` + `bib/config.toml`. Bridge Docker -> BIB via a temporary local
registry, populate the host containers-storage with podman-in-docker, run BIB with
`--rootfs ext4`.
**Verify:** `qemu-img info` shows a qcow2 on the remote host.

### Task 5: Provision Proxmox VM 110
Stream the qcow2 to node2, `test/provision-vm.sh` creates VM 110 (q35, cpu host,
SeaBIOS, `serial0 socket`, `hostpci0 mapping=rtx3080ti`), boots it.
**Verify:** guest-agent responds; Fedora 42, kernel matches the built module.

### Task 6: Validate success criteria
`test/validate.sh` (SSH over the VM's IPv6 SLAAC address, root):
networking (single EUI-64 global, no IPv4, networkd active), `nvidia-smi` on the host,
modules loaded, CDI spec present, CUDA inside a container (`cuDeviceGetCount = 1`),
`bootc status` + transient root, no failed units.
**Verify:** all checks pass.

### Task 7: README
`README.md` documenting build, disk creation, test, networking, root access, and the
`bootc upgrade` update path.

## Notes from execution

- Driver built: 580.159.03; image kernel: 6.19.14-101.fc42.x86_64.
- The remote Docker host has limited disk; BIB needs headroom for the osbuild store
  plus the output copy (ext4 has no reflink). Prune Docker if space is tight.
- The qemu-guest-agent runs confined (SELinux `virt_qemu_ga_t`) and cannot execute
  `nvidia-smi`; validation therefore uses SSH.
- Two boot-time service failures were fixed: `akmods-keygen@` (masked) and
  `serial-getty@ttyS0` (added `serial0 socket` to the VM).
- vmbr0 provides an IPv6 RA prefix `2001:67c:828:42::/64`, so IPv6-only SLAAC is
  reachable for testing.
