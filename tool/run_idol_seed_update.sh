#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${OTA_IDOL_UPDATER_APP_DIR:-/opt/ota-counter-idol-updater}"
PUBLIC_DIR="${OTA_IDOL_PUBLIC_DIR:-/var/www/status/ota-counter}"
DATA_DIR="${OTA_IDOL_DATA_DIR:-$PUBLIC_DIR/data}"
SEED_PATH="${OTA_IDOL_SEED_PATH:-$DATA_DIR/china_idols_seed.json}"
GENERATOR="${OTA_IDOL_GENERATOR:-$APP_DIR/generate_china_idols_seed.py}"
VALIDATOR="${OTA_IDOL_VALIDATOR:-$APP_DIR/validate_china_idols_seed.py}"
MANUAL_FILE="${OTA_IDOL_MANUAL_FILE:-$APP_DIR/manual_idols.json}"
PYTHON="${OTA_IDOL_PYTHON:-$APP_DIR/.venv/bin/python3}"
MIN_GROUPS="${OTA_IDOL_MIN_GROUPS:-100}"
MIN_MEMBERS="${OTA_IDOL_MIN_MEMBERS:-100}"
LOCK_FILE="${OTA_IDOL_LOCK_FILE:-/run/ota-counter-idol-seed-update.lock}"

if [[ ! -x "$PYTHON" ]]; then
  PYTHON="python3"
fi

if [[ ! -f "$GENERATOR" ]]; then
  echo "Missing generator: $GENERATOR" >&2
  exit 1
fi

if [[ ! -f "$VALIDATOR" ]]; then
  echo "Missing validator: $VALIDATOR" >&2
  exit 1
fi

install -d -m 0755 "$DATA_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another idol seed update is already running; skipping."
  exit 0
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

tmp_seed="$work_dir/china_idols_seed.json"
tmp_public="$SEED_PATH.tmp"

"$PYTHON" "$GENERATOR" --output "$tmp_seed" --manual "$MANUAL_FILE"
"$PYTHON" "$VALIDATOR" "$tmp_seed" \
  --min-groups "$MIN_GROUPS" \
  --min-members "$MIN_MEMBERS"

install -m 0644 "$tmp_seed" "$tmp_public"
mv "$tmp_public" "$SEED_PATH"

echo "Published China idols seed to $SEED_PATH"
