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

        self.assertEqual(payload["sourceLabel"], "中国偶像 Wiki")
        self.assertEqual(payload["groups"], [
            {
                "name": "测试团",
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
                "members": [
                    {"name": "兔兔Miottie", "status": "正式成员 / 粉色担当"}
                ],
            },
            payload["groups"],
        )


if __name__ == "__main__":
    unittest.main()
