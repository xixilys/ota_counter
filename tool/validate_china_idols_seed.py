#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional


class SeedValidationError(ValueError):
    pass


@dataclass(frozen=True)
class SeedSummary:
    group_count: int
    member_count: int


def _require_non_empty_string(payload: dict[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip():
        raise SeedValidationError(f"Missing non-empty string field: {key}")
    return value


def validate_payload(
    payload: dict[str, Any],
    *,
    min_groups: int = 100,
    min_members: int = 100,
) -> SeedSummary:
    _require_non_empty_string(payload, "sourceUrl")
    _require_non_empty_string(payload, "sourceLabel")
    _require_non_empty_string(payload, "generatedAt")

    groups = payload.get("groups")
    if not isinstance(groups, list):
        raise SeedValidationError("Field groups must be a list")

    if len(groups) < min_groups:
        raise SeedValidationError(
            f"Expected at least {min_groups} groups, found {len(groups)}"
        )

    member_count = 0
    for index, group in enumerate(groups):
        if not isinstance(group, dict):
            raise SeedValidationError(f"Group #{index + 1} must be an object")

        name = group.get("name")
        if not isinstance(name, str) or not name.strip():
            raise SeedValidationError(f"Group #{index + 1} is missing a name")

        members = group.get("members")
        if not isinstance(members, list):
            raise SeedValidationError(f"Group {name} members must be a list")

        for member_index, member in enumerate(members):
            if not isinstance(member, dict):
                raise SeedValidationError(
                    f"Member #{member_index + 1} in group {name} must be an object"
                )
            member_name = member.get("name")
            if not isinstance(member_name, str) or not member_name.strip():
                raise SeedValidationError(
                    f"Member #{member_index + 1} in group {name} is missing a name"
                )

        member_count += len(members)

    if member_count < min_members:
        raise SeedValidationError(
            f"Expected at least {min_members} members, found {member_count}"
        )

    return SeedSummary(group_count=len(groups), member_count=member_count)


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate a generated China idols seed JSON file.",
    )
    parser.add_argument("path", type=Path, help="Seed JSON path to validate.")
    parser.add_argument("--min-groups", type=int, default=100)
    parser.add_argument("--min-members", type=int, default=100)
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = parse_args(argv)

    try:
        payload = json.loads(args.path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise SeedValidationError("Top-level JSON value must be an object")
        summary = validate_payload(
            payload,
            min_groups=args.min_groups,
            min_members=args.min_members,
        )
    except (OSError, json.JSONDecodeError, SeedValidationError) as error:
        print(f"Invalid China idols seed: {error}", file=sys.stderr)
        return 1

    print(
        "Valid China idols seed: "
        f"{summary.group_count} groups, {summary.member_count} members"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
