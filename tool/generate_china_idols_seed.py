#!/usr/bin/env python3

from __future__ import annotations

import json
import re
from collections import OrderedDict
from datetime import datetime, timezone
from pathlib import Path
from time import sleep
from typing import Optional

import requests

API = "https://chinaidols.fandom.com/zh/api.php"
SOURCE_URL = (
    "https://chinaidols.fandom.com/zh/wiki/"
    "%E4%B8%AD%E5%9B%BD%E5%81%B6%E5%83%8F_Wiki"
)
SOURCE_LABEL = "中国偶像 Wiki"
OUTPUT = (
    Path(__file__).resolve().parents[1]
    / "assets"
    / "data"
    / "china_idols_seed.json"
)

SECTION_STOP_WORDS = ("作品", "经历", "重大事件", "时间线", "单曲", "公演", "活动")
EXCLUDED_GROUP_TITLES = {
    "空色轨迹/历史演出记录",
}

LINK_RE = re.compile(r"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]")
HEADING_RE = re.compile(r"^(=+)\s*(.*?)\s*\1\s*$")


def fetch_all_group_titles(session: requests.Session) -> list[str]:
    titles: list[str] = []
    continuation: dict[str, str] = {}

    while True:
        params = {
            "action": "query",
            "list": "categorymembers",
            "cmtitle": "Category:偶像团体",
            "cmlimit": "max",
            "format": "json",
        }
        params.update(continuation)

        response = session.get(API, params=params, timeout=30)
        response.raise_for_status()
        payload = response.json()
        titles.extend(
            item["title"]
            for item in payload.get("query", {}).get("categorymembers", [])
            if item.get("ns") == 0
        )

        if "continue" not in payload:
            break

        continuation = payload["continue"]

    return titles


def batched(values: list[str], size: int) -> list[list[str]]:
    return [values[index : index + size] for index in range(0, len(values), size)]


def fetch_pages(session: requests.Session, titles: list[str]) -> dict[str, str]:
    pages: dict[str, str] = {}

    for chunk in batched(titles, 20):
        params = {
            "action": "query",
            "prop": "revisions",
            "rvslots": "main",
            "rvprop": "content",
            "titles": "|".join(chunk),
            "format": "json",
            "formatversion": "2",
        }
        response = session.get(API, params=params, timeout=30)
        response.raise_for_status()
        payload = response.json()

        for page in payload.get("query", {}).get("pages", []):
            revisions = page.get("revisions") or []
            content = ""
            if revisions:
                content = (
                    revisions[0]
                    .get("slots", {})
                    .get("main", {})
                    .get("content", "")
                    or ""
                )
            pages[page["title"]] = content

        sleep(0.05)

    return pages


def replace_links(text: str) -> str:
    return LINK_RE.sub(lambda match: (match.group(2) or match.group(1)).strip(), text)


def simplify_heading(line: str) -> tuple[Optional[int], Optional[str]]:
    match = HEADING_RE.match(line)
    if not match:
        return None, None
    return len(match.group(1)), match.group(2).strip()


def clean_name(raw_line: str) -> str:
    text = raw_line.strip().lstrip("*").strip()
    text = replace_links(text)
    text = text.replace("'''", "").replace("''", "")
    text = text.split("<", 1)[0]
    text = text.split("（", 1)[0]
    text = text.split("(", 1)[0]
    text = text.split("{{", 1)[0]
    text = text.split("｜", 1)[0]
    text = text.split("|", 1)[0]
    text = text.strip("：:；;、，, ")
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def parse_infobox_current_members(text: str) -> list[tuple[str, str]]:
    match = re.search(r"\|\s*current\s*=\s*(.+)", text)
    if not match:
        return []

    line = replace_links(match.group(1).strip())
    line = line.split("<", 1)[0]
    line = re.sub(r"\{\{.*?\}\}", "", line)
    parts = re.split(r"[、,/， ]+", line)
    members = []
    for part in parts:
        name = part.strip()
        if name:
            members.append((name, "current"))
    return members


def parse_members(text: str) -> list[dict[str, str]]:
    in_member_section = False
    current_status = "未分类"
    members: list[tuple[str, str]] = []

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue

        level, heading = simplify_heading(line)
        if level is not None and heading is not None:
            if level == 2:
                if "成员" in heading:
                    in_member_section = True
                    current_status = "未分类"
                elif in_member_section and any(stop in heading for stop in SECTION_STOP_WORDS):
                    break
                elif in_member_section and "成员" not in heading:
                    break
            elif in_member_section and level >= 3:
                current_status = heading
            continue

        if not in_member_section or not line.startswith("*"):
            continue

        name = clean_name(line)
        if not name:
            continue
        members.append((name, current_status))

    if not members:
        members = parse_infobox_current_members(text)

    deduped: OrderedDict[tuple[str, str], None] = OrderedDict()
    for name, status in members:
        deduped[(name, status)] = None

    return [
        {"name": name, "status": status}
        for name, status in deduped.keys()
    ]


def should_keep_group(title: str, members: list[dict[str, str]]) -> bool:
    if title in EXCLUDED_GROUP_TITLES:
        return False
    if "/" in title and not members:
        return False
    return bool(members)


def main() -> None:
    session = requests.Session()
    group_titles = fetch_all_group_titles(session)
    pages = fetch_pages(session, group_titles)

    groups = []
    for title in group_titles:
        members = parse_members(pages.get(title, ""))
        if not should_keep_group(title, members):
            continue
        groups.append(
            {
                "name": title,
                "members": members,
            }
        )

    payload = {
        "sourceUrl": SOURCE_URL,
        "sourceLabel": SOURCE_LABEL,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "groups": groups,
    }

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print(f"Wrote {len(groups)} groups to {OUTPUT}")


if __name__ == "__main__":
    main()
