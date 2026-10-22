# OpenCode Container

Security-focused rootless [Podman](https://podman.io) setup for running [OpenCode](https://github.com/anomalyco/opencode) with restricted filesystem access and Podman-in-Podman support.

## Quick Start

```bash
# From your project directory:
./path/to/opencode.sh

# Update to latest version
./path/to/opencode.sh update
```

## Requirements

- Rootless Podman on the host (tested with 3.4.4 on Ubuntu 22.04)
- Podman user API socket enabled:

  ```bash
  systemctl --user enable --now podman.socket
  ```

- For `--kvm`: membership in the host `kvm` group

## First Run

On first run, the container builds with the latest OpenCode version. The version is stored in `.opencode-version` next to `opencode.sh`. Subsequent runs use the stored version (no automatic update checks). Run `./path/to/opencode.sh update` to update to the latest version.

## Usage

```bash
# Mount current working directory
./path/to/opencode.sh

# Mount specific path(s) - first path is the working directory
./path/to/opencode.sh /path/to/project
./path/to/opencode.sh /path/to/project /path/to/otherdir

# Update to latest version
./path/to/opencode.sh update
```

When paths are provided, they are resolved relative to the current working directory. Relative paths (e.g., `./upmon`) are supported. All paths are validated before starting the container.

## Mounted Paths

- Project directory (first path argument, or current working directory if no args)
- Additional directories (subsequent path arguments, each mounted at the same path inside the container)
- `~/.config/opencode/` - OpenCode settings and API key
- `~/.local/share/opencode/` - OpenCode data
- `~/.ssh/config` and `~/.ssh/sockets` - SSH access (OpenCode can SSH without password or key through existing connections shared via ControlPath)
- `$XDG_RUNTIME_DIR/podman/podman.sock` - rootless Podman API socket (for running tests)
- `/tmp/.X11-unix` - X11 forwarding (clipboard)

## Podman-in-Podman

The container ships a statically linked `podman-remote` client whose version
matches the host's Podman (passed as the `PODMAN_VERSION` build arg; the libpod
remote API is not cross-version compatible). A `docker` shim forwards to it, so
both `podman ...` and `docker ...` work inside the container.

Both talk to the host's **rootless, user-owned** Podman API socket — no
privileged daemon and no root-equivalent `/var/run/docker.sock` is mounted.
Containers started from inside OpenCode run with the host user's privileges,
and the launcher uses `--userns=keep-id` so file ownership in mounted
directories stays consistent.
