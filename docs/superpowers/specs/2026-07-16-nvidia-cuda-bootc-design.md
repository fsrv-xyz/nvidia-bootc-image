# Fedora bootc Image mit NVIDIA-Treiber + CUDA — Design

**Datum:** 2026-07-16
**Status:** Approved (Design)

## Ziel

Ein Fedora-basiertes **bootc**-Image für **AMD64**, das eine NVIDIA-GPU
(Zielsystem: RTX 4000 Ada) mit dem **neuesten proprietären Treiber** und
**CUDA** bereitstellt. Das Image soll so **minimal**, **immutable** und
**read-only** wie im bootc-Rahmen möglich sein und **update-fähig** bleiben.
Später (out of scope) läuft vllm als Container darauf.

**Erfolgskriterium:** Image in einer Proxmox-Test-VM (mit PCIe-Passthrough der
RTX 3080 Ti) gebootet; `nvidia-smi` erkennt die GPU und ein CUDA-Programm
(`deviceQuery` via `nvcc`) erkennt die GPU über CUDA.

## Entscheidungen (getroffen)

| Thema | Entscheidung |
|---|---|
| CUDA-Scope | **Kein** CUDA-Dev-Toolkit auf dem Host. Host = Treiber (`nvidia-smi`/`libcuda`) + `nvidia-container-toolkit`. CUDA wird **im Container** validiert (echter vllm-Pfad). |
| Treiberquelle | RPM Fusion `akmod-nvidia`, Kernel-Modul zur **Build-Zeit** vorkompiliert |
| Fedora-Basis | Fedora 42 (`quay.io/fedora/fedora-bootc:42`) |
| Registry / Update | Registry-URL parametrierbar, final später; Test via qcow2-Disk |
| Container-Runtime | `nvidia-container-toolkit` von Anfang an dabei (Ziel: vllm-Container) |
| Immutability | **Transient Root** (tmpfs-Overlay, jeder Boot frisch außerhalb `/var`) als Default |

## Architektur

### A. Image-Aufbau (`Containerfile`)

Basis: `quay.io/fedora/fedora-bootc:42`

1. **Repos aktivieren**
   - RPM Fusion free + nonfree (für `akmod-nvidia` / `xorg-x11-drv-nvidia-cuda`)
   - Kein NVIDIA-CUDA-Repo nötig (kein Host-Toolkit) → nur RPM Fusion.

2. **Treiber (RPM Fusion)**
   - `akmod-nvidia` (proprietär)
   - `xorg-x11-drv-nvidia-cuda` (liefert `nvidia-smi`, `libcuda`, CUDA-Runtime-Libs
     — **kein** `nvcc`/Dev-Toolkit; ausreichend, damit Container CUDA nutzen)

3. **Container-GPU-Support**
   - `nvidia-container-toolkit`
   - CDI-Spezifikation für `nvidia.com/gpu` beim Boot generieren
     (`nvidia-ctk cdi generate`), damit `podman run --device nvidia.com/gpu=all`
     funktioniert.

4. **Kernel-Modul vorbacken (kritischer Schritt)**
   - `kernel-devel` exakt auf die im Basisimage vorhandene Kernel-Version
     pinnen (`kernel-core` Version-Release ermitteln).
   - `akmods --kernels <image-kernel> --force` → `.ko` liegt immutable im
     Image. Kein Modul-Build zur Laufzeit; sofort beim ersten Boot verfügbar.
   - **Fallback,** falls akmod-Build gegen den Image-Kernel scheitert:
     `kmod-nvidia` (precompiled) aus RPM Fusion für die passende Kernel-Version.

5. **Konfiguration / Immutability**
   - nouveau blacklisten via `/usr/lib/bootc/kargs.d/` Drop-in
     (`rd.driver.blacklist=nouveau modprobe.blacklist=nouveau`).
   - `nvidia`, `nvidia_uvm`, `nvidia_modeset` laden (modules-load.d).
   - `nvidia-persistenced` Service aktivieren.
   - composefs/fs-verity (F42-Default) beibehalten; `/usr` read-only.
   - **Transient Root aktivieren** (Default): Root als tmpfs-Overlay, Änderungen
     außerhalb `/var` sind je Boot flüchtig. Umsetzung via
     `/usr/lib/ostree/prepare-root.conf` (`[root] transient = true`) im Image,
     damit die Eigenschaft Teil des immutable Images ist. `/var` bleibt persistent.
   - Folge für Provisioning: Login-User/SSH werden im Image gebacken; SSH-Host-Keys
     regenerieren pro Boot (für Test akzeptabel).

6. **Abschluss**
   - `ldconfig`, Aufräumen von Caches, `bootc container lint`.

### B. Update-Fähigkeit

- Image-Referenz als Build-Arg/Label parametrierbar; Default lokal.
- `bootc upgrade` zieht später ein neueres Image vom selben Ref.
- Kernel-Update = neues Image mit neu vorkompiliertem, passendem Modul →
  keine kaputten Module nach Update (Vorteil ggü. dkms-zur-Laufzeit).

### C. Build- & Test-Flow

1. **Build** auf docker-remote (`DOCKER_HOST=ssh://root@docker-remote-environment.drudge.systems:222`, amd64) via `docker build`.
2. **Disk erzeugen** mit `bootc-image-builder` → `qcow2`.
   `config.toml` injiziert SSH-Key + Login-User (Validierung per SSH).
3. **Upload** qcow2 nach `node2.dro1.pve.fsrv.cloud` (`local`-Storage, ~951G frei),
   `qm importdisk` in neue VM.
4. **Test-VM (neu, VMID 110)** analog VM 100:
   q35, `cpu host`, ~12G RAM, `hostpci: mapping=rtx3080ti`, SeaBIOS
   (kein Secure Boot → unsigniertes Kernel-Modul unkompliziert).
   **VM 100 bleibt unangetastet.**
5. **Boot mit GPU-Passthrough**, dann Validierung.

### D. Validierung (Erfolgskriterien)

1. `nvidia-smi` auf dem Host erkennt die RTX 3080 Ti.
2. CUDA **im Container** erkannt: `podman run --rm --device nvidia.com/gpu=all
   docker.io/nvidia/cuda:*-base-* nvidia-smi` läuft und listet die GPU; zusätzlich
   ein CUDA-Runtime-Check (`cudaGetDeviceCount > 0`, z.B. via `deviceQuery` aus
   einem CUDA-Sample-Image oder kurzem Python/torch-Check im CUDA-Container).
3. `bootc status` zeigt ein sauberes, update-fähiges Deployment
   (booted image + Upgrade-Pfad); Transient-Root aktiv (`/` als overlay/tmpfs).

## Bewusst außerhalb des Scope (jetzt)

- vllm-Container-Betrieb.
- Secure Boot / MOK-Signierung (nur nötig bei UEFI + Secure Boot in Produktion;
  Test-VM nutzt SeaBIOS).
- Finale Registry-Wahl und CI/CD-Push.

## Risiken & Gegenmaßnahmen

| Risiko | Gegenmaßnahme |
|---|---|
| akmod-Build gegen falschen Kernel | `kernel-devel` an `kernel-core` pinnen; Build-Log prüfen; Fallback `kmod-nvidia` |
| nvidia-container-toolkit findet libs nicht (CDI) | CDI zur Laufzeit generieren (`nvidia-ctk cdi generate`) via oneshot-Service nach Modul-Load |
| Transient Root bricht Provisioning/Login | User/SSH-Key im Image backen (nicht in `/etc` zur Laufzeit); Persistentes nur unter `/var` |
| Passthrough/Boot-Firmware-Mismatch | Test-VM spiegelt VM 100 (SeaBIOS); qcow2 von bootc-image-builder BIOS-fähig |

## Test-Infrastruktur (verifiziert)

- **Build:** docker-remote 29.6.1, linux/amd64 — erreichbar.
- **Test:** Proxmox node2 (pve 9.2.4), RTX 3080 Ti `41:00.0` (+Audio `41:00.1`),
  Resource-Mapping `rtx3080ti`, `local`-Storage ~951G, `vmpool` (zfs) ~665G frei.
- **Referenz-VM 100** (`ollama-test1`, stopped, `protection: 1`): q35, cpu host,
  `hostpci1: mapping=rtx3080ti`, SeaBIOS, 100G virtio-Disk auf vmpool.
