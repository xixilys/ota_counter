#!/usr/bin/env python3
"""Import a folder of face photos into OTA Counter through the MCP server.

Layout:  ~/.ota-counter/face-inbox/成员名/  or  成员名@团名/
For each image the script calls the `enroll_face` MCP tool with
`image_base64`. Token comes from OTA_SYNC_TOKEN or --token-file; it is never
printed. Processed folders move to done/, failures to failed/<reason>/.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

DEFAULT_INBOX = "~/.ota-counter/face-inbox"
DEFAULT_SERVER = "https://sub.lyszqx.love/ota-sync/mcp"
IMAGE_EXTENSIONS = {
    ".jpg",
    ".jpeg",
    ".png",
    ".webp",
    ".gif",
    ".bmp",
    ".heic",
    ".heif",
}
MAX_IMAGE_BYTES = 8 * 1024 * 1024
MAX_BASE64_BYTES = 8 * 1024 * 1024


class ImporterError(Exception):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        return None


def _read_token(args: argparse.Namespace) -> str:
    if args.token_file:
        try:
            value = Path(args.token_file).expanduser().read_text(encoding="utf-8")
        except OSError as error:
            raise ImporterError("无法读取 token 文件：%s" % error) from None
        token = value.strip()
        if not token:
            raise ImporterError("token 文件为空")
        return token
    token = os.environ.get("OTA_SYNC_TOKEN", "").strip()
    if not token:
        raise ImporterError(
            "未提供同步 token：设置 OTA_SYNC_TOKEN 或使用 --token-file <路径>"
        )
    return token


def _safe_reason(reason: str) -> str:
    cleaned = re.sub(r"[^\w\u4e00-\u9fff-]+", "_", reason.strip())[:48]
    return cleaned or "unknown"


def _parse_folder(name: str) -> tuple[str, str | None]:
    if "@" in name:
        member, group = name.rsplit("@", 1)
        member = member.strip()
        group = group.strip()
        if not member or not group:
            raise ImporterError("文件夹名应为 成员名 或 成员名@团名，例如 小雪@团A")
        return member, group
    member = name.strip()
    if not member:
        raise ImporterError("文件夹名不能为空")
    return member, None


def _image_files(folder: Path) -> list[Path]:
    return sorted(
        [
            path
            for path in folder.iterdir()
            if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS
        ],
        key=lambda path: path.name,
    )


def _move(folder: Path, destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / folder.name
    if target.exists():
        target = destination / (
            "%s-%s" % (folder.name, time.strftime("%Y%m%d-%H%M%S"))
        )
    shutil.move(str(folder), str(target))
    return target


def _post_mcp(
    server: str,
    token: str,
    arguments: dict[str, object],
    timeout: float,
) -> dict[str, object]:
    body = json.dumps(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "enroll_face", "arguments": arguments},
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        server,
        data=body,
        method="POST",
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "ota-counter-face-inbox/1.6.1",
        },
    )
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(request, timeout=timeout) as response:
            text = response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")
        try:
            parsed = json.loads(detail)
            message = parsed.get("error") or parsed.get("message") or ""
        except (ValueError, AttributeError):
            message = ""
        raise ImporterError(
            message or "同步服务返回 HTTP %s" % error.code
        ) from None
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise ImporterError("连不上同步服务：%s" % error) from None
    try:
        decoded = json.loads(text)
    except ValueError:
        raise ImporterError("同步服务返回了无法解析的数据") from None
    if not isinstance(decoded, dict):
        raise ImporterError("同步服务返回格式无效")
    if decoded.get("error") is not None:
        message = decoded["error"]
        if isinstance(message, dict):
            message = message.get("message")
        raise ImporterError(str(message or "MCP 请求失败"))
    result = decoded.get("result")
    if not isinstance(result, dict):
        raise ImporterError("MCP 响应缺少 result")
    if result.get("isError") is True:
        content = result.get("content")
        message = "脸照录入失败"
        if isinstance(content, list) and content:
            first = content[0]
            if isinstance(first, dict) and first.get("text"):
                message = str(first["text"])
        raise ImporterError(message)
    structured = result.get("structuredContent")
    if not isinstance(structured, dict):
        raise ImporterError("MCP 响应缺少 structuredContent")
    return structured


def _process_folder(
    folder: Path,
    server: str,
    token: str,
    timeout: float,
) -> tuple[int, int]:
    member, group = _parse_folder(folder.name)
    images = _image_files(folder)
    if not images:
        raise ImporterError("文件夹里没有支持的图片")
    print("folder %s -> %s" % (folder.name, member if group is None else member + "@" + group))
    queued = 0
    skipped = 0
    for path in images:
        raw_size = path.stat().st_size
        if raw_size > MAX_IMAGE_BYTES:
            print("skip %s: 文件超过 8 MB (%d bytes)" % (path.name, raw_size))
            skipped += 1
            continue
        data = path.read_bytes()
        encoded = base64.b64encode(data).decode("ascii")
        if len(encoded) > MAX_BASE64_BYTES:
            print("skip %s: base64 编码后超过 8 MB" % path.name)
            skipped += 1
            continue
        arguments: dict[str, object] = {"image_base64": encoded}
        if group is None:
            arguments["member"] = member
        else:
            arguments["member"] = member
            arguments["group"] = group
        result = _post_mcp(server, token, arguments, timeout)
        enrollment_id = result.get("enrollment_id") or result.get("action_id")
        print("queued %s/%s -> %s" % (folder.name, path.name, enrollment_id))
        queued += 1
    if queued == 0:
        raise ImporterError("没有可用图片（全部超限）")
    if skipped:
        print("folder %s: %d 张已排队，%d 张跳过" % (folder.name, queued, skipped))
    return queued, skipped


def _dry_run(inbox: Path) -> None:
    for folder in sorted(inbox.iterdir()):
        if not folder.is_dir() or folder.name in {"done", "failed"}:
            continue
        try:
            member, group = _parse_folder(folder.name)
            images = _image_files(folder)
            target = member if group is None else member + "@" + group
            if not images:
                print("would fail %s: 没有支持的图片" % folder.name)
                continue
            for path in images:
                size = path.stat().st_size
                encoded_size = 4 * ((size + 2) // 3)
                if size > MAX_IMAGE_BYTES or encoded_size > MAX_BASE64_BYTES:
                    print("would skip %s/%s: 超过 8 MB" % (folder.name, path.name))
                else:
                    print(
                        "would send %s/%s -> %s (base64 %d bytes)"
                        % (folder.name, path.name, target, encoded_size)
                    )
        except ImporterError as error:
            print("would fail %s: %s" % (folder.name, error))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="扫描脸照文件夹，通过 MCP enroll_face 排队导入。"
    )
    parser.add_argument(
        "--inbox",
        default=os.environ.get("OTA_FACE_INBOX", DEFAULT_INBOX),
        help="脸照根目录（默认 ~/.ota-counter/face-inbox）",
    )
    parser.add_argument(
        "--server",
        default=os.environ.get("OTA_SYNC_MCP_URL", DEFAULT_SERVER),
        help="MCP HTTP 地址（默认 %s）" % DEFAULT_SERVER,
    )
    parser.add_argument(
        "--token-file",
        help="从文件读取同步 token；否则读取 OTA_SYNC_TOKEN",
    )
    parser.add_argument("--dry-run", action="store_true", help="只列出将发送的内容")
    parser.add_argument(
        "--timeout", type=float, default=30.0, help="单次请求超时秒数（默认 30）"
    )
    args = parser.parse_args(argv)
    inbox = Path(os.path.expanduser(args.inbox))
    if not inbox.is_dir():
        print("脸照目录不存在：%s" % inbox, file=sys.stderr)
        return 2
    if args.dry_run:
        _dry_run(inbox)
        return 0
    try:
        token = _read_token(args)
    except ImporterError as error:
        print(str(error), file=sys.stderr)
        return 2
    if not args.server.startswith(("http://", "https://")):
        print("--server 必须是 HTTP(S) MCP 地址", file=sys.stderr)
        return 2
    parsed = urllib.parse.urlparse(args.server)
    if "token" in urllib.parse.parse_qs(parsed.query):
        print("不要把 token 放进 --server URL；请用 OTA_SYNC_TOKEN 或 --token-file", file=sys.stderr)
        return 2

    failures = 0
    processed = 0
    for folder in sorted(inbox.iterdir()):
        if not folder.is_dir() or folder.name in {"done", "failed"}:
            continue
        try:
            _process_folder(folder, args.server, token, args.timeout)
        except ImporterError as error:
            failures += 1
            reason = _safe_reason(str(error))
            target = _move(folder, inbox / "failed" / reason)
            print(
                "failed %s: %s -> %s" % (folder.name, error, target),
                file=sys.stderr,
            )
            continue
        except Exception as error:  # noqa: BLE001 - move the folder, never dump token
            failures += 1
            reason = _safe_reason(error.__class__.__name__)
            target = _move(folder, inbox / "failed" / reason)
            print(
                "failed %s: %s -> %s" % (folder.name, error.__class__.__name__, target),
                file=sys.stderr,
            )
            continue
        processed += 1
        target = _move(folder, inbox / "done")
        print("done %s -> %s" % (folder.name, target))
    print("finished: %d done, %d failed" % (processed, failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
