#!/usr/bin/env bash
# Deploy the OTA Counter sync/MCP bridge to a Docker host.
#
# Defaults follow the repo's other deployment scripts (root@bgvps), but every
# value can be overridden:
#   OTA_SYNC_SSH_USER=root OTA_SYNC_SSH_HOST=my-vps \
#   OTA_SYNC_REMOTE_DIR=/opt/ota-counter-sync tool/deploy_mcp_server.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SSH_USER="${OTA_SYNC_SSH_USER:-root}"
SSH_HOST="${OTA_SYNC_SSH_HOST:-bgvps}"
REMOTE_DIR="${OTA_SYNC_REMOTE_DIR:-/opt/ota-counter-sync}"
PUBLIC=0
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --public)
      PUBLIC=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    *)
      echo "Unsupported argument: $arg" >&2
      echo "Usage: tool/deploy_mcp_server.sh [--public] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$REMOTE_DIR" || "$REMOTE_DIR" == "/" || "$REMOTE_DIR" == "/opt" ||
      "$REMOTE_DIR" == "/var" || "$REMOTE_DIR" == "/home" ]]; then
  echo "Refusing unsafe remote dir: '$REMOTE_DIR'" >&2
  exit 1
fi

target="$SSH_USER@$SSH_HOST"
bind="${OTA_SYNC_BIND:-127.0.0.1}"
if [[ "$PUBLIC" -eq 1 ]]; then
  bind="0.0.0.0"
fi

echo "Deploy target : $target"
echo "Remote dir    : $REMOTE_DIR"
echo "Listen bind   : $bind:8787"
echo "Mode          : $([[ "$PUBLIC" -eq 1 ]] && echo 'direct public port (use HTTPS/firewall!)' || echo 'loopback (put Nginx/Caddy in front)')"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "Dry run only. Planned actions:"
  echo "1. tar mcp_server/ -> $target:$REMOTE_DIR"
  echo "2. ssh $target 'cd $REMOTE_DIR && OTA_SYNC_BIND=$bind docker compose up -d --build'"
  echo "3. print the generated token from /data/token"
  exit 0
fi

echo "Checking remote Docker..."
ssh "$target" 'command -v docker >/dev/null && docker compose version >/dev/null' || {
  echo "Remote host needs Docker + Docker Compose v2" >&2
  exit 1
}

echo "Uploading mcp_server/..."
tar -C "$REPO_ROOT" \
  --exclude='mcp_server/.dart_tool' \
  --exclude='mcp_server/data' \
  --exclude='mcp_server/.env' \
  -czf - mcp_server \
  | ssh "$target" "mkdir -p '$REMOTE_DIR' && tar -xzf - -C '$REMOTE_DIR' --strip-components=1"

echo "Starting container..."
ssh "$target" "cd '$REMOTE_DIR' && OTA_SYNC_BIND='$bind' docker compose up -d --build"

echo "Token:"
ssh "$target" "cd '$REMOTE_DIR' && docker compose exec -T ota-sync cat /data/token"

echo
echo "Done. App sync URL:"
if [[ "$PUBLIC" -eq 1 ]]; then
  echo "  http://<server-ip>:8787"
else
  echo "  http://127.0.0.1:8787  (only on the server; front it with Nginx/Caddy first)"
fi
echo "See mcp_server/DEPLOY.md for HTTPS, backups and MCP client setup."
