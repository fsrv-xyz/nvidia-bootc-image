#!/usr/bin/env bash
set -euo pipefail

# Build the bootc image on the remote Docker host (amd64).
: "${IMAGE_REF:=localhost/vllm-bootc:42}"
export DOCKER_HOST="${DOCKER_HOST:-ssh://root@docker-remote-environment.drudge.systems:222}"

echo ">> Building ${IMAGE_REF} on ${DOCKER_HOST}"
docker build --platform linux/amd64 -t "${IMAGE_REF}" -f Containerfile .
echo ">> Done: ${IMAGE_REF}"

