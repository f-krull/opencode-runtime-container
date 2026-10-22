FROM debian:13.3-slim 

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    ubuntu-keyring \
    curl \
    git \
    gh \
    bash \
    ripgrep \
    less \
    jq \
    tzdata \
    build-essential \
    npm \
    node.js \
    nano \
    ssh \
    xxd \
    file \
 && rm -rf /var/lib/apt/lists/*


RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-venv \
    xclip\
    xsel

ARG USERNAME=dev
ARG UID=1000
ARG GID=1000
ENV UID=${UID}
ENV GID=${GID}


RUN \
    # Check if the GID already exists, if not create it
    if ! getent group ${GID} >/dev/null; then \
        groupadd -g ${GID} ${USERNAME}; \
    else \
        # If GID exists but with different name, use existing group
        EXISTING_GROUP=$(getent group ${GID} | cut -d: -f1); \
        echo "Using existing group: ${EXISTING_GROUP} (${GID})"; \
    fi && \
    # Check if the UID already exists, if not create the user
    if ! getent passwd ${UID} >/dev/null; then \
        useradd -m -u ${UID} -g ${GID} -s /bin/bash ${USERNAME}; \
    else \
        # If UID exists, check if it's the user we want
        EXISTING_USER=$(getent passwd ${UID} | cut -d: -f1); \
        if [ "${EXISTING_USER}" != "${USERNAME}" ]; then \
            echo "User ${EXISTING_USER} already exists with UID ${UID}"; \
            # Rename the existing user if it's 'ubuntu' and we want 'dev'
            if [ "${EXISTING_USER}" = "ubuntu" ] && [ "${USERNAME}" = "dev" ]; then \
                usermod -l ${USERNAME} ${EXISTING_USER}; \
                groupmod -n ${USERNAME} ${EXISTING_USER} 2>/dev/null || true; \
                usermod -d /home/${USERNAME} -m ${USERNAME} 2>/dev/null || true; \
            fi; \
        fi; \
    fi

# ========================================
# Podman remote client for running project tests from inside opencode.
# The client drives the host's rootless Podman through the mounted Podman
# API socket (never a privileged daemon). Remote client and server versions
# must match (the libpod remote API is not cross-version compatible), so the
# host passes its own Podman version in at build time.
# ========================================
ARG TARGETARCH
ARG PODMAN_VERSION=3.4.4
RUN set -eu; \
    ARCH="${TARGETARCH}"; \
    if [ -z "${ARCH}" ]; then \
        ARCH="$(dpkg --print-architecture)"; \
    fi; \
    case "${ARCH}" in \
        amd64|x86_64) ARCH="amd64" ;; \
        arm64|aarch64) ARCH="arm64" ;; \
        *) echo "Unsupported architecture for Podman client: ${ARCH}" >&2; exit 1 ;; \
    esac; \
    case "${PODMAN_VERSION}" in \
        3.*) ASSET="podman-remote-static.tar.gz" ;; \
        *)   ASSET="podman-remote-static-linux_${ARCH}.tar.gz" ;; \
    esac; \
    BASE_URL="https://github.com/containers/podman/releases/download/v${PODMAN_VERSION}"; \
    echo "Downloading Podman remote client v${PODMAN_VERSION} (${ASSET})"; \
    curl -fsSL "${BASE_URL}/${ASSET}" -o /tmp/podman-remote.tar.gz; \
    if curl -fsSL "${BASE_URL}/shasums" -o /tmp/podman-shasums; then \
        EXPECTED="$(awk -v a="${ASSET}" '($2 == a || $2 == ("*" a)) {print $1}' /tmp/podman-shasums)"; \
        if [ -z "${EXPECTED}" ]; then \
            echo "Checksum for ${ASSET} not found in shasums" >&2; exit 1; \
        fi; \
        echo "${EXPECTED}  /tmp/podman-remote.tar.gz" | sha256sum -c -; \
    else \
        echo "WARNING: podman shasums unavailable, skipping checksum verification" >&2; \
    fi; \
    mkdir -p /tmp/podman-remote; \
    tar -xzf /tmp/podman-remote.tar.gz -C /tmp/podman-remote; \
    BIN="$(find /tmp/podman-remote -type f -name 'podman-remote-static*' | head -n 1)"; \
    if [ -z "${BIN}" ]; then \
        echo "podman-remote-static binary not found in archive" >&2; exit 1; \
    fi; \
    mv "${BIN}" /usr/local/bin/podman; \
    chmod 0755 /usr/local/bin/podman; \
    rm -rf /tmp/podman-remote /tmp/podman-remote.tar.gz /tmp/podman-shasums; \
    printf '#!/bin/sh\nexec podman "$@"\n' > /usr/local/bin/docker; \
    chmod 0755 /usr/local/bin/docker; \
    podman --version


# ========================================
# Install OpenCode from GitHub releases
# Automatically detects platform (amd64/arm64) and downloads the appropriate binary
# ========================================
ARG TARGETARCH
ARG OPENCODE_VERSION=latest
ENV OPENCODE_VERSION=${OPENCODE_VERSION}
RUN ARCH="${TARGETARCH}" && \
    if [ -z "${ARCH}" ]; then \
      if command -v dpkg >/dev/null 2>&1; then \
        ARCH=$(dpkg --print-architecture); \
      else \
        ARCH=$(uname -m); \
      fi; \
    fi && \
    case "${ARCH}" in \
      amd64|x86_64) ARCH="x64" ;; \
      arm64|aarch64) ARCH="arm64" ;; \
    esac && \
    if [ -z "${ARCH}" ]; then \
      echo "Unsupported architecture for OpenCode download" >&2; \
      exit 1; \
    fi && \
    # Construct download URL based on version
    if [ "${OPENCODE_VERSION}" = "latest" ]; then \
      DOWNLOAD_URL="https://github.com/anomalyco/opencode/releases/latest/download/opencode-linux-${ARCH}.tar.gz"; \
    else \
      DOWNLOAD_URL="https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/opencode-linux-${ARCH}.tar.gz"; \
    fi && \
    echo "Downloading OpenCode from: ${DOWNLOAD_URL}" && \
    # Download and install
    curl -fsSL "${DOWNLOAD_URL}" -o /tmp/opencode.tar.gz && \
    tar -xzf /tmp/opencode.tar.gz -C /usr/local/bin && \
    chmod 0755 /usr/local/bin/opencode && \
    rm /tmp/opencode.tar.gz && \
    # Verify installation
    opencode --version

USER ${USERNAME}
RUN mkdir -p /home/${USERNAME}/.config/opencode/
RUN mkdir -p /home/${USERNAME}/.local/share/
# Create default .bashrc so bash login shells work with the mounted bashrc
RUN echo "# dev shell" > /home/${USERNAME}/.bashrc
WORKDIR /workspace

