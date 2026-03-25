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
  calibre
  firefly
  immich
  nextcloud
  foundry
  observability
  watchtower
  healthcheck
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

get_token() {
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
}

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
    --silent \
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

inject_secrets_for() {
  local stack="$1"
  case "$stack" in
    cloudflare)
      remap CLOUDFLARE_API_TOKEN  CLOUDFLARE_API_TOKEN
      remap CLOUDFLARE_DOMAINS    DOMAINS
      remap CLOUDFLARE_PROXIED    PROXIED
      ;;
    servarr)
      remap WIREGUARD_PUBLIC_KEY      WIREGUARD_PUBLIC_KEY
      remap WIREGUARD_PRIVATE_KEY     WIREGUARD_PRIVATE_KEY
      remap WIREGUARD_PRESHARED_KEY   WIREGUARD_PRESHARED_KEY
      remap WIREGUARD_ADDRESSES       WIREGUARD_ADDRESSES
      ;;
    firefly)
      remap FIREFLY_APP_KEY       APP_KEY
      remap FIREFLY_DB_USERNAME   DB_USERNAME
      remap FIREFLY_DB_PASSWORD   DB_PASSWORD
      remap FIREFLY_SITEOWNER     SITE_OWNER
      remap FIREFLY_CRON_TOKEN    STATIC_CRON_TOKEN
      remap FIREFLY_DB_PASSWORD   MYSQL_PASSWORD
      remap FIREFLY_DB_USERNAME   MYSQL_USER
      ;;
    immich)
      remap IMMICH_DB_USER        IMMICH_DB_USER
      remap IMMICH_DB_PASSWORD    IMMICH_DB_PASSWORD
      ;;
    nextcloud)
      remap NEXTCLOUD_DB_USER          NEXTCLOUD_DB_USER
      remap NEXTCLOUD_DB_PASSWORD      NEXTCLOUD_DB_PASSWORD
      remap NEXTCLOUD_DB_ROOT_PASSWORD NEXTCLOUD_DB_ROOT_PASSWORD
      remap NEXTCLOUD_ADMIN_USER       NEXTCLOUD_ADMIN_USER
      remap NEXTCLOUD_ADMIN_PASSWORD   NEXTCLOUD_ADMIN_PASSWORD
      ;;
    foundry)
      remap FOUNDRY_USERNAME   FOUNDRY_USERNAME
      remap FOUNDRY_PASSWORD   FOUNDRY_PASSWORD
      remap FOUNDRY_ADMIN_KEY  FOUNDRY_ADMIN_KEY
      ;;
    observability)
      remap GRAFANA_ADMIN_PASSWORD  GRAFANA_ADMIN_PASSWORD
      remap DISCORD_WEBHOOK_URL     DISCORD_WEBHOOK_URL
      ;;
    watchtower)
      remap WATCHTOWER_NOTIFICATION_URL  WATCHTOWER_NOTIFICATION_URL
      ;;
    healthcheck)
      remap SONARR_API_KEY     SONARR_API_KEY
      remap RADARR_API_KEY     RADARR_API_KEY
      remap PROWLARR_API_KEY   PROWLARR_API_KEY
      remap LIDARR_API_KEY     LIDARR_API_KEY
      remap BAZARR_API_KEY     BAZARR_API_KEY
      remap BOOKSHELF_API_KEY  BOOKSHELF_API_KEY
      ;;
    npm|plex|infisical)
      ;;  # no secrets needed
  esac
}

inject_secrets() {
  local -a targets=("$@")
  section "Injecting secrets"
  info "Project ID: $PROJECT_ID"
  info "Environment: $INFISICAL_ENV"

  if [[ ${#targets[@]} -eq 0 ]]; then
    # Inject all secrets
    for stack in "${STACKS[@]}"; do
      info "Injecting secrets for: $stack"
      inject_secrets_for "$stack"
    done
  else
    # Inject only secrets for requested stacks
    for stack in "${targets[@]}"; do
      info "Injecting secrets for: $stack"
      inject_secrets_for "$stack"
    done
  fi

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
  (cd "$stack_dir" && env docker compose up -d --build 2>&1 | while IFS= read -r line; do
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

# ── Helpers ───────────────────────────────────────────────────────────────────

# Validate that all provided stack names exist in STACKS
validate_stacks() {
  local -a requested=("$@")
  for name in "${requested[@]}"; do
    local valid=0
    for s in "${STACKS[@]}"; do
      [[ "$s" == "$name" ]] && valid=1 && break
    done
    if [[ $valid -eq 0 ]]; then
      error "Unknown stack: '$name'. Valid stacks: ${STACKS[*]}"
      exit 1
    fi
  done
}

# Returns 1 if a stack name is in a provided list, 0 otherwise
in_list() {
  local needle="$1"
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_up() {
  local -a targets=("$@")

  if [[ ${#targets[@]} -eq 0 ]]; then
    # Full startup — all stacks in order
    section "Command: up (all stacks)"
    info "Stacks to start: ${STACKS[*]}"

    stack_up "infisical"
    info "Waiting for Infisical to be ready..."
    until curl -sf "http://192.168.1.49:8085/api/status" > /dev/null 2>&1; do
      debug "Infisical not ready yet, retrying in 5 seconds..."
      sleep 5
    done
    info "Infisical is ready"

    get_token
    inject_secrets  # injects all secrets

    for stack in "${STACKS[@]}"; do
      [[ "$stack" == "infisical" ]] && continue
      stack_up "$stack"
    done

  else
    # Selective startup — named stacks only
    validate_stacks "${targets[@]}"
    section "Command: up (selective: ${targets[*]})"

    # If infisical is not already running, start it first
    if ! docker compose -f "$DOCKER_DIR/infisical/compose.yaml" ps --quiet 2>/dev/null | grep -q .; then
      warn "Infisical does not appear to be running — starting it first"
      stack_up "infisical"
      info "Waiting for Infisical to be ready..."
      until curl -sf "http://192.168.1.49:8085/api/status" > /dev/null 2>&1; do
        debug "Infisical not ready yet, retrying in 5 seconds..."
        sleep 5
      done
    fi

    get_token
    inject_secrets "${targets[@]}"  # injects only secrets for requested stacks

    # Start requested stacks in canonical order
    for stack in "${STACKS[@]}"; do
      in_list "$stack" "${targets[@]}" && stack_up "$stack"
    done
  fi

  section "Done"
  info "Stacks up: ${targets[*]:-all}"
}

cmd_down() {
  local -a targets=("$@")

  if [[ ${#targets[@]} -eq 0 ]]; then
    # Full shutdown — all stacks in reverse order
    section "Command: down (all stacks)"
    info "Stacks to stop (reverse order): ${STACKS[*]}"
    for (( i=${#STACKS[@]}-1; i>=0; i-- )); do
      stack_down "${STACKS[$i]}"
    done
  else
    # Selective shutdown — named stacks only, reverse canonical order
    validate_stacks "${targets[@]}"
    section "Command: down (selective: ${targets[*]})"
    for (( i=${#STACKS[@]}-1; i>=0; i-- )); do
      in_list "${STACKS[$i]}" "${targets[@]}" && stack_down "${STACKS[$i]}"
    done
  fi

  section "Done"
  info "Stacks down: ${targets[*]:-all}"
}

cmd_restart() {
  local -a targets=("$@")

  if [[ ${#targets[@]} -eq 0 ]]; then
    section "Command: restart (all stacks)"
    cmd_down
    cmd_up
  else
    validate_stacks "${targets[@]}"
    section "Command: restart (selective: ${targets[*]})"
    cmd_down "${targets[@]}"
    cmd_up "${targets[@]}"
  fi
}

cmd_pull() {
  local -a targets=("$@")

  if [[ ${#targets[@]} -eq 0 ]]; then
    section "Command: pull (all stacks)"
    for stack in "${STACKS[@]}"; do
      stack_pull "$stack"
    done
  else
    validate_stacks "${targets[@]}"
    section "Command: pull (selective: ${targets[*]})"
    for stack in "${STACKS[@]}"; do
      in_list "$stack" "${targets[@]}" && stack_pull "$stack"
    done
  fi

  section "Done"
  info "Images pulled: ${targets[*]:-all}"
}

# ── Entrypoint ────────────────────────────────────────────────────────────────

COMMAND="${1:-}"
shift || true  # shift off the command, remaining args are stack names

info "manage.sh started — command: ${COMMAND:-<none>}"
info "Running as user: $(whoami)"
info "Docker dir: $DOCKER_DIR"

case "$COMMAND" in
  up)      cmd_up      "$@" ;;
  down)    cmd_down    "$@" ;;
  restart) cmd_restart "$@" ;;
  pull)    cmd_pull    "$@" ;;
  *)
    error "Unknown command: '${COMMAND:-}'"
    echo "Usage: $0 {up|down|restart|pull} [stack1 stack2 ...]"
    echo "Examples:"
    echo "  $0 up                        # start all stacks"
    echo "  $0 restart immich nextcloud  # restart only immich and nextcloud"
    echo "  $0 down servarr              # stop only servarr"
    echo "  $0 pull plex servarr         # pull images for plex and servarr"
    exit 1
    ;;
esac
