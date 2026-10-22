# Code Review: Key Findings

## Project Overview

This is a **security-focused rootless Podman container setup** for running [OpenCode](https://github.com/anomalyco/opencode), an AI-powered code editor. The project provides a containerized environment that restricts OpenCode's filesystem access while enabling full development workflows including Podman-in-Podman for test execution.

---

## Core Findings

### 1. Project Purpose

The project accomplishes three primary goals:

1. **Filesystem Isolation** - Restricts OpenCode to only explicitly mounted directories, not the entire host filesystem
2. **Podman-in-Podman Support** - Allows running tests and build commands that require Podman (or `docker`, via a shim) from inside the container
3. **Developer Experience** - Provides a seamless development environment with SSH, X11/clipboard, and proper file permissions

### 2. Security Model

The core security concept is **explicit allowlisting** of filesystem access:

- Only explicitly mounted paths are accessible to OpenCode inside the container
- Project directory mounted at the same path - this is what OpenCode "sees"
- Host's entire filesystem is NOT accessible (unlike a typical installation)
- Container runs as non-root user (`dev`) with configurable UID/GID matching the host user
- The Podman socket is the **rootless user socket** (`$XDG_RUNTIME_DIR/podman/podman.sock`, mode 0660, owned by the host user), not a root daemon socket — OpenCode gets the invoking user's privileges at most

### 3. Architecture

```
Host Machine                     Container
┌─────────────────┐            ┌─────────────────┐
│  Project Code   │◄──mount───►│  Project Dir    │
│  (current dir)  │            │  (same path)    │
├─────────────────┤            ├─────────────────┤
│  Podman (user)  │◄──socket─►│ podman-remote   │
│  API socket     │   mount    │  (run tests)    │
└─────────────────┘            └─────────────────┘
```

The container's remote client version is pinned to the host's Podman version
(the libpod remote API is not cross-version compatible). `opencode.sh` runs the
container with `--userns=keep-id` so the container user maps 1:1 to the host
user and file ownership is preserved.

### 4. Key Components

| Component | File | Purpose |
|-----------|------|---------|
| **Dockerfile** | `Dockerfile` | Defines container image with OpenCode, dev tools, Podman remote client |
| **Build Script** | `build.sh` | Simple wrapper for building the container image |
| **Run Script** | `opencode.sh` | Main entry point - handles versioning, building, and running container |
| **Version File** | `.opencode-version` | Stores current OpenCode version (gitignored) |

### 5. Volume Mounts

The container receives explicit mounts only:

```bash
-v "${PROJECT_DIR}:${PROJECT_DIR}"       # Current project (same path)
-v "${HOME}/.config/opencode/":...       # OpenCode settings
-v "${HOME}/.ssh/config":...             # SSH config
-v "${HOME}/.ssh/sockets":...            # SSH agent sockets
-v "${PODMAN_SOCKET}":...               # Rootless Podman API socket
-v /tmp/.X11-unix:...                    # X11/clipboard
```

### 6. Version Management Flow

```
First Run:
  → No version file → fetch latest from GitHub → build → save version

Regular Run:
  → Read stored version → run container (uses cached image)
  → No automatic update checks

Update Command:
  → Fetch latest → rebuild → update version file
```

The version file is stored in the same directory as `opencode.sh`, not in the project directory.

---

## Agent Analysis Summary

### Agent 1 Findings
- Emphasized security architecture and trade-offs (Podman socket access, host network mode)
- Detailed the version management system
- Noted the same-path mount pattern for Podman-in-Podman transparency

### Agent 2 Findings
- Identified the explicit whitelist model as the core security mechanism
- Analyzed Dockerfile components and opencode.sh
- Noted `.notes.md` contains an alternative, more complex Dockerfile with additional features like dotfiles support and entrypoint scripts

### Agent 3 Findings
- Provided detailed workflow diagrams
- Analyzed all mount points and their purposes
- Identified strengths: minimal attack surface, clean separation of concerns, production-ready code style

---

## Key Areas of Agreement

All three agents consistently identified:

1. **Core Purpose**: Security-focused container for OpenCode AI editor
2. **Security Model**: Filesystem isolation through explicit mount allowlisting
3. **Key Components**: Dockerfile, opencode.sh, build.sh
4. **Security Features**: Non-root user, least privilege, explicit mounts only
5. **Podman-in-Podman**: Enables test execution via the mounted rootless socket

---

## Design Strengths

1. **Minimal Attack Surface**: Only explicitly mounted paths are accessible
2. **User Mapping**: Container user UID/GID matches host user; `--userns=keep-id` preserves ownership under rootless Podman
3. **Least-Privilege Socket**: User-owned Podman socket instead of a root-equivalent daemon socket
4. **Version Pinning**: Local version file prevents unnecessary rebuilds while allowing easy updates
5. **Architecture Detection**: Automatically handles x64 and ARM64 platforms
6. **Clean Separation**: Build (Dockerfile) and runtime (shell script) concerns are separated
7. **Production-Ready Code**: Follows shell script best practices (strict mode, proper quoting)

---

## Security Considerations

1. **Podman Socket Access**: Mounting the user Podman socket lets the container run containers as the host user - necessary for the use case, but it does grant OpenCode everything the user can do with Podman
2. **Network Mode**: Uses `--network host` for simplicity, giving container full network access equivalent to the host
3. **X11 Forwarding**: Uses socket mounting for clipboard - appropriate for local development but has inherent X11 security limitations
