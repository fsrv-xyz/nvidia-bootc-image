#!/usr/bin/env bash
set -euo pipefail

# Validiert die Erfolgskriterien in der Test-VM.
# Zugriff via SSH (ProxyJump über den Proxmox-Host), da der qemu-guest-agent in
# einer confined SELinux-Domain (virt_qemu_ga_t) läuft und nvidia-smi nicht ausführen darf.
NODE="${NODE:-root@node2.dro1.pve.fsrv.cloud}"
VMID="${VMID:-110}"
VM_USER="${VM_USER:-florian}"
KEY="${KEY:-sshkeys/vllm_bootc_test}"

echo ">> VM-IP über guest-agent ermitteln"
VM_IP="$(ssh "${NODE}" "qm guest cmd ${VMID} network-get-interfaces" 2>/dev/null \
  | python3 -c 'import sys,json
d=json.load(sys.stdin)
for i in d:
  if i.get("name")=="lo": continue
  for a in i.get("ip-addresses",[]) or []:
    if a["ip-address-type"]=="ipv4" and not a["ip-address"].startswith("127."):
      print(a["ip-address"]); raise SystemExit')"
echo "   VM_IP=${VM_IP}"

SSH=(ssh -i "${KEY}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
     -o "ProxyJump=${NODE}" "${VM_USER}@${VM_IP}")

echo "############ 1) nvidia-smi (Host) ############"
"${SSH[@]}" 'nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader'

echo "############ 2) Kernel-Module geladen ############"
"${SSH[@]}" 'lsmod | grep nvidia'

echo "############ 3) CDI-Spec vorhanden ############"
"${SSH[@]}" 'ls -l /etc/cdi/ && sudo nvidia-ctk cdi list'

echo "############ 4) CUDA im Container (CDI) ############"
# Self-contained (unabhängig vom in-Image Skript-Stand): CDI injiziert libcuda.so.1
# in einen kleinen Container; geprüft werden nvidia-smi + CUDA-Driver-API.
"${SSH[@]}" 'set -e
sudo podman run --rm --device nvidia.com/gpu=all --security-opt label=disable \
  docker.io/library/python:3.12-slim nvidia-smi -L
sudo podman run --rm --device nvidia.com/gpu=all --security-opt label=disable \
  docker.io/library/python:3.12-slim python3 -c "
import ctypes
cuda=ctypes.CDLL(\"libcuda.so.1\"); assert cuda.cuInit(0)==0
n=ctypes.c_int(); assert cuda.cuDeviceGetCount(ctypes.byref(n))==0
print(\"CUDA driver API devices:\", n.value)
buf=ctypes.create_string_buffer(256); cuda.cuDeviceGetName(buf,256,0)
print(\"Device 0:\", buf.value.decode())
v=ctypes.c_int(); cuda.cuDriverGetVersion(ctypes.byref(v)); print(\"CUDA driver version:\", v.value)
"'

echo "############ 5) bootc status + transient root ############"
"${SSH[@]}" 'sudo bootc status --format=yaml | grep -E "image:|booted:" | head -6; echo; findmnt -no FSTYPE,OPTIONS /'

echo "############ ALLE CHECKS DURCH ############"
