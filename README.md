# OpenCode Container

Security-focused Docker container for running [OpenCode](https://github.com/anomalyco/opencode) with restricted filesystem access and Docker-in-Docker support.

## Quick Start

```bash
# Build and run OpenCode
./opencode.sh

# Update to latest version
./opencode.sh update
```

## Requirements

- Docker
- Docker socket accessible (`/var/run/docker.sock`)
- User in docker group (or equivalent)

## First Run

On first run, the container builds with the latest OpenCode version. Subsequent runs check for updates - if a new version is available, you'll see a banner and can choose to update or continue with the current version.

## Mounted Paths

- Project directory (current working directory → `/workspace`)
- `~/.config/opencode/` - OpenCode settings and API key
- `~/.ssh/config` and `~/.ssh/sockets` - SSH access (OpenCode can SSH without password or key through existing connections shared via ControlPath)
- `/var/run/docker.sock` - Docker daemon (for running tests)
- `/tmp/.X11-unix` - X11 forwarding (clipboard)
