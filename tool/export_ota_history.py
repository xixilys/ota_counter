#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


DEFAULT_BASE_URL = "https://ota.huangxuanqi.top"
DEFAULT_PREFIX = "ota_history_bundle"
USER_AGENT = "ota-counter-export/1.0"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export OTA site groups, idols, and history into JSON/CSV files.",
    )
    parser.add_argument(
        "--admin-key",
        default="",
        help="OTA admin key. If omitted, OTA_ADMIN_KEY is used.",
    )
    parser.add_argument(
        "--base-url",
        default=DEFAULT_BASE_URL,
        help=f"OTA site base URL. Default: {DEFAULT_BASE_URL}",
    )
    parser.add_argument(
        "--out-dir",
        default="tmp",
        help="Output directory. Default: tmp",
    )
    parser.add_argument(
        "--prefix",
        default=DEFAULT_PREFIX,
        help=f"Output filename prefix. Default: {DEFAULT_PREFIX}",
    )
    return parser.parse_args()


def fetch_json(url: str) -> Any:
    request = Request(
        url,
        headers={
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            payload = response.read()
            charset = response.headers.get_content_charset() or "utf-8"
            data = json.loads(payload.decode(charset))
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"{url} returned HTTP {exc.code}: {detail}") from exc
    except URLError as exc:
        raise RuntimeError(f"failed to reach {url}: {exc.reason}") from exc

    if isinstance(data, dict) and data.get("ok") is False:
        raise RuntimeError(data.get("message") or f"API error from {url}")
    return data


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def write_csv(path: Path, rows: list[dict[str, Any]], fieldnames: list[str]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in fieldnames})


def main() -> int:
    args = parse_args()
    admin_key = (args.admin_key or os.environ.get("OTA_ADMIN_KEY", "")).strip()
    if not admin_key:
        print("missing admin key; pass --admin-key", file=sys.stderr)
        return 1

    base_url = args.base_url.rstrip("/")
    out_dir = Path(args.out_dir).expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    groups = fetch_json(f"{base_url}/api/groups")
    idols = fetch_json(f"{base_url}/api/idols")
    records = fetch_json(
        f"{base_url}/api/records?key={quote(admin_key, safe='')}",
    )

    if not isinstance(groups, list) or not isinstance(idols, list) or not isinstance(records, list):
        print("unexpected API response format", file=sys.stderr)
        return 1

    exported_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    bundle = {
        "formatVersion": 1,
        "source": "ota_admin_export",
        "baseUrl": base_url,
        "exportedAt": exported_at,
        "groupCount": len(groups),
        "idolCount": len(idols),
        "recordCount": len(records),
        "groups": groups,
        "idols": idols,
        "records": records,
    }

    json_path = out_dir / f"{args.prefix}_{timestamp}.json"
    latest_json_path = out_dir / f"{args.prefix}_latest.json"
    groups_csv_path = out_dir / f"{args.prefix}_{timestamp}_groups.csv"
    idols_csv_path = out_dir / f"{args.prefix}_{timestamp}_idols.csv"
    records_csv_path = out_dir / f"{args.prefix}_{timestamp}_records.csv"

    write_json(json_path, bundle)
    write_json(latest_json_path, bundle)

    group_rows = [
        {
            "name": (group.get("name") or ""),
            "price_daqie": ((group.get("prices") or {}).get("daqie") if isinstance(group.get("prices"), dict) else ""),
            "price_xiaoqie": ((group.get("prices") or {}).get("xiaoqie") if isinstance(group.get("prices"), dict) else ""),
            "price_tuanqie": ((group.get("prices") or {}).get("tuanqie") if isinstance(group.get("prices"), dict) else ""),
        }
        for group in groups
        if isinstance(group, dict)
    ]
    idol_rows = [
        {
            "group": idol.get("group", ""),
            "name": idol.get("name", ""),
            "status": idol.get("status", ""),
        }
        for idol in idols
        if isinstance(idol, dict)
    ]
    record_rows = [
        {
            "id": record.get("id", ""),
            "name": record.get("name", ""),
            "group": record.get("group", ""),
            "idol": record.get("idol", ""),
            "qty": record.get("qty", ""),
            "cutType": record.get("cutType", ""),
            "price": record.get("price", ""),
            "finalAmount": record.get("finalAmount", ""),
            "note": record.get("note", ""),
            "ts": record.get("ts", ""),
        }
        for record in records
        if isinstance(record, dict)
    ]

    write_csv(
        groups_csv_path,
        group_rows,
        ["name", "price_daqie", "price_xiaoqie", "price_tuanqie"],
    )
    write_csv(
        idols_csv_path,
        idol_rows,
        ["group", "name", "status"],
    )
    write_csv(
        records_csv_path,
        record_rows,
        [
            "id",
            "name",
            "group",
            "idol",
            "qty",
            "cutType",
            "price",
            "finalAmount",
            "note",
            "ts",
        ],
    )

    print(f"bundle json: {json_path}")
    print(f"latest json: {latest_json_path}")
    print(f"groups csv: {groups_csv_path}")
    print(f"idols csv: {idols_csv_path}")
    print(f"records csv: {records_csv_path}")
    print(
        f"exported {len(groups)} groups, {len(idols)} idols, {len(records)} records",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
