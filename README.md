# vllm-bootc — Fedora bootc Image mit NVIDIA-Treiber + CUDA

Minimales, immutable (**transient-root**) Fedora-42 **bootc**-Image für AMD64 mit
proprietärem NVIDIA-Treiber (RPM Fusion `akmod-nvidia`, Kernel-Modul **zur
Build-Zeit** vorkompiliert) und `nvidia-container-toolkit`. Ziel: GPU-Workloads
(später vllm) als Container. CUDA wird bewusst **nicht** als Host-Toolkit
installiert — Container bringen ihre eigene CUDA-Runtime mit; die CUDA-Libs
(`libcuda.so`) werden per CDI in jeden GPU-Container injiziert.

Verifiziert auf einer Proxmox-VM mit PCIe-Passthrough (RTX 3080 Ti):
`nvidia-smi` erkennt die GPU auf dem Host, und CUDA erkennt die GPU im Container.

## Aufbau

| Datei | Zweck |
|---|---|
| `Containerfile` | Image-Definition (Treiber, Container-Toolkit, Modul-Build, Konfig) |
| `build.sh` | Baut das Image auf dem Docker-Remote-Host (amd64) |
| `make-disk.sh` | Erzeugt eine `qcow2` via `bootc-image-builder` |
| `bib/config.toml` | bootc-image-builder Konfiguration (minimal; Provisionierung ist im Image) |
| `files/` | In `/` kopierte Konfig (kargs, modules-load, transient-root, CDI-Service, sshd, sudo, CUDA-Check) |
| `sshkeys/florian.keys` | Public Key des Test-Users (in `/usr/share/sshkeys` gebacken) |
| `test/provision-vm.sh` | Legt Proxmox-VM 110 mit GPU-Passthrough an und startet sie |
| `test/validate.sh` | Prüft die Erfolgskriterien in der VM (via SSH) |

## Build

    export DOCKER_HOST="ssh://root@docker-remote-environment.drudge.systems:222"
    IMAGE_REF=localhost/vllm-bootc:42 ./build.sh

Der proprietäre Treiber kommt aus RPM Fusion. Das Kernel-Modul (`akmods`) wird
gegen den exakt im Image enthaltenen Kernel vorkompiliert und ist dadurch immutable
und sofort beim ersten Boot verfügbar. `install_weak_deps=False` hält das Image
headless-schlank (kein Desktop-/Audio-Ballast).

## Disk (qcow2) erzeugen

    ./make-disk.sh          # Ausgabe: /root/bib-output/qcow2/disk.qcow2 (auf dem Docker-Remote-Host)

`bootc-image-builder` benötigt einen initialisierten `containers-storage`. Da der
Docker-Host keinen podman-Storage hat, überbrückt `make-disk.sh` Docker → BIB über
eine temporäre lokale `registry:2` und befüllt den Host-`containers-storage` per
podman-in-docker. Fedora-bootc deklariert keinen Default-Root-FS-Typ, daher wird
`--rootfs ext4` gesetzt.

## Test (Proxmox node2, VM 110, GPU-Passthrough)

    # qcow2 auf node2 streamen:
    ssh -p 222 root@docker-remote-environment.drudge.systems 'cat /root/bib-output/qcow2/disk.qcow2' \
      | ssh root@node2.dro1.pve.fsrv.cloud 'cat > /var/lib/vz/template/vllm-bootc-disk.qcow2'

    ./test/provision-vm.sh   # erstellt + startet VM 110 (q35, SeaBIOS, hostpci mapping=rtx3080ti)
    ./test/validate.sh       # validiert nvidia-smi + CUDA im Container

Die VM spiegelt die Referenz-VM 100 (q35, `cpu host`, SeaBIOS → kein Secure Boot,
daher unsigniertes Kernel-Modul unkompliziert).

## Erfolgskriterien (verifiziert)

- `nvidia-smi` erkennt die GPU auf dem Host (RTX 3080 Ti, Treiber 580.159.03).
- CUDA erkennt die GPU im Container: `cuDeviceGetCount = 1`, Gerätename korrekt,
  CUDA-Driver-Version 13.0 — via CDI (`nvidia.com/gpu=all`).

Für den klassischen `nvcc`-`deviceQuery` (großes CUDA-devel-Image, ~4 GB Pull):

    sudo CUDA_FULL=1 /usr/libexec/cuda-container-check   # in der VM; braucht ausreichend /var-Platz

## Zugriff auf die Test-VM

Der `qemu-guest-agent` läuft in einer confined SELinux-Domain (`virt_qemu_ga_t`)
und darf `nvidia-smi` **nicht** ausführen — Validierung/Debugging daher via SSH
(ProxyJump über den Proxmox-Host):

    ssh -J root@node2.dro1.pve.fsrv.cloud -i sshkeys/vllm_bootc_test florian@<vm-ip>

VM-IP: `ssh root@node2... 'qm guest cmd 110 network-get-interfaces'`.

## Update-Fähigkeit

bootc-System, aktualisiert transaktional. Sobald das Image in eine aus der VM
erreichbare Registry gepusht ist (statt `localhost/...` / `127.0.0.1:5000`), zeigt
die gebootete Referenz dorthin und Updates laufen über:

    sudo bootc upgrade      # neues Image ziehen + beim nächsten Boot aktivieren
    sudo bootc status       # Deployments anzeigen
    sudo bootc rollback     # auf vorheriges Deployment zurück

Die Registry-Referenz ist über `IMAGE_REF` parametrierbar. Da das Kernel-Modul bei
jedem Image-Build gegen den enthaltenen Kernel neu vorkompiliert wird, bleibt der
Treiber nach Kernel-Updates konsistent.

## Immutability

- **Transient Root** (`root.transient=true`): `/` ist ein read-only composefs mit
  tmpfs-Overlay — Änderungen außerhalb `/var` sind pro Boot flüchtig. Persistente
  Daten gehören unter `/var`.
- `/usr` read-only (composefs/fs-verity).
- Provisionierung (User, SSH-Key, sudo, sshd-Konfig) ist im Image gebacken, damit
  sie transient-root-fest ist. Der CDI-Service regeneriert `/etc/cdi/nvidia.yaml`
  bei jedem Boot.

## Scope / offen

- vllm-Container-Betrieb (separat). Hinweis: Die Test-VM hat nur eine 10-GB-Disk;
  für vllm-Images sollte sie vergrößert werden.
- Secure Boot / MOK-Signierung (nur bei UEFI+Secure Boot nötig; Test nutzt SeaBIOS).
- Finale Registry-Wahl + CI-Push.
