#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

IMAGE_NAME="dev-browser"

# One browser instance per project: separate container, profile, CDP endpoint
# and CLI state. The project path is hashed with the same convention as
# OpenCode's history/mount keys. XDG-style fallbacks keep the script usable
# outside an OpenCode session.
PROJECT_DIR="${BROWSER_PROJECT_DIR:-${OPENCODE_PROJECT_DIR:-$(pwd)}}"
PROJECT_DIR="$(realpath "${PROJECT_DIR}" 2>/dev/null || printf '%s' "${PROJECT_DIR}")"
INSTANCE_KEY="${BROWSER_INSTANCE:-${OPENCODE_PROJECT_KEY:-$(printf '%s' "${PROJECT_DIR}" | sha256sum | awk '{print $1}')}}"

if [[ ! "${INSTANCE_KEY}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "✗ Invalid browser instance key: ${INSTANCE_KEY}" >&2
    exit 1
fi

INSTANCE_SHORT="${INSTANCE_KEY:0:12}"
CONTAINER_NAME="dev-browser-${INSTANCE_SHORT}"
DOCKERFILE="${SCRIPT_DIR}/browser/Dockerfile"
PROFILE_DIR="${BROWSER_PROFILE_DIR:-${SCRIPT_DIR}/browser-profile/${INSTANCE_KEY}}"
ENDPOINT_FILE="${PROFILE_DIR}/.cdp-endpoint"
MODE_FILE="${PROFILE_DIR}/.mode"
DEVTOOLS_FILE="${PROFILE_DIR}/DevToolsActivePort"

# Headless is the default: agent work never maps a window on the human's
# desktop. `login` relaunches the same profile headful for OIDC/2FA handoffs.
DISPLAY_NAME="${BROWSER_DISPLAY:-:0}"
WINDOW_SIZE="${BROWSER_WINDOW_SIZE:-1600,1000}"
CDP_PORT="${BROWSER_CDP_PORT:-0}"

show_help() {
    cat <<EOF
Usage: browser.sh [command]

Per-project Chromium for the human and OpenCode. Runs headless by default;
"login" relaunches the same profile headful for OIDC/2FA handoffs.

Commands:
  start      Start this project's browser (headless; leaves a running mode alone)
  login      Relaunch this project's browser headful on BROWSER_DISPLAY
  headless   Relaunch this project's browser without a window
  stop       Stop this project's browser (open tabs are remembered)
  restart    Stop and start headless
  status     Show instance, mode, CDP endpoint and display status
  endpoint   Print the CDP endpoint for this project
  list       List all per-project browser instances
  stop-all   Stop all per-project browser instances
  build      Build/refresh the dev-browser image only

Environment overrides:
  BROWSER_PROJECT_DIR   Project path used for the instance key (default: cwd)
  BROWSER_INSTANCE      Explicit instance key (default: sha256 of project path)
  BROWSER_PROFILE_DIR   Profile directory (default: browser-profile/<key>)
  BROWSER_DISPLAY       X display for headful mode (default: ${DISPLAY_NAME})
  BROWSER_CDP_PORT      CDP port, 0 = auto (default: ${CDP_PORT})
  BROWSER_WINDOW_SIZE   Headful window size (default: ${WINDOW_SIZE})

Instance: ${INSTANCE_KEY} (${CONTAINER_NAME})
Project:  ${PROJECT_DIR}
Profile:  ${PROFILE_DIR}
EOF
}

require_podman() {
    if ! command -v podman >/dev/null 2>&1; then
        echo "✗ podman not found" >&2
        exit 1
    fi
}

# Serialize lifecycle operations so two sessions cannot race a start/stop on
# the same instance (or stop-all racing a project start). Browsing itself is
# still parallel across projects.
acquire_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    mkdir -p "${SCRIPT_DIR}/browser-profile"
    exec 9>"${SCRIPT_DIR}/browser-profile/.lock"
    if ! flock -w 120 9; then
        echo "✗ Another browser.sh operation is still running" >&2
        exit 1
    fi
}

# X socket file name for a display name (:0 -> X0, :0.0 -> X0).
x_socket_name() {
    local display="${1#:}"
    display="${display%%.*}"
    printf 'X%s\n' "${display}"
}

require_display() {
    local socket="/tmp/.X11-unix/$(x_socket_name "${DISPLAY_NAME}")"
    if [[ ! -S "${socket}" ]]; then
        echo "✗ X display ${DISPLAY_NAME} not available (${socket} missing)" >&2
        echo "  Headless mode still works; override with BROWSER_DISPLAY=:N for login." >&2
        return 1
    fi
}

image_exists() {
    podman image inspect "${IMAGE_NAME}" >/dev/null 2>&1
}

container_status() {
    podman container inspect --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || true
}

label_value() {
    local name="$1" key="$2"
    podman container inspect --format "{{index .Config.Labels \"${key}\"}}" "${name}" 2>/dev/null || true
}

current_mode() {
    if [[ -s "${MODE_FILE}" ]]; then
        cat "${MODE_FILE}"
        return 0
    fi
    label_value "${CONTAINER_NAME}" "dev-browser.mode"
}

endpoint_url() {
    if [[ -s "${ENDPOINT_FILE}" ]]; then
        cat "${ENDPOINT_FILE}"
        return 0
    fi
    return 1
}

cdp_version() {
    local url
    url="$(endpoint_url)" || return 1
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsS -m 2 "${url}/json/version" 2>/dev/null
}

cdp_version_on_port() {
    local port="$1"
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsS -m 2 "http://127.0.0.1:${port}/json/version" 2>/dev/null
}

write_endpoint() {
    local port="$1"
    printf 'http://127.0.0.1:%s\n' "${port}" > "${ENDPOINT_FILE}.tmp"
    mv "${ENDPOINT_FILE}.tmp" "${ENDPOINT_FILE}"
}

discover_port() {
    local i port

    if [[ "${CDP_PORT}" != "0" ]]; then
        printf '%s\n' "${CDP_PORT}"
        return 0
    fi

    for (( i=0; i<120; i++ )); do
        if [[ -s "${DEVTOOLS_FILE}" ]]; then
            port="$(head -n1 "${DEVTOOLS_FILE}" | tr -d '[:space:]')"
            if [[ -n "${port}" ]]; then
                printf '%s\n' "${port}"
                return 0
            fi
        fi
        sleep 0.25
    done
    return 1
}

wait_for_cdp() {
    local port="$1" i
    for (( i=0; i<120; i++ )); do
        if cdp_version_on_port "${port}" >/dev/null; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

print_endpoints() {
    local mode url
    mode="$(current_mode)"
    url="$(endpoint_url)" || true

    echo "  project:  ${PROJECT_DIR}"
    echo "  instance: ${INSTANCE_KEY} (${CONTAINER_NAME})"
    echo "  mode:     ${mode:-unknown}"
    if [[ -n "${url}" ]]; then
        echo "  cdp:      ${url}"
    else
        echo "  cdp:      (not available)"
    fi
    echo "  profile:  ${PROFILE_DIR}"
}

cleanup_runtime_files() {
    rm -f "${ENDPOINT_FILE}" "${MODE_FILE}" "${DEVTOOLS_FILE}"
}

# Close via CDP "Browser.close" rather than podman stop: Chromium flushes
# cookies and the session store on a graceful close, so --restore-last-session
# can bring back both tabs and session cookies across headless/headful switches.
graceful_close_endpoint() {
    local url="$1" node_bin
    [[ -n "${url}" ]] || return 1
    command -v node >/dev/null 2>&1 || return 1
    [[ -f "${SCRIPT_DIR}/browser-cli/browser-cli.mjs" ]] || return 1

    node_bin="$(command -v node)"
    BROWSER_CDP_ENDPOINT="${url}" \
        "${node_bin}" "${SCRIPT_DIR}/browser-cli/browser-cli.mjs" quit >/dev/null 2>&1
}

graceful_close() {
    local url
    url="$(endpoint_url)" || return 1
    graceful_close_endpoint "${url}"
}

build_image() {
    echo "→ Building ${IMAGE_NAME} image"
    podman build -t "${IMAGE_NAME}" \
        --build-arg UID="$(id -u)" \
        --build-arg GID="$(id -g)" \
        -f "${DOCKERFILE}" "${SCRIPT_DIR}/browser"
    echo "✓ Image built: ${IMAGE_NAME}"
}

start_browser() {
    local mode="$1" status port
    local -a chrome_args

    case "${mode}" in
        headless|headful) ;;
        *)
            echo "✗ Invalid browser mode: ${mode}" >&2
            exit 1
            ;;
    esac

    status="$(container_status)"
    if [[ "${status}" == "running" ]]; then
        echo "✓ Browser already running ($(current_mode))"
        print_endpoints
        return 0
    fi

    if ! image_exists; then
        build_image
    fi

    if [[ "${mode}" == "headful" ]]; then
        require_display
    fi

    mkdir -p "${PROFILE_DIR}"
    rm -f "${ENDPOINT_FILE}" "${DEVTOOLS_FILE}" "${MODE_FILE}"

    chrome_args=(
        /usr/bin/chromium
        --user-data-dir=/profile
        --remote-debugging-port="${CDP_PORT}"
        --restore-last-session
        --no-first-run
        --no-default-browser-check
        --noerrdialogs
        --hide-crash-restore-bubble
        --password-store=basic
        --disable-dev-shm-usage
        --disable-gpu
        --no-sandbox
    )

    if [[ "${mode}" == "headless" ]]; then
        chrome_args+=(--headless=new)
    else
        chrome_args+=(
            --window-size="${WINDOW_SIZE}"
            --class="dev-browser-${INSTANCE_SHORT}"
        )
    fi

    # A stale stopped container can still own the name when --rm did not run.
    podman rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

    echo "→ Starting ${CONTAINER_NAME} in ${mode} mode"
    podman run -d --rm \
        --name "${CONTAINER_NAME}" \
        --label "dev-browser.instance=${INSTANCE_KEY}" \
        --label "dev-browser.project=${PROJECT_DIR}" \
        --label "dev-browser.profile=${PROFILE_DIR}" \
        --label "dev-browser.mode=${mode}" \
        --userns=keep-id \
        --network host \
        -e "DISPLAY=${DISPLAY_NAME}" \
        -v /tmp/.X11-unix:/tmp/.X11-unix \
        -v /etc/resolv.conf:/etc/resolv.conf:ro \
        -v "${PROFILE_DIR}:/profile" \
        "${IMAGE_NAME}" \
        "${chrome_args[@]}" >/dev/null

    if ! port="$(discover_port)"; then
        echo "⚠ Browser started but CDP did not open; check: podman logs ${CONTAINER_NAME}" >&2
        return 1
    fi

    write_endpoint "${port}"
    printf '%s\n' "${mode}" > "${MODE_FILE}"

    if ! wait_for_cdp "${port}"; then
        echo "⚠ Browser started but CDP is not reachable; check: podman logs ${CONTAINER_NAME}" >&2
        return 1
    fi

    echo "✓ Browser ready (${mode})"
    print_endpoints
}

stop_browser() {
    local status i
    status="$(container_status)"

    if [[ -z "${status}" ]]; then
        cleanup_runtime_files
        echo "✓ Browser not running"
        return 0
    fi

    echo "→ Stopping ${CONTAINER_NAME}"
    if graceful_close; then
        # Give the graceful close a moment to flush cookies/session and exit.
        for (( i=0; i<40; i++ )); do
            [[ -z "$(container_status)" ]] && break
            sleep 0.2
        done
    fi

    # Fallback for a hung browser or a missing node/browser-cli.
    if [[ -n "$(container_status)" ]]; then
        podman stop -t 15 "${CONTAINER_NAME}" >/dev/null 2>&1 \
            || podman rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 \
            || true
        for (( i=0; i<25; i++ )); do
            [[ -z "$(container_status)" ]] && break
            sleep 0.2
        done
    fi

    cleanup_runtime_files
    echo "✓ Browser stopped"
}

switch_mode() {
    local mode="$1" status

    if [[ "${mode}" == "headful" ]]; then
        require_display
    fi

    status="$(container_status)"
    if [[ "${status}" == "running" && "$(current_mode)" == "${mode}" ]]; then
        echo "✓ Browser already ${mode}"
        print_endpoints
        return 0
    fi

    if [[ "${status}" == "running" ]]; then
        stop_browser
    fi

    start_browser "${mode}"
}

status_browser() {
    local status mode url version

    echo "project:   ${PROJECT_DIR}"
    echo "instance:  ${INSTANCE_KEY}"
    echo "container: ${CONTAINER_NAME}"
    echo "profile:   ${PROFILE_DIR}"

    status="$(container_status)"
    if [[ -z "${status}" ]]; then
        echo "browser:  not running"
        return 0
    fi

    mode="$(current_mode)"
    echo "browser:  ${status} (${mode:-unknown})"

    url="$(endpoint_url)" || true
    if [[ -n "${url}" ]] && version="$(cdp_version)"; then
        version="$(printf '%s' "${version}" | grep -o '"Browser": *"[^"]*"' | cut -d'"' -f4)"
        echo "cdp:      ${url} (${version})"
    else
        echo "cdp:      ${url:-unreachable}"
    fi
    echo "display:  ${DISPLAY_NAME} (used only in headful mode)"
}

endpoint_command() {
    local url
    if [[ "$(container_status)" != "running" ]]; then
        echo "✗ Browser not running for ${PROJECT_DIR}" >&2
        exit 1
    fi
    url="$(endpoint_url)" || {
        echo "✗ Browser endpoint is not available yet" >&2
        exit 1
    }
    printf '%s\n' "${url}"
}

list_instances() {
    local -a names
    local name project mode status

    mapfile -t names < <(podman ps -a --filter "label=dev-browser.instance" --format '{{.Names}}')
    if (( ${#names[@]} == 0 )); then
        echo "no browser instances"
        return 0
    fi

    printf '%-14s %-8s %-9s %s\n' "INSTANCE" "MODE" "STATUS" "PROJECT"
    for name in "${names[@]}"; do
        project="$(label_value "${name}" "dev-browser.project")"
        mode="$(label_value "${name}" "dev-browser.mode")"
        status="$(podman container inspect --format '{{.State.Status}}' "${name}" 2>/dev/null || true)"
        printf '%-14s %-8s %-9s %s\n' \
            "${name#dev-browser-}" "${mode:-?}" "${status:-?}" "${project:-?}"
    done
}

stop_all_browsers() {
    local -a names
    local name key profile i

    mapfile -t names < <(podman ps -a --filter "label=dev-browser.instance" --format '{{.Names}}')
    if (( ${#names[@]} == 0 )); then
        echo "✓ No browser instances"
        return 0
    fi

    for name in "${names[@]}"; do
        key="$(label_value "${name}" "dev-browser.instance")"
        profile="$(label_value "${name}" "dev-browser.profile")"
        if [[ -z "${profile}" && -n "${key}" ]]; then
            profile="${SCRIPT_DIR}/browser-profile/${key}"
        fi

        echo "→ Stopping ${name}"
        if [[ -n "${profile}" && -s "${profile}/.cdp-endpoint" ]] \
            && graceful_close_endpoint "$(cat "${profile}/.cdp-endpoint")"; then
            for (( i=0; i<40; i++ )); do
                podman container inspect "${name}" >/dev/null 2>&1 || break
                sleep 0.2
            done
        fi

        if podman container inspect "${name}" >/dev/null 2>&1; then
            podman stop -t 15 "${name}" >/dev/null 2>&1 \
                || podman rm -f "${name}" >/dev/null 2>&1 \
                || true
        fi

        if [[ -n "${profile}" ]]; then
            rm -f "${profile}/.cdp-endpoint" "${profile}/.mode" "${profile}/DevToolsActivePort"
        fi
    done

    for (( i=0; i<25; i++ )); do
        mapfile -t names < <(podman ps -a --filter "label=dev-browser.instance" --format '{{.Names}}')
        (( ${#names[@]} == 0 )) && break
        sleep 0.2
    done

    echo "✓ All browser instances stopped"
}

main() {
    local cmd="${1:-start}"

    require_podman

    case "${cmd}" in
        status|endpoint|list|instances|-h|--help|help) ;;
        *) acquire_lock ;;
    esac

    case "${cmd}" in
        start)      start_browser headless ;;
        login|show) switch_mode headful ;;
        headless|hide|background) switch_mode headless ;;
        stop)       stop_browser ;;
        restart)    stop_browser; start_browser headless ;;
        status)     status_browser ;;
        endpoint)   endpoint_command ;;
        list|instances) list_instances ;;
        stop-all)   stop_all_browsers ;;
        build)      build_image ;;
        -h|--help|help) show_help ;;
        *)
            echo "✗ Unknown command: ${cmd}" >&2
            show_help >&2
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
