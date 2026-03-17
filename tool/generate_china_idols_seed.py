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
EXTERNAL_LINK_RE = re.compile(r"\[(https?://[^\s\]]+)\s+([^\]]+)\]")
HEADING_RE = re.compile(r"^(=+)\s*(.*?)\s*\1\s*$")
COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
REF_RE = re.compile(r"<ref[^>/]*/>|<ref[^>]*>.*?</ref>", re.S | re.I)
HTML_TAG_RE = re.compile(r"<[^>]+>")
FILE_LINK_RE = re.compile(r"\[\[(?:File|文件):[^\]]+\]\]", re.I)
COLORTEXT_TEMPLATE_RE = re.compile(
    r"\{\{\s*colortext\s*\|(?P<color>[^{}|]+)\|(?P<label>[^{}|]+)(?:\|[^{}]*)?\}\}",
    re.I,
)
COLOR_TEMPLATE_RE = re.compile(
    r"\{\{\s*(?:color|colour)\s*\|(?P<color>[^{}|]+)\|(?P<label>[^{}|]+)(?:\|[^{}]*)?\}\}",
    re.I,
)
INFOBOX_MEMBER_RE = re.compile(
    r"\|\s*"
    r"(?P<key>current|final|former|现任成员|現任成員|现有成员|現有成員|前成员)"
    r"\s*=\s*"
    r"(?P<value>.*?)"
    r"(?=\|\s*(?:[A-Za-z][^|=\n]*|[\u4e00-\u9fff][^|=\n]*)\s*=|}})",
    re.S | re.I,
)

STATUS_KEYWORDS = (
    "成员",
    "成員",
    "current",
    "former",
    "final",
    "研修生",
    "练习生",
    "練習生",
    "候补",
    "候補",
    "在籍",
    "毕业",
    "畢業",
    "离团",
    "離團",
    "初始",
    "正式",
)
ROLE_NAME_RE = re.compile(
    r"^(?:.+?(?:担当|擔當|成员|成員|研修生|练习生|練習生|队长|隊長|队员|隊員|主唱|主舞|center|C位))\s*[：:—－-]+\s*(.+)$",
    re.I,
)
TRAILING_STATUS_RE = re.compile(
    r"\s+(?:初始成员|正式成员|前成员|毕业成员|研修生|练习生|候补生|[12]\d{3}年.+)$"
)
INTRO_CURRENT_RE = re.compile(
    r"(?:现|現|目前)[^。；\n]{0,24}?有(?P<names>[^。；\n]+?)(?:等)?(?:\d+|[一二三四五六七八九十两]+)?(?:位|名)?成员"
)

INFOBOX_STATUS_BY_FIELD = {
    "current": "现成员",
    "现任成员": "现成员",
    "現任成員": "现成员",
    "现有成员": "现成员",
    "現有成員": "现成员",
    "final": "最终成员",
    "former": "前成员",
    "前成员": "前成员",
}

THEME_COLOR_VARIANTS = {
    "樱花粉色担当": ("樱花粉色", "樱花粉"),
    "玫红色担当": ("玫红色", "玫红"),
    "浅粉色担当": ("浅粉色", "浅粉"),
    "粉色担当": ("粉红色", "粉红", "粉色", "粉"),
    "桃色担当": ("桃色", "桃"),
    "红色担当": ("大红色", "大红", "红色", "红"),
    "橙色担当": ("橙色", "橙"),
    "黄色担当": ("亮黄色", "黄色", "黄"),
    "金色担当": ("金黄色", "金黄", "金色", "金"),
    "绿色担当": ("亮绿色", "绿色", "绿"),
    "薄荷色担当": ("薄荷色", "薄荷"),
    "水色担当": ("水蓝色", "水蓝", "水色"),
    "青蓝色担当": ("青蓝色", "青蓝"),
    "青色担当": ("青色", "青"),
    "湖蓝色担当": ("湖蓝色", "湖蓝"),
    "天蓝色担当": ("天蓝色", "天蓝"),
    "浅蓝色担当": ("浅蓝色", "浅蓝"),
    "深蓝色担当": ("深蓝色", "深蓝"),
    "蓝色担当": ("宝蓝色", "宝蓝", "蓝色", "蓝"),
    "紫色担当": ("紫罗兰色", "紫罗兰", "紫色", "紫"),
    "白色担当": ("纯白色", "纯白", "白色", "白"),
    "黑色担当": ("纯黑色", "纯黑", "黑色", "黑"),
    "银色担当": ("银白色", "银白", "银色", "银"),
    "灰色担当": ("灰色", "灰"),
    "棕色担当": ("棕色", "棕", "咖色", "咖啡色"),
}
THEME_COLOR_ALIAS_TO_LABEL = {
    alias: label
    for label, aliases in THEME_COLOR_VARIANTS.items()
    for alias in aliases
}
THEME_COLOR_ALIAS_PATTERN = "|".join(
    sorted(
        (re.escape(alias) for alias in THEME_COLOR_ALIAS_TO_LABEL),
        key=len,
        reverse=True,
    )
)
THEME_COLOR_LABEL_RE = re.compile(
    rf"(?P<label>{THEME_COLOR_ALIAS_PATTERN})(?:担当色|担当)"
)
THEME_COLOR_VALUE_RE = re.compile(
    rf"(?:担当色|代表色|应援色|應援色)\s*[：:]\s*(?P<label>{THEME_COLOR_ALIAS_PATTERN})"
)


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


def replace_external_links(text: str) -> str:
    return EXTERNAL_LINK_RE.sub(lambda match: match.group(2).strip(), text)


def replace_text_templates(text: str) -> str:
    text = COLORTEXT_TEMPLATE_RE.sub(lambda match: match.group("label").strip(), text)
    text = COLOR_TEMPLATE_RE.sub(lambda match: match.group("label").strip(), text)
    return text


def strip_templates(text: str) -> str:
    previous = None
    while previous != text:
        previous = text
        text = re.sub(r"\{\{[^{}]*\}\}", "", text)
    return text


def clean_inline_text(text: str) -> str:
    text = COMMENT_RE.sub("", text)
    text = FILE_LINK_RE.sub("", text)
    text = replace_text_templates(text)
    text = replace_links(text)
    text = replace_external_links(text)
    text = REF_RE.sub("", text)
    text = strip_templates(text)
    text = HTML_TAG_RE.sub("", text)
    text = text.replace("'''", "").replace("''", "")
    text = text.replace("&nbsp;", " ").replace("\u00a0", " ")
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def simplify_heading(line: str) -> tuple[Optional[int], Optional[str]]:
    match = HEADING_RE.match(line)
    if not match:
        return None, None
    return len(match.group(1)), clean_inline_text(match.group(2))


def clean_name(raw_line: str) -> str:
    text = raw_line.strip().lstrip("*#;:").strip()
    text = clean_inline_text(text)

    match = ROLE_NAME_RE.match(text)
    if match:
        text = match.group(1)

    text = re.sub(r"\s+@[\w\-\u4e00-\u9fff].*$", "", text)
    text = TRAILING_STATUS_RE.sub("", text)
    text = re.sub(r"\s*(?:[-—–]+>|-->).*$", "", text)
    text = text.split("<", 1)[0]
    text = text.split("（", 1)[0]
    text = text.split("(", 1)[0]
    text = re.sub(r"^[^0-9A-Za-z\u4e00-\u9fff\u3040-\u30ff\u30fc]+", "", text)
    text = text.strip("：:；;、，, ")
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def clean_status(raw_status: str) -> str:
    status = clean_inline_text(raw_status)
    return status or "未分类"


def extract_theme_color(raw_text: str) -> str:
    text = clean_inline_text(raw_text)
    if not text:
        return ""

    match = THEME_COLOR_LABEL_RE.search(text)
    if match:
        return THEME_COLOR_ALIAS_TO_LABEL.get(match.group("label"), "")

    match = THEME_COLOR_VALUE_RE.search(text)
    if match:
        return THEME_COLOR_ALIAS_TO_LABEL.get(match.group("label"), "")

    return ""


def merge_status(status: str, theme_color: str) -> str:
    if not theme_color:
        return status
    if theme_color in status:
        return status
    return f"{status} / {theme_color}" if status else theme_color


def parse_member_entry(raw_text: str, current_status: str) -> tuple[str, str]:
    name = clean_name(raw_text)
    theme_color = extract_theme_color(raw_text)
    return name, merge_status(current_status, theme_color)


def looks_like_status_heading(heading: str) -> bool:
    if not heading:
        return False
    lowered = heading.lower()
    return any(keyword in heading for keyword in STATUS_KEYWORDS) or any(
        keyword in lowered for keyword in ("current", "former", "final")
    )


def looks_like_member_name(name: str) -> bool:
    if not name or len(name) > 48:
        return False

    if any(token in name for token in ("http://", "https://", "{{", "}}", "[[")):
        return False

    if any(
        name.startswith(prefix)
        for prefix in (
            "生日",
            "生 日",
            "星座",
            "应援色",
            "應援色",
            "社交平台",
            "个人应援群",
            "個人應援群",
            "披露日期",
            "毕业日期",
            "畢業日期",
            "官方信息",
            "官方交流群",
            "微博",
            "微 博",
            "BiliBili",
            "地址",
            "日期",
            "活动名称",
            "活動名稱",
            "歌单",
            "歌單",
            "备注",
            "備註",
        )
    ):
        return False

    if "：" in name or ":" in name:
        return False

    return bool(re.search(r"[A-Za-z\u4e00-\u9fff\u3040-\u30ff\u30fc]", name))


def split_member_candidates(raw_value: str) -> list[tuple[str, str]]:
    cleaned = clean_inline_text(raw_value)
    if not cleaned:
        return []

    parts = re.split(r"[、/／,，；;]+", cleaned)
    names: list[tuple[str, str]] = []
    for part in parts:
        name = clean_name(part)
        if looks_like_member_name(name):
            names.append((name, extract_theme_color(part)))
    return names


def parse_infobox_members(text: str) -> list[tuple[str, str]]:
    sanitized = COMMENT_RE.sub("", text)
    sanitized = FILE_LINK_RE.sub("", sanitized)
    sanitized = replace_links(sanitized)
    sanitized = replace_external_links(sanitized)

    members: list[tuple[str, str]] = []
    for match in INFOBOX_MEMBER_RE.finditer(sanitized):
        key = clean_inline_text(match.group("key")).replace(" ", "")
        status = INFOBOX_STATUS_BY_FIELD.get(key)
        if not status:
            continue

        for name, theme_color in split_member_candidates(match.group("value")):
            members.append((name, merge_status(status, theme_color)))

    return members


def parse_intro_current_members(text: str) -> list[tuple[str, str]]:
    cleaned = clean_inline_text(text)
    matches = []
    for match in INTRO_CURRENT_RE.finditer(cleaned):
        names = split_member_candidates(match.group("names"))
        if names:
            matches.extend(
                (name, merge_status("现成员", theme_color))
                for name, theme_color in names
            )
    return matches


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
                if "成员" in heading or "成員" in heading:
                    in_member_section = True
                    current_status = "未分类"
                elif in_member_section and any(
                    stop in heading for stop in SECTION_STOP_WORDS
                ):
                    break
                elif in_member_section and "成员" not in heading and "成員" not in heading:
                    break
            elif in_member_section and level >= 3:
                if looks_like_status_heading(heading):
                    current_status = clean_status(heading)
                else:
                    name, status = parse_member_entry(heading, current_status)
                    if looks_like_member_name(name):
                        members.append((name, status))
            continue

        if not in_member_section or not line.startswith(("*", "#", ";")):
            continue

        name, status = parse_member_entry(line, current_status)
        if not looks_like_member_name(name):
            continue
        members.append((name, status))

    if not members:
        members = parse_infobox_members(text)

    if not members:
        members = parse_intro_current_members(text)

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
    return True


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
