#!/usr/bin/env bash
set -euo pipefail

# Build a qcow2 disk from the bootc image via bootc-image-builder.
# Docker->BIB bridge: a temporary local registry:2 (127.0.0.1:5000, which Docker
# treats as insecure automatically); BIB pulls from it with --tls-verify=false.
: "${IMAGE_REF:=localhost/vllm-bootc:42}"
export DOCKER_HOST="${DOCKER_HOST:-ssh://root@docker-remote-environment.drudge.systems:222}"

REG_LOCAL="127.0.0.1:5000/vllm-bootc:42"
OUT_DIR="/root/bib-output"

echo ">> Starting temporary registry"
docker rm -f bib-registry >/dev/null 2>&1 || true
docker run -d --name bib-registry -p 5000:5000 registry:2 >/dev/null

echo ">> Push ${IMAGE_REF} -> ${REG_LOCAL}"
docker tag "${IMAGE_REF}" "${REG_LOCAL}"
docker push "${REG_LOCAL}"

echo ">> Preparing output directory + config on the remote host"
docker run --rm -v /root:/host alpine sh -c "mkdir -p /host/bib-output"
# Copy config.toml onto the remote host via a helper container reading stdin:
docker run --rm -i -v /root/bib-output:/out alpine sh -c 'cat > /out/config.toml' < bib/config.toml

# BIB needs an initialized containers-storage (overlay). The Docker host has no
# podman storage, so we populate /var/lib/containers/storage via podman-in-docker
# and let BIB read from it locally.
echo ">> Pulling image into the host containers-storage (podman-in-docker)"
docker run --rm --privileged --network host \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/podman/stable \
  podman pull --tls-verify=false "${REG_LOCAL}"

echo ">> bootc-image-builder -> qcow2 (local, from host storage)"
# Fedora bootc declares no default root filesystem type, so --rootfs is required.
docker run --rm --privileged --network host \
  --security-opt label=disable \
  -v "${OUT_DIR}:/output" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "${OUT_DIR}/config.toml:/config.toml:ro" \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  --rootfs ext4 \
  --config /config.toml \
  "${REG_LOCAL}"

echo ">> Cleaning up registry"
docker rm -f bib-registry >/dev/null 2>&1 || true

echo ">> Done: ${OUT_DIR}/qcow2/disk.qcow2 (on the remote host)"
