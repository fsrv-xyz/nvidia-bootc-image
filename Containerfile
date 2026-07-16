FROM quay.io/fedora/fedora-bootc:42

# --- RPM Fusion (free + nonfree) für den proprietären NVIDIA-Treiber ---
RUN set -eux; \
    dnf -y install \
      "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-42.noarch.rpm" \
      "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-42.noarch.rpm"

# --- NVIDIA Container Toolkit Repo ---
RUN set -eux; \
    curl -fsSL -o /etc/yum.repos.d/nvidia-container-toolkit.repo \
      https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo

# --- Treiber (RPM Fusion), Container-Toolkit, Guest-Agent ---
# akmod-nvidia liefert die Modul-Quellen; xorg-x11-drv-nvidia-cuda liefert nvidia-smi/libcuda.
# Der eigentliche Modul-Build passiert in Task 2.
RUN set -eux; \
    dnf -y install \
      akmod-nvidia \
      xorg-x11-drv-nvidia-cuda \
      nvidia-container-toolkit \
      qemu-guest-agent; \
    dnf clean all

# --- NVIDIA Kernel-Modul zur Build-Zeit gegen den Image-Kernel kompilieren ---
# kernel-devel wird exakt auf die im Image vorhandene Kernel-Version gepinnt.
# Falls die passende kernel-devel-Version nicht im Repo liegt, wird der Kernel
# auf den neuesten verfügbaren Stand gebracht und erneut gepinnt.
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

LABEL containers.bootc=1
