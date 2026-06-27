from __future__ import annotations

import unittest

from tool.validate_china_idols_seed import SeedValidationError, validate_payload


class ValidateChinaIdolsSeedTest(unittest.TestCase):
    def test_accepts_payload_with_groups_and_members(self) -> None:
        summary = validate_payload(
            {
                "sourceUrl": "https://example.com/wiki",
                "sourceLabel": "中国偶像 Wiki",
                "generatedAt": "2026-06-18T00:00:00+00:00",
                "groups": [
                    {
                        "name": "测试团",
                        "members": [{"name": "小明", "status": "现成员"}],
                    }
                ],
            },
            min_groups=1,
            min_members=1,
        )

        self.assertEqual(summary.group_count, 1)
        self.assertEqual(summary.member_count, 1)

    def test_rejects_payload_with_too_few_groups(self) -> None:
        with self.assertRaisesRegex(SeedValidationError, "Expected at least 1 groups"):
            validate_payload(
                {
                    "sourceUrl": "https://example.com/wiki",
                    "sourceLabel": "中国偶像 Wiki",
                    "generatedAt": "2026-06-18T00:00:00+00:00",
                    "groups": [],
                },
                min_groups=1,
            )


if __name__ == "__main__":
    unittest.main()
