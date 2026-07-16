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

# BIB benötigt einen initialisierten containers-storage (overlay). Der Docker-Host
# hat keinen podman-Storage -> wir befüllen /var/lib/containers/storage per
# podman-in-docker und lassen BIB dann mit --local daraus lesen.
echo ">> Ziehe Image in Host containers-storage (podman-in-docker)"
docker run --rm --privileged --network host \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/podman/stable \
  podman pull --tls-verify=false "${REG_LOCAL}"

echo ">> bootc-image-builder -> qcow2 (--local aus Host-Storage)"
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

echo ">> Aufräumen Registry"
docker rm -f bib-registry >/dev/null 2>&1 || true

echo ">> Fertig: ${OUT_DIR}/qcow2/disk.qcow2 (auf Remote-Host)"
