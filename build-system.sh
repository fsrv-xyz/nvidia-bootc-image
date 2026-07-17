#!/usr/bin/env bash
set -euo pipefail

# Optional local build helper for a system image (systems/<name>) FROM the locally
# built base. The primary build path is CI (.gitlab-ci.yml). Run build.sh first so
# the base ref exists locally. Uses your local Docker; set DOCKER_HOST yourself to
# build on a remote engine.
#
# Usage: ./build-system.sh rtx3080ti
NAME="${1:?usage: build-system.sh <system-name> (e.g. rtx3080ti)}"
DIR="systems/${NAME}"
[ -f "${DIR}/Containerfile" ] || { echo "no ${DIR}/Containerfile"; exit 1; }

BASE_REF="${BASE_REF:-registry.fsrv.services/fsrvcorp/images/nvidia-bootc-image/base:main}"
IMAGE_REF="${IMAGE_REF:-localhost/nvidia-bootc-${NAME}:42}"

echo ">> Building system ${NAME} (${IMAGE_REF}) FROM ${BASE_REF}"
docker build --platform linux/amd64 --build-arg "BASE=${BASE_REF}" \
  -t "${IMAGE_REF}" -f "${DIR}/Containerfile" "${DIR}"
echo ">> Done: ${IMAGE_REF}"
