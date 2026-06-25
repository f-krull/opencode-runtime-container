# OpenCode Container

Security-focused Docker container for running [OpenCode](https://github.com/anomalyco/opencode) with restricted filesystem access and Docker-in-Docker support.

## Quick Start

```bash
# From your project directory:
./path/to/opencode.sh

# Update to latest version
./path/to/opencode.sh update
```

## Requirements

- Docker
- Docker socket accessible (`/var/run/docker.sock`)
- User in docker group (or equivalent)

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
- `/var/run/docker.sock` - Docker daemon (for running tests)
- `/tmp/.X11-unix` - X11 forwarding (clipboard)
