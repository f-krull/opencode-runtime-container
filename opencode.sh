#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
DOCKER_GID=$(getent group docker | cut -d: -f3 || echo 999)
KVM_GID=$(getent group kvm | cut -d: -f3 || true)

PROJECT_DIR="$(realpath "$(pwd)")"
VERSION_FILE="${SCRIPT_DIR}/.opencode-version"
OPENCODE_DIR="${SCRIPT_DIR}/.opencode"
OPENCODE_BASHRC="${OPENCODE_DIR}/.bashrc"

OPENCODE_VERSION="${OPENCODE_VERSION:-latest}"

# One history file per absolute project path (shared history would leak A↔B).
history_file_for_project() {
    local project_dir="$1"
    local hist_key
    hist_key="$(printf '%s' "${project_dir}" | sha256sum | awk '{print $1}')"
    printf '%s\n' "${OPENCODE_DIR}/history/${hist_key}"
}

get_stored_version() {
    if [[ -f "${VERSION_FILE}" ]]; then
        cat "${VERSION_FILE}"
    fi
}

get_latest_version() {
    curl -fsSL https://api.github.com/repos/anomalyco/opencode/releases/latest 2>/dev/null | \
        grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/'
}

check_for_updates() {
    local timeout="${1:-5}"
    local result
    result=$(curl -fsSL --max-time "${timeout}" https://api.github.com/repos/anomalyco/opencode/releases/latest 2>/dev/null | \
        grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/' || true)
    echo "${result}"
}

show_update_banner() {
    local new_version="$1"
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║           New OpenCode version available!                ║"
    echo "║                     ${new_version}                           ║"
    echo "║              Press any key to continue...                ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    if [[ -t 0 ]]; then
        read -n 1 -s
    else
        sleep 1
    fi
}

update_version_file() {
    local version="$1"
    echo "${version}" > "${VERSION_FILE}"
}

update_opencode() {
    local latest
    latest=$(check_for_updates)

    if [[ -z "${latest}" ]]; then
        echo "✗ Could not fetch latest version from GitHub" >&2
        exit 1
    fi

    show_update_banner "${latest}"

    OPENCODE_VERSION="${latest}"
    echo "→ Updating OpenCode to version ${latest}..."

    echo "→ Building opencode container with Docker client support (GID=${DOCKER_GID})"
    docker build -t opencode-fk \
        --build-arg OPENCODE_VERSION="${OPENCODE_VERSION}" \
        --build-arg DOCKER_GID="${DOCKER_GID}" \
        -f - "${SCRIPT_DIR}" < "${SCRIPT_DIR}/Dockerfile"

    update_version_file "${latest}"
    echo "✓ Updated to version ${latest}"
}

build_and_run() {
    echo "→ Building opencode container with Docker client support (GID=${DOCKER_GID})"
    docker build -t opencode-fk \
        --build-arg OPENCODE_VERSION="${OPENCODE_VERSION}" \
        --build-arg DOCKER_GID="${DOCKER_GID}" \
        -f - "${SCRIPT_DIR}" < "${SCRIPT_DIR}/Dockerfile"

    run_container
}

validate_paths() {
    local -a paths=("$@")
    local path resolved

    for path in "${paths[@]}"; do
        resolved="$(realpath "${path}")"
        if [[ ! -e "${resolved}" ]]; then
            echo "✗ Path does not exist: ${path}" >&2
            return 1
        fi
    done

    local -a sorted
    mapfile -t sorted < <(printf "%s\n" "${paths[@]}" | sort)
    for (( i=1; i<${#sorted[@]}; i++ )); do
        if [[ "${sorted[$i]}" == "${sorted[$((i-1))]}" ]]; then
            echo "✗ Duplicate path specified: ${sorted[$i]}" >&2
            return 1
        fi
    done
}

run_container() {
    echo "→ Starting opencode v${OPENCODE_VERSION}"

    local OPENCODE_HISTORY
    OPENCODE_HISTORY="$(history_file_for_project "${PROJECT_DIR}")"

    mkdir -p "${HOME}/.local/share/opencode/"
    mkdir -p "${OPENCODE_DIR}/history"
    touch "${OPENCODE_BASHRC}"
    touch "${OPENCODE_HISTORY}"

    local -a volume_args=(
        -v "${PROJECT_DIR}:${PROJECT_DIR}"
    )

    for path in "${EXTRA_MOUNTS[@]}"; do
        volume_args+=(-v "${path}:${path}")
    done

    volume_args+=(
        -v "${HOME}/.config/opencode/":/home/dev/.config/opencode/
        -v "${HOME}/.local/share/opencode/":/home/dev/.local/share/opencode/
        -v "${HOME}/.ssh/config":/home/dev/.ssh/config
        -v "${HOME}/.ssh/sockets":/home/dev/.ssh/sockets
        -v /tmp/.X11-unix:/tmp/.X11-unix
        -v "${HOME}/.grok/":/home/dev/.grok/
        -v "${HOME}/.config/opencode/skills":/home/dev/.grok/skills
        -v "${OPENCODE_BASHRC}":/home/dev/.bashrc
        -v "${OPENCODE_HISTORY}":/home/dev/.bash_history
    )

    if [[ "${MOUNT_DOCKER}" == true ]]; then
        volume_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
    fi

    local -a extra_args=()
    if [[ "${MOUNT_DOCKER}" == true ]]; then
        extra_args+=(--group-add "${DOCKER_GID}")
    fi

    if [[ "${MOUNT_KVM}" == true ]]; then
        extra_args+=(--device /dev/kvm)
        if [[ -n "${KVM_GID}" ]]; then
            extra_args+=(--group-add "${KVM_GID}")
        fi
    fi

    docker run -it --rm \
        -e DISPLAY=$DISPLAY \
        "${volume_args[@]}" \
        -w "${PROJECT_DIR}" \
        --network host \
        "${extra_args[@]}" \
        opencode-fk \
        bash -c "exec bash"
}

MOUNT_DOCKER=true
MOUNT_KVM=false

show_help() {
    cat <<'EOF'
Usage: opencode.sh [options] [project-dir] [extra-mounts...]

Run OpenCode inside a Docker container.

Options:
  --no-docker    Do not mount the Docker socket (default: mounted)
  --kvm          Mount /dev/kvm for hardware-accelerated virtualization
                 (default: not mounted)
  -h, --help     Show this help message and exit
  update         Build/update the container image to the latest version

Commands:
  project-dir            Path to the project to open (default: current dir)
  extra-mounts...        Additional paths to mount into the container
EOF
}

parse_flags() {
    local args=()
    for arg in "$@"; do
        case "${arg}" in
            --no-docker)
                MOUNT_DOCKER=false
                ;;
            --kvm)
                MOUNT_KVM=true
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                echo "✗ Unknown option: ${arg}" >&2
                show_help >&2
                exit 1
                ;;
            *)
                args+=("${arg}")
                ;;
        esac
    done
    POSITIONAL=("${args[@]}")
}

main() {
    parse_flags "$@"

    if [[ "${POSITIONAL[0]:-}" == "update" ]]; then
        update_opencode
        return
    fi

    case "${#POSITIONAL[@]}" in
        0)
            PROJECT_DIR="$(realpath "$(pwd)")"
            EXTRA_MOUNTS=()
            check_and_run
            ;;
        *)
            PROJECT_DIR="$(realpath "${POSITIONAL[0]}")"
            mapfile -t EXTRA_MOUNTS < <(resolve_extra_mounts "${POSITIONAL[@]:1}")

            if ! validate_paths "${PROJECT_DIR}" "${EXTRA_MOUNTS[@]}"; then
                exit 1
            fi

            check_and_run
            ;;
    esac
}

check_and_run() {
    local stored latest
    stored=$(get_stored_version)
    latest=$(check_for_updates 1)

    if [[ -n "${latest}" && "${latest}" != "${stored}" ]]; then
        show_update_banner "${latest}"
    fi

    if [[ -n "${stored}" ]]; then
        OPENCODE_VERSION="${stored}"
        run_container
    else
        if [[ -z "${latest}" ]]; then
            echo "→ First run: no stored version found, fetching latest..."
            latest=$(get_latest_version)
        fi
        OPENCODE_VERSION="${latest}"
        build_and_run
        update_version_file "${latest}"
    fi
}

resolve_extra_mounts() {
    local path resolved
    for path in "$@"; do
        resolved="$(realpath "${path}")"
        echo "${resolved}"
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi