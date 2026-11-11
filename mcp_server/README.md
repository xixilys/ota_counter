# OTA Counter Sync / MCP Server

把 OTA Counter 的数据桥接给 AI 助手（Grok Bot、Hermes、Claude Desktop 等），
同时提供 App 可调用的快照同步接口。纯 Dart 标准库实现，**不需要 `pub get`，
不需要 Flutter 引擎**。

## 为什么不是“直接读手机数据库”

Android/iOS 的 App 数据沙盒不能从电脑直接访问，所以这里采用“快照 + 待执行操作”
的本地优先模型：

```text
┌────────────────────┐    POST /api/v1/snapshot     ┌─────────────────────┐
│  OTA Counter App   │ ───────────────────────────▶ │  Sync server        │
│  (SQLite, 手机)    │                              │  state.json         │
│                    │ ◀─────────────────────────── │  (电脑 / 服务器)     │
└────────────────────┘    GET /api/v1/actions       └─────────┬───────────┘
                                                               │ MCP
                                                    ┌──────────▼───────────┐
                                                    │ Grok Bot / Hermes /  │
                                                    │ Claude Desktop       │
                                                    └──────────────────────┘
```

- **读取**：AI 通过 MCP 读服务端最新快照，不直接碰手机。
- **写入**：AI 调用 `record_cheki` / `add_ticket` / 脸照录入工具，服务端只排入
  `pending_actions`；App 下次“一键同步”时拉取、写入 SQLite、再回传新快照。
- App 始终是数据的最终来源；MCP 不会在没有 App 参与的情况下改手机数据。
- 不在同一网络时，把服务端放到有公网入口的机器上，并用 HTTPS / Tailscale /
  WireGuard 保护；不要直接裸奔在公网。

## 部署到服务器

生产部署（Docker Compose / systemd / Nginx HTTPS / 备份）见
[DEPLOY.md](DEPLOY.md)。已有 Docker 的服务器可以用仓库脚本一键部署：

```bash
tool/deploy_mcp_server.sh --dry-run
tool/deploy_mcp_server.sh              # 默认 root@bgvps:/opt/ota-counter-sync，127.0.0.1
tool/deploy_mcp_server.sh --public     # 直接暴露 8787，需自己配防火墙/HTTPS

# 目标只有 systemd、没有 Docker：
tool/build_mcp_server_linux.sh
tool/deploy_mcp_server_binary.sh --dry-run
tool/deploy_mcp_server_binary.sh
```

App 不要求与服务器同局域网，填公网或内网地址即可。

## 快速开始

在仓库根目录：

```bash
# 1) 启动 HTTP 服务（默认只监听 127.0.0.1:8787）
dart mcp_server/bin/ota_sync_server.dart serve

# 手机需要连电脑时，监听局域网：
dart mcp_server/bin/ota_sync_server.dart serve --host 0.0.0.0

# 2) 查看/复制 token（首次会自动生成）
dart mcp_server/bin/ota_sync_server.dart token

# 3) 只使用 stdio MCP（给桌面客户端）
dart mcp_server/bin/ota_sync_server.dart mcp
```

默认数据目录：`~/.ota_counter_sync/`
（`state.json`、`token`、`state.json.bak`、临时 `face-images/`）。可用 `--data-dir` 改：

```bash
dart mcp_server/bin/ota_sync_server.dart serve \
  --host 0.0.0.0 --port 8787 \
  --data-dir "$HOME/ota-sync"
```

启动日志仅显示地址、MCP 配置和局域网 IP，不打印 token。配对时由管理员在可信终端单独使用 `token` 命令读取，不把它发送给聊天助手或粘进日志。

## App 侧配对

1. App 首页右上角 `⋮` → **MCP 同步**。
2. 服务地址填电脑的局域网地址，例如 `http://192.168.1.20:8787`。
3. Token 填管理员在可信终端用 `token` 命令取得的值；启动日志不包含 token。
4. 点 **测试连接**，再点 **一键同步**。
   - 一键同步会先拉取待执行操作并写入本地，再上传最新快照。
   - 也可以分别使用“拉取操作 / 上传快照”。

> 手机和电脑需要在同一个 Wi-Fi / VPN；macOS 防火墙要允许 Dart 监听端口。
> Android 已允许 cleartext（局域网 HTTP）；iOS 已声明本地网络用途。
> 正式跨公网建议用 HTTPS 反向代理或 Tailscale，而不是明文 HTTP。

## MCP 客户端配置

### stdio（推荐，桌面客户端最稳）

先找到仓库绝对路径，例如 `/Users/you/ota_counter`：

```json
{
  "mcpServers": {
    "ota-counter": {
      "command": "dart",
      "args": [
        "/Users/you/ota_counter/mcp_server/bin/ota_sync_server.dart",
        "mcp",
        "--data-dir",
        "/Users/you/.ota_counter_sync"
      ]
    }
  }
}
```

> 用 `dart <file>`，不要用 `dart run <file>`。本项目根 `pubspec.yaml` 有
> build hooks，`dart run` 可能把 “Running build hooks...” 打到 stdout，
> 污染 MCP 的 JSON-RPC 流；直接执行脚本不会。
>
> 也可以直接用包装脚本，省掉绝对路径参数：
> `{"command": "/ABSOLUTE/PATH/ota_counter/tool/run_mcp_server.sh", "args": ["mcp"]}`。

如果客户端不方便调用 `dart`，可以编译成独立可执行文件：

```bash
dart compile exe mcp_server/bin/ota_sync_server.dart \
  -o mcp_server/bin/ota-sync-server
```

然后把 `command` 改成该可执行文件的绝对路径，`args` 里保留 `mcp --data-dir ...`。

### HTTP / SSE

不同客户端的配置字段名略有差异，常见两种：

```json
{
  "mcpServers": {
    "ota-counter": {
      "url": "http://127.0.0.1:8787/sse",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

或 Streamable HTTP：

```json
{
  "mcpServers": {
    "ota-counter": {
      "type": "http",
      "url": "http://127.0.0.1:8787/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

仓库里还有可直接改路径使用的示例：
`mcp_server/clients.example.json`（stdio）和
`mcp_server/http-clients.example.json`（HTTP）。

Grok Bot / Hermes 若只支持其中一种，按客户端的 MCP 配置 schema 调整字段即可；
服务端同时实现了：

- `POST /mcp`（Streamable HTTP，JSON 响应，支持 `Mcp-Session-Id`）
- `GET /sse` + `POST /messages?sessionId=...`（旧版 HTTP+SSE）

## MCP 工具

| 工具 | 作用 |
| --- | --- |
| `get_overview` | 总数、成员数、记录数、金额、分类型统计、待执行数 |
| `list_members` | 按姓名/团体搜索成员，含分类计数 |
| `get_member` | 单成员详情 + 最近记录 + 各团籍卡片 |
| `list_records` | 按日期、成员、类型查流水 |
| `list_groups` | 团体/价格配置列表 |
| `record_cheki` | **排队**增加切奇（3寸/5寸/宿题/团切/无签） |
| `add_ticket` | **排队**添加门票记录（支持 `ticket_type` / `is_free`） |
| `list_pending_actions` | 查看还没被 App 执行的队列 |
| `get_sync_status` | 快照时间、版本号、待执行数、是否过期 |
| `create_face_upload_link` | 按 `member_id`（优先）或 `member` + 可选 `group` 生成限量上传链接 |
| `enroll_face` | 按成员身份 + `image_url` / `image_base64`（二选一）+ 可选 `face` 排队 |
| `list_face_enrollments` | 按可选 `member_id` / `member` / `group`、`status`、`limit` 查处理结果 |

资源：`ota://overview`、`ota://members`、`ota://recent-records`、
`ota://sync-status`、`ota://snapshot`。

提示词：`daily-summary`、`monthly-report`、`enroll-member-face`。

### 计数语义

- `total_count` 与 App 首页“累计切奇”一致（多人切按可见参与人去重）。
- `by_type` 的 3寸/5寸包含无签；无签另外放在 `unsigned`。
- `record_cheki` 只做加法，不接受负数；纠正请在 App 里编辑/删除记录。
- AI 写入后，`get_overview` 的 `pending_actions` 会大于 0，直到 App 同步。

## 从聊天录入成员脸照

先同步一次 App 快照。聊天模型收到“照片 + 这是X”后先 `list_members`/`get_member`
核对 `member_id`；重名时补充 `group`，不能按累计数擅自选择。

- 聊天机器人已有图片字节：调用 `enroll_face`，传 `member_id`（优先）或
  `member`+`group`，并传 `image_base64`。支持 JPEG/PNG、可选
  `data:image/jpeg;base64,` / `data:image/png;base64,` 前缀；编码后上限 8 MB，
  其他格式返回中文错误。`image_url` 与 `image_base64` 只能提供一个。
- 只有公开可访问的图片 URL：`enroll_face` 传 `image_url`。只接受 HTTP(S)，
  不发送同步凭据给图片来源，不访问本机/内网地址；重定向最多 3 次。下载总超时
  20 秒，每张上限 15 MiB，Content-Type 须为 image/*（拒绝 SVG）。
- 没有图片字节也没有 URL：调用 `create_face_upload_link`，给用户手机上传链接。
  链接是独立 256-bit 随机凭证，24 小时有效，累计最多 10 张；只能为该成员排队。
- `face` 可选：`auto`（默认，单脸/可信相似度/最大脸 1.5 倍规则）、`largest`、
  `left_N`（按人脸框中心从左到右第 N 张，N 从 1 开始）。
- 排队后只能回复“已排队，手机打开同步后生效”。用户打开 App → MCP 同步 →
  一键同步才会检测和录入。多人脸先选可信相似度匹配；否则仅在最大脸面积至少为
  次大脸 1.5 倍时选择，无法确定或零张脸均失败。
- 用 `list_face_enrollments` 查询 `pending` / `applied` / `failed`。每条记录含
  `faces_found`、`used_face`（从左边数，1 开始）、`samples_kept` 和 `faces`
  （`index_from_left` + 0..1 的 `box`）。失败还有中文 `failure`，可让用户用
  `face: left_N` 重试。每人最多保留 30 个样本，`samples_kept=0` 表示新样本未保留，
  不能说新增。默认最新 50 条，最多 100 条。
- 未广告 `x-ota-capabilities: face-enroll-v1` 的旧 App（含 v1.6.0）不会收到
  `enroll_face` 操作，因此旧版同步仍能正常工作；新 App 会自动带上该头。

### 公开地址必须显式配置

```bash
OTA_SYNC_PUBLIC_BASE_URL=https://sub.lyszqx.love/ota-sync \
  dart mcp_server/bin/ota_sync_server.dart serve --host 127.0.0.1 --port 8787
```

环境变量为 `OTA_SYNC_PUBLIC_BASE_URL`，CLI `--public-base-url <url>` 优先。值包含 scheme、域名和完整反向代理前缀，不含 query/fragment/账号密码，末尾斜杠会去掉。**没有自动推导规则**：不读取 Host、`X-Forwarded-Proto` 或 `X-Forwarded-Prefix`；未配置时仅生成上传链接会报配置错误，其他功能仍可用。脸照流程推荐使用 HTTP MCP，由服务进程统一读写队列和上传凭证。当前存储只支持一个写入进程，**不得同时启动 stdio 与 HTTP 两个进程共写同一数据目录**。stdio 离线使用时同样需要配置公开地址；先停止 stdio，再启动同目录的 HTTP 服务，上传链接才能由该服务接收。

生产 haproxy 会剥除 `/ota-sync`，因此必须配置上面的完整 URL。页面用相对当前路径提交，浏览器请求仍保留 `/ota-sync/face-upload`；服务端只处理去前缀的 `/face-upload`。上传链接首次打开可用 query `token`，页面立即从历史地址删除该参数，后续上传用该**上传凭证**的 Bearer 头；无缓存、无 referrer。反向代理仍应避免记录该页面的 query，避免短期上传链接进入 access log。

## REST API

同步 REST 和 MCP 端点需要同步凭据（上传页例外，仅使用它自己的限量上传凭证）：

```http
Authorization: Bearer <token>
```

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/health` | 公开健康检查 |
| GET | `/api/v1/status` | 快照/队列状态 |
| POST | `/api/v1/snapshot` | 上传 App 快照 |
| GET | `/api/v1/actions?status=pending` | 拉取待执行操作 |
| POST | `/api/v1/actions` | 手动排入操作 |
| POST | `/api/v1/actions/ack` | 回传成功/失败及脸照结果，随后删除图片 |
| GET | `/api/v1/face-images/<imageId>` | 仅同步 Bearer header 可下载；不接受 query token |
| GET / POST | `/face-upload` | 成员限定的上传凭证；GET 中文表单，POST 原始 image body |

如果客户端支持 OpenAPI / 自定义 Action 而不是 MCP，可直接导入
[`openapi.yaml`](openapi.yaml)。

`POST /api/v1/snapshot` 请求体：

```json
{ "device_id": "ota-...", "snapshot": { "schema": "ota-counter-snapshot", "...": "..." } }
```

（也接受直接把 snapshot 作为请求体。）

脸照操作格式：

```json
{"kind":"enroll_face","payload":{"counter_id":1,"person_id":7,"person_name":"成员名","member_name":"成员名","group_name":"团名","imageId":"opaque-id","source":"base64","face":"auto"}}
```

`source` 为 `upload`、`url` 或 `base64`；`face` 为 `auto`、`largest` 或 `left_N`。App 通过 Bearer 下载 `imageId`，处理后回传：

```json
{"ids":["成功操作id","失败操作id"],"failures":{"失败操作id":"照片里有多张脸，无法判断是谁"},"results":{"成功操作id":{"faces_found":2,"used_face":1,"samples_kept":1},"失败操作id":{"faces_found":2,"used_face":null,"samples_kept":0,"faces":[{"index_from_left":1,"box":{"x":0.1,"y":0.2,"width":0.3,"height":0.4}}]}}}
```

`ids` 同时包含成功、失败的脸照操作；失败不能同时记为成功。成功摘要以 `result` 字段供查询。重复脸照 ack 不重复计数。原有非脸照操作和 ack 行为保持不变。

## 数据、备份与安全

- `state.json` 是完整快照 + 操作队列；写入前会更新 `state.json.bak`。
- Token 文件权限在 POSIX 上尝试设为 `600`。
- Token 也会随 `Authorization` 头传输；用 HTTP 时只应在可信局域网。
- 生产环境建议：Tailscale/WireGuard + 反向代理 HTTPS + 防火墙只放行你的设备。
- 不要把 `state.json` 或 token 提交到 Git。
- 脸照暂存于数据目录的 `face-images/`（原始 bytes + MIME 元数据），不进入快照或 MCP 文本；收到成功或失败 ack 即删除。
- 服务启动时及每 24 小时清理超过 7 天的图片，因此周期清理最迟在满 7 天后的下次扫描发生；到时 App 仍未拉取的操作会因图片已清理而失败，可重新录入。
- 上传链接及其剩余额度保存在 `state.json`。该文件、备份与图片目录均按敏感数据管理，备份可能另有保留期，ack 不会回收外部备份。
- 日志不打印同步 token，外部图片 URL 的网络异常也不回显签名 query。

## 故障排查

| 现象 | 处理 |
| --- | --- |
| App 测试连接 401 | token 不一致；重新复制 `token` 命令输出 |
| 连接被拒 | 服务是否 `--host 0.0.0.0`；防火墙；IP 是否是电脑局域网 IP |
| App 显示“尚未连接” | 先在 App 里保存设置再点测试；确认手机与电脑同网 |
| `get_overview` 报 no snapshot | 先在 App 点“上传快照”或“一键同步” |
| `pending_actions` 一直不清零 | 打开 App 点“拉取操作”；查看失败提示（成员不存在等） |
| AI 说找不到成员 | 先 `list_members`，用返回的 `member_id` |
| 端口被占用 | `--port 8788`，App 地址同步改端口 |

## 开发与自测

```bash
# 纯 Dart 端到端自测（临时目录、随机端口）
dart mcp_server/test/self_test.dart

# App 与 server 的集成测试
flutter test test/sync_service_test.dart --concurrency=1

# 静态分析
dart analyze mcp_server
flutter analyze
```

目录：

```text
mcp_server/
├── bin/ota_sync_server.dart   # CLI: serve / mcp / token / status / import
├── lib/store.dart             # 原子 JSON 状态 + 操作队列 + token
├── lib/snapshot.dart          # 快照读取、成员聚合、搜索
├── lib/mcp_protocol.dart      # tools/resources/prompts JSON-RPC
├── lib/http_transport.dart    # REST + /mcp + /sse
├── lib/stdio_transport.dart   # stdio MCP
├── lib/face_images.dart       # 图片存储、受限外部下载、7 天清理
├── lib/face_upload_page.dart  # 无外链中文手机上传表单
└── test/self_test.dart        # 同步回归 + 脸照端到端检查
```
