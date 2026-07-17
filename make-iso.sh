#!/usr/bin/env bash
set -euo pipefail

# Optional local helper: build an Anaconda installer ISO for a bootc image via
# bootc-image-builder. The primary build path is CI; this is for local iteration.
# The installed system references IMAGE_REF (defaults to the ref.ci base), so pass a
# published, pullable registry ref. Uses your local Docker; set DOCKER_HOST for a
# remote engine.
: "${IMAGE_REF:=registry.fsrv.services/fsrvcorp/images/nvidia-bootc-image/base:main}"

OUT_DIR="/root/bib-output"

echo ">> Pulling ${IMAGE_REF} into the host containers-storage (podman-in-docker)"
docker run --rm --privileged --network host \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/podman/stable \
  podman pull "${IMAGE_REF}"

echo ">> Preparing output dir + kickstart config on the Docker host"
docker run --rm -v /root:/host alpine sh -c "mkdir -p /host/bib-output"
docker run --rm -i -v /root/bib-output:/out alpine sh -c 'cat > /out/iso-config.toml' < bib/iso-config.toml

echo ">> bootc-image-builder -> anaconda-iso (installed system references ${IMAGE_REF})"
docker run --rm --privileged --network host \
  --security-opt label=disable \
  -v "${OUT_DIR}:/output" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "${OUT_DIR}/iso-config.toml:/config.toml:ro" \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type anaconda-iso \
  --rootfs ext4 \
  --config /config.toml \
  "${IMAGE_REF}"

echo ">> Done: ${OUT_DIR}/bootiso/install.iso (on the Docker host)"
