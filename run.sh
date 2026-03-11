#!/usr/bin/env bash
set -euo pipefail

# # ──────────────────────────────────────────────────────────────────────────────
# # Find the directory where THIS script lives (and where Dockerfile is)
# # Works even when called from another directory, via symlink, sourced, etc.
# # ──────────────────────────────────────────────────────────────────────────────
# SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# # Optional: print for debugging
# # echo "Running from project dir: $PWD"
# # echo "Script is located in:     $SCRIPT_DIR"

# # Detect host Docker group GID (fallback if docker not installed on host)
# DOCKER_GID=$(getent group docker | cut -d: -f3 || echo 999)

# echo "→ Building opencode container with Docker client support (GID=${DOCKER_GID})"

# docker build -t opencode-fk \
#     --build-arg DOCKER_GID="${DOCKER_GID}" \
#     -f - "${SCRIPT_DIR}" < "${SCRIPT_DIR}/Dockerfile"

# echo "→ Starting opencode (Docker socket mounted — tests now work)"
# docker run -it --rm \
#     -v "${PWD}":/workspace/ \
#     -v "${HOME}/.config/opencode/":/home/dev/.config/opencode/ \
#     -v /var/run/docker.sock:/var/run/docker.sock \
#     -w /workspace/ \
#     --network host \
#     --group-add "${DOCKER_GID}" \
#     opencode-fk \
#     bash -c "exec bash"

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
DOCKER_GID=$(getent group docker | cut -d: -f3 || echo 999)

# Canonicalise the path (handles symlinks, .., etc.)
PROJECT_DIR="$(realpath "$(pwd)")"

echo "→ Building opencode container with Docker client support (GID=${DOCKER_GID})"
docker build -t opencode-fk \
    --build-arg DOCKER_GID="${DOCKER_GID}" \
    -f - "${SCRIPT_DIR}" < "${SCRIPT_DIR}/Dockerfile"

echo "→ Starting opencode (same-path mount — inner docker commands now work transparently)"
echo PROJECT_DIR $PROJECT_DIR
echo DOCKER_GID $DOCKER_GID
docker run -it --rm \
    -v "${PROJECT_DIR}:${PROJECT_DIR}" \
    -v "${PROJECT_DIR}:/workspace" \
    -v "${HOME}/.config/opencode/":/home/dev/.config/opencode/ \
    -v "${HOME}/.ssh/config":/home/dev/.ssh/config \
    -v "${HOME}/.ssh/sockets":/home/dev/.ssh/sockets \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -w "${PROJECT_DIR}" \
    --network host \
    --group-add "${DOCKER_GID}" \
    opencode-fk \
    bash -c "exec bash"