from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from tool import generate_china_idols_seed  # noqa: E402


class GenerateChinaIdolsSeedTest(unittest.TestCase):
    def test_main_writes_to_requested_output_path(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            output_path = Path(temp_dir) / "public" / "china_idols_seed.json"

            with (
                patch.object(
                    generate_china_idols_seed,
                    "fetch_all_group_titles",
                    return_value=["测试团"],
                ),
                patch.object(
                    generate_china_idols_seed,
                    "fetch_pages",
                    return_value={"测试团": "== 成员 ==\n* 小明"},
                ),
            ):
                manual_path = Path(temp_dir) / "manual_idols.json"
                manual_path.write_text('{"groups": []}', encoding="utf-8")

                generate_china_idols_seed.main(
                    ["--output", str(output_path), "--manual", str(manual_path)]
                )

            payload = json.loads(output_path.read_text(encoding="utf-8"))

        self.assertEqual(payload["sourceLabel"], generate_china_idols_seed.SOURCE_LABEL)
        self.assertEqual(payload["groups"], [
            {
                "name": "测试团",
                "sourceLabel": "中国偶像 Wiki（社区）",
                "sourceUrl": "https://chinaidols.fandom.com/zh/wiki/%E6%B5%8B%E8%AF%95%E5%9B%A2",
                "members": [{"name": "小明", "status": "未分类"}],
            }
        ])

    def test_main_merges_manual_idol_additions(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            output_path = Path(temp_dir) / "public" / "china_idols_seed.json"
            manual_path = Path(temp_dir) / "manual_idols.json"
            manual_path.write_text(
                json.dumps(
                    {
                        "groups": [
                            {
                                "name": "ReCream",
                                "members": [
                                    {
                                        "name": "兔兔Miottie",
                                        "status": "正式成员 / 粉色担当",
                                    }
                                ],
                            }
                        ]
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )

            with (
                patch.object(
                    generate_china_idols_seed,
                    "fetch_all_group_titles",
                    return_value=["测试团"],
                ),
                patch.object(
                    generate_china_idols_seed,
                    "fetch_pages",
                    return_value={"测试团": "== 成员 ==\n* 小明"},
                ),
            ):
                generate_china_idols_seed.main(
                    ["--output", str(output_path), "--manual", str(manual_path)]
                )

            payload = json.loads(output_path.read_text(encoding="utf-8"))

        self.assertIn(
            {
                "name": "ReCream",
                "sourceLabel": "人工补充",
                "members": [
                    {"name": "兔兔Miottie", "status": "正式成员 / 粉色担当", "sourceLabel": "人工补充"}
                ],
            },
            payload["groups"],
        )

    def test_manual_status_overrides_wiki_without_mutating_input(self) -> None:
        wiki = [{"name": "A", "members": [{"name": "成员", "status": "现成员"}]}]
        manual = [{"name": "A", "members": [{"name": "成员", "status": "前成员"}]}]
        merged = generate_china_idols_seed.merge_manual_additions(wiki, manual)
        self.assertEqual(merged[0]["members"], [{"name": "成员", "status": "前成员", "sourceLabel": "人工补充"}])
        self.assertEqual(wiki[0]["members"][0]["status"], "现成员")

    def test_invalid_manual_file_fails_instead_of_dropping_manual_groups(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "manual.json"
            path.write_text('{broken', encoding="utf-8")
            with self.assertRaises(json.JSONDecodeError):
                generate_china_idols_seed.load_manual_additions(path)

    def test_api_error_and_missing_revision_fail_before_publishing(self) -> None:
        from unittest.mock import Mock
        session = Mock()
        session.get.return_value.json.return_value = {"error": {"code": "maxlag"}}
        with self.assertRaises(ValueError):
            generate_china_idols_seed.fetch_all_group_titles(session)
        with self.assertRaises(ValueError):
            generate_china_idols_seed.fetch_pages(session, ["A"])
        session.get.return_value.json.return_value = {"query": {"pages": [{"title": "A", "missing": True}]}}
        with self.assertRaises(ValueError):
            generate_china_idols_seed.fetch_pages(session, ["A"])

    def test_mediawiki_normalized_title_maps_back_to_requested_title(self) -> None:
        from unittest.mock import Mock
        session = Mock()
        session.get.return_value.json.return_value = {"query": {
            "normalized": [{"from": "A_B", "to": "A B"}],
            "pages": [{"title": "A B", "revisions": [{"slots": {"main": {"content": "== 成员 ==\n* A"}}}]}],
        }}
        self.assertIn("A_B", generate_china_idols_seed.fetch_pages(session, ["A_B"]))


if __name__ == "__main__":
    unittest.main()
