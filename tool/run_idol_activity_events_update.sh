#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${OTA_IDOL_ACTIVITY_UPDATER_APP_DIR:-/opt/ota-counter-idol-activity-updater}"
PUBLIC_DIR="${OTA_IDOL_PUBLIC_DIR:-/var/www/status/ota-counter}"
DATA_DIR="${OTA_IDOL_DATA_DIR:-$PUBLIC_DIR/data}"
EVENTS_PATH="${OTA_IDOL_ACTIVITY_EVENTS_PATH:-$DATA_DIR/idol_activity_events.json}"
GENERATOR="${OTA_IDOL_ACTIVITY_GENERATOR:-$APP_DIR/generate_idol_activity_events.py}"
PYTHON="${OTA_IDOL_PYTHON:-$APP_DIR/.venv/bin/python3}"
LOCK_FILE="${OTA_IDOL_ACTIVITY_LOCK_FILE:-/run/ota-counter-idol-activity-update.lock}"

if [[ ! -x "$PYTHON" ]]; then
  PYTHON="python3"
fi

if [[ ! -f "$GENERATOR" ]]; then
  echo "Missing generator: $GENERATOR" >&2
  exit 1
fi

install -d -m 0755 "$DATA_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another idol activity update is already running; skipping."
  exit 0
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

tmp_events="$work_dir/idol_activity_events.json"
tmp_public="$EVENTS_PATH.tmp"

"$PYTHON" "$GENERATOR" --output "$tmp_events"

"$PYTHON" - "$tmp_events" <<'PY'
import json
import sys

path = sys.argv[1]
payload = json.load(open(path, encoding="utf-8"))
events = payload.get("events")
if not isinstance(events, list) or len(events) < 100:
    raise SystemExit(f"Expected at least 100 events, found {len(events) if isinstance(events, list) else 'invalid'}")
for index, event in enumerate(events, start=1):
    for key in ("sourceEventId", "date", "eventName"):
        if not str(event.get(key, "")).strip():
            raise SystemExit(f"Event #{index} missing {key}")
print(f"Valid idol activity events: {len(events)} events")
PY

install -m 0644 "$tmp_events" "$tmp_public"
mv "$tmp_public" "$EVENTS_PATH"

echo "Published idol activity events to $EVENTS_PATH"
