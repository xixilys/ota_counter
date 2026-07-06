#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SSH_USER="${OTA_UPDATE_SSH_USER:-root}"
SSH_HOST="${OTA_UPDATE_SSH_HOST:-hk-ares}"
REMOTE_APP_DIR="${OTA_IDOL_UPDATER_APP_DIR:-/opt/ota-counter-idol-updater}"
REMOTE_PUBLIC_DIR="${OTA_UPDATE_REMOTE_DIR:-/var/www/status/ota-counter}"
PUBLIC_BASE_URL="${OTA_UPDATE_PUBLIC_BASE_URL:-https://ota-counter.huangxuanqi.top/ota-counter}"

DRY_RUN=0
RUN_NOW=1

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    --no-run-now)
      RUN_NOW=0
      ;;
    *)
      echo "Unsupported argument: $arg" >&2
      echo "Usage: tool/deploy_idol_seed_updater.sh [--dry-run] [--no-run-now]" >&2
      exit 1
      ;;
  esac
done

ssh_target="$SSH_USER@$SSH_HOST"
remote_stage_dir="/tmp/ota-counter-idol-updater-$(date +%s)"

files=(
  "$REPO_ROOT/tool/generate_china_idols_seed.py"
  "$REPO_ROOT/tool/validate_china_idols_seed.py"
  "$REPO_ROOT/tool/run_idol_seed_update.sh"
  "$REPO_ROOT/assets/data/manual_idols.json"
  "$REPO_ROOT/release/systemd/ota-counter-idol-seed-update.service"
  "$REPO_ROOT/release/systemd/ota-counter-idol-seed-update.timer"
)

for file in "${files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "Missing required file: $file" >&2
    exit 1
  fi
done

echo "Deploy target : $ssh_target"
echo "App dir       : $REMOTE_APP_DIR"
echo "Public dir    : $REMOTE_PUBLIC_DIR"
echo "Data URL      : $PUBLIC_BASE_URL/data/china_idols_seed.json"
echo "Run now       : $RUN_NOW"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "Dry run only. Planned actions:"
  echo "1. ssh $ssh_target mkdir -p '$remote_stage_dir'"
  echo "2. scp updater scripts and systemd units to '$remote_stage_dir'"
  echo "3. install files under '$REMOTE_APP_DIR' and /etc/systemd/system"
  echo "4. systemctl daemon-reload && systemctl enable --now ota-counter-idol-seed-update.timer"
  if [[ "$RUN_NOW" -eq 1 ]]; then
    echo "5. systemctl start ota-counter-idol-seed-update.service"
  fi
  exit 0
fi

ssh "$ssh_target" "rm -rf '$remote_stage_dir' && mkdir -p '$remote_stage_dir'"
scp "${files[@]}" "$ssh_target:$remote_stage_dir/"

remote_commands=(
  "set -e"
  "install -d -m 0755 '$REMOTE_APP_DIR' '$REMOTE_PUBLIC_DIR/data'"
  "install -m 0644 '$remote_stage_dir/generate_china_idols_seed.py' '$REMOTE_APP_DIR/generate_china_idols_seed.py'"
  "install -m 0644 '$remote_stage_dir/validate_china_idols_seed.py' '$REMOTE_APP_DIR/validate_china_idols_seed.py'"
  "install -m 0755 '$remote_stage_dir/run_idol_seed_update.sh' '$REMOTE_APP_DIR/run_idol_seed_update.sh'"
  "install -m 0644 '$remote_stage_dir/manual_idols.json' '$REMOTE_APP_DIR/manual_idols.json'"
  "install -m 0644 '$remote_stage_dir/ota-counter-idol-seed-update.service' '/etc/systemd/system/ota-counter-idol-seed-update.service'"
  "install -m 0644 '$remote_stage_dir/ota-counter-idol-seed-update.timer' '/etc/systemd/system/ota-counter-idol-seed-update.timer'"
  "rm -rf '$remote_stage_dir'"
  "systemctl daemon-reload"
  "systemctl enable --now ota-counter-idol-seed-update.timer"
)

if [[ "$RUN_NOW" -eq 1 ]]; then
  remote_commands+=("systemctl start ota-counter-idol-seed-update.service")
fi

remote_commands+=(
  "systemctl list-timers --all --no-pager ota-counter-idol-seed-update.timer"
)

ssh "$ssh_target" "$(printf '%s; ' "${remote_commands[@]}")"

echo
echo "Deploy finished:"
echo "  $PUBLIC_BASE_URL/data/china_idols_seed.json"
