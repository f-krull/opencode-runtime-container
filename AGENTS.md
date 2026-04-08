# AGENTS.md - OpenCode Container Setup

## Project Overview

Security-focused Docker container setup for running [OpenCode](https://github.com/anomalyco/opencode). 

**Design goals:**
- Restrict OpenCode's filesystem access by only mounting specific files/folders
- Limit what files OpenCode can view and edit
- Allow running Docker from inside the container to execute code with specific dependencies

This is NOT the OpenCode source code - it's a containerized environment for safely using OpenCode on development projects.

## Build Commands

### Build the Container

```bash
# Using the build script (recommended)
./build.sh

# Or directly with docker
docker build -t opencode-fk -f Dockerfile .
```

### Run the Container

Run from your project directory:

```bash
# Using the run script (recommended)
./path/to/opencode.sh

# Or directly with docker
docker run -it --rm \
    -v "${PWD}:${PWD}" \
    -v "${HOME}/.config/opencode/":/home/dev/.config/opencode/ \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -w "${PWD}" \
    --network host \
    opencode-fk
```

### Single Command Execution

```bash
docker run --rm -it \
    -v "$(pwd):$(pwd)" \
    -w "$(pwd)" \
    opencode-fk <command>
```

### Architecture

```
Host Machine                    Container
┌─────────────────┐            ┌─────────────────┐
│  Project Code   │◄──mount───►│  Project Dir    │
│  (current dir)  │            │  (same path)    │
├─────────────────┤            ├─────────────────┤
│  Docker Daemon  │◄──socket─►│  docker client  │
│                 │   mount    │  (run tests)    │
└─────────────────┘            └─────────────────┘
```

### Environment Variables

The container includes the following environment variables:
- `OPENCODE_VERSION` - The OpenCode version baked into the container image
- `UID` / `GID` - User/group IDs for the dev user

### Security Model

Only explicitly mounted directories are accessible to OpenCode. Key mounts in opencode.sh:
- Project directory (current working directory, mounted at same path)
- `~/.config/opencode/` (OpenCode settings)
- `~/.ssh/config` and sockets (SSH access)
- `/var/run/docker.sock` (Docker-in-Docker for dependency execution)

## Testing

This project does not contain application source code to test. To verify the container works:

```bash
# Test container builds successfully
./build.sh

# Test container runs and OpenCode is available
docker run --rm -it opencode-fk opencode --version
```

## Code Style Guidelines

### Shell Scripts (build.sh, opencode.sh)

Follow these conventions:
- Use strict mode: `set -euo pipefail`
- Use lowercase with underscores for variables: `project_dir`, `docker_gid`
- Use uppercase for constants: `DEFAULT_PORT=8080`
- Quote all variable expansions: `"${VAR}"` not `$VAR`
- Use `$(..)` not backticks for command substitution
- Handle command failures: `DOCKER_GID=$(getent group docker | cut -d: -f3) || DOCKER_GID=999`
- Use `[[ ]]` for tests, not `[ ]`
- Use case statements for pattern matching

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

case "${ARCH}" in
    amd64|x86_64) ARCH="x64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) echo "Unsupported architecture" >&2; exit 1 ;;
esac
```

### Dockerfile

Follow Docker best practices:
- Use specific tags: `debian:13.3-slim` not `debian:latest`
- Put least-changing layers first, most-changing last
- Combine related operations to reduce layers
- Run as non-root user when possible
- Use `--no-install-recommends` and clean up caches

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git jq && rm -rf /var/lib/apt/lists/*

ARG USERNAME=dev
RUN groupadd -g ${GID:-1000} ${USERNAME} && \
    useradd -m -u ${UID:-1000} -g ${GID:-1000} -s /bin/bash ${USERNAME}
USER ${USERNAME}

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD opencode --version || exit 1
```

### General Conventions

#### File Permissions
- Scripts should be executable: `chmod +x build.sh opencode.sh`
- Use `#!` shebang with `/usr/bin/env` for portability

#### Comments
- Explain *why*, not *what*
- Use comments to document non-obvious decisions

#### Commit Messages
- Use imperative mood: "Add feature" not "Added feature"
- First line under 50 characters

## Common Tasks

### Update OpenCode Version

Use the built-in update command:
```bash
./path/to/opencode.sh update
```

This will:
1. Check GitHub for the latest version
2. Show a banner with the new version number
3. Wait for keypress to continue
4. Build a new container with the latest version
5. Update the version file (`.opencode-version`)

The `update` command does not start the container—it only updates the Docker image.

The current version is displayed on startup and is also available inside the container as the `OPENCODE_VERSION` environment variable.

### Version File Location

The version file (`.opencode-version`) is stored in the same directory as `opencode.sh`, not in the project directory. This allows using different OpenCode versions for different projects by placing `opencode.sh` in each project.

### Version Checking

On regular runs, the script:
- Reads stored version from `.opencode-version` (next to opencode.sh)
- Checks GitHub for newer version (1 second timeout, non-blocking)
- If newer version available, shows banner and waits for keypress before continuing
- Runs container with stored version (uses cached image)
- Displays current version on startup

The version is persisted in `.opencode-version` and also baked into the container as `OPENCODE_VERSION` environment variable.

### Add New Volume Mounts

Edit `opencode.sh` and add to the `docker run` command:
```bash
-v "${HOME}/path/to/dir":/home/dev/path/to/dir
```

## Troubleshooting

### Docker Socket Permission Denied
Ensure your user is in the docker group or use `--group-add ${DOCKER_GID}` as shown in opencode.sh.

### X11 Forwarding Not Working
The container mounts `/tmp/.X11-unix` for X11. Ensure X server is running on host.

### SSH Not Working
Verify `~/.ssh/config` exists on host and is mounted in opencode.sh.