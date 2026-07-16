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

## Layout

| Path | Purpose |
|---|---|
| `Containerfile` | Image definition (driver, container toolkit, module build, networking, config) |
| `build.sh` | Build the image on the remote Docker host (amd64) |
| `make-disk.sh` | Produce a `qcow2` via `bootc-image-builder` |
| `bib/config.toml` | bootc-image-builder config (minimal; provisioning is in the image) |
| `files/` | Content copied into `/` (kargs, modules-load, transient-root, CDI service, networkd, sshd, CUDA check) |
| `sshkeys/root.keys` | Public key for root (baked into `/usr/share/sshkeys`) |
| `test/provision-vm.sh` | Create Proxmox VM 110 with GPU passthrough and start it |
| `test/validate.sh` | Check the success criteria inside the VM (via SSH over IPv6) |

## Build

    export DOCKER_HOST="ssh://root@docker-remote-environment.drudge.systems:222"
    IMAGE_REF=localhost/vllm-bootc:42 ./build.sh

The proprietary driver comes from RPM Fusion. The kernel module (`akmods`) is
precompiled against the exact kernel included in the image, so it is immutable and
available on first boot. `install_weak_deps=False` keeps the image headless-lean.

## Create the disk (qcow2)

    ./make-disk.sh          # output: /root/bib-output/qcow2/disk.qcow2 (on the remote Docker host)

`bootc-image-builder` needs an initialized `containers-storage`. Since the Docker
host has no podman storage, `make-disk.sh` bridges Docker -> BIB via a temporary
local `registry:2` and populates the host `containers-storage` with podman-in-docker.
Fedora bootc declares no default root filesystem type, so `--rootfs ext4` is set.

## Test (Proxmox node2, VM 110, GPU passthrough)

    # Stream the qcow2 to node2:
    ssh -p 222 root@docker-remote-environment.drudge.systems 'cat /root/bib-output/qcow2/disk.qcow2' \
      | ssh root@node2.dro1.pve.fsrv.cloud 'cat > /var/lib/vz/template/vllm-bootc-disk.qcow2'

    ./test/provision-vm.sh   # create + start VM 110 (q35, SeaBIOS, hostpci mapping=rtx3080ti, serial0)
    ./test/validate.sh       # validate networking + nvidia-smi + CUDA in a container

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

Root, SSH key only (`PermitRootLogin prohibit-password`). The key is baked at
`/usr/share/sshkeys/root.keys`; the private test key lives in the repo under
`sshkeys/vllm_bootc_test` (gitignored). Because the host is IPv6-only, connect to
its global SLAAC address (ProxyJump through the Proxmox host):

    ssh -J root@node2.dro1.pve.fsrv.cloud -i sshkeys/vllm_bootc_test root@<vm-ipv6>

Find the address: `ssh root@node2... 'qm guest cmd 110 network-get-interfaces'`.
Console access (no network needed) is available via `qm terminal 110` (serial0).

## CI / GitLab

`.gitlab-ci.yml` uses two shared components (`fsrvcorp/ci-components`):

- `container@0.1.0` — builds the image with `docker buildx` on the remote Docker
  host and pushes to the project registry (`$CI_REGISTRY_IMAGE`). Tag: `latest` on
  the default branch, `<version>` on a git tag, `branch-<ref>` otherwise.
- `semver@0.1.0` — on the default branch, derives the next version from conventional
  commits and creates a git tag, which triggers a versioned image build.

The pushed image is the update base:

    registry.fsrv.services/fsrvcorp/images/nvidia-bootc-image:<tag>

## Update capability

This is a bootc system; it updates transactionally. Point the booted deployment at
the registry image once, then upgrades pull from there:

    # point the running VM at the GitLab registry image (pulls + stages)
    sudo bootc switch registry.fsrv.services/fsrvcorp/images/nvidia-bootc-image:<tag>
    sudo systemctl reboot

    sudo bootc upgrade      # pull a newer image + activate on next boot
    sudo bootc status       # show deployments
    sudo bootc rollback     # roll back to the previous deployment

For local builds the reference is parameterized via `IMAGE_REF`. Because the kernel
module is recompiled against the included kernel on every image build, the driver
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
