#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SSH_USER="${OTA_UPDATE_SSH_USER:-xixilys}"
SSH_HOST="${OTA_UPDATE_SSH_HOST:-s2.hostuno.com}"
REMOTE_DIR="${OTA_UPDATE_REMOTE_DIR:-/home/xixilys/domains/peace.huangxuanqi.top/public_nodejs/public/ota-counter}"

DRY_RUN=0
SKIP_APK=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    --skip-apk)
      SKIP_APK=1
      ;;
    *)
      echo "Unsupported argument: $arg" >&2
      echo "Usage: tool/deploy_update_site.sh [--dry-run] [--skip-apk]" >&2
      exit 1
      ;;
  esac
done

cd "$REPO_ROOT"

version_line="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)[[:space:]]*$/\1+\2/p' pubspec.yaml | head -n 1)"
if [[ -z "$version_line" ]]; then
  echo "Failed to read version from pubspec.yaml" >&2
  exit 1
fi

version_name="${version_line%%+*}"
apk_file_name="OTA-Counter-v$version_name.apk"

index_path="$REPO_ROOT/release/update_site/index.html"
manifest_path="$REPO_ROOT/release/update_site/latest.json"
apk_path="$REPO_ROOT/build/app/outputs/flutter-apk/$apk_file_name"

for required_file in "$index_path" "$manifest_path"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Missing required file: $required_file" >&2
    exit 1
  fi
done

if [[ "$SKIP_APK" -eq 0 && ! -f "$apk_path" ]]; then
  echo "Missing APK: $apk_path" >&2
  exit 1
fi

ssh_target="$SSH_USER@$SSH_HOST"
remote_stage_dir="$REMOTE_DIR/.upload-$version_name-$(date +%s)"

echo "Deploy target : $ssh_target"
echo "Remote path   : $REMOTE_DIR"
echo "Version       : v$version_name"
echo "Stage path    : $remote_stage_dir"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "Dry run only. Planned actions:"
  echo "1. ssh $ssh_target mkdir -p '$REMOTE_DIR' '$remote_stage_dir'"
  echo "2. scp '$index_path' '$manifest_path' ... '$ssh_target:$remote_stage_dir/'"
  echo "3. ssh $ssh_target move staged files into '$REMOTE_DIR'"
  exit 0
fi

ssh "$ssh_target" "mkdir -p '$REMOTE_DIR' '$remote_stage_dir'"

upload_files=("$index_path" "$manifest_path")
if [[ "$SKIP_APK" -eq 0 ]]; then
  upload_files+=("$apk_path")
fi

scp "${upload_files[@]}" "$ssh_target:$remote_stage_dir/"

remote_commands=(
  "set -e"
  "mv '$remote_stage_dir/index.html' '$REMOTE_DIR/index.html'"
  "mv '$remote_stage_dir/latest.json' '$REMOTE_DIR/latest.json'"
)

if [[ "$SKIP_APK" -eq 0 ]]; then
  remote_commands+=("mv '$remote_stage_dir/$apk_file_name' '$REMOTE_DIR/$apk_file_name'")
fi

remote_commands+=(
  "rmdir '$remote_stage_dir'"
  "ls -lah '$REMOTE_DIR'"
)

ssh "$ssh_target" "$(printf '%s; ' "${remote_commands[@]}")"

echo
echo "Deploy finished:"
echo "  https://peace.huangxuanqi.top/ota-counter/"
echo "  https://peace.huangxuanqi.top/ota-counter/latest.json"
if [[ "$SKIP_APK" -eq 0 ]]; then
  echo "  https://peace.huangxuanqi.top/ota-counter/$apk_file_name"
fi
