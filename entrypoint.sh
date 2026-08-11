#!/usr/bin/env bash
# =============================================================================
# GitHub Actions Self-Hosted Runner — Entrypoint Script
# =============================================================================
# Responsibilities:
#   1. Resolve a valid GitHub runner registration token (from Docker secret,
#      env var, or auto-generated from a long-lived PAT via GitHub REST API)
#   2. Configure proxy settings into the runner .env file (per GitHub docs)
#   3. Register the runner with config.sh (unattended, optionally ephemeral)
#   4. Trap SIGTERM/SIGINT to gracefully deregister the runner before exit
#   5. Start run.sh in the foreground
#
# Environment Variables:
#   Required:
#     GITHUB_URL          Full URL of the repo or org, e.g.:
#                         https://github.com/myorg/myrepo  (repo-level)
#                         https://github.com/myorg         (org-level)
#
#   Token — provide exactly one of:
#     RUNNER_TOKEN        Raw registration token (expires in ~1 hour).
#                         OK for development / single-use.
#     GITHUB_PAT          Long-lived PAT (repo or admin:org scope).
#                         Used to auto-generate a fresh reg token on startup.
#                         Prefer Docker secrets over this env var.
#
#   Docker Secrets (preferred for production):
#     /run/secrets/runner_token   — pre-generated registration token
#     /run/secrets/github_pat     — long-lived PAT (auto-generates token)
#
#   Optional:
#     RUNNER_NAME         Display name in GitHub UI. Auto-generated if unset.
#     RUNNER_LABELS       Comma-separated labels. Default: self-hosted,linux,x64
#     RUNNER_GROUP        Runner group name. Default: Default
#     RUNNER_EPHEMERAL    "true" = runner deregisters after one job (recommended).
#                         Default: true
#     HTTPS_PROXY / https_proxy   Proxy for HTTPS traffic
#     HTTP_PROXY  / http_proxy    Proxy for HTTP traffic
#     NO_PROXY    / no_proxy      Comma-separated bypass list
# =============================================================================

set -euo pipefail

# ── Colour-coded logging helpers ──────────────────────────────────────────────
log()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [INFO]  $*"; }
warn() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [WARN]  $*" >&2; }
err()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [ERROR] $*" >&2; }

# ── Validate required environment variables ───────────────────────────────────
if [[ -z "${GITHUB_URL:-}" ]]; then
  err "GITHUB_URL is required. Set it to the GitHub repo or org URL."
  err "Example: GITHUB_URL=https://github.com/myorg/myrepo"
  exit 1
fi

# Strip trailing slash from URL for consistency
GITHUB_URL="${GITHUB_URL%/}"

# ── Configuration with defaults ───────────────────────────────────────────────
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_EPHEMERAL="${RUNNER_EPHEMERAL:-true}"

# ── Token resolution ──────────────────────────────────────────────────────────
# Generates a fresh registration token by calling the GitHub REST API.
# Works for both repository-level and organization-level URLs.
generate_token_from_pat() {
  local pat="$1"

  # Extract the path component after github.com (e.g. "myorg/myrepo" or "myorg")
  local url_path
  url_path=$(echo "$GITHUB_URL" | sed 's|https://github.com/||;s|http://github.com/||')

  # Count path segments to distinguish repo (2 segments) from org (1 segment)
  local segment_count
  segment_count=$(echo "$url_path" | tr -cd '/' | wc -c)

  local api_url
  if [[ "$segment_count" -ge 1 ]]; then
    # Repository-level (e.g. myorg/myrepo)
    api_url="https://api.github.com/repos/${url_path}/actions/runners/registration-token"
    log "Generating repo-level registration token for: ${url_path}"
  else
    # Organization-level (e.g. myorg)
    api_url="https://api.github.com/orgs/${url_path}/actions/runners/registration-token"
    log "Generating org-level registration token for: ${url_path}"
  fi

  local response http_status token
  response=$(curl -sSf \
    -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${pat}" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${api_url}") || {
      err "Failed to reach GitHub API at ${api_url}"
      exit 1
    }

  http_status=$(echo "$response" | tail -n1)
  local body
  body=$(echo "$response" | head -n -1)

  if [[ "$http_status" != "201" ]]; then
    err "GitHub API returned HTTP ${http_status}. Check your PAT scopes."
    err "Response: ${body}"
    exit 1
  fi

  token=$(echo "$body" | jq -r '.token // empty')
  if [[ -z "$token" ]]; then
    err "Could not parse token from API response: ${body}"
    exit 1
  fi

  echo "$token"
}

# Resolves the registration token from available sources (priority order):
#   1. /run/secrets/runner_token  — Docker Swarm secret (raw token)
#   2. /run/secrets/github_pat    — Docker Swarm secret (PAT → auto-gen token)
#   3. RUNNER_TOKEN env var       — raw token passed as environment variable
#   4. GITHUB_PAT env var         — PAT passed as environment variable
resolve_registration_token() {
  # 1. Docker secret: pre-generated registration token
  if [[ -f /run/secrets/runner_token ]]; then
    log "Using runner registration token from Docker secret: runner_token"
    tr -d '[:space:]' < /run/secrets/runner_token
    return
  fi

  # 2. Docker secret: PAT → generate fresh token
  if [[ -f /run/secrets/github_pat ]]; then
    log "Using GitHub PAT from Docker secret: github_pat"
    local pat
    pat=$(tr -d '[:space:]' < /run/secrets/github_pat)
    generate_token_from_pat "$pat"
    return
  fi

  # 3. Env var: raw registration token
  if [[ -n "${RUNNER_TOKEN:-}" ]]; then
    warn "Using RUNNER_TOKEN env var. This token expires in ~1 hour."
    warn "For production, prefer Docker secrets with a long-lived PAT."
    echo "${RUNNER_TOKEN}"
    return
  fi

  # 4. Env var: PAT → generate fresh token
  if [[ -n "${GITHUB_PAT:-}" ]]; then
    warn "Using GITHUB_PAT env var directly. Consider using Docker secrets instead."
    generate_token_from_pat "${GITHUB_PAT}"
    return
  fi

  err "No token source found. Provide one of:"
  err "  - Docker secret: runner_token  (raw registration token)"
  err "  - Docker secret: github_pat    (long-lived PAT)"
  err "  - Env var: RUNNER_TOKEN        (raw token, dev use only)"
  err "  - Env var: GITHUB_PAT          (PAT, prefer secrets in production)"
  exit 1
}

# ── Proxy configuration ───────────────────────────────────────────────────────
# Per GitHub documentation, proxy settings must be written to a .env file
# in the runner application directory. The runner reads this file on startup.
# Reference: https://docs.github.com/en/actions/how-tos/manage-runners/use-proxy-servers
configure_proxy() {
  local env_file="/home/runner/.env"

  # Start fresh — truncate or create the .env file
  : > "$env_file"

  local proxy_configured=false

  # HTTPS proxy (prefer lowercase per GitHub docs recommendation for Linux)
  local https_val="${https_proxy:-${HTTPS_PROXY:-}}"
  if [[ -n "$https_val" ]]; then
    echo "https_proxy=${https_val}" >> "$env_file"
    proxy_configured=true
    log "Proxy: https_proxy=${https_val}"
  fi

  # HTTP proxy
  local http_val="${http_proxy:-${HTTP_PROXY:-}}"
  if [[ -n "$http_val" ]]; then
    echo "http_proxy=${http_val}" >> "$env_file"
    proxy_configured=true
    log "Proxy: http_proxy=${http_val}"
  fi

  # No-proxy bypass list
  local no_proxy_val="${no_proxy:-${NO_PROXY:-}}"
  if [[ -n "$no_proxy_val" ]]; then
    echo "no_proxy=${no_proxy_val}" >> "$env_file"
    proxy_configured=true
    log "Proxy: no_proxy=${no_proxy_val}"
  fi

  if [[ "$proxy_configured" == "true" ]]; then
    log "Proxy settings written to ${env_file}"
  else
    log "No proxy settings configured."
  fi
}

# ── Graceful shutdown handler ─────────────────────────────────────────────────
# Triggered by SIGTERM (docker service scale, stack remove, rolling update)
# or SIGINT (Ctrl+C in dev). Deregisters the runner cleanly from GitHub so
# it does not appear as offline/zombie in the GitHub runners list.
RUNNER_PID=""
cleanup() {
  log "Received termination signal. Initiating graceful shutdown..."

  # Stop run.sh if it's still running
  if [[ -n "$RUNNER_PID" ]] && kill -0 "$RUNNER_PID" 2>/dev/null; then
    log "Stopping runner process (PID: ${RUNNER_PID})..."
    kill -SIGTERM "$RUNNER_PID" 2>/dev/null || true
    # Give run.sh up to 30 seconds to finish the current job step
    local i=0
    while kill -0 "$RUNNER_PID" 2>/dev/null && [[ $i -lt 30 ]]; do
      sleep 1
      (( i++ ))
    done
  fi

  # Deregister the runner from GitHub
  log "Deregistering runner from GitHub..."
  local dereg_token
  dereg_token=$(resolve_registration_token) || {
    warn "Could not resolve token for deregistration. Runner may appear offline."
    exit 0
  }

  ./config.sh remove \
    --token "$dereg_token" \
    --unattended \
    2>&1 | sed 's/^/[deregister] /' \
    || warn "Deregistration failed. The runner may need to be removed manually from GitHub."

  log "Runner deregistered successfully. Exiting."
  exit 0
}

# Register signal handlers before any blocking operations
trap 'cleanup' SIGTERM SIGINT SIGQUIT

# ── Main ──────────────────────────────────────────────────────────────────────
log "=== GitHub Actions Self-Hosted Runner ==="
log "GitHub URL:      ${GITHUB_URL}"
log "Runner Labels:   ${RUNNER_LABELS}"
log "Runner Group:    ${RUNNER_GROUP}"
log "Ephemeral Mode:  ${RUNNER_EPHEMERAL}"

# Step 1: Configure proxy (writes runner .env file)
configure_proxy

# Step 2: Resolve registration token
log "Resolving registration token..."
REGISTRATION_TOKEN=$(resolve_registration_token)
log "Registration token resolved successfully."

# Step 3: Generate a unique runner name
# When Swarm runs multiple replicas, each must have a unique name.
# RUNNER_NAME can be set explicitly; otherwise auto-generated from hostname + random suffix.
if [[ -z "${RUNNER_NAME:-}" ]]; then
  RUNNER_NAME="runner-$(hostname -s)-$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 6 || echo "000000")"
fi
log "Runner name:     ${RUNNER_NAME}"

# Step 4: Build config.sh arguments
CONFIG_ARGS=(
  --url       "$GITHUB_URL"
  --token     "$REGISTRATION_TOKEN"
  --name      "$RUNNER_NAME"
  --labels    "$RUNNER_LABELS"
  --runnergroup "$RUNNER_GROUP"
  --unattended              # Non-interactive mode (required for containers)
  --disableupdate           # Disable auto-update; manage versions via image builds
)

# Add --ephemeral flag when ephemeral mode is enabled (recommended)
if [[ "${RUNNER_EPHEMERAL}" == "true" ]]; then
  CONFIG_ARGS+=(--ephemeral)
  log "Ephemeral mode enabled: runner will deregister after processing one job."
fi

# Step 5: Register the runner
log "Registering runner with GitHub..."
./config.sh "${CONFIG_ARGS[@]}" \
  2>&1 | sed 's/^/[config] /'

log "Runner registered successfully."

# Step 6: Start the runner in the background and wait
log "Starting runner (run.sh)..."
./run.sh &
RUNNER_PID=$!

log "Runner started with PID ${RUNNER_PID}. Waiting for jobs..."

# Wait for run.sh; this will be interrupted by the trap on signal
wait "$RUNNER_PID"
EXIT_CODE=$?

log "run.sh exited with code ${EXIT_CODE}."

# If ephemeral and runner exited cleanly (job done), exit 0 so Swarm restarts
# the container to create a fresh ephemeral runner.
if [[ "${RUNNER_EPHEMERAL}" == "true" && "$EXIT_CODE" -eq 0 ]]; then
  log "Ephemeral runner completed its job. Exiting to allow Swarm to restart."
fi

exit "$EXIT_CODE"
