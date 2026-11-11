#!/usr/bin/env bash
# Cross-compile the sync server for linux/amd64 using a Dart Docker image.
# Output: build/ota-sync-linux-amd64
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$REPO_ROOT/build"
OUT="$OUT_DIR/ota-sync-linux-amd64"

command -v docker >/dev/null || {
  echo "Docker is required to cross-compile for Linux." >&2
  exit 1
}

mkdir -p "$OUT_DIR"
docker run --rm \
  --platform linux/amd64 \
  -v "$REPO_ROOT:/repo" \
  -w /repo/mcp_server \
  dart:stable \
  bash -c 'mkdir -p /repo/build && dart compile exe bin/ota_sync_server.dart -o /repo/build/ota-sync-linux-amd64'

chmod 755 "$OUT"
echo "Built $OUT"
file "$OUT" || true
