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
# Driver + module build + toolchain removal are ONE layer on purpose: akmod-nvidia pulls
# the build toolchain (gcc, kernel-devel, ...); building the module and removing that
# toolchain in the same layer means it never lands in a committed layer, so it is reclaimed
# from the pulled image (a `dnf remove` in a *later* layer would only whiteout it). The
# kernel-devel is pinned to the image kernel; if that version is unavailable, upgrade the
# kernel and re-pin. akmods is masked at runtime — nothing rebuilds modules on the appliance.
RUN set -eux; \
    dnf -y install --setopt=install_weak_deps=False \
      akmod-nvidia \
      xorg-x11-drv-nvidia-cuda \
      nvidia-persistenced \
      nvidia-container-toolkit \
      qemu-guest-agent \
      systemd-networkd \
      systemd-resolved \
      cloud-utils-growpart \
      nvtop; \
    KVER="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core | sort -V | tail -1)"; \
    if ! dnf -y install --setopt=install_weak_deps=False "kernel-devel-${KVER}"; then \
      dnf -y upgrade --setopt=install_weak_deps=False kernel kernel-core kernel-modules kernel-modules-core; \
      KVER="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core | sort -V | tail -1)"; \
      dnf -y install --setopt=install_weak_deps=False "kernel-devel-${KVER}"; \
    fi; \
    akmods --force --kernels "${KVER}"; \
    depmod -a "${KVER}"; \
    modinfo -k "${KVER}" nvidia >/dev/null; \
    echo "Built nvidia module for kernel ${KVER}"; \
    # Drop the build toolchain + the module SOURCE now that the module is compiled — same \
    # layer, so reclaimed from the pull. akmods is masked at runtime and the module is \
    # prebuilt, so kmodsrc is dead weight. grep|xargs removes only installed pkgs; mokutil \
    # stays (shim-x64 requires it for Secure Boot). \
    rpm -qa --qf '%{NAME}\n' | grep -xE \
      'gcc|cpp|binutils|make|kmodtool|akmods|kernel-devel|kernel-devel-matched|kernel-debug-devel|kernel-headers|glibc-devel|elfutils-libelf-devel|annobin-plugin-gcc|gcc-plugin-annobin|xorg-x11-drv-nvidia-kmodsrc' \
      | xargs -r dnf -y remove; \
    # Guard: fail the build if that cascaded into the runtime driver, kernel, or module. \
    rpm -q xorg-x11-drv-nvidia-cuda-libs kernel-core; \
    modinfo -k "${KVER}" nvidia >/dev/null; \
    dnf clean all; \
    rm -rf /var/cache/* /tmp/*

# --- System configuration & provisioning (transient-root safe) ---
COPY files/ /
COPY sshkeys/root.keys /usr/share/sshkeys/root.keys

RUN set -eux; \
    chmod 0755 /usr/libexec/cuda-container-check /usr/libexec/grow-var; \
    chmod 0644 /usr/share/sshkeys/root.keys; \
    # Local root password for console/serial login only (SSH stays key-only via the
    # sshd drop-in). Baked into /etc/shadow so it survives the transient root. \
    # NOTE: this hash ships in the (public) image — "root" is intentionally weak and \
    # meant for local console access, not a secret. \
    echo 'root:root' | chpasswd; \
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
    # Let podman read the bootc bound-image store as a (read-only) additional image
    # store, so a workload image that ships a logically bound image (e.g. the vLLM
    # system overlays) runs it directly from there instead of re-pulling a second
    # copy into the podman r/w store. Generic; useful for any bound-image workload. \
    sed -i 's#^"/usr/lib/containers/storage",#"/usr/lib/containers/storage",\n"/usr/lib/bootc/storage",#' /usr/share/containers/storage.conf; \
    grep -q '/usr/lib/bootc/storage' /usr/share/containers/storage.conf; \
    # Runtime akmods is pointless on an immutable/prebuilt image and fails (MOK \
    # keygen on a read-only /etc). Modules are already built at image build time. \
    systemctl mask akmods.service akmods-keygen@.service

# --- Slim the image for a headless GPU-passthrough VM appliance ---
# Drop base-image packages this use case never touches. All leaves / no-role-here:
#  - cross-arch user-mode emulation + the AWS SDK (leaf; no cloud-init);
#  - firmware for absent hardware (keep nvidia-gpu-firmware + CPU microcode);
#  - service packages with nothing to do: lvm2 (plain partitions), mdadm (no RAID),
#    pcsc-lite (no smartcard), udisks2 (no removable media), avahi/bluez (no mDNS/BT),
#    nfs-utils (no NFS) — which pulls gssproxy + rpcbind (GSSAPI/NFS-Kerberos). libtirpc
#    and krb5-libs stay: nvidia-persistenced/pam/sshd link them;
#  - the sssd AD/IPA backends (no directory here) — removing them lets dnf autoclean drop
#    the ~20 MB samba client cluster they alone pull in, while sssd-common/-client stay
#    (via krb5/ldap) so pam/nss login is untouched;
#  - NetworkManager-libnm (orphan; we use systemd-networkd, the NM daemon is already gone),
#    the NTFS stack (ntfs-3g/ntfsprogs; no Windows filesystems), and ModemManager-glib +
#    fwupd-plugin-modem-manager (no modem).
# Whited-out from the FROM base -> reclaimed from the deployed rootfs (and ISO), not the
# pull. Cannot be dropped: mesa/llvm, gtk3, cups-libs, libtinysparql, avahi-libs (hard deps
# of the NVIDIA driver via nvidia-settings -> gtk3); fuse3/fuse3-libs (ostree/rpm-ostree/
# grub2 — i.e. bootc itself).
RUN set -eux; \
    rpm -qa --qf '%{NAME}\n' | grep -xE \
      'qemu-user-static.*|python3-boto3|python3-botocore|python3-s3transfer|(atheros|mt7xxx|brcmfmac|realtek|nxpwireless|qcom-wwan|tiwilink|amd-gpu|intel-gpu|cirrus-audio|intel-audio)-firmware|lvm2|mdadm|pcsc-lite|udisks2|avahi|bluez|sssd-ad|sssd-ipa|sssd-common-pac|samba-client-libs|samba-common-libs|samba-common|libsmbclient|libwbclient|nfs-utils|gssproxy|rpcbind|NetworkManager-libnm|ntfs-3g|ntfs-3g-libs|ntfs-3g-system-compression|ntfsprogs|ModemManager-glib|fwupd-plugin-modem-manager' \
      | xargs -r dnf -y remove; \
    # sssd-common/-client stay (pam/nss login) — just don't run the daemon. \
    systemctl mask sssd.service; \
    dnf clean all; \
    rm -rf /var/cache/* /tmp/*

LABEL containers.bootc=1

RUN bootc container lint
