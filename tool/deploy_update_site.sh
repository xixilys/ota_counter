#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SSH_USER="${OTA_UPDATE_SSH_USER:-root}"
SSH_HOST="${OTA_UPDATE_SSH_HOST:-bgvps}"
REMOTE_DIR="${OTA_UPDATE_REMOTE_DIR:-/var/www/ota-counter}"
PUBLIC_BASE_URL="${OTA_UPDATE_PUBLIC_BASE_URL:-https://ota-counter.huangxuanqi.top/ota-counter}"

DRY_RUN=0
SKIP_APK=0
EXPLICIT_APK=
PREVIOUS_MANIFEST=
SITE_DIR="$REPO_ROOT/release/update_site"

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    --skip-apk)
      SKIP_APK=1
      ;;
    --apk=/*)
      EXPLICIT_APK="${arg#--apk=}"
      ;;
    --site-dir=/*)
      SITE_DIR="${arg#--site-dir=}"
      ;;
    --previous-manifest=/*)
      PREVIOUS_MANIFEST="${arg#--previous-manifest=}"
      ;;
    *)
      echo "Unsupported argument: $arg" >&2
      echo "Usage: tool/deploy_update_site.sh [--dry-run] [--skip-apk | --apk=/path/to/APK] [--site-dir=/path/to/site] [--previous-manifest=/path/to/previous.json]" >&2
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
ipa_file_name="OTA-Counter-v$version_name.ipa"

index_path="$SITE_DIR/index.html"
manifest_path="$SITE_DIR/latest.json"
apk_path="$REPO_ROOT/build/app/outputs/flutter-apk/$apk_file_name"
ipa_path="$REPO_ROOT/build/ios/ipa/$ipa_file_name"

if [[ -n "$EXPLICIT_APK" ]]; then
  if [[ "$SKIP_APK" -eq 1 || "${EXPLICIT_APK##*/}" != "$apk_file_name" ]]; then
    echo "Expected --apk=.../$apk_file_name without --skip-apk" >&2
    exit 1
  fi
  apk_path="$EXPLICIT_APK"
  # An explicit APK release must not pick up an unrelated local IPA.
  ipa_path=""
fi

for required_file in "$index_path" "$manifest_path"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Missing required file: $required_file" >&2
    exit 1
  fi
done

if grep -Eq '"publishedAt"[[:space:]]*:[[:space:]]*null' "$manifest_path"; then
  echo "Release manifest has no publication timestamp; use tool/publish_android_release.sh" >&2
  exit 1
fi

if [[ "$SKIP_APK" -eq 0 && ! -f "$apk_path" ]]; then
  echo "Missing APK: $apk_path" >&2
  exit 1
fi

if [[ -n "$PREVIOUS_MANIFEST" && "${PREVIOUS_MANIFEST##*/}" != previous.json ]]; then
  echo 'Expected --previous-manifest=.../previous.json' >&2
  exit 1
fi
if [[ -n "$PREVIOUS_MANIFEST" && ! -f "$PREVIOUS_MANIFEST" ]]; then
  echo "Missing previous manifest: $PREVIOUS_MANIFEST" >&2
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

if [[ "$SKIP_APK" -eq 0 ]]; then
  "$SCRIPT_DIR/verify_android_release_signature.sh" "$apk_path"
fi

ssh "$ssh_target" "mkdir -p '$REMOTE_DIR' '$remote_stage_dir'"

upload_files=("$index_path" "$manifest_path")
if [[ -n "$PREVIOUS_MANIFEST" ]]; then
  upload_files+=("$PREVIOUS_MANIFEST")
fi
if [[ "$SKIP_APK" -eq 0 ]]; then
  upload_files+=("$apk_path")
fi
if [[ -f "$ipa_path" ]]; then
  upload_files+=("$ipa_path")
fi

scp "${upload_files[@]}" "$ssh_target:$remote_stage_dir/"

remote_commands=(
  "set -e"
)

if [[ -n "$PREVIOUS_MANIFEST" ]]; then
  remote_commands+=(
    "cmp -s '$remote_stage_dir/previous.json' '$REMOTE_DIR/latest.json' || { echo 'Live OTA manifest changed after preflight; stopped before activation' >&2; exit 1; }"
    "unlink '$remote_stage_dir/previous.json'"
  )
fi

if [[ "$SKIP_APK" -eq 0 ]]; then
  remote_commands+=("mv '$remote_stage_dir/$apk_file_name' '$REMOTE_DIR/$apk_file_name'")
fi
if [[ -f "$ipa_path" ]]; then
  remote_commands+=("mv '$remote_stage_dir/$ipa_file_name' '$REMOTE_DIR/$ipa_file_name'")
fi

remote_commands+=(
  "mv '$remote_stage_dir/index.html' '$REMOTE_DIR/index.html'"
  "mv '$remote_stage_dir/latest.json' '$REMOTE_DIR/latest.json'"
  "rmdir '$remote_stage_dir'"
  "ls -lah '$REMOTE_DIR'"
)

ssh "$ssh_target" "$(printf '%s; ' "${remote_commands[@]}")"

echo
echo "Deploy finished:"
echo "  $PUBLIC_BASE_URL/"
echo "  $PUBLIC_BASE_URL/latest.json"
if [[ "$SKIP_APK" -eq 0 ]]; then
  echo "  $PUBLIC_BASE_URL/$apk_file_name"
fi
if [[ -f "$ipa_path" ]]; then
  echo "  $PUBLIC_BASE_URL/$ipa_file_name"
fi
