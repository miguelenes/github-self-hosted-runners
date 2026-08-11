#!/usr/bin/env bash
# =============================================================================
# GitHub Actions Self-Hosted Runner — Swarm Operator CLI
# =============================================================================
# Helper script for managing the Docker Swarm runner stack lifecycle.
#
# Usage:
#   ./manage.sh secret-create [PAT_TOKEN]   Create the github_pat secret
#   ./manage.sh deploy                      Deploy or update the Swarm stack
#   ./manage.sh scale <N>                   Scale the runner service to N replicas
#   ./manage.sh status                      Show status of stack and tasks
#   ./manage.sh logs                        Follow live runner service logs
#   ./manage.sh down                        Remove the runner stack
# =============================================================================

set -euo pipefail

STACK_NAME="runner"
SERVICE_NAME="${STACK_NAME}_github-runner"
COMPOSE_FILE="docker-compose.yml"

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
err()  { echo "[ERROR] $*" >&2; }

usage() {
  cat <<EOF
GitHub Actions Runner Stack Operator CLI

Usage:
  ./manage.sh secret-create [PAT]   Create the 'github_pat' Docker Swarm secret
  ./manage.sh deploy                Deploy / update the stack using .env settings
  ./manage.sh scale <N>             Scale service to N runner replicas
  ./manage.sh status                Display current stack status and tasks
  ./manage.sh logs                  Follow service logs
  ./manage.sh down                  Remove the stack gracefully

Options:
  --help, -h                        Show this help message
EOF
}

cmd_secret_create() {
  local token="${1:-}"
  if [[ -z "$token" ]]; then
    read -rsp "Enter GitHub Personal Access Token (PAT): " token
    echo ""
  fi

  if [[ -z "$token" ]]; then
    err "Token cannot be empty."
    exit 1
  fi

  if docker secret inspect github_pat >/dev/null 2>&1; then
    warn "Docker secret 'github_pat' already exists."
    read -rp "Overwrite existing secret? [y/N]: " choice
    if [[ "${choice,,}" =~ ^y ]]; then
      docker secret rm github_pat
      echo "$token" | docker secret create github_pat -
      log "Secret 'github_pat' recreated successfully."
    else
      log "Secret creation cancelled."
    fi
  else
    echo "$token" | docker secret create github_pat -
    log "Secret 'github_pat' created successfully."
  fi
}

cmd_deploy() {
  if [[ ! -f .env ]]; then
    err ".env file not found! Copy .env.example to .env and configure it first:"
    err "  cp .env.example .env"
    exit 1
  fi

  log "Loading environment variables from .env..."
  set -o allexport
  # shellcheck source=/dev/null
  source .env
  set +o allexport

  if [[ -z "${GITHUB_URL:-}" || "$GITHUB_URL" == *"YOUR_ORG_OR_USER"* ]]; then
    err "Please set a valid GITHUB_URL in .env before deploying."
    exit 1
  fi

  log "Validating Docker Compose configuration..."
  docker compose -f "$COMPOSE_FILE" config --quiet || {
    err "Compose file validation failed."
    exit 1
  }

  log "Deploying stack '$STACK_NAME'..."
  docker stack deploy -c "$COMPOSE_FILE" "$STACK_NAME"
  log "Stack deployed. Use './manage.sh status' or './manage.sh logs' to monitor."
}

cmd_scale() {
  local count="${1:-}"
  if [[ -z "$count" || ! "$count" =~ ^[0-9]+$ ]]; then
    err "Please specify a valid numeric replica count (e.g. ./manage.sh scale 4)."
    exit 1
  fi

  log "Scaling service '$SERVICE_NAME' to $count replica(s)..."
  docker service scale "${SERVICE_NAME}=${count}"
}

cmd_status() {
  log "=== Stack Services ==="
  docker stack services "$STACK_NAME" 2>/dev/null || warn "Stack '$STACK_NAME' is not currently deployed."
  echo ""
  log "=== Stack Tasks ==="
  docker stack ps "$STACK_NAME" --no-trunc 2>/dev/null || true
}

cmd_logs() {
  log "Following logs for service '$SERVICE_NAME' (Ctrl+C to stop)..."
  docker service logs "$SERVICE_NAME" --follow
}

cmd_down() {
  warn "Removing stack '$STACK_NAME'..."
  docker stack rm "$STACK_NAME"
  log "Stack removal initiated. Swarm will gracefully deregister running instances."
}

main() {
  local action="${1:-help}"
  shift || true

  case "$action" in
    secret-create) cmd_secret_create "$@" ;;
    deploy)        cmd_deploy "$@" ;;
    scale)         cmd_scale "$@" ;;
    status)        cmd_status "$@" ;;
    logs)          cmd_logs "$@" ;;
    down)          cmd_down "$@" ;;
    help|--help|-h) usage ;;
    *)
      err "Unknown command: '$action'"
      usage
      exit 1
      ;;
  esac
}

main "$@"
