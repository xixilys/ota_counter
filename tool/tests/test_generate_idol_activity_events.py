from __future__ import annotations

import unittest

from tool.generate_idol_activity_events import extract_ticket_info, generate_payload


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
                        "description": "🎫门票 一般：¥25 三人票：¥50 当日：¥75",
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
        self.assertFalse(detail["isFree"])
        self.assertEqual(
            detail["ticketTiers"],
            [
                {"name": "普通", "price": 25.0},
                {"name": "三人", "price": 50.0},
                {"name": "当日", "price": 75.0},
            ],
        )

        fallback = payload["events"][1]
        self.assertTrue(fallback["sourceEventId"].startswith("minecool-group-"))
        self.assertEqual(fallback["eventName"], "测试团单独行程")
        self.assertFalse(fallback["isFree"])
        self.assertEqual(fallback["ticketTiers"], [])

    def test_extract_ticket_info_handles_free_premium_and_lottery_noise(self) -> None:
        free = extract_ticket_info(["🎫门票：无料入场，VIP票：66元"])
        self.assertTrue(free["isFree"])
        self.assertEqual(free["ticketTiers"], [{"name": "VIP", "price": 66.0}])

        lottery = extract_ticket_info(["本条抽入场门票 2 张"])
        self.assertEqual(lottery, {"isFree": False, "ticketTiers": []})

        points = extract_ticket_info(["普通票2000积分兑换"])
        self.assertEqual(points, {"isFree": False, "ticketTiers": []})

        presale = extract_ticket_info(["票价：预售/59 现场/69"])
        self.assertEqual(
            presale["ticketTiers"],
            [
                {"name": "预售", "price": 59.0},
                {"name": "现场", "price": 69.0},
            ],
        )


if __name__ == "__main__":
    unittest.main()
