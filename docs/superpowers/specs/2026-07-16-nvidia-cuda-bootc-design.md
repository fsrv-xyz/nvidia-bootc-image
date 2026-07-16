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
| CUDA-Scope | Voll-CUDA auf dem Host (CUDA-Toolkit im Image) |
| Treiberquelle | RPM Fusion `akmod-nvidia`, Kernel-Modul zur **Build-Zeit** vorkompiliert |
| Fedora-Basis | Fedora 42 (`quay.io/fedora/fedora-bootc:42`) |
| Registry / Update | Registry-URL parametrierbar, final später; Test via qcow2-Disk |
| Container-Runtime | `nvidia-container-toolkit` von Anfang an dabei (Ziel: vllm-Container) |
| Immutability | Maximal read-only im bootc-Rahmen |

## Architektur

### A. Image-Aufbau (`Containerfile`)

Basis: `quay.io/fedora/fedora-bootc:42`

1. **Repos aktivieren**
   - RPM Fusion free + nonfree (für `akmod-nvidia` / `xorg-x11-drv-nvidia-cuda`)
   - NVIDIA CUDA-Repo für Fedora (x86_64) — für das CUDA-Toolkit (`nvcc` etc.)

2. **Treiber (RPM Fusion)**
   - `akmod-nvidia` (proprietär)
   - `xorg-x11-drv-nvidia-cuda` (liefert `nvidia-smi`, `libcuda`, Runtime-Libs)

3. **CUDA-Toolkit (NVIDIA-Repo)**
   - `cuda-toolkit-<ver>` (nvcc, cudart, headers)
   - **Ohne** die Treiberpakete aus dem CUDA-Repo (Konfliktvermeidung mit dem
     RPM-Fusion-Treiber). Offiziell von RPM Fusion dokumentierter Weg:
     „Treiber von RPM Fusion + Toolkit von NVIDIA".

4. **Container-GPU-Support**
   - `nvidia-container-toolkit`
   - CDI-Spezifikation für `nvidia.com/gpu` beim Boot generieren
     (`nvidia-ctk cdi generate`), damit `podman run --device nvidia.com/gpu=all`
     funktioniert.

5. **Kernel-Modul vorbacken (kritischer Schritt)**
   - `kernel-devel` exakt auf die im Basisimage vorhandene Kernel-Version
     pinnen (`kernel-core` Version-Release ermitteln).
   - `akmods --kernels <image-kernel> --force` → `.ko` liegt immutable im
     Image. Kein Modul-Build zur Laufzeit; sofort beim ersten Boot verfügbar.
   - **Fallback,** falls akmod-Build gegen den Image-Kernel scheitert:
     `kmod-nvidia` (precompiled) aus RPM Fusion für die passende Kernel-Version.

6. **Konfiguration / Immutability**
   - nouveau blacklisten via `/usr/lib/bootc/kargs.d/` Drop-in
     (`rd.driver.blacklist=nouveau modprobe.blacklist=nouveau`).
   - `nvidia`, `nvidia_uvm`, `nvidia_modeset` laden (modules-load.d).
   - `nvidia-persistenced` Service aktivieren.
   - Read-only maximieren: composefs/fs-verity (F42-Default) beibehalten;
     `/usr` read-only; nur `/etc` und `/var` beschreibbar und minimal halten.
   - `transient-root` (tmpfs-Root, jeder Boot frisch außerhalb `/var`) wird als
     Option im `config.toml`/Install dokumentiert; Default: read-only Root.

7. **Abschluss**
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

1. `nvidia-smi` erkennt die RTX 3080 Ti.
2. `deviceQuery` (minimal, mit `nvcc` kompiliert) meldet die GPU über CUDA
   (`cudaGetDeviceCount` > 0, Properties lesbar).
3. `bootc status` zeigt ein sauberes, update-fähiges Deployment
   (booted image + Upgrade-Pfad).
4. (Bonus) `podman run --device nvidia.com/gpu=all ... nvidia-smi` im Container.

## Bewusst außerhalb des Scope (jetzt)

- vllm-Container-Betrieb.
- Secure Boot / MOK-Signierung (nur nötig bei UEFI + Secure Boot in Produktion;
  Test-VM nutzt SeaBIOS).
- Finale Registry-Wahl und CI/CD-Push.

## Risiken & Gegenmaßnahmen

| Risiko | Gegenmaßnahme |
|---|---|
| akmod-Build gegen falschen Kernel | `kernel-devel` an `kernel-core` pinnen; Build-Log prüfen; Fallback `kmod-nvidia` |
| CUDA-Toolkit ↔ Treiber-Version inkompatibel | Toolkit-Version passend zum akmod-Treiber wählen; dnf-Auflösung prüfen |
| CUDA-Repo enthält keine passende Fedora-42-Variante | Nächstliegende unterstützte Fedora-Repo-Variante nutzen; ggf. Toolkit-Version anpassen |
| Image-Größe (Voll-CUDA) | Nur `cuda-toolkit` statt Meta `cuda`; Caches entfernen; Storage reicht |
| Passthrough/Boot-Firmware-Mismatch | Test-VM spiegelt VM 100 (SeaBIOS); qcow2 von bootc-image-builder BIOS-fähig |

## Test-Infrastruktur (verifiziert)

- **Build:** docker-remote 29.6.1, linux/amd64 — erreichbar.
- **Test:** Proxmox node2 (pve 9.2.4), RTX 3080 Ti `41:00.0` (+Audio `41:00.1`),
  Resource-Mapping `rtx3080ti`, `local`-Storage ~951G, `vmpool` (zfs) ~665G frei.
- **Referenz-VM 100** (`ollama-test1`, stopped, `protection: 1`): q35, cpu host,
  `hostpci1: mapping=rtx3080ti`, SeaBIOS, 100G virtio-Disk auf vmpool.
