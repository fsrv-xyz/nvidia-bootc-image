#!/usr/bin/env bash
set -euo pipefail

# Validate the success criteria inside the test VM.
# Access is via SSH (ProxyJump through the Proxmox host) because the qemu-guest-agent
# runs in a confined SELinux domain (virt_qemu_ga_t) and may not execute nvidia-smi.
# The host is IPv6-only, so we connect to its global SLAAC address.
NODE="${NODE:-root@node2.dro1.pve.fsrv.cloud}"
VMID="${VMID:-110}"
VM_USER="${VM_USER:-root}"
KEY="${KEY:-sshkeys/vllm_bootc_test}"

echo ">> Resolving VM global IPv6 via guest-agent"
VM_IP="$(ssh "${NODE}" "qm guest cmd ${VMID} network-get-interfaces" 2>/dev/null \
  | python3 -c 'import sys,json
d=json.load(sys.stdin)
for i in d:
  if i.get("name")=="lo": continue
  for a in i.get("ip-addresses",[]) or []:
    ip=a["ip-address"]
    if a["ip-address-type"]=="ipv6" and not ip.startswith("fe80") and ip!="::1":
      print(ip); raise SystemExit')"
echo "   VM_IP=${VM_IP}"

SSH=(ssh -i "${KEY}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
     -o "ProxyJump=${NODE}" "${VM_USER}@${VM_IP}")

echo "############ 0) Network: IPv6-only, single stable EUI-64 address ############"
"${SSH[@]}" 'echo "-- global IPv6 --"; ip -6 -br addr show scope global
echo "-- IPv4 (expect none) --"; ip -4 -br addr show scope global || true
echo "-- backend --"; systemctl is-active systemd-networkd; ! systemctl is-enabled NetworkManager 2>/dev/null && echo "NetworkManager: not enabled"'

echo "############ 1) nvidia-smi (host) ############"
"${SSH[@]}" 'nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader'

echo "############ 2) Kernel modules loaded ############"
"${SSH[@]}" 'lsmod | grep nvidia'

echo "############ 3) CDI spec present ############"
"${SSH[@]}" 'ls -l /etc/cdi/ && nvidia-ctk cdi list'

echo "############ 4) CUDA inside a container (CDI) ############"
# Self-contained (independent of the in-image script version): CDI injects
# libcuda.so.1 into a small container; checks nvidia-smi + the CUDA driver API.
"${SSH[@]}" 'set -e
podman run --rm --device nvidia.com/gpu=all --security-opt label=disable \
  quay.io/fedora/fedora:42 nvidia-smi -L
podman run --rm --device nvidia.com/gpu=all --security-opt label=disable \
  quay.io/fedora/fedora:42 python3 -c "
import ctypes
cuda=ctypes.CDLL(\"libcuda.so.1\"); assert cuda.cuInit(0)==0
n=ctypes.c_int(); assert cuda.cuDeviceGetCount(ctypes.byref(n))==0
print(\"CUDA driver API devices:\", n.value)
buf=ctypes.create_string_buffer(256); cuda.cuDeviceGetName(buf,256,0)
print(\"Device 0:\", buf.value.decode())
v=ctypes.c_int(); cuda.cuDriverGetVersion(ctypes.byref(v)); print(\"CUDA driver version:\", v.value)
"'

echo "############ 5) bootc status + transient root ############"
"${SSH[@]}" 'bootc status --format=yaml | grep -E "image:|booted:" | head -6; echo; findmnt -no FSTYPE,OPTIONS /'

echo "############ 6) No failed units ############"
"${SSH[@]}" 'systemctl --failed --no-pager'

echo "############ ALL CHECKS PASSED ############"
