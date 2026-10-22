#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

IMAGE_NAME="dev-browser"
CONTAINER_NAME="dev-browser"
DOCKERFILE="${SCRIPT_DIR}/browser/Dockerfile"
PROFILE_DIR="${SCRIPT_DIR}/browser-profile"

# Shared Chromium for the human and OpenCode: a native window on the host
# display plus a CDP endpoint on 127.0.0.1 (reachable from every container
# because they run with --network host).
CDP_PORT="${BROWSER_CDP_PORT:-9222}"
DISPLAY_NAME="${BROWSER_DISPLAY:-:0}"
WINDOW_SIZE="${BROWSER_WINDOW_SIZE:-1600,1000}"

show_help() {
    cat <<EOF
Usage: browser.sh [command]

Shared Chromium for the human and OpenCode on the host display, with a CDP
endpoint for agent control. The browser runs as a detached container and
outlives OpenCode sessions; logins persist in browser-profile/.

Commands:
  start      Start the browser (default; builds the image on first run)
  stop       Stop the browser
  restart    Stop and start the browser
  status     Show container, CDP and display status
  build      Build/refresh the dev-browser image only

Environment overrides:
  BROWSER_DISPLAY     X display (default: ${DISPLAY_NAME})
  BROWSER_CDP_PORT    Remote debugging port (default: ${CDP_PORT})
  BROWSER_WINDOW_SIZE Chromium window size (default: ${WINDOW_SIZE})

CDP endpoint: http://127.0.0.1:${CDP_PORT}
EOF
}

require_podman() {
    if ! command -v podman >/dev/null 2>&1; then
        echo "✗ podman not found" >&2
        exit 1
    fi
}

# X socket file name for a display name (:0 -> X0, :0.0 -> X0).
x_socket_name() {
    local display="${1#:}"
    display="${display%%.*}"
    printf 'X%s\n' "${display}"
}

image_exists() {
    podman image inspect "${IMAGE_NAME}" >/dev/null 2>&1
}

container_status() {
    podman container inspect --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || true
}

cdp_version() {
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsS -m 2 "http://127.0.0.1:${CDP_PORT}/json/version" 2>/dev/null
}

wait_for_cdp() {
    local i
    for (( i=0; i<30; i++ )); do
        if cdp_version >/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

print_endpoints() {
    echo "  window:  display ${DISPLAY_NAME} (on the host desktop)"
    echo "  cdp:     http://127.0.0.1:${CDP_PORT}"
    echo "  profile: ${PROFILE_DIR}"
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
    local status socket

    status="$(container_status)"
    if [[ "${status}" == "running" ]]; then
        echo "✓ Browser already running"
        print_endpoints
        return 0
    fi

    if ! image_exists; then
        build_image
    fi

    socket="/tmp/.X11-unix/$(x_socket_name "${DISPLAY_NAME}")"
    if [[ ! -S "${socket}" ]]; then
        echo "✗ X display ${DISPLAY_NAME} not available (${socket} missing)" >&2
        echo "  Is the desktop session running? Override with BROWSER_DISPLAY=:N" >&2
        exit 1
    fi

    mkdir -p "${PROFILE_DIR}"

    echo "→ Starting ${CONTAINER_NAME} on display ${DISPLAY_NAME}"
    podman run -d --rm \
        --name "${CONTAINER_NAME}" \
        --userns=keep-id \
        --network host \
        -e "DISPLAY=${DISPLAY_NAME}" \
        -v /tmp/.X11-unix:/tmp/.X11-unix \
        -v "${PROFILE_DIR}:/profile" \
        "${IMAGE_NAME}" \
        /usr/bin/chromium \
            --user-data-dir=/profile \
            --remote-debugging-port="${CDP_PORT}" \
            --no-first-run \
            --no-default-browser-check \
            --noerrdialogs \
            --hide-crash-restore-bubble \
            --password-store=basic \
            --disable-dev-shm-usage \
            --disable-gpu \
            --no-sandbox \
            --window-size="${WINDOW_SIZE}" \
            about:blank

    if command -v curl >/dev/null 2>&1; then
        if wait_for_cdp; then
            echo "✓ Browser ready"
        else
            echo "⚠ Browser started but CDP not reachable yet; check: browser.sh status" >&2
        fi
    fi

    print_endpoints
}

stop_browser() {
    local status
    status="$(container_status)"
    if [[ -z "${status}" ]]; then
        echo "✓ Browser not running"
        return 0
    fi

    echo "→ Stopping ${CONTAINER_NAME}"
    # With --rm the container removes itself once stopped; rm -f is a fallback
    # for stale entries after a podman restart.
    podman stop -t 15 "${CONTAINER_NAME}" >/dev/null 2>&1 \
        || podman rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 \
        || true
    echo "✓ Browser stopped"
}

status_browser() {
    local status version
    status="$(container_status)"

    if [[ -z "${status}" ]]; then
        echo "browser:  not running"
        return 0
    fi

    echo "browser:  ${status}"
    if [[ "${status}" == "running" ]] && version="$(cdp_version)"; then
        version="$(printf '%s' "${version}" | grep -o '"Browser": *"[^"]*"' | cut -d'"' -f4)"
        echo "cdp:      http://127.0.0.1:${CDP_PORT} (${version})"
    else
        echo "cdp:      http://127.0.0.1:${CDP_PORT} (unreachable)"
    fi
    echo "display:  ${DISPLAY_NAME}"
    echo "profile:  ${PROFILE_DIR}"
}

main() {
    require_podman

    case "${1:-start}" in
        start)   start_browser ;;
        stop)    stop_browser ;;
        restart) stop_browser; start_browser ;;
        status)  status_browser ;;
        build)   build_image ;;
        -h|--help|help) show_help ;;
        *)
            echo "✗ Unknown command: $1" >&2
            show_help >&2
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
