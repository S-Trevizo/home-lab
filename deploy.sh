#!/bin/bash
set -e

DOCKER_DIR="/docker"
VALID_STACKS="infisical npm cloudflare servarr plex firefly foundry observability watchtower healthcheck"

sudo -u xeon git -C "$DOCKER_DIR" pull

# Guard against missing HEAD~1 (first commit, shallow clone, etc.)
if ! git -C "$DOCKER_DIR" rev-parse HEAD~1 &>/dev/null; then
  echo "No previous commit to diff against, skipping restart"
  exit 0
fi

CHANGED=$(git -C "$DOCKER_DIR" diff --name-only HEAD~1 HEAD \
  | cut -d'/' -f1 \
  | sort -u)

for folder in $CHANGED; do
  # Skip anything that isn't a valid stack name
  if ! echo "$VALID_STACKS" | grep -qw "$folder"; then
    echo "Skipping '$folder' — not a recognised stack"
    continue
  fi

  # Skip if no compose.yaml exists
  if [ ! -f "$DOCKER_DIR/$folder/compose.yaml" ]; then
    echo "Skipping '$folder' — no compose.yaml found"
    continue
  fi

  echo "Restarting $folder..."
  sudo -u xeon /docker/manage.sh restart "$folder"
done