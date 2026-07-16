FROM quay.io/fedora/fedora-bootc:42

# --- RPM Fusion (free + nonfree) for the proprietary NVIDIA driver ---
RUN set -eux; \
    dnf -y install \
      "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-42.noarch.rpm" \
      "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-42.noarch.rpm"

# --- NVIDIA Container Toolkit repo ---
RUN set -eux; \
    curl -fsSL -o /etc/yum.repos.d/nvidia-container-toolkit.repo \
      https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo

# --- Driver (RPM Fusion), container toolkit, guest agent, networkd/resolved ---
# akmod-nvidia provides the module sources; xorg-x11-drv-nvidia-cuda provides
# nvidia-smi/libcuda. The module build itself happens in the next step.
# install_weak_deps=False keeps the image headless-lean (no desktop/audio bloat
# such as pipewire/mesa-va). nvidia-persistenced is listed explicitly because it
# would otherwise be pulled only as a weak dependency.
RUN set -eux; \
    dnf -y install --setopt=install_weak_deps=False \
      akmod-nvidia \
      xorg-x11-drv-nvidia-cuda \
      nvidia-persistenced \
      nvidia-container-toolkit \
      qemu-guest-agent \
      systemd-networkd \
      systemd-resolved \
      cloud-utils-growpart; \
    dnf clean all

# --- Precompile the NVIDIA kernel module against the image kernel at build time ---
# kernel-devel is pinned to the exact kernel version present in the image. If that
# kernel-devel version is not available in the repos, the kernel is upgraded to the
# latest available version and the pin is recomputed.
RUN set -eux; \
    KVER="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core | sort -V | tail -1)"; \
    if ! dnf -y install "kernel-devel-${KVER}"; then \
      dnf -y upgrade kernel kernel-core kernel-modules kernel-modules-core; \
      KVER="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core | sort -V | tail -1)"; \
      dnf -y install "kernel-devel-${KVER}"; \
    fi; \
    akmods --force --kernels "${KVER}"; \
    depmod -a "${KVER}"; \
    modinfo -k "${KVER}" nvidia >/dev/null; \
    echo "Built nvidia module for kernel ${KVER}"; \
    dnf clean all; \
    rm -rf /var/cache/* /tmp/*

# --- System configuration & provisioning (transient-root safe) ---
COPY files/ /
COPY sshkeys/root.keys /usr/share/sshkeys/root.keys

RUN set -eux; \
    chmod 0755 /usr/libexec/cuda-container-check /usr/libexec/grow-var; \
    chmod 0644 /usr/share/sshkeys/root.keys; \
    # Networking: IPv6-only via systemd-networkd; do without NetworkManager. \
    dnf -y remove NetworkManager NetworkManager-tui 2>/dev/null || true; \
    systemctl mask NetworkManager.service NetworkManager-wait-online.service 2>/dev/null || true; \
    systemctl enable systemd-networkd.service systemd-resolved.service; \
    ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf; \
    # Services. \
    systemctl enable qemu-guest-agent.service; \
    systemctl enable nvidia-cdi-generate.service; \
    systemctl enable grow-var.service; \
    ( systemctl enable nvidia-persistenced.service || true ); \
    # vllm.container / vllm.image are Quadlet units; the generator honors their \
    # [Install] WantedBy, so no explicit enable is needed here. \
    # Runtime akmods is pointless on an immutable/prebuilt image and fails (MOK \
    # keygen on a read-only /etc). Modules are already built at image build time. \
    systemctl mask akmods.service akmods-keygen@.service

LABEL containers.bootc=1

RUN bootc container lint
