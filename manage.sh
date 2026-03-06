#!/bin/bash
# /docker/manage.sh
# Manages all Docker stacks with Infisical secret injection
# Auth credentials loaded from /docker/infisical-auth (gitignored)

set -e

# ── Config ────────────────────────────────────────────────────────────────────

DOCKER_DIR="/docker"
AUTH_FILE="$DOCKER_DIR/infisical-auth"
INFISICAL_API_URL="http://192.168.1.49:8085/api"
PROJECT_ID="c518f78a-d755-43fa-8d01-44cddeaeb8b8"
INFISICAL_ENV="prod"

STACKS=(
  infisical
  npm
  cloudflare
  servarr
  plex
  firefly
  foundry
  observability
  watchtower
)

# ── Logging ───────────────────────────────────────────────────────────────────

LOG_FILE="/var/log/manage.log"

log() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] [$level] $msg" | tee -a "$LOG_FILE"
}

info()    { log "INFO " "$@"; }
warn()    { log "WARN " "$@"; }
error()   { log "ERROR" "$@"; }
debug()   { log "DEBUG" "$@"; }
section() { log "-----" "--- $* ---"; }

# ── Load auth ─────────────────────────────────────────────────────────────────

section "Loading auth"

if [[ ! -f "$AUTH_FILE" ]]; then
  error "Auth file not found at $AUTH_FILE"
  exit 1
fi

debug "Sourcing auth file: $AUTH_FILE"
source "$AUTH_FILE"

if [[ -z "$CLIENT_ID" ]]; then
  error "CLIENT_ID is not set in $AUTH_FILE"
  exit 1
fi

if [[ -z "$CLIENT_SECRET" ]]; then
  error "CLIENT_SECRET is not set in $AUTH_FILE"
  exit 1
fi

info "Auth file loaded. CLIENT_ID=$CLIENT_ID"

# ── Get access token ──────────────────────────────────────────────────────────

section "Authenticating with Infisical"
info "Requesting access token from $INFISICAL_API_URL"
info "Method: universal-auth"

INFISICAL_TOKEN=$(INFISICAL_API_URL="$INFISICAL_API_URL" infisical login \
  --method=universal-auth \
  --client-id="$CLIENT_ID" \
  --client-secret="$CLIENT_SECRET" \
  --silent \
  --plain)

if [[ -z "$INFISICAL_TOKEN" ]]; then
  error "Failed to obtain access token from Infisical"
  error "Check CLIENT_ID, CLIENT_SECRET, and that Infisical is reachable at $INFISICAL_API_URL"
  exit 1
fi

info "Access token obtained successfully"
debug "Token length: ${#INFISICAL_TOKEN} chars"

# ── Secret remapping ──────────────────────────────────────────────────────────
# Fetches a secret from Infisical and exports it under a different name
# Usage: remap INFISICAL_KEY TARGET_ENV_VAR

remap() {
  local infisical_key="$1"
  local target_var="$2"

  debug "Fetching secret: $infisical_key -> $target_var"

  local value
  value=$(infisical secrets get "$infisical_key" \
    --token="$INFISICAL_TOKEN" \
    --domain="$INFISICAL_API_URL" \
    --projectId="$PROJECT_ID" \
    --env="$INFISICAL_ENV" \
    --plain 2>&1)

  local exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    warn "Infisical CLI returned exit code $exit_code for secret '$infisical_key'"
    warn "Output: $value"
    return
  fi

  if [[ -z "$value" ]]; then
    warn "Secret '$infisical_key' returned empty value — skipping export of '$target_var'"
    return
  fi

  export "$target_var=$value"
  info "Exported $target_var (from $infisical_key)"
}

inject_secrets() {
  section "Injecting secrets"
  info "Project ID: $PROJECT_ID"
  info "Environment: $INFISICAL_ENV"

  # Cloudflare DDNS
  info "Remapping Cloudflare secrets"
  remap CLOUDFLARE_API_TOKEN  CLOUDFLARE_API_TOKEN
  remap CLOUDFLARE_DOMAINS    DOMAINS
  remap CLOUDFLARE_PROXIED    PROXIED

  # Servarr / gluetun (WireGuard)
  info "Remapping WireGuard secrets"
  remap WIREGUARD_PUBLIC_KEY      WIREGUARD_PUBLIC_KEY
  remap WIREGUARD_PRIVATE_KEY     WIREGUARD_PRIVATE_KEY
  remap WIREGUARD_PRESHARED_KEY   WIREGUARD_PRESHARED_KEY
  remap WIREGUARD_ADDRESSES       WIREGUARD_ADDRESSES

  # Firefly (app)
  info "Remapping Firefly app secrets"
  remap FIREFLY_APP_KEY       APP_KEY
  remap FIREFLY_DB_USERNAME   DB_USERNAME
  remap FIREFLY_DB_PASSWORD   DB_PASSWORD
  remap FIREFLY_SITEOWNER     SITE_OWNER
  remap FIREFLY_CRON_TOKEN    STATIC_CRON_TOKEN

  # Firefly (db — MYSQL_PASSWORD must match DB_PASSWORD)
  info "Remapping Firefly DB secrets"
  remap FIREFLY_DB_PASSWORD   MYSQL_PASSWORD
  remap FIREFLY_DB_USERNAME   MYSQL_USERNAME

  # Foundry
  info "Remapping Foundry secrets"
  remap FOUNDRY_USERNAME   FOUNDRY_USERNAME
  remap FOUNDRY_PASSWORD   FOUNDRY_PASSWORD
  remap FOUNDRY_ADMIN_KEY  FOUNDRY_ADMIN_KEY

  # Grafana
  info "Remapping Grafana secrets"
  remap GRAFANA_ADMIN_PASSWORD  GRAFANA_ADMIN_PASSWORD

  # Watchtower
  info "Remapping Watchtower secrets"
  remap WATCHTOWER_NOTIFICATION_URL  WATCHTOWER_NOTIFICATION_URL

  info "Secret injection complete"
}

# ── Stack commands ─────────────────────────────────────────────────────────────

stack_up() {
  local stack="$1"
  local stack_dir="$DOCKER_DIR/$stack"

  info "Starting stack: $stack"

  if [[ ! -d "$stack_dir" ]]; then
    error "Stack directory not found: $stack_dir — skipping"
    return
  fi

  if [[ ! -f "$stack_dir/compose.yaml" ]]; then
    error "No compose.yaml found in $stack_dir — skipping"
    return
  fi

  debug "Running: docker compose up -d in $stack_dir"
  (cd "$stack_dir" && docker compose up -d 2>&1 | while IFS= read -r line; do
    debug "[$stack] $line"
  done)

  local exit_code=${PIPESTATUS[0]}
  if [[ $exit_code -ne 0 ]]; then
    error "docker compose up failed for $stack (exit code $exit_code)"
  else
    info "Stack $stack is up"
  fi
}

stack_down() {
  local stack="$1"
  local stack_dir="$DOCKER_DIR/$stack"

  info "Stopping stack: $stack"

  if [[ ! -d "$stack_dir" ]]; then
    warn "Stack directory not found: $stack_dir — skipping"
    return
  fi

  debug "Running: docker compose down in $stack_dir"
  (cd "$stack_dir" && docker compose down 2>&1 | while IFS= read -r line; do
    debug "[$stack] $line"
  done)

  info "Stack $stack is down"
}

stack_pull() {
  local stack="$1"
  local stack_dir="$DOCKER_DIR/$stack"

  info "Pulling images for stack: $stack"

  if [[ ! -d "$stack_dir" ]]; then
    warn "Stack directory not found: $stack_dir — skipping"
    return
  fi

  debug "Running: docker compose pull in $stack_dir"
  (cd "$stack_dir" && docker compose pull 2>&1 | while IFS= read -r line; do
    debug "[$stack] $line"
  done)

  info "Images pulled for $stack"
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_up() {
  section "Command: up"
  info "Stacks to start: ${STACKS[*]}"
  inject_secrets
  for stack in "${STACKS[@]}"; do
    stack_up "$stack"
  done
  section "Done"
  info "All stacks started"
}

cmd_down() {
  section "Command: down"
  info "Stacks to stop (reverse order): ${STACKS[*]}"
  for (( i=${#STACKS[@]}-1; i>=0; i-- )); do
    stack_down "${STACKS[$i]}"
  done
  section "Done"
  info "All stacks stopped"
}

cmd_restart() {
  section "Command: restart"
  cmd_down
  cmd_up
}

cmd_pull() {
  section "Command: pull"
  info "Pulling images for all stacks"
  for stack in "${STACKS[@]}"; do
    stack_pull "$stack"
  done
  section "Done"
  info "All images pulled"
}

# ── Entrypoint ────────────────────────────────────────────────────────────────

info "manage.sh started — command: ${1:-<none>}"
info "Running as user: $(whoami)"
info "Docker dir: $DOCKER_DIR"

case "$1" in
  up)      cmd_up ;;
  down)    cmd_down ;;
  restart) cmd_restart ;;
  pull)    cmd_pull ;;
  *)
    error "Unknown command: '${1:-}'"
    echo "Usage: $0 {up|down|restart|pull}"
    exit 1
    ;;
esac
