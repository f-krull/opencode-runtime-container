FROM debian:13.3-slim 

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    ubuntu-keyring \
    curl \
    git \
    bash \
    ripgrep \
    less \
    jq \
    tzdata \
    build-essential \
    npm \
    node.js \
    nano \
    docker.cli \
    ssh \
 && rm -rf /var/lib/apt/lists/*


RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-venv

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
# Docker client support for running project tests from inside opencode
# ========================================
ARG DOCKER_GID=999
RUN \
    if [ "${DOCKER_GID}" != "999" ]; then \
        if ! getent group docker >/dev/null; then \
            groupadd -g ${DOCKER_GID} docker; \
        fi && \
        usermod -aG docker ${USERNAME}; \
    fi


# ========================================
# Install OpenCode from GitHub releases
# Automatically detects platform (amd64/arm64) and downloads the appropriate binary
# ========================================
ARG TARGETARCH
ARG OPENCODE_VERSION=latest
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
      DOWNLOAD_URL="https://github.com/anomalyco/opencode/releases/download/${OPENCODE_VERSION}/opencode-linux-${ARCH}.tar.gz"; \
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
WORKDIR /workspace

