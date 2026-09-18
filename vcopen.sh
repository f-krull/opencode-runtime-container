#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Reuse opencode.sh helpers (mounts_file_for_project, get_mem_mounts,
# history_file_for_project). The guard inside opencode.sh prevents its main().
source "${SCRIPT_DIR}/opencode.sh"

# Project dirs from the registry, filtered to those with a history and/or
# mounts file, newest first (registry order). Populates PROJECTS array.
list_projects() {
    local registry="${OPENCODE_DIR}/projects"
    local path m h
    PROJECTS=()
    [[ -f "${registry}" ]] || return 1
    while IFS= read -r path; do
        [[ -z "${path}" ]] && continue
        m=0; h=0
        [[ -f "$(mounts_file_for_project "${path}")" ]] && m=1
        [[ -f "$(history_file_for_project "${path}")" ]] && h=1
        (( m || h )) || continue
        PROJECTS+=("${path}:${m}${h}")
    done < "${registry}"
    (( ${#PROJECTS[@]} > 0 ))
}

# Render the arrow-key menu over an array of "path:marker" entries.
# Echoes the selected path to stdout; returns 1 if cancelled.
# All menu rendering goes to stderr so stdout carries only the selection.
pick_project() {
    local -a entries=("$@")
    local n="${#entries[@]}"
    local i=0 idx entry marker key rest
    local -a path=()

    # Enter raw mode: disable echo, enable reading arrow-key escapes.
    stty -echo
    trap 'stty echo; echo' EXIT INT TERM

    while true; do
        # Move cursor to top and redraw the list.
        printf '\r\033[J' >&2
        for (( idx = 0; idx < n; idx++ )); do
            entry="${entries[$idx]}"
            marker="${entry##*:}"
            if (( idx == i )); then
                printf '\033[7m> %s  [%s]\033[0m\n' "${entry%:*}" "${marker}" >&2
            else
                printf '  %s  [%s]\n' "${entry%:*}" "${marker}" >&2
            fi
        done

        IFS= read -rsn1 key || { printf '\033[J' >&2; return 1; }
        if [[ "${key}" == $'\e' ]]; then
            IFS= read -rsn1 rest || true
            case "${rest}" in
                '[') IFS= read -rsn1 key ;;
                *)   key="${rest}" ;;
            esac
            case "${key}" in
                A) i=$(( (i + n - 1) % n )) ;;   # Up
                B) i=$(( (i + 1) % n )) ;;       # Down
            esac
        else
            case "${key}" in
                '') printf '\033[J' >&2; break ;;     # Enter
                q|Q) printf '\033[J' >&2; return 1 ;; # quit
                k) i=$(( (i + n - 1) % n )) ;;
                j) i=$(( (i + 1) % n )) ;;
            esac
        fi
    done

    stty echo
    trap - EXIT INT TERM
    printf '%s\n' "${entries[$i]%:*}"
}

main() {
    if ! list_projects; then
        echo "No previously opened projects found." >&2
        echo "Open opencode.sh on a project first to register it." >&2
        exit 1
    fi

    local chosen mounts
    chosen="$(pick_project "${PROJECTS[@]}")" || {
        echo "Cancelled." >&2
        exit 1
    }

    # Auto-restore the project's memorized mounts (none if absent).
    mounts=()
    if get_mem_mounts "${chosen}"; then
        mounts=( "${MEM_MOUNTS[@]}" )
    fi

    exec "${SCRIPT_DIR}/opencode.sh" "${chosen}" "${mounts[@]}"
}

main "$@"