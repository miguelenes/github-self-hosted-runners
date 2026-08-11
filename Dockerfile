# =============================================================================
# GitHub Actions Self-Hosted Runner — Dockerfile (multi-stage)
# =============================================================================
# Base:  ubuntu:24.04 (LTS, matches GitHub-hosted ubuntu-24.04 runner)
# User:  runner (non-root, UID 1001)
# DooD:  Docker CE CLI installed; host socket bind-mounted at runtime
#
# Stages:
#   1. builder — full dev toolchain; downloads & verifies runner; installs deps
#   2. runtime — minimal production image; copies artifacts from builder
# =============================================================================

# ── Stage 1: Builder ──────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS builder

# Use bash with pipefail for all RUN instructions
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Suppress interactive prompts during apt operations
ARG DEBIAN_FRONTEND=noninteractive

# ── Build arguments ────────────────────────────────────────────────────────────
# Pin the runner version; update this ARG to upgrade (check actions/runner releases)
ARG RUNNER_VERSION="2.336.0"

# SHA-256 checksums from the release page (https://github.com/actions/runner/releases)
# Update these whenever RUNNER_VERSION changes.
#   linux-x64:  04cf0be1aff4c3ec3554466c39124ca250e3effd8873bb7e8d68535aa9505d5d
#   linux-arm64: 58b758e420b87093fbd4bfddd368074960053e2f1388f01848c82624b90f27d1
ARG RUNNER_CHECKSUM_AMD64="04cf0be1aff4c3ec3554466c39124ca250e3effd8873bb7e8d68535aa9505d5d"
ARG RUNNER_CHECKSUM_ARM64="58b758e420b87093fbd4bfddd368074960053e2f1388f01848c82624b90f27d1"

# ── Labels ────────────────────────────────────────────────────────────────────
LABEL org.opencontainers.image.title="GitHub Actions Self-Hosted Runner" \
      org.opencontainers.image.description="Containerized GitHub Actions runner for Docker Swarm" \
      org.opencontainers.image.source="https://github.com/actions/runner" \
      runner.version="${RUNNER_VERSION}"

# ── System packages (full dev toolchain for runner dependency installation) ─────
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      acl \
      build-essential \
      ca-certificates \
      curl \
      dnsutils \
      git \
      gnupg \
      iputils-ping \
      jq \
      libffi-dev \
      libssl-dev \
      lsb-release \
      netcat-openbsd \
      pkg-config \
      python3 \
      python3-dev \
      python3-pip \
      python3-venv \
      rsync \
      software-properties-common \
      sudo \
      tar \
      unzip \
      wget \
      xz-utils \
      zip \
 && rm -rf /var/lib/apt/lists/*

# ── Download and verify the GitHub Actions Runner binary ──────────────────────
# Architecture is auto-detected from the build platform using dpkg.
# Checksum verification ensures supply-chain integrity.
WORKDIR /home/runner

RUN ARCH=$(dpkg --print-architecture | sed 's/amd64/x64/;s/aarch64/arm64/;s/armhf/arm/') \
 && TARBALL="actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz" \
 && DOWNLOAD_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}" \
 && echo "Downloading runner: ${DOWNLOAD_URL}" \
 && curl -fsSL "${DOWNLOAD_URL}" -o "${TARBALL}" \
 # Determine expected checksum based on build architecture
 && DOCKER_ARCH=$(dpkg --print-architecture) \
 && EXPECTED_CHECKSUM="" \
 && case "${DOCKER_ARCH}" in \
      amd64)  EXPECTED_CHECKSUM="${RUNNER_CHECKSUM_AMD64}" ;; \
      arm64)  EXPECTED_CHECKSUM="${RUNNER_CHECKSUM_ARM64}" ;; \
      *)      echo "ERROR: Unsupported architecture: ${DOCKER_ARCH}"; exit 1 ;; \
    esac \
 # Verify SHA-256 checksum
 && echo "${EXPECTED_CHECKSUM}  ${TARBALL}" | sha256sum -c - \
 # Extract the tarball
 && tar xzf "${TARBALL}" \
 && rm "${TARBALL}" \
 # Install runner dependencies (libicu, libssl compat shims, etc.)
 && ./bin/installdependencies.sh \
 && rm -rf /var/lib/apt/lists/*

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS runtime

# Use bash with pipefail for all RUN instructions
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Suppress interactive prompts during apt operations
ARG DEBIAN_FRONTEND=noninteractive

# ── Runtime system packages (minimal set) ─────────────────────────────────────
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      acl \
      ca-certificates \
      curl \
      git \
      gnupg \
      jq \
      libicu74 \
      liblttng-ust1t64 \
      lsb-release \
      python3 \
      python3-pip \
      python3-venv \
      rsync \
      sudo \
      tar \
      unzip \
      xz-utils \
      zip \
 && rm -rf /var/lib/apt/lists/*

# ── Docker CE CLI — Docker-out-of-Docker (DooD) ───────────────────────────────
# We install only docker-ce-cli (not the full daemon). The host Docker socket
# is mounted at /var/run/docker.sock at runtime, allowing the runner to build
# and run containers using the host's Docker daemon.
# hadolint ignore=DL3008
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
       https://download.docker.com/linux/ubuntu \
       $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      docker-buildx-plugin \
      docker-ce-cli \
      docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# ── GitHub CLI (gh) ───────────────────────────────────────────────────────────
# Many CI workflows use gh for issue/PR automation and release management.
# Installed via official GitHub CLI apt repository.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod a+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# ── Copy runner artifacts from builder stage ──────────────────────────────────
# Use --chown to avoid a separate chown RUN layer.
COPY --from=builder --chown=1001:0 /home/runner /home/runner

# ── Create non-root 'runner' user ─────────────────────────────────────────────
# The GitHub Actions runner binary explicitly refuses to run as root.
# UID 1001 is chosen to avoid conflicts with common system UIDs.
#
# The 'docker' group (GID 999) is created to match the typical GID of the
# docker group on the Swarm host. This allows the runner to access the
# bind-mounted Docker socket without needing root. Adjust GID if your host
# uses a different value (check: stat -c '%g' /var/run/docker.sock on the host).
# --no-log-init avoids a known Go sparse-file issue with /var/log/faillog.
RUN groupadd --gid 999 docker 2>/dev/null || true \
 && useradd \
      --uid 1001 \
      --gid 0 \
      --groups docker \
      --create-home \
      --shell /bin/bash \
      --no-log-init \
      runner \
 # Allow runner to call sudo (needed by some action steps, e.g. apt installs)
 && echo "runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/runner \
 && chmod 0440 /etc/sudoers.d/runner

# ── Copy and configure entrypoint ─────────────────────────────────────────────
COPY --chown=1001:0 entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
 && chmod -R g+rw /home/runner

# ── Switch to non-root runner user ────────────────────────────────────────────
# Use numeric UID (1001) per Docker security best practices & Hadolint DL3066
USER 1001
WORKDIR /home/runner

ENTRYPOINT ["/entrypoint.sh"]
