#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

podman build -t opencode-fk \
    --build-arg UID="$(id -u)" \
    --build-arg GID="$(id -g)" \
    --build-arg PODMAN_VERSION="$(podman --version | awk '{print $NF}')" \
    -f "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}"
