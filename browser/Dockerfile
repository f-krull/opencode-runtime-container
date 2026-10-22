FROM debian:13.3-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    chromium \
    fonts-liberation \
    fonts-dejavu-core \
    fonts-noto-color-emoji \
    tzdata \
 && rm -rf /var/lib/apt/lists/*

ARG USERNAME=dev
ARG UID=1000
ARG GID=1000

RUN \
    # Check if the GID already exists, if not create it
    if ! getent group ${GID} >/dev/null; then \
        groupadd -g ${GID} ${USERNAME}; \
    fi && \
    # Check if the UID already exists, if not create the user
    if ! getent passwd ${UID} >/dev/null; then \
        useradd -m -u ${UID} -g ${GID} -s /bin/bash ${USERNAME}; \
    fi

# The browser is launched with --user-data-dir=/profile (bind-mounted by
# browser.sh), so the profile survives container restarts. With
# --userns=keep-id the process runs as the invoking host user, which must have
# a passwd entry here for HOME to resolve.
USER ${USERNAME}
WORKDIR /home/${USERNAME}
