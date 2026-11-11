from __future__ import annotations

import json
import copy
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from tool import generate_china_idols_seed  # noqa: E402


class GenerateChinaIdolsSeedTest(unittest.TestCase):
    def test_next_day_wiki_and_manual_win_over_accumulated_weibo_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            directory = Path(temp_dir)
            output = directory / "seed.json"
            manual = directory / "manual.json"
            manual.write_text(json.dumps({"groups": [{"name": "星空", "members": [
                {"name": "小夏", "status": "人工确认毕业", "note": "人工字段"},
            ]}]}), encoding="utf-8")
            weibo = directory / "weibo.json"
            weibo.write_text(json.dumps({"sourceLabel": "微博自动补充", "groups": [
                {"name": "星空_Official", "members": [
                    {"name": "小春", "status": "正式成员"},
                    {"name": "小夏", "status": "正式成员"},
                    {"name": "小秋", "status": "正式成员"},
                    {"name": "小_秋", "status": "重复记录"},
                ]},
            ]}), encoding="utf-8")
            later = directory / "later.json"
            later.write_text(json.dumps({"sourceLabel": "微博自动补充", "groups": [
                {"name": "星空偶像计划", "members": [
                    {"name": "小·秋", "status": "另文件重复"},
                    {"name": "小冬", "status": "见习成员"},
                ]},
            ]}), encoding="utf-8")
            with (
                patch.object(generate_china_idols_seed, "fetch_all_group_titles", return_value=["星空"]),
                patch.object(generate_china_idols_seed, "fetch_pages", return_value={"星空": "== 成员 ==\n=== 前成员 ===\n* 小春"}),
                patch.object(generate_china_idols_seed.requests.Session, "get", side_effect=AssertionError("Unexpected network request")),
            ):
                # Yesterday, only Weibo knew these names.
                with patch.object(generate_china_idols_seed, "fetch_pages", return_value={"星空": "== 成员 =="}):
                    generate_china_idols_seed.main(["--output", str(output), "--manual", str(weibo)])
                yesterday = json.loads(output.read_text(encoding="utf-8"))
                self.assertEqual(yesterday["groups"][0]["members"][0]["sourceLabel"], "微博自动补充")
                # Today Wiki/manual have authoritative records, but yesterday's
                # accumulated Weibo files are still passed last by the runner.
                generate_china_idols_seed.main([
                    "--output", str(output), "--manual", str(manual),
                    "--manual", str(weibo), "--manual", str(later),
                ])
            groups = json.loads(output.read_text(encoding="utf-8"))["groups"]
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]["sourceLabel"], "中国偶像 Wiki（社区）")
        self.assertIn("chinaidols.fandom.com", groups[0]["sourceUrl"])
        self.assertEqual(groups[0]["members"], [
            {"name": "小春", "status": "前成员"},
            {"name": "小夏", "status": "人工确认毕业", "note": "人工字段", "sourceLabel": "人工补充"},
            {"name": "小秋", "status": "正式成员", "sourceLabel": "微博自动补充"},
            {"name": "小冬", "status": "见习成员", "sourceLabel": "微博自动补充"},
        ])

    def test_weibo_preserves_all_existing_fields_and_normalizes_names(self) -> None:
        original = [
            {"name": " Aster-Project ", "sourceLabel": "人工补充", "sourceUrl": "https://example.com",
             "note": {"keep": True}, "members": [
                 {"name": " A_li-ce· ", "status": "前成员", "sourceLabel": "人工补充", "note": "保留"},
             ]},
            {"name": "Aster", "members": [{"name": "Bob", "status": "现成员", "extra": 1}]},
        ]
        before = copy.deepcopy(original)
        for group_name, target in (
            ("aster", 1),
            ("ASTER _ PROJECT Official", 0),
            (" Aster_·- Project·oFfIcIaL ", 0),
        ):
            with self.subTest(group_name=group_name):
                merged = generate_china_idols_seed.merge_manual_additions(original, [{
                    "name": group_name, "sourceLabel": "微博自动补充", "sourceUrl": "https://weibo.com/u/123",
                    "members": [
                        {"name": "alice", "status": "错误覆盖"},
                        {"name": "B_o-b·", "status": "错误覆盖"},
                        {"name": "Carol", "status": "见习成员"},
                        {"name": "C a_r-o·l", "status": "重复"},
                    ],
                }])
                expected = copy.deepcopy(before)
                expected[target]["members"].append({"name": "Carol", "status": "见习成员", "sourceLabel": "微博自动补充"})
                self.assertEqual(merged, expected)
                self.assertEqual(original, before)

    def test_weibo_ambiguous_containment_skips_group_and_logs_candidates(self) -> None:
        groups = [{"name": name, "members": [], "note": "保留"}
                  for name in ("Aster-Project", "Aster-Idol")]
        for original in (groups, list(reversed(groups))):
            with self.subTest(order=[group["name"] for group in original]):
                before = copy.deepcopy(original)
                with patch("builtins.print") as log:
                    merged = generate_china_idols_seed.merge_manual_additions(original, [
                        {"name": "Aster·Official", "sourceLabel": "微博自动补充",
                         "members": [{"name": "Carol", "status": "见习成员"}]},
                        {"name": "另一团", "sourceLabel": "微博自动补充",
                         "members": [{"name": "小新", "status": "正式成员"}]},
                    ])
                self.assertEqual(merged[:2], before)
                self.assertEqual(original, before)
                self.assertEqual(merged[2]["name"], "另一团")
                log.assert_called_once()
                message = log.call_args.args[0]
                for text in ("跳过", "歧义", "Aster·Official", "Aster-Project", "Aster-Idol"):
                    self.assertIn(text, message)

    def test_weibo_unique_containment_appends_in_either_direction(self) -> None:
        for existing_name, incoming_name in (
            ("Aster-Project", "aster·Official"),
            ("Aster", "Aster-Project·Official"),
        ):
            with self.subTest(existing=existing_name, incoming=incoming_name):
                original = [{"name": existing_name, "members": [], "note": "保留"}]
                merged = generate_china_idols_seed.merge_manual_additions(original, [{
                    "name": incoming_name, "sourceLabel": "微博自动补充",
                    "members": [{"name": "Carol", "status": "见习成员"}],
                }])
                self.assertEqual(merged, [{
                    "name": existing_name, "note": "保留", "members": [
                        {"name": "Carol", "status": "见习成员", "sourceLabel": "微博自动补充"},
                    ],
                }])
                self.assertEqual(original[0]["members"], [])

    def test_weibo_new_groups_and_members_deduplicate_across_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            directory = Path(temp_dir)
            merged = []
            for index, name in enumerate(("新-团_Official", "新团", "新团偶像")):
                path = directory / f"weibo-{index}.json"
                path.write_text(json.dumps({"sourceLabel": "微博自动补充", "groups": [
                    {"name": name, "members": [
                        {"name": "A_li-ce", "status": "首条" if index == 0 else "不得覆盖"},
                        {"name": "ALICE", "status": "不得重复"},
                        {"name": f"新人{index}", "status": "见习成员"},
                    ]},
                    {"name": name + " ", "members": [{"name": "a·lice", "status": "团内重复"}]},
                ]}), encoding="utf-8")
                merged = generate_china_idols_seed.merge_manual_additions(
                    merged, generate_china_idols_seed.load_manual_additions(path),
                )
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0]["name"], "新-团_Official")
        self.assertEqual(merged[0]["sourceLabel"], "微博自动补充")
        self.assertEqual(merged[0]["members"], [
            {"name": "A_li-ce", "status": "首条", "sourceLabel": "微博自动补充"},
            *[{"name": f"新人{index}", "status": "见习成员", "sourceLabel": "微博自动补充"} for index in range(3)],
        ])

    def test_manual_files_merge_in_order_with_file_source_labels(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            directory = Path(temp_dir)
            manual = directory / "manual.json"
            weibo = directory / "weibo.json"
            output = directory / "seed.json"
            manual.write_text(json.dumps({"groups": [
                {"name": "测试团", "members": [
                    {"name": "小明", "status": "人工状态"},
                    {"name": "小红", "status": "现成员"},
                ]},
                {"name": "人工团", "members": []},
            ]}), encoding="utf-8")
            weibo.write_text(json.dumps({"sourceLabel": "微博", "groups": [
                {"name": "测试团", "members": [
                    {"name": "小明", "status": "微博状态", "sourceLabel": "忽略成员来源"},
                    {"name": "小蓝", "status": "现成员"},
                ]},
                {"name": "微博团", "sourceLabel": "忽略团体来源", "members": []},
            ]}), encoding="utf-8")
            with (
                patch.object(generate_china_idols_seed, "fetch_all_group_titles", return_value=["测试团"]),
                patch.object(generate_china_idols_seed, "fetch_pages", return_value={"测试团": "== 成员 ==\n* 小明\n* 小白"}),
                patch.object(generate_china_idols_seed, "MANUAL", directory / "must_not_load.json"),
                patch.object(generate_china_idols_seed.requests.Session, "get", side_effect=AssertionError("Unexpected network request")),
            ):
                generate_china_idols_seed.main([
                    "--output", str(output), "--manual", str(manual), "--manual", str(weibo),
                ])
            groups = json.loads(output.read_text(encoding="utf-8"))["groups"]
        self.assertEqual([group["name"] for group in groups], ["测试团", "人工团", "微博团"])
        self.assertEqual(groups[0]["sourceLabel"], "中国偶像 Wiki（社区）")
        self.assertEqual(groups[0]["members"], [
            {"name": "小白", "status": "未分类"},
            {"name": "小红", "status": "现成员", "sourceLabel": "人工补充"},
            {"name": "小明", "status": "微博状态", "sourceLabel": "微博"},
            {"name": "小蓝", "status": "现成员", "sourceLabel": "微博"},
        ])
        self.assertEqual(groups[1]["sourceLabel"], "人工补充")
        self.assertEqual(groups[2]["sourceLabel"], "微博")

    def test_no_manual_argument_uses_default_file_only_if_present(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            directory = Path(temp_dir)
            manual = directory / "manual.json"
            output = directory / "seed.json"
            for present in (False, True):
                with self.subTest(present=present):
                    if present:
                        manual.write_text(json.dumps({"groups": [{"name": "人工团", "members": []}]}), encoding="utf-8")
                    with (
                        patch.object(generate_china_idols_seed, "MANUAL", manual),
                        patch.object(generate_china_idols_seed, "fetch_all_group_titles", return_value=["测试团"]),
                        patch.object(generate_china_idols_seed, "fetch_pages", return_value={"测试团": "== 成员 ==\n* 小明"}),
                        patch.object(generate_china_idols_seed.requests.Session, "get", side_effect=AssertionError("Unexpected network request")),
                    ):
                        generate_china_idols_seed.main(["--output", str(output)])
                    groups = json.loads(output.read_text(encoding="utf-8"))["groups"]
                    self.assertEqual([group["name"] for group in groups], ["测试团", "人工团"] if present else ["测试团"])

    def test_invalid_manual_source_label_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "manual.json"
            for label in (None, 123, "", "  "):
                with self.subTest(label=label):
                    path.write_text(json.dumps({"sourceLabel": label, "groups": []}), encoding="utf-8")
                    with self.assertRaisesRegex(ValueError, "sourceLabel"):
                        generate_china_idols_seed.load_manual_additions(path)

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


class RunIdolSeedUpdateTest(unittest.TestCase):
    def test_optional_weibo_file_is_appended_only_when_nonempty(self) -> None:
        with tempfile.TemporaryDirectory(prefix="idol update ") as temp_dir:
            directory = Path(temp_dir)
            commands = directory / "bin"
            commands.mkdir()
            # macOS has no flock; this test checks argument assembly/publication,
            # not the existing Linux lock implementation.
            flock = commands / "flock"
            flock.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            flock.chmod(0o755)
            generator = directory / "generator.py"
            capture = directory / "args.json"
            generator.write_text(
                "import json, os, sys\nfrom pathlib import Path\n"
                "Path(os.environ['CAPTURE_ARGS']).write_text(json.dumps(sys.argv[1:]))\n"
                "Path(sys.argv[sys.argv.index('--output') + 1]).write_text(json.dumps({"
                "'sourceUrl': 'https://example.com', 'sourceLabel': '测试', "
                "'generatedAt': '2026-11-09T00:00:00+00:00', 'groups': []}))\n",
                encoding="utf-8",
            )
            for override in (False, True):
                for state in ("missing", "empty", "nonempty", "directory"):
                    with self.subTest(override=override, state=state):
                        weibo = directory / f"{override}-{state}.json" if override else directory / "weibo_idols.json"
                        if state == "empty":
                            weibo.write_text("", encoding="utf-8")
                        elif state == "nonempty":
                            weibo.write_text('{"groups": []}', encoding="utf-8")
                        elif state == "directory":
                            if weibo.is_file():
                                weibo.unlink()
                            weibo.mkdir()
                        environment = {
                            key: value for key, value in os.environ.items()
                            if not key.startswith("OTA_IDOL_")
                        }
                        environment.update(
                            PATH=str(commands) + os.pathsep + os.environ["PATH"],
                            OTA_IDOL_UPDATER_APP_DIR=str(directory),
                            OTA_IDOL_PUBLIC_DIR=str(directory / "public"),
                            OTA_IDOL_GENERATOR=str(generator),
                            OTA_IDOL_VALIDATOR=str(REPO_ROOT / "tool/validate_china_idols_seed.py"),
                            OTA_IDOL_PYTHON=sys.executable,
                            OTA_IDOL_LOCK_FILE=str(directory / "update.lock"),
                            OTA_IDOL_MIN_GROUPS="0", OTA_IDOL_MIN_MEMBERS="0",
                            CAPTURE_ARGS=str(capture),
                        )
                        if override:
                            environment["OTA_IDOL_WEIBO_FILE"] = str(weibo)
                        result = subprocess.run(
                            ["bash", str(REPO_ROOT / "tool/run_idol_seed_update.sh")],
                            env=environment, capture_output=True, text=True,
                        )
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        args = json.loads(capture.read_text(encoding="utf-8"))
                        expected = ["--manual", str(directory / "manual_idols.json")]
                        if state == "nonempty":
                            expected += ["--manual", str(weibo)]
                        self.assertEqual(args[2:], expected)
                        self.assertTrue((directory / "public/data/china_idols_seed.json").is_file())


if __name__ == "__main__":
    unittest.main()
