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
        # Use a unit separator as delimiter (safe for paths containing ':').
        PROJECTS+=("${path}"$'\x1f'"${m}${h}")
    done < "${registry}"
    (( ${#PROJECTS[@]} > 0 ))
}

# Render the arrow-key menu over an array of "path:marker" entries.
# Echoes the selected path to stdout; returns 1 if cancelled.
# All menu rendering goes to stderr so stdout carries only the selection.
pick_project() {
    local -a entries=("$@")
    local n="${#entries[@]}"
    local i=0 idx entry marker path label rest key
    local orig
    local interrupted=0
    local first=1
    PICK_RESULT=""

    # Save original terminal settings so they can be restored exactly.
    orig="$(stty -g 2>/dev/null)" || orig=""

    # Canonical off + no echo so each key returns immediately. ISIG is left ON
    # so Ctrl-C generates a normal SIGINT, which we trap into `interrupted` and
    # notice via the timed read (a trapped SIGINT makes read re-block, not
    # return, so we poll). This works regardless of the terminal's ISIG setup.
    stty -echo -icanon min 1 time 0 2>/dev/null || stty -echo

    restore_tty() {
        if (( !first )); then
            printf '\033[%dA\033[J' "${n}" >&2
        fi
        if [[ -n "${orig}" ]]; then
            stty "${orig}" 2>/dev/null || stty echo icanon
        else
            stty echo icanon 2>/dev/null
        fi
        echo >&2
    }
    trap restore_tty EXIT TERM
    trap 'interrupted=1' INT

    # Redraw in place by moving the cursor up to the menu's first line and
    # clearing down (we know the height is n lines). Avoids the ANSI
    # save/restore-cursor sequences (\033[s/\033[u) which some terminals don't
    # honour, which made arrow navigation append duplicate lists.
    redraw() {
        if (( !first )); then
            printf '\033[%dA\033[J' "${n}" >&2
        fi
        first=0
        for (( idx = 0; idx < n; idx++ )); do
            entry="${entries[$idx]}"
            marker="${entry##*$'\x1f'}"
            path="${entry%$'\x1f'*}"
            case "${marker}" in
                '11') label="mounts + history" ;;
                '10') label="mounts" ;;
                '01') label="history" ;;
                *)    label="${marker}" ;;
            esac
            if (( idx == i )); then
                printf '\033[7m> %s  \033[32m[%s]\033[0m\n' "${path}" "${label}" >&2
            else
                printf '  %s  \033[32m[%s]\033[0m\n' "${path}" "${label}" >&2
            fi
        done
    }

    redraw
    while true; do
        if (( interrupted )); then i=-1; break; fi

        # Timed read: lets us notice Ctrl-C (via the flag) and a lone Esc key.
        if ! IFS= read -rsn1 -t 0.3 key; then
            (( interrupted )) && { i=-1; break; }
            continue
        fi
        case "${key}" in
            $'\x1b')                         # escape: arrow-key prefix
                IFS= read -rsn1 -t 0.3 rest || rest=''
                case "${rest}" in
                    '[') IFS= read -rsn1 -t 0.3 key || key='' ;;
                    *)   key="${rest}" ;;
                esac
                case "${key}" in
                    A) i=$(( (i + n - 1) % n )); redraw ;;   # Up
                    B) i=$(( (i + 1) % n )); redraw ;;       # Down
                esac
                ;;
            '') break ;;                     # Enter: select
            $'\x03'|q|Q) i=-1; break ;;      # Ctrl-C byte / q: cancel
            k) i=$(( (i + n - 1) % n )); redraw ;;
            j) i=$(( (i + 1) % n )); redraw ;;
        esac
    done

    trap - EXIT TERM INT
    restore_tty
    if (( i < 0 )); then
        return 1
    fi
    PICK_RESULT="${entries[$i]%$'\x1f'*}"
}

main() {
    if ! list_projects; then
        echo "No previously opened projects found." >&2
        echo "Open opencode.sh on a project first to register it." >&2
        exit 1
    fi

    local chosen mounts
    # Run pick_project in the current shell (not $(...)) so Ctrl-C's SIGINT
    # goes straight to the single process running the menu; the result is
    # delivered via the global PICK_RESULT.
    if ! pick_project "${PROJECTS[@]}"; then
        echo "Cancelled." >&2
        exit 1
    fi
    chosen="${PICK_RESULT}"

    # Auto-restore the project's memorized mounts (none if absent).
    mounts=()
    if get_mem_mounts "${chosen}"; then
        mounts=( "${MEM_MOUNTS[@]}" )
    fi

    exec "${SCRIPT_DIR}/opencode.sh" "${chosen}" "${mounts[@]}"
}

main "$@"