#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
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
    # Upstream descriptions and titles sometimes contain HTML entities.
    return html.unescape(str(value or "")).strip()


_MATCH_NOISE_RE = re.compile(
    r"[\s·•・_\-~/\\()\[\]{}（）【】「」『』“”\"\'’&\u200b\u200c\u200d\ufeff]+"
)


def normalize_for_match(value: Any) -> str:
    return _MATCH_NOISE_RE.sub("", normalize_text(value)).casefold()


_VENUE_PREFIX_RE = re.compile(
    r"^(?:📍\s*)?(?:活动地点|活动地址|演出地点|演出地址|地点|地址|会場|会场)\s*[：:]\s*"
)
# A venue that starts mid-word is a fragment of the post title, not a venue.
_LOWERCASE_VENUE_RE = re.compile(r"^[a-z]")
_GARBLED_VENUE_RE = re.compile(r"&(?:amp|lt|gt|quot|#\d+);|^mp;", re.I)
_PLACEHOLDER_EVENTS = {"", "？？？", "???", "（日）？？？", "(日)？？？", "待定", "tba", "tbd"}


def clean_venue(venue: Any, city: Any, event_name: Any) -> str:
    value = _VENUE_PREFIX_RE.sub("", normalize_text(venue)).strip(" ·，,。;；")
    if not value:
        return ""
    if normalize_for_match(value) == normalize_for_match(city):
        return ""
    if _GARBLED_VENUE_RE.search(value) or _LOWERCASE_VENUE_RE.match(value):
        return ""
    # A title suffix such as "rellas熠期一会Live" is a broken venue; keep it
    # only when it still looks like a real venue name.
    normalized_venue = normalize_for_match(value)
    if (
        len(normalized_venue) >= 4
        and normalized_venue in normalize_for_match(event_name)
        and not re.search(r"live|house|space|剧场|中心|馆|厅|店|场|club|bar", value, re.I)
    ):
        return ""
    return value


_WEEKDAY_RE = re.compile(r"周[一二三四五六日天]")


def _is_placeholder_event(value: Any, city: Any) -> bool:
    """A post such as 广州 ？？？ only announces that a date is undecided."""
    text = normalize_text(value)
    if "？？？" in text or "???" in text:
        return True
    if (
        text.endswith(("？", "?"))
        and not text.endswith(("！？", "!?", "？!", "?!", "！?", "?！"))
        and len(text) <= 20
    ):
        return True
    normalized = normalize_for_match(value)
    if normalized in {
        normalize_for_match(item) for item in _PLACEHOLDER_EVENTS
    }:
        return True
    for token in ("？", "?", "待定", "tba", "tbd"):
        normalized = normalized.replace(normalize_for_match(token), "")
    normalized = _WEEKDAY_RE.sub("", normalized)
    city_key = normalize_for_match(city)
    if city_key:
        normalized = normalized.replace(city_key, "")
    return len(normalized) <= 2


def clean_event_name(name: Any, city: Any = "") -> str:
    value = normalize_text(name)
    if len(value) > 80:
        return ""
    if _is_placeholder_event(value, city):
        return ""
    return value


_TIME_RE = re.compile(r"(?<!\d)([01]?\d|2[0-3])[:：]([0-5]\d)(?!\d)")


def _clock(value: str) -> str:
    hour, minute = re.split(r"[:：]", value, maxsplit=1)
    return f"{int(hour):02d}:{minute}"


def extract_times(description: Any) -> dict[str, str]:
    """Fill OPEN/START from explicit wording in the post, never guess."""
    text = normalize_text(description)
    times = {"openTime": "", "startTime": ""}
    if not text:
        return times
    open_patterns = (
        re.compile(r"\bOPEN\s*[-–—]?\s*(\d{1,2}[:：]\d{2})", re.I),
        re.compile(r"开(?:场|始)(?:时间)?\s*[:：]?\s*(\d{1,2}[:：]\d{2})"),
    )
    start_patterns = (
        re.compile(r"\bSTART\s*[-–—]?\s*(\d{1,2}[:：]\d{2})", re.I),
        re.compile(r"开演(?:时间)?\s*[:：]?\s*(\d{1,2}[:：]\d{2})"),
    )
    pair = re.search(
        r"(\d{1,2}[:：]\d{2})\s*(?:入场|開場|开场)[^\d]{0,15}?"
        r"(\d{1,2}[:：]\d{2})\s*(?:正式)?(?:开演|開演|开始|START)",
        text,
        re.I,
    )
    if pair:
        times["openTime"] = _clock(pair.group(1))
        times["startTime"] = _clock(pair.group(2))
        return times
    for pattern in open_patterns:
        match = pattern.search(text)
        if match:
            times["openTime"] = _clock(match.group(1))
            break
    for pattern in start_patterns:
        match = pattern.search(text)
        if match:
            times["startTime"] = _clock(match.group(1))
            break
    if not times["startTime"]:
        match = re.search(
            r"(?:演出时间|活动时间|Live\s*时间|时间)\s*[:：]\s*(\d{1,2}[:：]\d{2})",
            text,
            re.I,
        )
        if match:
            times["startTime"] = _clock(match.group(1))
    return times


def _group_identity(group: dict[str, Any]) -> str:
    return normalize_text(group.get("uid")) or normalize_for_match(group.get("name"))


def merge_event(target: dict[str, Any], incoming: dict[str, Any]) -> dict[str, Any]:
    """Merge two rows for the same date/city/title; detail data wins."""
    target_is_detail = target["sourceEventId"].startswith("minecool-detail")
    incoming_is_detail = incoming["sourceEventId"].startswith("minecool-detail")
    if incoming_is_detail and not target_is_detail:
        base, extra = incoming, target
    else:
        base, extra = target, incoming
    merged = dict(base)
    for field in ("venue", "openTime", "startTime", "description", "sourceLink", "posterUrl"):
        if not merged.get(field) and extra.get(field):
            merged[field] = extra[field]
    merged["isFree"] = bool(target.get("isFree") or incoming.get("isFree"))
    tiers: list[dict[str, Any]] = []
    seen_tiers: set[str] = set()
    for source in (target, incoming):
        for tier in source.get("ticketTiers") or []:
            key = normalize_for_match(tier.get("name"))
            if not key or key in seen_tiers:
                continue
            seen_tiers.add(key)
            tiers.append(tier)
    merged["ticketTiers"] = tiers
    groups: list[dict[str, str]] = []
    seen_groups: set[str] = set()
    for source in (target, incoming):
        for group in source.get("groups") or []:
            key = _group_identity(group)
            if not key or key in seen_groups:
                continue
            seen_groups.add(key)
            groups.append(group)
    merged["groups"] = groups
    return merged


def source_id(*parts: str) -> str:
    raw = "|".join(part.strip() for part in parts)
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:24]


def normalize_group(value: dict[str, Any]) -> dict[str, str]:
    return {
        "name": normalize_text(value.get("name") or value.get("username")),
        "uid": normalize_text(value.get("uid")),
    }



_TICKET_LABEL = (
    r"(?:SVIP票?|VIP票?|双人普通票预售|普通票预售|VIP预售|VIP现场|"
    r"预售票?|前売票?|当日票?|现场票?|普通票?|一般票?|学生票?|女性优惠|"
    r"女性票?|优先票?|早鸟票?|三人票?|双人票?|特典票?|通票?|"
    r"单日票?|双日票?|SS席|S席|A席|门票|1D)"
)
_TICKET_PRICE_RE = re.compile(
    rf"(?P<label>{_TICKET_LABEL})\s*(?:票价|现金)?\s*[:：/]?\s*"
    r"[¥￥💰]?\s*[（(]?\s*(?P<price>\d{1,4})(?:\s*(?:元|R|r))?",
    re.IGNORECASE,
)
_TICKET_CURRENCY_RE = re.compile(r"[¥￥]\s*(?P<price>\d{1,4})")
_FREE_PATTERNS = [
    re.compile(r"(?:无料|免费|免票)(?:入场|观演|门票|入場)"),
    re.compile(r"(?:无料|免费|免票)\s*[+＋/]\s*(?:1D|1d|drink)"),
    re.compile(r"(?:入场|观演|门票)[^。\n]{0,8}(?:无料|免费|免票)"),
]
_TICKET_CONTEXT_RE = re.compile(r"票|票价|票务|料金|🎫|💰")
_BAD_TICKET_CONTEXT_RE = re.compile(r"抽|送|基金|补贴|消费满|奖励|积分|兑换")


def _normalize_tier_name(label: str) -> str:
    name = label.strip()
    if name == "门票":
        return "普通"
    if name in ("一般", "普通票"):
        return "普通"
    if name in ("前売", "前売票"):
        return "预售"
    if name == "女性优惠":
        return "女性"
    if name.upper() == "SVIP":
        return "SVIP"
    if name.lower() == "vip":
        return "VIP"
    if name.lower() == "1d":
        return "1D"
    if name.endswith("票"):
        name = name[:-1]
    return name.strip() or "门票"


def extract_ticket_info(texts: list[Any]) -> dict[str, Any]:
    """Best-effort parsing of Chinese event copy.

    The upstream MineCool detail payload has no dedicated price field, but the
    Weibo description usually contains phrases such as
    ``🎫门票 一般：¥25 三人票：¥50`` or ``预售/59 现场/69``. This parser keeps
    only explicitly labelled ticket prices and free-entry phrases so it does not
    turn dates, lottery prizes, or drink fees into ticket prices.
    """
    text = "\n".join(
        html.unescape(str(value or ""))
        for value in texts
        if str(value or "").strip()
    )
    if not text:
        return {"isFree": False, "ticketTiers": []}

    is_free = False
    for pattern in _FREE_PATTERNS:
        for match in pattern.finditer(text):
            before = text[max(0, match.start() - 14) : match.start()]
            after = text[match.end() : match.end() + 10]
            if re.search(r"揪|抽|送|转|中奖|福利|名额", before):
                continue
            if re.search(r"抽|送|名额|奖品", after):
                continue
            is_free = True
            break
        if is_free:
            break

    tiers: list[dict[str, Any]] = []
    seen: set[str] = set()
    for match in _TICKET_PRICE_RE.finditer(text):
        label = match.group("label")
        try:
            price = float(match.group("price"))
        except (TypeError, ValueError):
            continue
        if price <= 0 or price > 999:
            continue
        around = text[max(0, match.start() - 12) : match.end() + 9]
        has_currency = bool(re.search(r"[¥￥💰]|\d\s*(?:元|R|r)\b", match.group(0)))
        # A free event's "当日 18" is usually a time; only trust explicit
        # currency or premium/paid tier labels there.
        if is_free and not has_currency and not re.search(
            r"VIP|优先|生日|特典|招待|1D", label, re.IGNORECASE
        ):
            continue
        premium_tier = bool(
            re.search(r"VIP|优先|生日|特典|招待|1D", label, re.IGNORECASE)
        )
        if _BAD_TICKET_CONTEXT_RE.search(around) and not has_currency:
            continue
        if not has_currency and not premium_tier and not _TICKET_CONTEXT_RE.search(
            text[max(0, match.start() - 70) : match.end() + 20]
        ):
            continue
        name = _normalize_tier_name(label)
        key = name.casefold()
        if key in seen:
            continue
        seen.add(key)
        tiers.append({"name": name, "price": price})

    if not tiers:
        for match in _TICKET_CURRENCY_RE.finditer(text):
            around = text[max(0, match.start() - 35) : match.end() + 20]
            if not _TICKET_CONTEXT_RE.search(around):
                continue
            if _BAD_TICKET_CONTEXT_RE.search(around):
                continue
            try:
                price = float(match.group("price"))
            except (TypeError, ValueError):
                continue
            if 0 < price <= 999:
                tiers.append({"name": "门票", "price": price})
                break

    return {
        "isFree": is_free,
        "ticketTiers": tiers[:6],
    }


def event_from_detail(raw: dict[str, Any]) -> Optional[dict[str, Any]]:
    date = normalize_text(raw.get("date"))
    city = normalize_text(raw.get("city"))
    name = clean_event_name(raw.get("event_name"), city)
    if not date or not name:
        return None

    groups = []
    seen_groups: set[str] = set()
    for item in raw.get("groups", []):
        if not isinstance(item, dict):
            continue
        group = normalize_group(item)
        key = _group_identity(group)
        if group["name"] and key and key not in seen_groups:
            seen_groups.add(key)
            groups.append(group)
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

    ticket_info = extract_ticket_info(
        [
            raw.get("description"),
            raw.get("retweeted_text_raw"),
            raw.get("text_raw"),
        ]
    )
    times = extract_times(raw.get("description"))

    return {
        "sourceEventId": f"minecool-detail-{stable_id}",
        "date": date,
        "city": city,
        "venue": clean_venue(raw.get("venue"), city, name),
        "eventName": name,
        "openTime": normalize_text(raw.get("open_time")) or times["openTime"],
        "startTime": normalize_text(raw.get("start_time")) or times["startTime"],
        "description": normalize_text(raw.get("description")),
        "sourceLink": normalize_text(
            raw.get("original_link") or raw.get("source_link")
        ),
        "posterUrl": poster,
        "groups": groups,
        "isFree": ticket_info["isFree"],
        "ticketTiers": ticket_info["ticketTiers"],
    }


def event_from_group(group: dict[str, Any], raw: dict[str, Any]) -> Optional[dict[str, Any]]:
    date = normalize_text(raw.get("date"))
    city = normalize_text(raw.get("city"))
    name = clean_event_name(raw.get("event"), city)
    if not date or not name:
        return None

    group_name = normalize_text(group.get("username"))
    uid = normalize_text(group.get("uid"))
    # One post per group means many rows per actual event.  A stable ID based
    # on the event identity lets the payload writer merge those rows; keeping
    # group order out of the ID also keeps it stable across runs.
    stable_id = source_id("merged", date, city, name)

    return {
        "sourceEventId": f"minecool-group-{stable_id}",
        "date": date,
        "city": city,
        "venue": clean_venue(raw.get("venue"), city, name),
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
        "isFree": False,
        "ticketTiers": [],
    }


def generate_payload(
    events_data: dict[str, Any],
    events_detail: dict[str, Any],
) -> dict[str, Any]:
    events_by_key: dict[tuple[str, str, str], dict[str, Any]] = {}

    def add(event: dict[str, Any]) -> None:
        key = (
            event["date"],
            normalize_for_match(event["city"]),
            normalize_for_match(event["eventName"]),
        )
        existing = events_by_key.get(key)
        events_by_key[key] = event if existing is None else merge_event(existing, event)

    for raw in events_detail.get("events", []):
        if not isinstance(raw, dict):
            continue
        event = event_from_detail(raw)
        if event is not None:
            add(event)

    for group in events_data.get("groups", []):
        if not isinstance(group, dict):
            continue
        for raw in group.get("events", []):
            if not isinstance(raw, dict):
                continue
            event = event_from_group(group, raw)
            if event is not None:
                add(event)

    events = sorted(
        events_by_key.values(),
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
