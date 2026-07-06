#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

import requests

BASE_URL = "http://idol.minecool.site"
EVENTS_DATA_URL = f"{BASE_URL}/data/events_data_ai.json"
EVENTS_DETAIL_URL = f"{BASE_URL}/data/events_detail.json"
SOURCE_LABEL = "MineCool 地下偶像行程"
OUTPUT = (
    Path(__file__).resolve().parents[1]
    / "release"
    / "update_site"
    / "data"
    / "idol_activity_events.json"
)


def fetch_json(session: requests.Session, url: str) -> dict[str, Any]:
    response = session.get(url, timeout=30)
    response.raise_for_status()
    payload = response.json()
    if not isinstance(payload, dict):
        raise ValueError(f"Expected JSON object from {url}")
    return payload


def normalize_text(value: Any) -> str:
    return str(value or "").strip()


def source_id(*parts: str) -> str:
    raw = "|".join(part.strip() for part in parts)
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:24]


def normalize_group(value: dict[str, Any]) -> dict[str, str]:
    return {
        "name": normalize_text(value.get("name") or value.get("username")),
        "uid": normalize_text(value.get("uid")),
    }


def event_from_detail(raw: dict[str, Any]) -> Optional[dict[str, Any]]:
    date = normalize_text(raw.get("date"))
    name = normalize_text(raw.get("event_name"))
    if not date or not name:
        return None

    groups = [
        group
        for group in (
            normalize_group(item)
            for item in raw.get("groups", [])
            if isinstance(item, dict)
        )
        if group["name"]
    ]
    stable_id = normalize_text(raw.get("original_mid") or raw.get("detail_mid"))
    if not stable_id:
        stable_id = source_id(
            "detail",
            date,
            normalize_text(raw.get("city")),
            normalize_text(raw.get("venue")),
            name,
            ",".join(group["name"] for group in groups),
        )

    poster = normalize_text(raw.get("poster"))
    if poster and poster.startswith("images/"):
        poster = f"{BASE_URL}/{poster}"

    return {
        "sourceEventId": f"minecool-detail-{stable_id}",
        "date": date,
        "city": normalize_text(raw.get("city")),
        "venue": normalize_text(raw.get("venue")),
        "eventName": name,
        "openTime": normalize_text(raw.get("open_time")),
        "startTime": normalize_text(raw.get("start_time")),
        "description": normalize_text(raw.get("description")),
        "sourceLink": normalize_text(
            raw.get("original_link") or raw.get("source_link")
        ),
        "posterUrl": poster,
        "groups": groups,
    }


def event_from_group(group: dict[str, Any], raw: dict[str, Any]) -> Optional[dict[str, Any]]:
    date = normalize_text(raw.get("date"))
    name = normalize_text(raw.get("event"))
    if not date or not name:
        return None

    group_name = normalize_text(group.get("username"))
    uid = normalize_text(group.get("uid"))
    stable_id = source_id(
        "group",
        uid,
        group_name,
        date,
        normalize_text(raw.get("city")),
        normalize_text(raw.get("venue")),
        name,
    )

    return {
        "sourceEventId": f"minecool-group-{stable_id}",
        "date": date,
        "city": normalize_text(raw.get("city")),
        "venue": normalize_text(raw.get("venue")),
        "eventName": name,
        "openTime": "",
        "startTime": "",
        "description": "",
        "sourceLink": "",
        "posterUrl": "",
        "groups": [
            {
                "name": group_name,
                "uid": uid,
            }
        ]
        if group_name
        else [],
    }


def generate_payload(
    events_data: dict[str, Any],
    events_detail: dict[str, Any],
) -> dict[str, Any]:
    events_by_id: dict[str, dict[str, Any]] = {}

    for raw in events_detail.get("events", []):
        if not isinstance(raw, dict):
            continue
        event = event_from_detail(raw)
        if event is not None:
            events_by_id[event["sourceEventId"]] = event

    for group in events_data.get("groups", []):
        if not isinstance(group, dict):
            continue
        for raw in group.get("events", []):
            if not isinstance(raw, dict):
                continue
            event = event_from_group(group, raw)
            if event is not None:
                events_by_id.setdefault(event["sourceEventId"], event)

    events = sorted(
        events_by_id.values(),
        key=lambda item: (
            item["date"],
            item["city"],
            item["venue"],
            item["eventName"],
            item["sourceEventId"],
        ),
    )

    return {
        "sourceUrl": BASE_URL,
        "sourceLabel": SOURCE_LABEL,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "upstreamGenerated": normalize_text(
            events_detail.get("generated") or events_data.get("generated")
        ),
        "totalEvents": len(events),
        "events": events,
    }


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate OTA Counter idol activity events from MineCool.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=OUTPUT,
        help=f"Path to write idol_activity_events.json. Defaults to {OUTPUT}.",
    )
    parser.add_argument("--events-data-url", default=EVENTS_DATA_URL)
    parser.add_argument("--events-detail-url", default=EVENTS_DETAIL_URL)
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> None:
    args = parse_args(argv)
    session = requests.Session()
    events_data = fetch_json(session, args.events_data_url)
    events_detail = fetch_json(session, args.events_detail_url)
    payload = generate_payload(events_data, events_detail)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {payload['totalEvents']} activity events to {args.output}")


if __name__ == "__main__":
    main()
