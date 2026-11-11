#!/usr/bin/env bash
# Deploy the sync bridge as a systemd service with a Linux binary.
# Useful when the target has systemd but no Docker (e.g. the existing bgvps).
#
#   tool/build_mcp_server_linux.sh              # optional; script builds if missing
#   tool/deploy_mcp_server_binary.sh --dry-run
#   OTA_SYNC_SSH_HOST=my-vps tool/deploy_mcp_server_binary.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY="${OTA_SYNC_BINARY:-$REPO_ROOT/build/ota-sync-linux-amd64}"
SSH_USER="${OTA_SYNC_SSH_USER:-root}"
SSH_HOST="${OTA_SYNC_SSH_HOST:-bgvps}"
REMOTE_BIN="${OTA_SYNC_REMOTE_BIN:-/usr/local/bin/ota-sync}"
REMOTE_APP_DIR="${OTA_SYNC_REMOTE_APP_DIR:-/opt/ota-counter-sync}"
UNIT_FILE="$REPO_ROOT/mcp_server/deploy/ota-counter-sync.service"
DRY_RUN=0
BUILD=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --build) BUILD=1 ;;
    *)
      echo "Unsupported argument: $arg" >&2
      echo "Usage: tool/deploy_mcp_server_binary.sh [--build] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

target="$SSH_USER@$SSH_HOST"
if [[ ! -f "$BINARY" || "$BUILD" -eq 1 ]] ||
   [[ -n "$(find "$REPO_ROOT/mcp_server" -type f -name "*.dart" -newer "$BINARY" -print -quit)" ]]; then
  echo "Building linux/amd64 binary..."
  "$REPO_ROOT/tool/build_mcp_server_linux.sh"
fi
if [[ ! -f "$BINARY" ]]; then
  echo "Missing binary: $BINARY" >&2
  exit 1
fi
if [[ ! -f "$UNIT_FILE" ]]; then
  echo "Missing systemd unit: $UNIT_FILE" >&2
  exit 1
fi

echo "Deploy target : $target"
echo "Binary        : $BINARY"
echo "Remote binary : $REMOTE_BIN"
echo "Remote docs   : $REMOTE_APP_DIR/README.md"
echo "Service       : ota-counter-sync (127.0.0.1:8787)"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "Dry run only. Planned actions:"
  echo "1. check remote x86_64 + systemd"
  echo "2. scp binary to $target:$REMOTE_BIN"
  echo "3. install/refresh systemd unit, create ota-sync user"
  echo "4. systemctl daemon-reload && systemctl enable --now ota-counter-sync"
  echo "5. print /var/lib/ota-counter-sync/token"
  exit 0
fi

remote_arch="$(ssh "$target" 'uname -m')"
if [[ "$remote_arch" != "x86_64" && "$remote_arch" != "amd64" ]]; then
  echo "Remote arch is $remote_arch; this binary is linux/amd64." >&2
  echo "Set OTA_SYNC_BINARY to an arm64 build if needed." >&2
  exit 1
fi
ssh "$target" 'command -v systemctl >/dev/null' || {
  echo "Remote host needs systemd" >&2
  exit 1
}

echo "Uploading binary..."
scp "$BINARY" "$target:/tmp/ota-sync-upload.$$"
scp "$UNIT_FILE" "$target:/tmp/ota-counter-sync.service.$$"
scp "$REPO_ROOT/mcp_server/README.md" "$target:/tmp/ota-counter-sync.README.$$"

echo "Installing service..."
ssh "$target" "
  set -e
  groupadd --system ota-sync 2>/dev/null || true
  id -u ota-sync >/dev/null 2>&1 || useradd --system --gid ota-sync --home /var/lib/ota-counter-sync --shell /usr/sbin/nologin ota-sync
  install -d -m 0755 '$REMOTE_APP_DIR'
  install -d -m 0750 -o ota-sync -g ota-sync /var/lib/ota-counter-sync
  install -m 0644 '/tmp/ota-counter-sync.README.$$' '$REMOTE_APP_DIR/README.md'
  install -m 0755 '/tmp/ota-sync-upload.$$' '$REMOTE_BIN'
  install -m 0644 '/tmp/ota-counter-sync.service.$$' /etc/systemd/system/ota-counter-sync.service
  rm -f '/tmp/ota-sync-upload.$$' '/tmp/ota-counter-sync.service.$$' '/tmp/ota-counter-sync.README.$$'
  systemctl daemon-reload
  systemctl enable --now ota-counter-sync
  systemctl restart ota-counter-sync
"

echo "Service status:"
ssh "$target" 'systemctl --no-pager --full status ota-counter-sync | sed -n "1,12p"'
echo
echo "Token:"
ssh "$target" 'cat /var/lib/ota-counter-sync/token'
echo
echo "Next: reverse-proxy 127.0.0.1:8787 over HTTPS, then use that URL in App → MCP 同步."
