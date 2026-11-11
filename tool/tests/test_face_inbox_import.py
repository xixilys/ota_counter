import base64
import contextlib
import io
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tool import face_inbox_import as importer  # noqa: E402

PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/"
    "ScLbtAAAAABJRU5ErkJggg=="
)
TOKEN = "synthetic-inbox-secret"


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):  # noqa: A002
        return

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("content-length", "0"))
        body = json.loads(self.rfile.read(length).decode("utf-8"))
        self.server.requests.append(body)
        auth = self.headers.get("authorization")
        if auth != "Bearer " + TOKEN:
            self._send(401, {"ok": False, "error": "unauthorized"})
            return
        params = body.get("params", {})
        arguments = params.get("arguments", {})
        if arguments.get("member") == "坏成员":
            result = {
                "content": [
                    {
                        "type": "text",
                        "text": "匹配到多位成员，请补充 member 与 group：小雪 / 甲团；小雪 / 乙团",
                    }
                ],
                "isError": True,
            }
        else:
            result = {
                "content": [{"type": "text", "text": "queued"}],
                "structuredContent": {
                    "enrollment_id": "act_%d" % len(self.server.requests),
                    "status": "pending",
                },
                "isError": False,
            }
        self._send(200, {"jsonrpc": "2.0", "id": body.get("id"), "result": result})

    def _send(self, status, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class FaceInboxImportTest(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self.server.requests = []
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = "http://127.0.0.1:%d/mcp" % self.server.server_port
        self.tmp = tempfile.TemporaryDirectory()
        self.inbox = Path(self.tmp.name) / "face-inbox"
        self.inbox.mkdir()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.tmp.cleanup()

    def _run(self, argv, env=None):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, env or {}, clear=False):
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = importer.main(argv)
        return code, out.getvalue(), err.getvalue()

    def _folder(self, name, count=1, suffix=".png", size=None):
        folder = self.inbox / name
        folder.mkdir()
        for index in range(count):
            path = folder / ("photo-%d%s" % (index, suffix))
            path.write_bytes(PNG if size is None else b"x" * size)
        return folder

    def test_import_moves_done_and_failed_without_printing_token(self):
        self._folder("小雪@团A", count=2)
        self._folder("坏成员", count=1)
        code, out, err = self._run(
            ["--inbox", str(self.inbox), "--server", self.url],
            {"OTA_SYNC_TOKEN": TOKEN},
        )
        self.assertEqual(code, 1)
        self.assertEqual(len(self.server.requests), 3)
        calls = [item["params"] for item in self.server.requests]
        self.assertTrue(all(call["name"] == "enroll_face" for call in calls))
        good = [call for call in calls if call["arguments"]["member"] == "小雪"]
        self.assertEqual(len(good), 2)
        self.assertEqual(good[0]["arguments"]["group"], "团A")
        self.assertEqual(base64.b64decode(good[0]["arguments"]["image_base64"]), PNG)
        self.assertTrue((self.inbox / "done" / "小雪@团A").is_dir())
        failed = self.inbox / "failed"
        failed_folders = [path for path in failed.rglob("坏成员") if path.is_dir()]
        self.assertEqual(len(failed_folders), 1)
        self.assertIn("匹配到多位成员", out + err)
        self.assertNotIn(TOKEN, out + err)
        self.assertNotIn(TOKEN, json.dumps(self.server.requests))

    def test_dry_run_lists_without_network_or_token(self):
        self._folder("小雪", count=1)
        code, out, err = self._run(["--dry-run", "--inbox", str(self.inbox)])
        self.assertEqual(code, 0)
        self.assertEqual(self.server.requests, [])
        self.assertIn("would send", out)
        self.assertTrue((self.inbox / "小雪").is_dir())

    def test_token_file_and_member_only_folder(self):
        self._folder("小雪", count=1)
        token_file = Path(self.tmp.name) / "token"
        token_file.write_text(TOKEN + "\n", encoding="utf-8")
        code, out, err = self._run(
            [
                "--inbox",
                str(self.inbox),
                "--server",
                self.url,
                "--token-file",
                str(token_file),
            ]
        )
        self.assertEqual(code, 0, out + err)
        arguments = self.server.requests[0]["params"]["arguments"]
        self.assertEqual(arguments["member"], "小雪")
        self.assertNotIn("group", arguments)
        self.assertTrue((self.inbox / "done" / "小雪").is_dir())
        self.assertNotIn(TOKEN, out + err)

    def test_oversize_file_is_skipped_and_valid_one_queued(self):
        folder = self.inbox / "小雪"
        folder.mkdir()
        (folder / "huge.png").write_bytes(b"x" * (importer.MAX_IMAGE_BYTES + 1))
        (folder / "ok.png").write_bytes(PNG)
        code, out, err = self._run(
            ["--inbox", str(self.inbox), "--server", self.url],
            {"OTA_SYNC_TOKEN": TOKEN},
        )
        self.assertEqual(code, 0, out + err)
        self.assertEqual(len(self.server.requests), 1)
        self.assertIn("超过 8 MB", out)
        self.assertTrue((self.inbox / "done" / "小雪").is_dir())

    def test_missing_token_returns_usage_error(self):
        self._folder("小雪")
        code, out, err = self._run(
            ["--inbox", str(self.inbox), "--server", self.url],
            {"OTA_SYNC_TOKEN": ""},
        )
        self.assertEqual(code, 2)
        self.assertIn("OTA_SYNC_TOKEN", err)
        self.assertEqual(self.server.requests, [])

    def test_bad_folder_name_moves_to_failed(self):
        self._folder("@团A")
        code, out, err = self._run(
            ["--inbox", str(self.inbox), "--server", self.url],
            {"OTA_SYNC_TOKEN": TOKEN},
        )
        self.assertEqual(code, 1)
        self.assertEqual(self.server.requests, [])
        folders = [path for path in (self.inbox / "failed").rglob("@团A") if path.is_dir()]
        self.assertEqual(len(folders), 1)


if __name__ == "__main__":
    unittest.main()
