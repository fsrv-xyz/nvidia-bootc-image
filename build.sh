#!/usr/bin/env bash
set -euo pipefail

# Build the generic base image on the remote Docker host (amd64) and tag it as the
# registry base ref, so the system Containerfiles' `FROM ${BASE}` default resolves
# against this locally-built base (offline, no registry pull).
BASE_REF="${BASE_REF:-registry.fsrv.services/fsrvcorp/images/nvidia-bootc-image/base:main}"
export DOCKER_HOST="${DOCKER_HOST:-ssh://root@docker-remote-environment.drudge.systems:222}"

echo ">> Building base ${BASE_REF} on ${DOCKER_HOST}"
docker build --platform linux/amd64 -t "${BASE_REF}" -t localhost/nvidia-bootc-base:42 -f Containerfile .
echo ">> Done: ${BASE_REF} (also tagged localhost/nvidia-bootc-base:42)"
