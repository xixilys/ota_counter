from __future__ import annotations

import unittest

from tool.generate_idol_activity_events import generate_payload


class GenerateIdolActivityEventsTest(unittest.TestCase):
    def test_generate_payload_merges_detail_and_group_events(self) -> None:
        payload = generate_payload(
            {
                "generated": "2026-07-06",
                "groups": [
                    {
                        "username": "测试团",
                        "uid": "123",
                        "events": [
                            {
                                "date": "2026-07-10",
                                "city": "上海",
                                "venue": "世界树剧场",
                                "event": "测试团单独行程",
                            }
                        ],
                    }
                ],
            },
            {
                "events": [
                    {
                        "date": "2026-07-10",
                        "city": "上海",
                        "event_name": "HanaFes Vol.30",
                        "venue": "世界树剧场",
                        "open_time": "19:00",
                        "start_time": "19:15",
                        "groups": [{"name": "测试团", "uid": "123"}],
                        "description": "详细说明",
                        "poster": "images/posters/example.jpg",
                        "original_link": "https://weibo.com/example",
                        "original_mid": "456",
                    }
                ]
            },
        )

        self.assertEqual(payload["sourceLabel"], "MineCool 地下偶像行程")
        self.assertEqual(payload["upstreamGenerated"], "2026-07-06")
        self.assertEqual(payload["totalEvents"], 2)

        detail = payload["events"][0]
        self.assertEqual(detail["sourceEventId"], "minecool-detail-456")
        self.assertEqual(detail["eventName"], "HanaFes Vol.30")
        self.assertEqual(detail["posterUrl"], "http://idol.minecool.site/images/posters/example.jpg")
        self.assertEqual(detail["groups"], [{"name": "测试团", "uid": "123"}])

        fallback = payload["events"][1]
        self.assertTrue(fallback["sourceEventId"].startswith("minecool-group-"))
        self.assertEqual(fallback["eventName"], "测试团单独行程")


if __name__ == "__main__":
    unittest.main()
