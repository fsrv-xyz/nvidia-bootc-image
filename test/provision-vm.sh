#!/usr/bin/env bash
set -euo pipefail

# Create Proxmox VM 110 (like reference VM 100: q35, cpu host, SeaBIOS) with GPU passthrough.
NODE="${NODE:-root@node2.dro1.pve.fsrv.cloud}"
VMID="${VMID:-110}"
DISK="${DISK:-/var/lib/vz/template/vllm-bootc-disk.qcow2}"
STORAGE="${STORAGE:-vmpool}"

ssh "${NODE}" bash -s <<EOF
set -euo pipefail
if qm status ${VMID} >/dev/null 2>&1; then
  echo "VM ${VMID} already exists -- aborting (check/remove it manually)."; exit 1
fi
qm create ${VMID} --name vllm-bootc-test --machine q35 --cpu host --cores 4 \
  --memory 12288 --numa 1 --ostype l26 --agent 1 \
  --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr0 --bios seabios --vga std \
  --serial0 socket
# serial0: the bootc/cloud kernel cmdline contains console=ttyS0; without a serial
# device serial-getty@ttyS0 fails. The socket serial also provides console access
# via 'qm terminal ${VMID}'.
echo ">> importdisk"
qm importdisk ${VMID} ${DISK} ${STORAGE}
qm set ${VMID} --virtio0 ${STORAGE}:vm-${VMID}-disk-0,iothread=1
qm set ${VMID} --boot order=virtio0
echo ">> GPU passthrough"
qm set ${VMID} --hostpci0 mapping=rtx3080ti,pcie=1
echo ">> Start"
qm start ${VMID}
qm config ${VMID}
EOF
