# NVIDIA CUDA Fedora bootc Image — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein minimales, immutable (transient-root) Fedora-42 bootc-Image für AMD64, das den proprietären NVIDIA-Treiber (RPM Fusion akmod, zur Build-Zeit vorkompiliert) plus `nvidia-container-toolkit` bereitstellt, in einer Proxmox-VM mit GPU-Passthrough bootet, wo `nvidia-smi` die GPU erkennt und CUDA im Container funktioniert.

**Architecture:** `Containerfile` auf Basis `quay.io/fedora/fedora-bootc:42` installiert Treiber + Container-Toolkit + qemu-guest-agent, backt das Kernel-Modul via `akmods` zur Build-Zeit ein und legt System-Konfig (nouveau-blacklist kargs, modules-load, transient-root, CDI-Generate-Service, User/SSH) ab. Build läuft via Docker auf dem Remote-Host; ein temporäres `registry:2` überbrückt das Image zu `bootc-image-builder` (qcow2). Die qcow2 wird nach Proxmox node2 transferiert, als VM 110 mit `rtx3080ti`-Passthrough importiert und gebootet. Validierung via qemu-guest-agent `exec`.

**Tech Stack:** Fedora bootc, RPM Fusion, dnf5, akmods, nvidia-container-toolkit (CDI), podman, bootc-image-builder, Docker (Remote), Proxmox VE (`qm`), qemu-guest-agent.

## Global Constraints

- Zielarchitektur: **linux/amd64** (alle Builds mit `--platform linux/amd64`).
- Basis-Image: **`quay.io/fedora/fedora-bootc:42`** (exakt Fedora 42).
- Treiber ausschließlich aus **RPM Fusion** (`akmod-nvidia` + `xorg-x11-drv-nvidia-cuda`). **Kein** CUDA-Dev-Toolkit (`nvcc`) auf dem Host.
- Kernel-Modul wird **zur Build-Zeit** vorkompiliert (kein DKMS/akmods zur Laufzeit).
- Root-Dateisystem **transient** (`root.transient = true`); nur `/var` persistent. Alle Provisionierung (User, SSH, sudo, Konfig) wird **im Image** unter `/usr` bzw. build-time-`/etc` gebacken.
- Build-Host (Docker Remote): `DOCKER_HOST="ssh://root@docker-remote-environment.drudge.systems:222"`.
- Test-Host (Proxmox): `node2.dro1.pve.fsrv.cloud`, GPU-Mapping `rtx3080ti`, Storage `vmpool` (VM-Disks) / `local` (Dateien). **Neue VM-ID: 110.** VM 100 bleibt unangetastet.
- Image-Referenz parametrierbar über Env `IMAGE_REF` (Default `localhost/vllm-bootc:42`), damit `bootc upgrade` später gegen eine echte Registry zeigt.
- Alle Commit-Messages: Conventional-Commits-Präfix (`feat:`/`fix:`/`docs:`/`chore:` …) — sonst blockt der commit-msg-Hook.

---

### Task 1: Projekt-Gerüst + Containerfile (Basis, Repos, Treiber-Pakete, Container-Toolkit)

Erzeugt ein baubares Image **ohne** den Kernel-Modul-Build (kommt in Task 2). Deliverable: `docker build` läuft durch und die Treiberpakete + Container-Toolkit + guest-agent sind installiert.

**Files:**
- Create: `Containerfile`
- Create: `build.sh`
- Create: `.dockerignore`

**Interfaces:**
- Produces: baubares Image-Stage mit RPM-Fusion-Repos aktiv, Paketen `akmod-nvidia`, `xorg-x11-drv-nvidia-cuda`, `nvidia-container-toolkit`, `qemu-guest-agent` installiert.
- Produces: `build.sh` mit Env `IMAGE_REF` (Default `localhost/vllm-bootc:42`), baut auf Docker Remote.

- [ ] **Step 1: `.dockerignore` anlegen**

```
docs/
*.qcow2
*.raw
output/
.git/
```

- [ ] **Step 2: Containerfile (Basis-Version) schreiben**

`Containerfile`:

```dockerfile
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
```

- [ ] **Step 3: `build.sh` schreiben**

`build.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Baut das bootc-Image auf dem Docker-Remote-Host (amd64).
: "${IMAGE_REF:=localhost/vllm-bootc:42}"
export DOCKER_HOST="${DOCKER_HOST:-ssh://root@docker-remote-environment.drudge.systems:222}"

echo ">> Building ${IMAGE_REF} on ${DOCKER_HOST}"
docker build --platform linux/amd64 -t "${IMAGE_REF}" -f Containerfile .
echo ">> Done: ${IMAGE_REF}"
```

```bash
chmod +x build.sh
```

- [ ] **Step 4: Build ausführen (Verifikation)**

Run:
```bash
./build.sh
```
Expected: Build endet mit `>> Done: localhost/vllm-bootc:42`, keine dnf-Fehler.

- [ ] **Step 5: Pakete im Image verifizieren**

Run:
```bash
DOCKER_HOST="ssh://root@docker-remote-environment.drudge.systems:222" \
  docker run --rm --platform linux/amd64 localhost/vllm-bootc:42 \
  rpm -q akmod-nvidia xorg-x11-drv-nvidia-cuda nvidia-container-toolkit qemu-guest-agent nvidia-smi
```
Expected: alle Pakete mit Version gelistet (kein „not installed"). `nvidia-smi` als Datei-Provider von `xorg-x11-drv-nvidia-cuda` ist vorhanden.

- [ ] **Step 6: Commit**

```bash
git add Containerfile build.sh .dockerignore
git commit -m "feat: base bootc image with nvidia driver packages and container toolkit"
```

---

### Task 2: Kernel-Modul zur Build-Zeit vorkompilieren

Deliverable: Das gebaute Image enthält das vorkompilierte `nvidia.ko` für den Image-Kernel; `modinfo` findet es.

**Files:**
- Modify: `Containerfile` (Modul-Build-Stage ergänzen)

**Interfaces:**
- Consumes: installiertes `akmod-nvidia` aus Task 1.
- Produces: `/usr/lib/modules/<KVER>/extra/nvidia/nvidia*.ko*` im Image, `depmod`-Metadaten aktuell.

- [ ] **Step 1: Modul-Build in Containerfile ergänzen**

In `Containerfile` **nach** dem Treiber-Install-Block (vor `LABEL`) einfügen:

```dockerfile
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
```

- [ ] **Step 2: Neu bauen**

Run:
```bash
./build.sh
```
Expected: Zeile `Built nvidia module for kernel <KVER>` erscheint; Build endet erfolgreich.

- [ ] **Step 3: Modul im Image verifizieren**

Run:
```bash
DOCKER_HOST="ssh://root@docker-remote-environment.drudge.systems:222" \
  docker run --rm --platform linux/amd64 localhost/vllm-bootc:42 bash -c \
  'KVER=$(ls /usr/lib/modules | sort -V | tail -1); echo "KVER=$KVER"; modinfo -k "$KVER" nvidia | head -5; ls -1 /usr/lib/modules/$KVER/extra/nvidia/'
```
Expected: `modinfo` zeigt `filename`, `version` (Treiberversion), `license: NVIDIA`; `.ko.xz`/`.ko`-Dateien (nvidia, nvidia-modeset, nvidia-uvm, nvidia-drm) gelistet.

- [ ] **Step 4: Commit**

```bash
git add Containerfile
git commit -m "feat: precompile nvidia kernel module at build time"
```

---

### Task 3: System-Konfiguration (kargs, module load, transient root, CDI-Service, User/SSH, CUDA-Check)

Deliverable: Alle Drop-ins/Services/Provisionierung im Image; `bootc container lint` ist grün.

**Files:**
- Create: `files/usr/lib/bootc/kargs.d/00-nvidia.toml`
- Create: `files/usr/lib/modules-load.d/nvidia.conf`
- Create: `files/usr/lib/ostree/prepare-root.conf`
- Create: `files/usr/lib/systemd/system/nvidia-cdi-generate.service`
- Create: `files/usr/lib/tmpfiles.d/florian-home.conf`
- Create: `files/etc/ssh/sshd_config.d/10-florian.conf`
- Create: `files/etc/sudoers.d/wheel-nopasswd`
- Create: `files/usr/libexec/cuda-container-check`
- Create: `sshkeys/florian.keys` (generierter Pubkey)
- Modify: `Containerfile` (COPY der files, useradd, Services enablen, lint)

**Interfaces:**
- Consumes: Treiber + Container-Toolkit aus Task 1/2.
- Produces: bootbares, konfiguriertes Image; SSH-Login als `florian` (key-only), passwortloses sudo; `nvidia-cdi-generate.service` schreibt beim Boot `/etc/cdi/nvidia.yaml`; `/usr/libexec/cuda-container-check` validiert CUDA im Container.

- [ ] **Step 1: SSH-Keypair für den Test erzeugen**

Run:
```bash
mkdir -p sshkeys
ssh-keygen -t ed25519 -N '' -C 'vllm-bootc-test' -f sshkeys/vllm_bootc_test
cp sshkeys/vllm_bootc_test.pub sshkeys/florian.keys
```
Expected: `sshkeys/vllm_bootc_test` (privat), `sshkeys/florian.keys` (public). Der private Key wird in Task 5/6 auf node2 gebraucht.

- [ ] **Step 2: kargs-Drop-in (nouveau blacklist + drm modeset)**

`files/usr/lib/bootc/kargs.d/00-nvidia.toml`:

```toml
kargs = [
  "rd.driver.blacklist=nouveau",
  "modprobe.blacklist=nouveau",
  "nvidia-drm.modeset=1",
]
```

- [ ] **Step 3: modules-load Drop-in**

`files/usr/lib/modules-load.d/nvidia.conf`:

```
nvidia
nvidia_modeset
nvidia_uvm
nvidia_drm
```

- [ ] **Step 4: transient-root aktivieren**

`files/usr/lib/ostree/prepare-root.conf`:

```ini
[composefs]
enabled = true

[sysroot]
readonly = true

[root]
transient = true
```

- [ ] **Step 5: CDI-Generate-Service**

`files/usr/lib/systemd/system/nvidia-cdi-generate.service`:

```ini
[Unit]
Description=Generate NVIDIA CDI spec for podman
After=local-fs.target systemd-modules-load.service
Wants=systemd-modules-load.service
ConditionPathExists=/usr/bin/nvidia-ctk

[Service]
Type=oneshot
RemainAfterExit=yes
# Geräteknoten sicherstellen (nvidia0 + uvm), dann CDI-Spec nach /etc/cdi schreiben.
ExecStartPre=-/usr/bin/nvidia-modprobe -c 0 -u
ExecStart=/usr/bin/nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
ExecStartPost=/usr/bin/nvidia-ctk cdi list

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 6: tmpfiles für Home-Verzeichnis (persistent unter /var)**

`files/usr/lib/tmpfiles.d/florian-home.conf`:

```
d /var/home/florian 0700 florian florian - -
```

- [ ] **Step 7: sshd AuthorizedKeysFile in /usr (transient-root-fest)**

`files/etc/ssh/sshd_config.d/10-florian.conf`:

```
AuthorizedKeysFile /usr/share/sshkeys/%u.keys
```

- [ ] **Step 8: passwortloses sudo für wheel**

`files/etc/sudoers.d/wheel-nopasswd`:

```
%wheel ALL=(ALL) NOPASSWD: ALL
```

- [ ] **Step 9: CUDA-Container-Check-Skript**

`files/usr/libexec/cuda-container-check`:

```bash
#!/usr/bin/env bash
# Validiert CUDA im Container: nvidia-smi + cudaGetDeviceCount via nvcc.
set -euo pipefail
IMAGE="${CUDA_IMAGE:-docker.io/nvidia/cuda:12.6.2-devel-ubi9}"

echo "== nvidia-smi im Container =="
podman run --rm --device nvidia.com/gpu=all --security-opt label=disable \
  "${IMAGE}" nvidia-smi

echo "== CUDA runtime check (cudaGetDeviceCount) =="
podman run --rm --device nvidia.com/gpu=all --security-opt label=disable \
  "${IMAGE}" bash -c '
cat > /tmp/q.cu <<EOF
#include <cstdio>
#include <cuda_runtime.h>
int main(){
  int n=0; cudaError_t e=cudaGetDeviceCount(&n);
  if(e){printf("CUDA error: %s\n", cudaGetErrorString(e)); return 1;}
  printf("CUDA devices: %d\n", n);
  for(int i=0;i<n;i++){cudaDeviceProp p; cudaGetDeviceProperties(&p,i);
    printf("  [%d] %s  cc %d.%d  %.1f GiB\n", i, p.name, p.major, p.minor,
           p.totalGlobalMem/1073741824.0);}
  return n>0?0:2;
}
EOF
nvcc -o /tmp/q /tmp/q.cu && /tmp/q'
```

- [ ] **Step 10: Containerfile um COPY/useradd/enable/lint erweitern**

In `Containerfile` **vor** `LABEL containers.bootc=1` einfügen:

```dockerfile
# --- System-Konfiguration & Provisionierung (transient-root-fest) ---
COPY files/ /
COPY sshkeys/florian.keys /usr/share/sshkeys/florian.keys

RUN set -eux; \
    chmod 0755 /usr/libexec/cuda-container-check; \
    chmod 0644 /usr/share/sshkeys/florian.keys; \
    chmod 0440 /etc/sudoers.d/wheel-nopasswd; \
    # Login-User (Home wird via tmpfiles unter /var/home angelegt) \
    useradd -M -G wheel florian; \
    # Services aktivieren \
    systemctl enable qemu-guest-agent.service; \
    systemctl enable nvidia-cdi-generate.service; \
    ( systemctl enable nvidia-persistenced.service || true )
```

Und **ganz am Ende** des Containerfiles ergänzen:

```dockerfile
RUN bootc container lint
```

- [ ] **Step 11: Neu bauen**

Run:
```bash
./build.sh
```
Expected: Build inkl. `bootc container lint` erfolgreich (keine Lint-Fehler).

- [ ] **Step 12: Konfig im Image verifizieren**

Run:
```bash
DOCKER_HOST="ssh://root@docker-remote-environment.drudge.systems:222" \
  docker run --rm --platform linux/amd64 localhost/vllm-bootc:42 bash -c '
set -e
echo "--- prepare-root ---"; grep -A1 "\[root\]" /usr/lib/ostree/prepare-root.conf
echo "--- kargs ---"; cat /usr/lib/bootc/kargs.d/00-nvidia.toml
echo "--- user ---"; id florian
echo "--- services ---"; systemctl is-enabled qemu-guest-agent nvidia-cdi-generate || true
echo "--- sshkey ---"; test -f /usr/share/sshkeys/florian.keys && echo OK
echo "--- check script ---"; test -x /usr/libexec/cuda-container-check && echo OK'
```
Expected: `transient = true`, kargs korrekt, `uid=…(florian)` mit Gruppe wheel, Services `enabled`, beide `OK`.

- [ ] **Step 13: Commit**

```bash
git add Containerfile files/ sshkeys/florian.keys
git commit -m "feat: system config for transient-root, cdi, user provisioning and cuda check"
```

Hinweis: `sshkeys/vllm_bootc_test` (privat) ist per `.gitignore` auszuschließen.

- [ ] **Step 14: privaten Key ignorieren**

`.gitignore` ergänzen:
```
sshkeys/vllm_bootc_test
```
Run:
```bash
git rm --cached sshkeys/vllm_bootc_test 2>/dev/null || true
git add .gitignore
git commit -m "chore: ignore private test ssh key"
```

---

### Task 4: qcow2-Disk via bootc-image-builder erzeugen

Deliverable: eine bootbare `disk.qcow2` auf dem Docker-Remote-Host, gebaut aus dem Image über eine temporäre lokale Registry.

**Files:**
- Create: `make-disk.sh`
- Create: `bib/config.toml`

**Interfaces:**
- Consumes: Image `localhost/vllm-bootc:42` in Docker (Remote).
- Produces: `/root/bib-output/qcow2/disk.qcow2` auf dem Remote-Host.

- [ ] **Step 1: BIB-config.toml (minimal, Provisionierung ist im Image)**

`bib/config.toml`:

```toml
# Provisionierung (User/SSH/sudo) ist bereits im Image gebacken.
# Diese Datei bleibt bewusst minimal; sie dokumentiert den Ort für spätere Anpassungen.
[customizations]
```

- [ ] **Step 2: make-disk.sh schreiben**

`make-disk.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Erzeugt eine qcow2 aus dem bootc-Image via bootc-image-builder.
# Brücke Docker->BIB: temporäre lokale registry:2 (127.0.0.1:5000, von Docker
# automatisch als "insecure" behandelt), BIB zieht mit --tls-verify=false.
: "${IMAGE_REF:=localhost/vllm-bootc:42}"
export DOCKER_HOST="${DOCKER_HOST:-ssh://root@docker-remote-environment.drudge.systems:222}"

REG_LOCAL="127.0.0.1:5000/vllm-bootc:42"
OUT_DIR="/root/bib-output"

echo ">> Starte temporäre Registry"
docker rm -f bib-registry >/dev/null 2>&1 || true
docker run -d --name bib-registry -p 5000:5000 registry:2 >/dev/null

echo ">> Push ${IMAGE_REF} -> ${REG_LOCAL}"
docker tag "${IMAGE_REF}" "${REG_LOCAL}"
docker push "${REG_LOCAL}"

echo ">> Bereite Output-Verzeichnis + config auf Remote-Host vor"
docker run --rm -v /root:/host alpine sh -c "mkdir -p /host/bib-output"
# config.toml auf den Remote-Host bringen (über einen Hilfscontainer via stdin):
docker run --rm -i -v /root/bib-output:/out alpine sh -c 'cat > /out/config.toml' < bib/config.toml

echo ">> bootc-image-builder -> qcow2"
docker run --rm --privileged --network host \
  --security-opt label=disable \
  -v "${OUT_DIR}:/output" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "${OUT_DIR}/config.toml:/config.toml:ro" \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  --tls-verify=false \
  --config /config.toml \
  "${REG_LOCAL}"

echo ">> Aufräumen Registry"
docker rm -f bib-registry >/dev/null 2>&1 || true

echo ">> Fertig: ${OUT_DIR}/qcow2/disk.qcow2 (auf Remote-Host)"
```

```bash
chmod +x make-disk.sh
```

- [ ] **Step 3: Disk erzeugen**

Run:
```bash
./make-disk.sh
```
Expected: BIB läuft durch (manifest → build → qcow2), endet mit `Fertig:`-Zeile. Bei Pull-Fehlern der lokalen Registry: prüfen, dass `--network host` und `--tls-verify=false` gesetzt sind.

- [ ] **Step 4: qcow2 verifizieren**

Run:
```bash
ssh -p 222 root@docker-remote-environment.drudge.systems \
  'ls -lh /root/bib-output/qcow2/disk.qcow2 && qemu-img info /root/bib-output/qcow2/disk.qcow2'
```
Expected: Datei existiert (mehrere GB), `file format: qcow2`.

- [ ] **Step 5: Commit**

```bash
git add make-disk.sh bib/config.toml
git commit -m "feat: build qcow2 disk image via bootc-image-builder"
```

---

### Task 5: Test-VM 110 auf Proxmox erzeugen und booten

Deliverable: VM 110 läuft mit GPU-Passthrough; qemu-guest-agent antwortet.

**Files:**
- Create: `test/provision-vm.sh`

**Interfaces:**
- Consumes: qcow2 auf Docker-Remote-Host.
- Produces: laufende Proxmox-VM 110 mit `virtio0` (bootc-Disk auf `vmpool`) + `hostpci0: mapping=rtx3080ti`.

- [ ] **Step 1: qcow2 auf node2 transferieren**

Da direkte Konnektivität Remote-Host↔node2 nicht garantiert ist, wird durch die lokale Session gestreamt.

Run:
```bash
ssh -p 222 root@docker-remote-environment.drudge.systems 'cat /root/bib-output/qcow2/disk.qcow2' \
  | ssh root@node2.dro1.pve.fsrv.cloud 'cat > /var/lib/vz/template/vllm-bootc-disk.qcow2'
ssh root@node2.dro1.pve.fsrv.cloud 'ls -lh /var/lib/vz/template/vllm-bootc-disk.qcow2 && qemu-img info /var/lib/vz/template/vllm-bootc-disk.qcow2'
```
Expected: Datei auf node2 vorhanden, `qcow2`-Format bestätigt.

- [ ] **Step 2: provision-vm.sh schreiben**

`test/provision-vm.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Erzeugt Proxmox-VM 110 analog VM 100 (q35, cpu host, SeaBIOS) mit GPU-Passthrough.
NODE="${NODE:-root@node2.dro1.pve.fsrv.cloud}"
VMID="${VMID:-110}"
DISK="${DISK:-/var/lib/vz/template/vllm-bootc-disk.qcow2}"
STORAGE="${STORAGE:-vmpool}"

ssh "${NODE}" bash -s <<EOF
set -euo pipefail
if qm status ${VMID} >/dev/null 2>&1; then
  echo "VM ${VMID} existiert bereits — Abbruch (manuell prüfen/entfernen)."; exit 1
fi
qm create ${VMID} --name vllm-bootc-test --machine q35 --cpu host --cores 4 \
  --memory 12288 --numa 1 --ostype l26 --agent 1 \
  --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr0 --bios seabios --vga std
echo ">> importdisk"
qm importdisk ${VMID} ${DISK} ${STORAGE}
qm set ${VMID} --virtio0 ${STORAGE}:vm-${VMID}-disk-0,iothread=1
qm set ${VMID} --boot order=virtio0
echo ">> GPU-Passthrough"
qm set ${VMID} --hostpci0 mapping=rtx3080ti,pcie=1
echo ">> Start"
qm start ${VMID}
qm config ${VMID}
EOF
```

```bash
chmod +x test/provision-vm.sh
```

- [ ] **Step 3: GPU-Verfügbarkeit prüfen (keine andere VM nutzt sie)**

Run:
```bash
ssh root@node2.dro1.pve.fsrv.cloud 'qm list | grep -E "running|VMID"; echo "---"; qm config 100 | grep hostpci || true'
```
Expected: keine laufende VM belegt `rtx3080ti` (VM 100 stopped). Falls belegt: klären, bevor Task fortgesetzt wird.

- [ ] **Step 4: VM erzeugen und starten**

Run:
```bash
./test/provision-vm.sh
```
Expected: `qm config 110` zeigt `virtio0`, `hostpci0: mapping=rtx3080ti,pcie=1`, `machine: q35`, `bios: seabios`. Kein Fehler beim Start.

- [ ] **Step 5: Boot + Guest-Agent abwarten**

Run:
```bash
ssh root@node2.dro1.pve.fsrv.cloud 'for i in $(seq 1 30); do if qm guest cmd 110 ping >/dev/null 2>&1; then echo "guest-agent up"; break; fi; sleep 5; done; qm guest cmd 110 get-osinfo 2>/dev/null || echo "agent noch nicht bereit"'
```
Expected: `guest-agent up` und OS-Info (Fedora). Falls nach ~150s nichts: Konsole prüfen (`qm terminal 110` / Proxmox-Web-Konsole) → systematic-debugging (z.B. Boot-Firmware, GRUB, nouveau).

- [ ] **Step 6: Commit**

```bash
git add test/provision-vm.sh
git commit -m "feat: provision proxmox test vm 110 with gpu passthrough"
```

---

### Task 6: Validierung der Erfolgskriterien

Deliverable: `nvidia-smi` erkennt die GPU auf dem Host; CUDA im Container erkennt die GPU; bootc-Status + transient-root bestätigt.

**Files:**
- Create: `test/validate.sh`

**Interfaces:**
- Consumes: laufende VM 110 (guest-agent).
- Produces: Validierungsreport (nvidia-smi, CUDA-Container, bootc status).

- [ ] **Step 1: validate.sh schreiben**

`test/validate.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Führt Kommandos in der VM via qemu-guest-agent aus und gibt stdout aus.
NODE="${NODE:-root@node2.dro1.pve.fsrv.cloud}"
VMID="${VMID:-110}"

run() {  # run <timeout> <cmd...>
  local to="$1"; shift
  ssh "${NODE}" "qm guest exec ${VMID} --timeout ${to} -- $*" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("out-data",""));sys.stderr.write(d.get("err-data",""));sys.exit(d.get("exitcode",0) or 0)'
}

echo "############ 1) nvidia-smi (Host) ############"
run 60 /usr/bin/nvidia-smi

echo "############ 2) Kernel-Modul geladen ############"
run 30 /usr/bin/bash -lc 'lsmod | grep nvidia'

echo "############ 3) CDI-Spec vorhanden ############"
run 30 /usr/bin/bash -lc 'ls -l /etc/cdi/ && nvidia-ctk cdi list'

echo "############ 4) CUDA im Container ############"
run 600 /usr/libexec/cuda-container-check

echo "############ 5) bootc status + transient root ############"
run 30 /usr/bin/bootc status
run 30 /usr/bin/bash -lc 'findmnt / -o SOURCE,FSTYPE,OPTIONS; echo; grep -H . /usr/lib/ostree/prepare-root.conf'

echo "############ ALLE CHECKS DURCH ############"
```

```bash
chmod +x test/validate.sh
```

- [ ] **Step 2: Validierung ausführen**

Run:
```bash
./test/validate.sh
```
Expected:
1. `nvidia-smi` listet „NVIDIA GeForce RTX 3080 Ti" + Treiberversion + CUDA-Version.
2. `lsmod` zeigt `nvidia`, `nvidia_uvm`, `nvidia_modeset`.
3. `/etc/cdi/nvidia.yaml` existiert, `nvidia-ctk cdi list` zeigt `nvidia.com/gpu=all`.
4. `cuda-container-check`: `nvidia-smi` im Container + `CUDA devices: 1` + `[0] NVIDIA GeForce RTX 3080 Ti cc 8.6`.
5. `bootc status` zeigt gebootetes Image; `findmnt /` zeigt overlay/tmpfs-transient Root; `prepare-root.conf` mit `transient = true`.

Bei Fehlern (z.B. `nvidia-smi` „No devices"): systematic-debugging — prüfen ob nouveau geblacklistet ist (`lsmod | grep nouveau` leer), Passthrough im Gast sichtbar (`lspci -nnk | grep -iA3 nvidia`), Modul-Version passt zum Kernel.

- [ ] **Step 3: Commit**

```bash
git add test/validate.sh
git commit -m "feat: validation script for nvidia-smi and cuda-in-container"
```

---

### Task 7: Dokumentation (README) inkl. Update-Pfad

Deliverable: `README.md` beschreibt Build, Disk-Erzeugung, Test und den `bootc upgrade`-Update-Pfad.

**Files:**
- Create: `README.md`

- [ ] **Step 1: README schreiben**

`README.md` mit Abschnitten:

```markdown
# vllm-bootc — Fedora bootc Image mit NVIDIA-Treiber + CUDA

Minimales, immutable (transient-root) Fedora-42 bootc-Image für AMD64 mit
proprietärem NVIDIA-Treiber (RPM Fusion, zur Build-Zeit vorkompiliert) und
`nvidia-container-toolkit`. Ziel: GPU-Workloads (später vllm) als Container.

## Build
    export DOCKER_HOST="ssh://root@docker-remote-environment.drudge.systems:222"
    IMAGE_REF=localhost/vllm-bootc:42 ./build.sh

## Disk (qcow2) erzeugen
    ./make-disk.sh          # Ausgabe: /root/bib-output/qcow2/disk.qcow2 (Remote-Host)

## Test (Proxmox node2, VM 110, GPU-Passthrough)
    # qcow2 nach node2 streamen (siehe Plan Task 5, Step 1), dann:
    ./test/provision-vm.sh
    ./test/validate.sh

## Erfolgskriterien
- `nvidia-smi` erkennt die GPU auf dem Host.
- CUDA im Container erkannt (`cuda-container-check`).

## Update-Fähigkeit
Das System ist ein bootc-Image und aktualisiert transaktional. Sobald das Image
in eine erreichbare Registry gepusht ist (statt `localhost/...`), zeigt die
gebootete Referenz dorthin und Updates laufen über:

    sudo bootc upgrade      # neues Image ziehen + beim nächsten Boot aktivieren
    sudo bootc status       # Deployments anzeigen
    sudo bootc rollback     # auf vorheriges Deployment zurück

Da das Kernel-Modul bei jedem Image-Build gegen den enthaltenen Kernel neu
vorkompiliert wird, bleibt der Treiber nach Kernel-Updates konsistent.

## Immutability
- Root-Dateisystem transient (`root.transient=true`): Änderungen außerhalb
  `/var` sind pro Boot flüchtig. Persistente Daten gehören unter `/var`.
- `/usr` read-only (composefs/fs-verity).

## Scope / offen
- vllm-Container-Betrieb (separat).
- Secure Boot / MOK-Signierung (nur bei UEFI+SB nötig; Test nutzt SeaBIOS).
- Finale Registry + CI-Push.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with build, test and bootc upgrade flow"
```

---

## Self-Review-Ergebnis

- **Spec-Coverage:** Treiber via RPM Fusion akmod (T1/T2), kein Host-CUDA-Toolkit (T1), nvidia-container-toolkit + CDI (T1/T3), transient-root (T3), kernel-modul build-time (T2), qcow2+VM+Passthrough (T4/T5), nvidia-smi + CUDA-im-Container Validierung (T6), Update-Pfad/parametrierbare Referenz (build.sh/T7). Alle Spec-Punkte abgedeckt.
- **Platzhalter:** keine „TBD/TODO" — alle Datei-Inhalte und Kommandos vollständig.
- **Typ-/Namens-Konsistenz:** `IMAGE_REF`, VMID 110, `rtx3080ti`, Pfade `/root/bib-output/qcow2/disk.qcow2`, `/usr/libexec/cuda-container-check` durchgängig identisch verwendet.
- **Bekannte Risiken mit Execution-Fallbacks:** kernel-devel-Pin (T2 Auto-Fallback auf Kernel-Upgrade), SeaBIOS-Boot (T5 Step 5 Konsole/OVMF), CDI-Geräteknoten (T3 ExecStartPre nvidia-modprobe), transient-root-Login (Provisionierung in /usr gebacken).
