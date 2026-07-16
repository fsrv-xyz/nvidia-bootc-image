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

LABEL containers.bootc=1
