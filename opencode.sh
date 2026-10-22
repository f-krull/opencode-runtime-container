#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Rootless Podman API socket on the host. The container talks to the host's
# user-level Podman through this socket (never a privileged daemon).
PODMAN_SOCKET="${PODMAN_SOCKET:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock}"

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

# Record a project path so previous projects can be listed later (mounts and
# history files are keyed by one-way hash, so the real path must be stored).
# Maintains newest-first order with no duplicates.
register_project() {
    local project="$1" file tmp
    file="${OPENCODE_DIR}/projects"
    mkdir -p "${OPENCODE_DIR}"
    touch "${file}"
    tmp="$(mktemp)"
    printf '%s\n' "${project}" > "${tmp}"
    grep -vxF "${project}" "${file}" >> "${tmp}" || true
    mv "${tmp}" "${file}"
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

require_podman() {
    if ! command -v podman >/dev/null 2>&1; then
        echo "✗ podman not found; this launcher requires rootless Podman on the host." >&2
        exit 1
    fi
}

host_podman_version() {
    podman --version | awk '{print $NF}'
}

# The container's Podman remote client must match the host's Podman version
# (the libpod remote API is not cross-version compatible).
build_image() {
    local podman_version
    podman_version="$(host_podman_version)"

    echo "→ Building opencode container with Podman remote client v${podman_version}"
    podman build -t opencode-fk \
        --build-arg OPENCODE_VERSION="${OPENCODE_VERSION}" \
        --build-arg UID="$(id -u)" \
        --build-arg GID="$(id -g)" \
        --build-arg PODMAN_VERSION="${podman_version}" \
        -f "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}"
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

    build_image

    update_version_file "${latest}"
    echo "✓ Updated to version ${latest}"
}

build_and_run() {
    build_image
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
    register_project "${PROJECT_DIR}"

    local -a volume_args=(
        -v "${PROJECT_DIR}:${PROJECT_DIR}"
    )

    # The tooling repo (this script's directory) is always mounted so the
    # shared-browser skill and browser-cli/browser.sh are available to every
    # project. Deduplicate against PROJECT_DIR and extra mounts.
    if [[ "${SCRIPT_DIR}" != "${PROJECT_DIR}" ]]; then
        volume_args+=(-v "${SCRIPT_DIR}:${SCRIPT_DIR}")
    fi

    for path in "${EXTRA_MOUNTS[@]}"; do
        [[ "${path}" == "${SCRIPT_DIR}" || "${path}" == "${PROJECT_DIR}" ]] && continue
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

    local -a env_args=(-e "DISPLAY=${DISPLAY:-}")

    if [[ "${MOUNT_PODMAN}" == true ]]; then
        if [[ ! -S "${PODMAN_SOCKET}" ]]; then
            echo "✗ Podman API socket not found: ${PODMAN_SOCKET}" >&2
            echo "  Enable it on the host with: systemctl --user enable --now podman.socket" >&2
            exit 1
        fi
        # Mount at the same path, so paths inside API requests stay valid on the host.
        volume_args+=(-v "${PODMAN_SOCKET}:${PODMAN_SOCKET}")
        env_args+=(-e "CONTAINER_HOST=unix://${PODMAN_SOCKET}")
    fi

    # keep-id maps the host user to the same UID/GID inside the container, so
    # mounted project files keep their ownership (rootless Podman remaps UIDs).
    local -a extra_args=(--userns=keep-id)
    if [[ "${MOUNT_KVM}" == true ]]; then
        extra_args+=(--device /dev/kvm)
        # Rootless Podman cannot grant the host 'kvm' group by GID; keep-groups
        # passes the invoking user's supplementary groups into the container.
        if id -nG | tr ' ' '\n' | grep -qx kvm; then
            extra_args+=(--group-add keep-groups)
        else
            echo "⚠ Not a member of the host 'kvm' group; /dev/kvm may be inaccessible." >&2
            echo "  Fix with: sudo usermod -aG kvm ${USER}" >&2
        fi
    fi

    podman run -it --rm \
        "${env_args[@]}" \
        "${volume_args[@]}" \
        -w "${PROJECT_DIR}" \
        --network host \
        "${extra_args[@]}" \
        opencode-fk \
        bash -c "exec bash"
}

MOUNT_PODMAN=true
MOUNT_KVM=false

show_help() {
    cat <<'EOF'
Usage: opencode.sh [options] [project-dir] [extra-mounts...]

Run OpenCode inside a rootless Podman container.

Options:
  --no-podman    Do not mount the Podman API socket (default: mounted)
  --kvm          Mount /dev/kvm for hardware-accelerated virtualization
                 (requires membership in the host 'kvm' group)
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
            --no-podman|--no-docker)
                MOUNT_PODMAN=false
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
    require_podman

    if [[ "${POSITIONAL[0]:-}" == "update" ]]; then
        update_opencode
        return
    fi

    case "${#POSITIONAL[@]}" in
        0)
            PROJECT_DIR="$(realpath "$(pwd)")"
            EXTRA_MOUNTS=()
            ;;
        *)
            PROJECT_DIR="$(realpath "${POSITIONAL[0]}")"
            mapfile -t EXTRA_MOUNTS < <(resolve_extra_mounts "${POSITIONAL[@]:1}")
            ;;
    esac

    apply_mount_memory

    if ! validate_paths "${PROJECT_DIR}" "${EXTRA_MOUNTS[@]}"; then
        exit 1
    fi

    check_and_run
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

# One memory file per absolute project path (mirrors history_file_for_project).
mounts_file_for_project() {
    local project_dir="$1"
    local key
    key="$(printf '%s' "${project_dir}" | sha256sum | awk '{print $1}')"
    printf '%s\n' "${OPENCODE_DIR}/mounts/${key}"
}

# Load extra mounts for a project into the global MEM_MOUNTS array.
# Returns 0 if a memory file for the project exists, 1 otherwise.
get_mem_mounts() {
    local project="$1" file
    MEM_MOUNTS=()
    file="$(mounts_file_for_project "${project}")"
    [[ -f "${file}" ]] || return 1
    mapfile -t MEM_MOUNTS < "${file}"
}

# Save extra mounts for a project (one per line). Removes the file if empty.
save_mem_mounts() {
    local project="$1" file tmp
    shift
    file="$(mounts_file_for_project "${project}")"
    mkdir -p "$(dirname "${file}")"

    if (( $# > 0 )); then
        tmp="$(mktemp)"
        printf '%s\n' "$@" > "${tmp}"
        mv "${tmp}" "${file}"
    else
        rm -f "${file}"
    fi
}

# Remove the memory file for a project.
clear_mem_mounts() {
    local project="$1" file
    file="$(mounts_file_for_project "${project}")"
    rm -f "${file}"
}

# True if the two referenced arrays contain the same members regardless of order.
sets_equal() {
    local -n _a="$1" _b="$2"
    local -a sa=() sb=()
    if (( ${#_a[@]} > 0 )); then
        mapfile -t sa < <(printf '%s\n' "${_a[@]}" | sort -u)
    fi
    if (( ${#_b[@]} > 0 )); then
        mapfile -t sb < <(printf '%s\n' "${_b[@]}" | sort -u)
    fi
    [[ "${sa[*]}" == "${sb[*]}" ]]
}

# Prompt for Y/n. Defaults to ${2:-y}; non-interactive input takes the default.
prompt_yn() {
    local prompt="$1" default="${2:-y}" answer
    while true; do
        if ! [[ -t 0 ]]; then
            [[ "${default}" =~ ^[yY]$ ]] && return 0 || return 1
        fi
        printf '%s ' "${prompt}"
        IFS= read -r answer
        case "${answer}" in
            '' )
                [[ "${default}" =~ ^[yY]$ ]] && return 0 || return 1
                ;;
            y|Y) return 0 ;;
            n|N) return 1 ;;
            *) echo "Please answer y or n." >&2 ;;
        esac
    done
}

# Print an array, one item per line.
show_mount_list() {
    local -n _list="$1"
    local item
    for item in "${_list[@]}"; do
        printf '  %s\n' "${item}"
    done
}

# Print only the genuine additions/removals between the newly-passed and
# memorized extra mounts (items present in both sets are unchanged, not listed).
show_mount_diff() {
    local -n _new="$1" _old="$2"
    local item other found
    local -a added=() removed=()

    for item in "${_new[@]}"; do
        found=0
        for other in "${_old[@]}"; do
            [[ "${item}" == "${other}" ]] && { found=1; break; }
        done
        (( found )) || added+=("${item}")
    done
    for item in "${_old[@]}"; do
        found=0
        for other in "${_new[@]}"; do
            [[ "${item}" == "${other}" ]] && { found=1; break; }
        done
        (( found )) || removed+=("${item}")
    done

    if (( ${#added[@]} > 0 )); then
        echo "  added:"
        for item in "${added[@]}"; do
            printf '    + %s\n' "${item}"
        done
    fi
    if (( ${#removed[@]} > 0 )); then
        echo "  removed:"
        for item in "${removed[@]}"; do
            printf '    - %s\n' "${item}"
        done
    fi
}

# Resolve mount memory: reuse, save, prompt, or clear based on the current invocation.
apply_mount_memory() {
    local -a reuse=()

    if get_mem_mounts "${PROJECT_DIR}"; then
        # Memory exists for this project.
        if (( ${#EXTRA_MOUNTS[@]} > 0 )); then
            # 2+ dirs passed.
            if sets_equal EXTRA_MOUNTS MEM_MOUNTS; then
                return 0
            fi
            show_mount_diff EXTRA_MOUNTS MEM_MOUNTS
            if prompt_yn "use new mounts [Y/n]" y; then
                save_mem_mounts "${PROJECT_DIR}" "${EXTRA_MOUNTS[@]}"
            else
                EXTRA_MOUNTS=( "${MEM_MOUNTS[@]}" )
            fi
        else
            # 0 or 1 dir passed: offer to reuse the memorized mounts.
            reuse=( "${PROJECT_DIR}" "${MEM_MOUNTS[@]}" )
            show_mount_list reuse
            if prompt_yn "reuse mounts [Y/n]" y; then
                EXTRA_MOUNTS=( "${MEM_MOUNTS[@]}" )
            else
                clear_mem_mounts "${PROJECT_DIR}"
            fi
        fi
    elif (( ${#EXTRA_MOUNTS[@]} > 0 )); then
        # No memory yet for this project: silently save when 2+ dirs are passed.
        save_mem_mounts "${PROJECT_DIR}" "${EXTRA_MOUNTS[@]}"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi