"""Offline contract tests: never read browser credentials or contact a service."""

from __future__ import annotations

import copy
import json
import os
import sys
import tempfile
import unittest
from contextlib import ExitStack
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import Mock, call, patch

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from tool import weibo_idol_updater as updater  # noqa: E402

REAL_CLIENT = updater.WeiboClient
REAL_EXTRACT_MEMBERS = updater.extract_members

NOW = datetime(2026, 11, 9, 12, tzinfo=timezone.utc)


def event(days_ago, *groups):
    return {"date": (NOW - timedelta(days=days_ago)).date().isoformat(),
            "groups": list(groups)}


def group(name, uid):
    return {"name": name, "uid": uid}


class SelectionTest(unittest.TestCase):
    def test_clean_names_preserve_identity_and_are_idempotent(self):
        for name in ("星空", "Aster", "星空Project", "七色☆光"):
            with self.subTest(name=name):
                self.assertEqual(updater.clean_group_name(name), name)
                cleaned = updater.clean_group_name("  " + name + "  ")
                self.assertEqual(cleaned, name)
                self.assertEqual(updater.clean_group_name(cleaned), cleaned)

    def test_normalization_ignores_ascii_case_and_spaces(self):
        self.assertEqual(updater.normalize_group_name(" ASTER "),
                         updater.normalize_group_name("aster"))

    def test_official_suffix_is_removed_case_insensitively_only_at_end(self):
        for name in ("星空official", "星空_Official", " 星空-OFFICIAL "):
            with self.subTest(name=name):
                self.assertEqual(updater.clean_group_name(name), "星空")
        self.assertEqual(updater.clean_group_name("Official星空"), "Official星空")
        self.assertEqual(updater.normalize_group_name(" Aster_Official "), "aster")

    def test_date_window_uid_seed_containment_and_cooldown(self):
        events = [
            event(1, group("新团", "1")),
            event(90, group("边界团", "2")),
            event(91, group("过期团", "3")),
            event(-1, group("未来团", "4")),
            event(1, group("无UID", "")),
            event(1, group("星空", "5"), group("星空偶像", "6")),
            event(1, group("冷却团", "7"), group("刚满七天", "8")),
            event(2, group("新团", "1")),
        ]
        state = {"7": (NOW - timedelta(days=6)).isoformat(),
                 "8": (NOW - timedelta(days=7)).isoformat()}
        selected = updater.select_groups(events, [{"name": "星空偶像计划"}], state, NOW, 25)
        self.assertEqual({item["uid"] for item in selected}, {"1", "2", "8"})
        self.assertEqual(len(selected), 3)

    def test_unchecked_groups_come_in_random_order_with_rng(self):
        import random as _random
        events = [event(1, *[group(f"团{i}", str(i)) for i in range(1, 9)])]
        state = {"8": (NOW - timedelta(days=30)).isoformat()}
        orders = {tuple(item["uid"] for item in updater.select_groups(
            events, [], state, NOW, 8, rng=_random.Random(seed)))
            for seed in range(5)}
        self.assertGreater(len(orders), 1)
        for order in orders:
            self.assertEqual(order[-1], "8")  # checked groups still last

    def test_groups_this_tool_published_are_still_rechecked(self):
        events = [event(1, group("微博团", "1"), group("维基团", "2"))]
        seed = [{"name": "微博团", "sourceLabel": updater.SOURCE_LABEL},
                {"name": "维基团", "sourceLabel": "中国偶像 Wiki（社区）"}]
        selected = updater.select_groups(events, seed, {}, NOW, 25)
        self.assertEqual([item["uid"] for item in selected], ["1"])

    def test_unchecked_first_then_oldest_checked_and_limit_rotation(self):
        events = [event(1, group("近期团", "1"), group("旧团", "2"),
                        group("未查团", "3"), group("另一未查团", "4"))]
        state = {"1": (NOW - timedelta(days=8)).isoformat(),
                 "2": (NOW - timedelta(days=30)).isoformat()}
        selected = updater.select_groups(events, [], state, NOW, 3)
        self.assertEqual({item["uid"] for item in selected[:2]}, {"3", "4"})
        self.assertEqual(selected[2]["uid"], "2")
        for item in selected:
            state[item["uid"]] = NOW.isoformat()
        self.assertEqual(updater.select_groups(events, [], state, NOW, 3), [group("近期团", "1")])


class MergeTest(unittest.TestCase):
    def test_repeated_runs_accumulate_without_duplicate_groups_or_members(self):
        original = {"sourceLabel": "微博", "groups": [
            {"name": "旧团", "members": [{"name": "小旧", "status": "现成员"}]},
        ]}
        before = copy.deepcopy(original)
        target = group("新团", "123")
        first_members = [{"name": "小春", "status": "现成员"}]
        first, count, is_new = updater.merge_additions(original, target, first_members, NOW.isoformat())
        self.assertEqual((count, is_new), (1, True))
        self.assertEqual(original, before, "merge must not mutate its input")
        second, count, is_new = updater.merge_additions(first, target, [
            {"name": "小春", "status": "现成员"},
            {"name": "小夏", "status": "现成员"},
        ], NOW.isoformat())
        self.assertEqual((count, is_new), (1, False))
        third, count, is_new = updater.merge_additions(second, target, first_members, NOW.isoformat())
        self.assertEqual((count, is_new), (0, False))
        self.assertEqual(len(third["groups"]), 2)
        self.assertEqual(next(g for g in third["groups"] if g["name"] == "旧团")["members"],
                         before["groups"][0]["members"])
        self.assertCountEqual([m["name"] for g in third["groups"] if g["name"] == "新团"
                               for m in g["members"]], ["小春", "小夏"])

    def test_existing_status_and_other_fields_are_never_overwritten(self):
        original = {"sourceLabel": "微博", "groups": [{
            "name": "星空", "sourceUrl": "https://weibo.com/u/123",
            "note": "保留", "members": [{"name": "Alice", "status": "见习成员", "note": "保留"}],
        }]}
        merged, count, is_new = updater.merge_additions(original, group("星空Official", "123"), [
            {"name": "alice", "status": "正式成员"},
        ], NOW.isoformat())
        self.assertEqual((count, is_new), (0, False))
        self.assertEqual(merged["groups"][0]["members"], original["groups"][0]["members"])
        self.assertEqual(merged["groups"][0]["note"], "保留")


class MemberGuardsTest(unittest.TestCase):
    def filter(self, candidates, posts, seed_groups=None):
        return updater.filter_members("星空", candidates, posts, seed_groups or [])

    def test_accepts_grounded_current_and_trainee_members_and_cleans_suffix(self):
        accepted, rejected, overflow = self.filter([
            {"name": "@小春_星空", "status": "正式成员"},
            {"name": "小夏", "status": "见习成员"},
        ], ["成员介绍：@小春_星空\n见习成员 小夏"])
        self.assertEqual(accepted, [{"name": "小春", "status": "正式成员"},
                                    {"name": "小夏", "status": "见习成员"}])
        self.assertEqual(rejected, [])
        self.assertFalse(overflow)

    def test_length_url_group_and_noise_names_are_rejected(self):
        names = ["", "长" * 21, "https://a.cn", "example.io", "ftp://host/path",
                 "星空", "运营", "官方", "staff"]
        accepted, rejected, overflow = self.filter([
            {"name": name, "status": "正式成员"} for name in names
        ], ["\n".join(names)])
        self.assertEqual(accepted, [])
        self.assertEqual(len(rejected), len(names))
        self.assertTrue(all(item["reason"] for item in rejected))
        self.assertFalse(overflow)

    def test_name_length_boundaries_are_inclusive(self):
        names = ["春", "夏" * 20]
        candidates = [{"name": name, "status": "正式成员"} for name in names]
        self.assertEqual(self.filter(candidates, ["成员：" + "、".join(names)])[0], candidates)

    def test_only_official_and_trainee_statuses_are_allowed(self):
        candidates = [{"name": name, "status": status} for name, status in (
            ("小春", "毕业成员"), ("小夏", "前成员"), ("小秋", "运营"), ("小冬", "未分类"),
        )]
        accepted, rejected, overflow = self.filter(candidates, ["小春 小夏 小秋 小冬"])
        self.assertEqual(accepted, [])
        self.assertEqual(len(rejected), 4)
        self.assertFalse(overflow)

    def test_unmentioned_inactive_and_conflicting_mentions_are_rejected(self):
        candidates = [{"name": name, "status": "正式成员"}
                      for name in ("凭空名字", "小春", "小夏", "小秋")]
        accepted, rejected, _ = self.filter(candidates, [
            "小春毕业公告\n前成员小夏\n小秋毕业公告", "正式成员：小秋",
        ])
        self.assertEqual(accepted, [])
        self.assertEqual({item["name"] for item in rejected}, {"凭空名字", "小春", "小夏", "小秋"})

    def test_graduation_evidence_overrides_extractor_current_status_in_either_order(self):
        candidate = {"name": "小秋", "status": "正式成员"}
        for posts in (["正式成员：小秋", "小秋毕业公告"],
                      ["小秋毕业公告", "正式成员：小秋"],
                      ["小秋已毕业，不再是正式成员"]):
            with self.subTest(posts=posts):
                accepted, rejected, overflow = self.filter([candidate], posts)
                self.assertEqual(accepted, [])
                self.assertEqual([item["name"] for item in rejected], ["小秋"])
                self.assertTrue(rejected[0]["reason"])
                self.assertFalse(overflow)

    def test_inactive_heading_and_name_on_separate_lines_reject_entire_post(self):
        candidate = {"name": "小春", "status": "正式成员"}
        for heading in ("毕业公告", "前成员名单", "离团公告"):
            for posts in ([heading + "\n小春", "正式成员：小春"],
                          ["正式成员：小春", heading + "\n小春"]):
                with self.subTest(posts=posts):
                    accepted, rejected, overflow = self.filter([candidate], posts)
                    self.assertEqual(accepted, [])
                    self.assertEqual([item["name"] for item in rejected], ["小春"])
                    self.assertTrue(rejected[0]["reason"])
                    self.assertFalse(overflow)

    def test_inactive_evidence_does_not_cross_independent_post_boundaries(self):
        candidate = {"name": "小春", "status": "正式成员"}
        accepted, rejected, overflow = self.filter([candidate], [
            "毕业公告\n小夏", "正式成员：小春",
        ])
        self.assertEqual(accepted, [candidate])
        self.assertEqual(rejected, [])
        self.assertFalse(overflow)

    def test_seed_and_batch_duplicates_use_normalized_names_and_matching_group(self):
        candidates = [{"name": name, "status": "正式成员"}
                      for name in ("Alice", "小春", "小春", "小夏")]
        seeds = [{"name": "星空Official", "members": [{"name": "ALICE", "status": "见习成员"}]},
                 {"name": "其他团", "members": [{"name": "小夏", "status": "正式成员"}]}]
        accepted, rejected, _ = self.filter(candidates, ["Alice 小春 小夏"], seeds)
        self.assertEqual([item["name"] for item in accepted], ["小春", "小夏"])
        self.assertEqual({item["name"] for item in rejected}, {"Alice", "小春"})

    def test_thirteen_members_rejects_whole_group_not_truncates(self):
        candidates = [{"name": "成员%d" % i, "status": "正式成员"} for i in range(13)]
        accepted, rejected, overflow = self.filter(candidates, [" ".join(c["name"] for c in candidates)])
        self.assertEqual(accepted, [])
        self.assertTrue(rejected)
        self.assertTrue(overflow)
        accepted, rejected, overflow = self.filter(candidates[:12], [" ".join(c["name"] for c in candidates)])
        self.assertEqual(len(accepted), 12)
        self.assertFalse(overflow)


class OfflineTest(unittest.TestCase):
    """Fail closed if any test accidentally reaches outside its mocks."""

    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(updater.browser_cookie3, "edge", return_value=[]))
        self.stack.enter_context(patch("requests.sessions.Session.request", side_effect=AssertionError("Real HTTP forbidden")))
        self.stack.enter_context(patch("socket.socket.connect", side_effect=AssertionError("Real socket forbidden")))
        self.process = self.stack.enter_context(patch.object(updater.subprocess, "run", side_effect=AssertionError("Real subprocess forbidden")))
        self.sleep = self.stack.enter_context(patch.object(updater.time, "sleep"))


class MainTest(OfflineTest):
    def setUp(self):
        super().setUp()
        self.directory = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.stack.enter_context(patch.dict(os.environ, {
            "OTA_WEIBO_IDOLS_DIR": str(self.directory), "OTA_WEIBO_MAX_REQUESTS": "",
        }))
        # main() shuffles unchecked groups; keep event order so outcomes are deterministic.
        self.stack.enter_context(patch.object(updater.random, "Random",
                                              return_value=Mock(shuffle=lambda items: None)))
        self.logger = self.stack.enter_context(patch.object(updater, "setup_logging", return_value=Mock()))
        self.output = self.directory / "weibo_idols.json"
        self.state = self.directory / "state.json"
        self.original = {"sourceLabel": "微博", "groups": [
            {"name": "旧团", "members": [{"name": "小旧", "status": "正式成员"}]},
        ]}
        self.output.write_text(json.dumps(self.original, ensure_ascii=False), encoding="utf-8")
        self.state.write_text('{"999": "2020-01-01T00:00:00+00:00"}', encoding="utf-8")
        self.original_output = self.output.read_bytes()
        self.original_state = self.state.read_bytes()
        recent = datetime.now(timezone(timedelta(hours=8))).date().isoformat()
        self.events = [{"date": recent, "groups": [group("新团", "123")]}]
        self.download = self.stack.enter_context(patch.object(updater, "download_json", side_effect=self.download_json))
        self.client_type = self.stack.enter_context(patch.object(updater, "WeiboClient"))
        self.client = self.client_type.return_value
        self.client.posts.return_value = (["正式成员：小春、小夏"], 0)
        self.extract = self.stack.enter_context(patch.object(updater, "extract_members", return_value=[
            {"name": "小春", "status": "正式成员"},
        ]))

    def download_json(self, url):
        if url == updater.SEED_URL:
            return {"groups": []}
        if url == updater.EVENTS_URL:
            return {"events": self.events}
        self.fail("Unexpected download URL")

    def assert_original_files(self):
        self.assertEqual(self.output.read_bytes(), self.original_output)
        self.assertEqual(self.state.read_bytes(), self.original_state)

    def test_dry_run_logs_but_does_not_consume_rotation_or_write_output(self):
        self.assertEqual(updater.main(["--dry-run"]), 0)
        self.assert_original_files()
        self.assertTrue(self.logger.return_value.info.called)
        self.process.assert_not_called()
        self.assertEqual(updater.main([]), 0)
        self.assertEqual(self.client.posts.call_count, 2, "dry-run must not cool down this group")
        self.assertIn("123", json.loads(self.state.read_text(encoding="utf-8")))

    def test_success_accumulates_and_next_run_obeys_cooldown(self):
        self.assertEqual(updater.main([]), 0)
        result = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual([item["name"] for item in result["groups"]], ["旧团", "新团"])
        self.assertEqual(updater.main([]), 0)
        self.assertEqual(self.client.posts.call_count, 1)
        self.assertEqual(json.loads(self.output.read_text(encoding="utf-8")), result)
        self.process.assert_not_called()

    def test_new_members_upgrade_legacy_or_missing_source_label(self):
        for old_label in ("微博", None):
            with self.subTest(old_label=old_label):
                payload = copy.deepcopy(self.original)
                if old_label is None:
                    payload.pop("sourceLabel")
                self.output.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
                self.state.write_bytes(self.original_state)
                self.assertEqual(updater.main([]), 0)
                result = json.loads(self.output.read_text(encoding="utf-8"))
                self.assertEqual(result["sourceLabel"], "微博自动补充")
                self.assertEqual(result["groups"][0], payload["groups"][0])
                self.assertEqual(result["groups"][1]["members"], [
                    {"name": "小春", "status": "正式成员"},
                ])
        self.assertEqual(self.client.posts.call_count, 2)
        self.process.assert_not_called()

    def test_publish_existing_output_without_additions_upgrades_source_label_first(self):
        self.events = []

        def publish(command, **kwargs):
            self.assertEqual(command, [
                "scp", str(self.output), "test-host:/opt/ota-counter-idol-updater/weibo_idols.json",
            ])
            self.assertEqual(kwargs, {"check": True})
            # Check the actual artifact presented to scp, not just the final file.
            published = json.loads(Path(command[1]).read_text(encoding="utf-8"))
            self.assertEqual(published["sourceLabel"], "微博自动补充")
            self.assertEqual(published["groups"], self.original["groups"])
            return Mock(returncode=0)

        self.process.side_effect = publish
        for old_label in ("微博", None):
            with self.subTest(old_label=old_label):
                payload = copy.deepcopy(self.original)
                if old_label is None:
                    payload.pop("sourceLabel")
                self.output.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
                with patch.dict(os.environ, {"OTA_IDOL_WEIBO_SSH_HOST": "test-host"}):
                    self.assertEqual(updater.main(["--publish"]), 0)
                self.assertEqual(json.loads(self.output.read_text(encoding="utf-8")), {
                    "sourceLabel": "微博自动补充", "groups": payload["groups"],
                })
        self.assertEqual(self.process.call_count, 2)
        self.client_type.assert_not_called()
        self.extract.assert_not_called()

    def test_independent_rerun_after_cooldown_deduplicates_and_accumulates(self):
        self.assertEqual(updater.main([]), 0)
        state = json.loads(self.state.read_text(encoding="utf-8"))
        state["123"] = (datetime.now(timezone.utc) - timedelta(days=8)).isoformat()
        self.state.write_text(json.dumps(state), encoding="utf-8")
        self.extract.return_value = [
            {"name": "小春", "status": "正式成员"},
            {"name": "小夏", "status": "见习成员"},
        ]
        self.assertEqual(updater.main([]), 0)
        result = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(self.client_type.call_count, 2)
        self.assertEqual(len(result["groups"]), 2)
        self.assertEqual(result["groups"][0], self.original["groups"][0])
        self.assertEqual(result["groups"][1]["members"], [
            {"name": "小春", "status": "正式成员"},
            {"name": "小夏", "status": "见习成员"},
        ])
        self.assertIn("999", json.loads(self.state.read_text(encoding="utf-8")))
        self.process.assert_not_called()

    def test_max_new_overflow_rolls_back_entire_batch_and_never_publishes(self):
        self.events[0]["groups"].append(group("另一团", "456"))
        self.assertEqual(updater.main(["--max-new", "1", "--publish"]), 4)
        self.assertEqual(self.client.posts.call_count, 2)
        self.assert_original_files()
        self.process.assert_not_called()

    def test_login_expired_after_prior_success_rolls_back_entire_batch(self):
        self.events[0]["groups"].append(group("另一团", "456"))
        self.client.posts.side_effect = [(["正式成员：小春"], 0), updater.LoginExpired()]
        self.assertEqual(updater.main(["--publish"]), 3)
        self.assert_original_files()
        self.process.assert_not_called()
        self.logger.return_value.error.assert_any_call(updater.LOGIN_MESSAGE)

    def test_http_auth_failures_and_login_page_exit_three_without_writes(self):
        cases = [
            (401, {}, ""), (403, {}, ""), (432, {}, ""),
            (302, {"Location": "https://passport.weibo.com/login"}, ""),
            (200, {}, "<!DOCTYPE html><html>请登录 login</html>"),
        ]
        for status, headers, text in cases:
            with self.subTest(status=status):
                session = Mock()
                session.get.return_value = Mock(status_code=status, headers=headers, text=text)
                with patch.object(updater, "WeiboClient", REAL_CLIENT), \
                        patch.object(updater.requests, "Session", return_value=session):
                    self.assertEqual(updater.main(["--publish"]), 3)
                self.assert_original_files()
        self.extract.assert_not_called()
        self.process.assert_not_called()

    def test_json_please_login_exits_three_and_preserves_files(self):
        self.process.side_effect = None
        self.process.return_value = Mock(returncode=0)
        session = Mock()
        session.get.return_value = Mock(status_code=200, headers={}, text='{"ok":0,"msg":"请登录"}')
        session.get.return_value.json.return_value = {"ok": 0, "msg": "请登录"}
        with patch.object(updater, "WeiboClient", REAL_CLIENT), \
                patch.object(updater.requests, "Session", return_value=session):
            self.assertEqual(updater.main(["--publish"]), 3)
        self.assert_original_files()
        self.extract.assert_not_called()
        self.process.assert_not_called()

    def test_fetch_failure_does_not_cool_down_uid_and_other_group_is_published(self):
        self.events[0]["groups"].append(group("成功团", "456"))
        self.client.posts.side_effect = [updater.FetchError("离线模拟失败"), (["正式成员：小春"], 0)]
        self.process.side_effect = None
        self.process.return_value = Mock(returncode=0)
        self.assertEqual(updater.main(["--publish"]), 0)
        self.assertEqual(self.client.posts.call_count, 2)
        self.assertEqual([item["name"] for item in json.loads(self.output.read_text(encoding="utf-8"))["groups"]],
                         ["旧团", "成功团"])
        self.process.assert_called_once()
        self.assertEqual(self.process.call_args.args[0][0], "scp")
        state = json.loads(self.state.read_text(encoding="utf-8"))
        self.assertIn("456", state)
        self.assertNotIn("123", state, "FetchError must not consume the failed UID's cooldown")
        self.assertIn("999", state)

    def test_dsh_failure_does_not_cool_down_uid_and_other_group_is_published(self):
        self.events[0]["groups"].append(group("成功团", "456"))
        dsh_calls = []

        def run(command, **kwargs):
            if command[0] == "dsh":
                dsh_calls.append(command)
                if len(dsh_calls) == 1:
                    raise updater.subprocess.CalledProcessError(1, command)
                return Mock(returncode=0, stdout=json.dumps({"members": [
                    {"name": "小春", "status": "正式成员"},
                ]}))
            self.assertEqual(command[0], "scp")
            return Mock(returncode=0)

        self.process.side_effect = run
        with patch.object(updater, "extract_members", REAL_EXTRACT_MEMBERS):
            self.assertEqual(updater.main(["--publish"]), 0)
        self.assertEqual(len(dsh_calls), 2)
        self.assertEqual(self.client.posts.call_count, 2)
        self.assertEqual(self.process.call_args.args[0][0], "scp")
        self.assertEqual([item["name"] for item in json.loads(self.output.read_text(encoding="utf-8"))["groups"]],
                         ["旧团", "成功团"])
        state = json.loads(self.state.read_text(encoding="utf-8"))
        self.assertIn("456", state)
        self.assertNotIn("123", state, "dsh failure must not consume the failed UID's cooldown")
        self.assertIn("999", state)

    def test_publish_calls_only_mocked_scp_with_accumulated_output(self):
        self.process.side_effect = None
        self.process.return_value = Mock(returncode=0)
        with patch.dict(os.environ, {"OTA_IDOL_WEIBO_SSH_HOST": "test-host"}):
            self.assertEqual(updater.main(["--publish"]), 0)
        self.process.assert_called_once_with([
            "scp", str(self.output), "test-host:/opt/ota-counter-idol-updater/weibo_idols.json",
        ], check=True)
        self.assertEqual(len(json.loads(self.output.read_text(encoding="utf-8"))["groups"]), 2)


class ClientTest(OfflineTest):
    def read_posts(self, statuses, request_limit=None, longtext=None, reserved=0):
        session = Mock()
        payloads = [{"ok": 1}, {"data": {"list": statuses}},
                    {"data": {} if longtext is None else {"longTextContent": longtext}}]
        responses = []
        for payload in payloads:
            response = Mock(status_code=200, headers={}, text=json.dumps(payload))
            response.json.return_value = payload
            responses.append(response)
        session.get.side_effect = responses
        with patch.object(updater.requests, "Session", return_value=session):
            posts, skipped = REAL_CLIENT(request_limit=request_limit).posts("123", reserved=reserved)
        return posts, skipped, session

    def test_budget_limited_longtext_is_not_used_as_evidence(self):
        for limit, reserved in ((2, 0), (3, 1)):
            with self.subTest(limit=limit, reserved=reserved):
                posts, skipped, session = self.read_posts([
                    {"isLongText": True, "mblogid": "long1", "text_raw": "正式成员小秋（截断）"},
                    {"text_raw": "完整短文"},
                ], request_limit=limit, reserved=reserved)
                self.assertEqual(posts, ["完整短文"])
                self.assertEqual(skipped, 1)
                self.assertEqual(session.get.call_count, 2)

    def test_missing_longtext_content_never_falls_back_to_truncated_body(self):
        for content in (None, ""):
            with self.subTest(content=content):
                posts, _, session = self.read_posts([
                    {"isLongText": True, "idstr": "long1", "text_raw": "正式成员小秋（截断）"},
                ], longtext=content)
                self.assertEqual(posts, [])
                self.assertEqual(session.get.call_count, 3)

    def test_longtext_without_id_is_not_used_as_evidence(self):
        posts, _, session = self.read_posts([
            {"isLongText": True, "text": "正式成员小秋（截断）"},
        ])
        self.assertEqual(posts, [])
        self.assertEqual(session.get.call_count, 2)

    def test_completed_longtext_replaces_truncated_body(self):
        posts, skipped, session = self.read_posts([
            {"isLongText": True, "mblogid": "long1", "text_raw": "正式成员小秋（截断）"},
        ], longtext="小秋已毕业，前文为历史资料")
        self.assertEqual(posts, ["小秋已毕业，前文为历史资料"])
        self.assertEqual(skipped, 0)
        self.assertEqual(session.get.call_count, 3)

    def test_all_subsequent_requests_wait_random_three_to_six_seconds(self):
        session = Mock()
        response = Mock(status_code=200, headers={}, text="{}")
        response.json.return_value = {"ok": 1}
        session.get.return_value = response
        with patch.object(updater.requests, "Session", return_value=session), \
                patch.object(updater.random, "uniform", side_effect=[3.25, 5.75]) as uniform:
            client = updater.WeiboClient()
            for _ in range(3):
                client.get_json("/ajax/profile/info", "123", {"uid": "123"})
        self.assertEqual(uniform.call_args_list, [call(3, 6), call(3, 6)])
        self.assertEqual(self.sleep.call_args_list, [call(3.25), call(5.75)])
        self.assertEqual(session.get.call_count, 3)

    def test_login_responses_raise_specific_error_without_extraction(self):
        cases = [
            (401, {}, "", {}), (403, {}, "", {}), (432, {}, "", {}),
            (302, {"Location": "https://passport.weibo.com/login"}, "", {}),
            (200, {}, "<html>请登录 login</html>", {}),
            (200, {}, "{}", {"ok": 0, "msg": "请先登录"}),
            (200, {}, "{}", {"ok": 0, "msg": "请登录"}),
        ]
        for code, headers, text, payload in cases:
            with self.subTest(code=code, payload=payload):
                session = Mock()
                session.get.return_value = Mock(status_code=code, headers=headers, text=text)
                session.get.return_value.json.return_value = payload
                with patch.object(updater.requests, "Session", return_value=session):
                    client = updater.WeiboClient()
                    with self.assertRaises(updater.LoginExpired):
                        client.get_json("/ajax/profile/info", "123", {"uid": "123"})

    def test_cookie_copy_is_saved_and_used_when_edge_is_unreadable(self):
        import http.cookiejar, stat
        cookie = http.cookiejar.Cookie(0, "SUB", "v", None, False, ".weibo.com", True, True,
                                       "/", True, True, None, False, None, None, {})
        jar = http.cookiejar.CookieJar()
        jar.set_cookie(cookie)
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / "cookies.lwp"
            with patch.object(updater.browser_cookie3, "edge", return_value=jar):
                updater.load_cookies(cache)
            self.assertEqual(stat.S_IMODE(cache.stat().st_mode), 0o600)
            with patch.object(updater.browser_cookie3, "edge",
                              side_effect=OSError("authorization denied")):
                loaded = updater.load_cookies(cache)
            self.assertEqual([c.name for c in loaded], ["SUB"])
            with patch.object(updater.browser_cookie3, "edge", side_effect=OSError("denied")):
                with self.assertRaises(OSError):
                    updater.load_cookies(Path(tmp) / "missing.lwp")

if __name__ == "__main__":
    unittest.main()
