#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
DOCKER_GID=$(getent group docker | cut -d: -f3 || echo 999)

PROJECT_DIR="$(realpath "$(pwd)")"
VERSION_FILE="${PROJECT_DIR}/.opencode-version"

OPENCODE_VERSION="${OPENCODE_VERSION:-latest}"

get_stored_version() {
    if [[ -f "${VERSION_FILE}" ]]; then
        cat "${VERSION_FILE}"
    fi
}

get_latest_version() {
    curl -fsSL https://api.github.com/repos/anomalyco/opencode/releases/latest 2>/dev/null | \
        grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/'
}

update_version_file() {
    local version="$1"
    echo "${version}" > "${VERSION_FILE}"
}

print_update_banner() {
    local current="$1"
    local latest="$2"
    local banner
    banner=$(cat <<'EOF'

╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║      🎉  New OpenCode Version Available!  🎉             ║
║                                                           ║
║         Current: CURRENT_VERSION                          ║
║         Latest:  LATEST_VERSION                           ║
║                                                           ║
║              Press any key to continue...                 ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝

EOF
)
    banner="${banner//CURRENT_VERSION/$current}"
    banner="${banner//LATEST_VERSION/$latest}"
    echo "${banner}"
}

check_for_updates() {
    local stored
    stored=$(get_stored_version)

    if [[ -z "${stored}" ]]; then
        echo "→ First run: no stored version found, fetching latest..."
        return 1
    fi

    local latest
    latest=$(get_latest_version)

    if [[ -z "${latest}" ]]; then
        echo "→ Could not fetch latest version from GitHub, continuing..."
        return 0
    fi

    if [[ "${stored}" != "${latest}" ]]; then
        print_update_banner "${stored}" "${latest}"
        read -n 1 -s -r
        echo ""
        return 1
    else
        echo "→ OpenCode is up to date (${stored})"
        return 0
    fi
}

update_opencode() {
    local latest
    latest=$(get_latest_version)

    if [[ -z "${latest}" ]]; then
        echo "✗ Could not fetch latest version from GitHub" >&2
        exit 1
    fi

    OPENCODE_VERSION="${latest}"
    echo "→ Updating OpenCode to version ${latest}..."

    build_and_run
    update_version_file "${latest}"
    echo "→ Updated to version ${latest}"
}

build_and_run() {
    echo "→ Building opencode container with Docker client support (GID=${DOCKER_GID})"
    docker build -t opencode-fk \
        --build-arg OPENCODE_VERSION="${OPENCODE_VERSION}" \
        --build-arg DOCKER_GID="${DOCKER_GID}" \
        -f - "${SCRIPT_DIR}" < "${SCRIPT_DIR}/Dockerfile"

    run_container
}

run_container() {
    echo "→ Starting opencode (same-path mount — inner docker commands now work transparently)"

    mkdir -p "${HOME}/.local/share/opencode/"

    docker run -it --rm \
        -e DISPLAY=$DISPLAY \
        -v "${PROJECT_DIR}:${PROJECT_DIR}" \
        -v "${PROJECT_DIR}:/workspace" \
        -v "${HOME}/.config/opencode/":/home/dev/.config/opencode/ \
        -v "${HOME}/.local/share/opencode/":/home/dev/.local/share/opencode/ \
        -v "${HOME}/.ssh/config":/home/dev/.ssh/config \
        -v "${HOME}/.ssh/sockets":/home/dev/.ssh/sockets \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /tmp/.X11-unix:/tmp/.X11-unix \
        -w "${PROJECT_DIR}" \
        --network host \
        --group-add "${DOCKER_GID}" \
        opencode-fk \
        bash -c "exec bash"
}

main() {
    case "${1:-}" in
        update)
            update_opencode
            ;;
        "")
            local stored
            stored=$(get_stored_version)
            local needs_build=true

            if [[ -n "${stored}" ]] && check_for_updates; then
                OPENCODE_VERSION="${stored}"
                needs_build=false
            fi

            if [[ "${needs_build}" == "true" ]]; then
                if [[ -z "${stored}" ]]; then
                    OPENCODE_VERSION=$(get_latest_version)
                fi
                build_and_run
                update_version_file "${OPENCODE_VERSION}"
            else
                run_container
            fi
            ;;
        *)
            echo "Usage: $0 [update]" >&2
            exit 1
            ;;
    esac
}

main "$@"