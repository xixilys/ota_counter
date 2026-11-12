from __future__ import annotations

import unittest

from tool.generate_idol_activity_events import (
    clean_event_name,
    clean_venue,
    extract_ticket_info,
    extract_times,
    generate_payload,
)


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

    def test_clean_venue_drops_title_fragments_and_keeps_real_venues(self) -> None:
        self.assertEqual(
            clean_venue("rellas熠期一会Live", "青岛", "Estrellas熠期一会Live Vol.55"), "")
        self.assertEqual(
            clean_venue("mp;小季Ameku生日Live", "广州", "枕星而眠"), "")
        self.assertEqual(clean_venue("上海", "上海", "测试活动"), "")
        self.assertEqual(
            clean_venue("📍活动地点：ThreeLive", "上海", "感電注意 IDOL LIVE Vol.19"),
            "ThreeLive")
        self.assertEqual(clean_venue("MAO Livehouse", "上海", "ULTIMATUM GAME"),
                         "MAO Livehouse")
        self.assertEqual(clean_venue("又又中心", "上海", "绮丽偶像日mini Vol.184"),
                         "又又中心")

    def test_clean_event_name_unescapes_and_drops_tba(self) -> None:
        self.assertEqual(clean_event_name("笼中吟&amp;林间歌"), "笼中吟&林间歌")
        self.assertEqual(clean_event_name("广州 ？？？", "广州"), "")
        self.assertEqual(clean_event_name("Miami？", "北京"), "")
        self.assertEqual(
            clean_event_name("我推变成魔法少女了怎么办！？", "广州"),
            "我推变成魔法少女了怎么办！？")
        self.assertEqual(clean_event_name("x" * 81), "")

    def test_extract_times_reads_only_explicit_open_start_wording(self) -> None:
        self.assertEqual(extract_times("OPEN 13:45 START 14:00"),
                         {"openTime": "13:45", "startTime": "14:00"})
        self.assertEqual(extract_times("时间：15:10入场｜15:30正式开演"),
                         {"openTime": "15:10", "startTime": "15:30"})
        self.assertEqual(extract_times("开场时间：12:40 开演时间：13:00"),
                         {"openTime": "12:40", "startTime": "13:00"})
        self.assertEqual(extract_times("9 月 25 日见"), {"openTime": "", "startTime": ""})

    def test_generate_payload_merges_rows_for_the_same_event(self) -> None:
        detail = {
            "date": "2026-09-25",
            "city": "上海",
            "event_name": "测试活动",
            "venue": "",
            "description": "OPEN 13:30 START 14:00",
            "detail_mid": "1",
        }
        groups = [
            {"username": "甲团", "uid": "1", "events": [
                {"date": "2026-09-25", "city": "上海", "venue": "", "event": "测试活动"}]},
            {"username": "乙团", "uid": "2", "events": [
                {"date": "2026-09-25", "city": "上海", "venue": "", "event": "测试活动"}]},
        ]
        payload = generate_payload({"groups": groups}, {"events": [detail]})
        self.assertEqual(payload["totalEvents"], 1)
        event = payload["events"][0]
        self.assertEqual(event["eventName"], "测试活动")
        self.assertEqual(event["openTime"], "13:30")
        self.assertEqual(event["startTime"], "14:00")
        self.assertEqual({group["uid"] for group in event["groups"]}, {"1", "2"})

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
