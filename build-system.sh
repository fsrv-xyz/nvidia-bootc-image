#!/usr/bin/env bash
set -euo pipefail

# Build a system image (systems/<name>) FROM the locally-built base on the remote
# Docker host (amd64). Run build.sh first so the base ref exists locally.
#
# Usage: ./build-system.sh rtx3080ti
NAME="${1:?usage: build-system.sh <system-name> (e.g. rtx3080ti)}"
DIR="systems/${NAME}"
[ -f "${DIR}/Containerfile" ] || { echo "no ${DIR}/Containerfile"; exit 1; }

BASE_REF="${BASE_REF:-registry.fsrv.services/fsrvcorp/images/nvidia-bootc-image/base:main}"
IMAGE_REF="${IMAGE_REF:-localhost/nvidia-bootc-${NAME}:42}"
export DOCKER_HOST="${DOCKER_HOST:-ssh://root@docker-remote-environment.drudge.systems:222}"

echo ">> Building system ${NAME} (${IMAGE_REF}) FROM ${BASE_REF}"
docker build --platform linux/amd64 --build-arg "BASE=${BASE_REF}" \
  -t "${IMAGE_REF}" -f "${DIR}/Containerfile" "${DIR}"
echo ">> Done: ${IMAGE_REF}"
