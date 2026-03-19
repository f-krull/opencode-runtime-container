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

On first run, the container builds with the latest OpenCode version. Subsequent runs check for updates - if a new version is available, you'll see a banner and can choose to update or continue with the current version.

## Usage

Run `opencode.sh` from the project directory you want to work on. The current working directory is mounted into the container, allowing OpenCode to access and edit only that project.

## Mounted Paths

- Project directory (current working directory, mounted at same path)
- `~/.config/opencode/` - OpenCode settings and API key
- `~/.ssh/config` and `~/.ssh/sockets` - SSH access (OpenCode can SSH without password or key through existing connections shared via ControlPath)
- `/var/run/docker.sock` - Docker daemon (for running tests)
- `/tmp/.X11-unix` - X11 forwarding (clipboard)
