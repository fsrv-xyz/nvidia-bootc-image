#!/usr/bin/env bash
set -euo pipefail

# Optional local build helper for the base image. The primary build path is CI
# (.gitlab-ci.yml). This uses your local Docker; to build on a remote engine, set
# DOCKER_HOST yourself (e.g. export DOCKER_HOST=ssh://user@builder) before running.
#
# The base is also tagged as the registry base ref so a system image's `FROM ${BASE}`
# (build-system.sh) resolves against this freshly built local base.
BASE_REF="${BASE_REF:-registry.fsrv.services/fsrvcorp/images/nvidia-bootc-image/base:main}"

echo ">> Building base ${BASE_REF}"
docker build --platform linux/amd64 -t "${BASE_REF}" -t localhost/nvidia-bootc-base:42 -f Containerfile .
echo ">> Done: ${BASE_REF} (also tagged localhost/nvidia-bootc-base:42)"
