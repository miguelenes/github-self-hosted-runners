# =============================================================================
# GitHub Actions Self-Hosted Runner — Dockerfile
# =============================================================================
# Base:  ubuntu:22.04 (LTS, matches GitHub-hosted ubuntu-22.04 runner)
# User:  runner (non-root, UID 1001)
# DooD:  Docker CE CLI installed; host socket bind-mounted at runtime
# =============================================================================

FROM ubuntu:22.04

# ── Build arguments ────────────────────────────────────────────────────────────
# Pin the runner version; update this ARG to upgrade (check actions/runner releases)
ARG RUNNER_VERSION="2.325.0"
# Suppress interactive prompts during apt operations
ARG DEBIAN_FRONTEND=noninteractive

# ── Labels ────────────────────────────────────────────────────────────────────
LABEL org.opencontainers.image.title="GitHub Actions Self-Hosted Runner"
LABEL org.opencontainers.image.description="Containerized GitHub Actions runner for Docker Swarm"
LABEL org.opencontainers.image.source="https://github.com/actions/runner"
LABEL runner.version="${RUNNER_VERSION}"

# ── System upgrade + CI/CD dependencies ───────────────────────────────────────
# Install in a single layer to reduce image size and keep apt cache clean.
RUN apt-get update -y \
 && apt-get upgrade -y --no-install-recommends \
 && apt-get install -y --no-install-recommends \
      # Core utilities
      ca-certificates \
      curl \
      wget \
      gnupg \
      lsb-release \
      apt-transport-https \
      software-properties-common \
      # Developer tools (required by many CI workflows)
      git \
      jq \
      unzip \
      zip \
      tar \
      xz-utils \
      # Build tools
      build-essential \
      pkg-config \
      # Network utilities (useful for debugging connectivity)
      iputils-ping \
      dnsutils \
      netcat \
      # Crypto libraries (required by pip, node-gyp, openssl-based tools)
      libssl-dev \
      libffi-dev \
      # Python 3 (many Actions use Python-based tools)
      python3 \
      python3-pip \
      python3-venv \
      python3-dev \
      # Miscellaneous runner-compatible utilities
      sudo \
      acl \
      rsync \
 && rm -rf /var/lib/apt/lists/*

# ── Docker CE CLI — Docker-out-of-Docker (DooD) ───────────────────────────────
# We install only docker-ce-cli (not the full daemon). The host Docker socket
# is mounted at /var/run/docker.sock at runtime, allowing the runner to build
# and run containers using the host's Docker daemon.
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
       https://download.docker.com/linux/ubuntu \
       $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      docker-ce-cli \
      docker-buildx-plugin \
      docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# ── Create non-root 'runner' user ─────────────────────────────────────────────
# The GitHub Actions runner binary explicitly refuses to run as root.
# UID 1001 is chosen to avoid conflicts with common system UIDs.
#
# The 'docker' group (GID 999) is created to match the typical GID of the
# docker group on the Swarm host. This allows the runner to access the
# bind-mounted Docker socket without needing root. Adjust GID if your host
# uses a different value (check: stat -c '%g' /var/run/docker.sock on the host).
RUN groupadd --gid 999 docker 2>/dev/null || true \
 && useradd \
      --uid 1001 \
      --gid 0 \
      --groups docker \
      --create-home \
      --shell /bin/bash \
      runner \
 # Allow runner to call sudo (needed by some action steps, e.g. apt installs)
 && echo "runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/runner \
 && chmod 0440 /etc/sudoers.d/runner

# ── Download and install the GitHub Actions Runner binary ─────────────────────
# The binary is fetched from the official actions/runner GitHub Releases page.
# Architecture is auto-detected from the build platform (amd64 → x64, arm64 → arm64).
WORKDIR /home/runner

RUN ARCH=$(dpkg --print-architecture | sed 's/amd64/x64/;s/aarch64/arm64/;s/armhf/arm/') \
 && TARBALL="actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz" \
 && DOWNLOAD_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}" \
 && echo "Downloading runner: ${DOWNLOAD_URL}" \
 && curl -fsSL "${DOWNLOAD_URL}" -o "${TARBALL}" \
 # Verify the download completed (non-zero size)
 && [ -s "${TARBALL}" ] \
 && tar xzf "${TARBALL}" \
 && rm "${TARBALL}" \
 # Install runner dependencies (e.g. libicu, libssl compat shims)
 && ./bin/installdependencies.sh \
 && rm -rf /var/lib/apt/lists/*

# ── Copy and configure entrypoint ────────────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
 # Ensure runner owns its working directory
 && chown -R runner:root /home/runner \
 && chmod -R g+rw /home/runner

# ── Switch to non-root runner user ───────────────────────────────────────────
USER runner
WORKDIR /home/runner

ENTRYPOINT ["/entrypoint.sh"]
