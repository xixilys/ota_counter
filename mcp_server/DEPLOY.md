# 部署到服务器

这个同步服务是一个无状态 HTTP 进程 + 一个数据目录，适合放在：

- 家里的 NAS / 小主机 / 树莓派（局域网直连）；
- 有公网 IP 的 VPS（配 HTTPS / 反向代理）；
- 任何支持 Docker 的云主机。

App 只需要能访问 `http(s)://<host>:8787`，不要求与服务器同一个局域网。

## 方案 A：Docker Compose（推荐）

如果目标机器已有 Docker，也可以从仓库直接一键部署（默认 `root@bgvps`，
可用环境变量覆盖）：

```bash
# 先 dry-run 看计划
tool/deploy_mcp_server.sh --dry-run

# 只监听 127.0.0.1（推荐，前面放 Nginx/Caddy）
tool/deploy_mcp_server.sh

# 手机直接连 8787（需要防火墙/可信网络）
tool/deploy_mcp_server.sh --public
```

脚本会同步 `mcp_server/`、在远端 `docker compose up -d --build`，并打印
`/data/token`。下面是手动方式：

```bash
cd mcp_server
cp .env.example .env
# 如果手机需要直接连 8787：OTA_SYNC_BIND=0.0.0.0
# 如果放在 Nginx 后面：OTA_SYNC_BIND=127.0.0.1
docker compose up -d --build
```

启动日志不输出 token。仅在可信管理员终端读取配对凭据，不把输出复制到聊天或归档日志：

```bash
docker compose exec ota-sync cat /data/token
```

App 填：

```text
服务地址：http://<服务器IP或域名>:8787
Token：上面拿到的值
```

如果本机防火墙开启，需要放行 8787（或只放行反向代理的 443）。

### 数据与备份

- 数据在 Docker named volume `ota-sync-data` 的 `/data`。
- 备份：

```bash
cd mcp_server
docker compose exec -T ota-sync tar czf - -C /data . > ota-sync-backup.tgz
# 恢复
docker compose exec -T ota-sync tar xzf - -C /data < ota-sync-backup.tgz
```

- 备份包含 `state.json`、`token`、`state.json.bak` 和尚未清理的 `face-images/`；含敏感上传链接及脸照，按私有数据管理，恢复后重启容器。ack 只删除在线图片，不回收已有备份。
- `state.json` 每次写入前会生成 `state.json.bak`。

### HTTPS（公网 / 不可信网络）

不要把 8787 明文裸奔在公网。用 Nginx/Caddy 反代并配证书：

```bash
sudo cp deploy/nginx-ota-sync.conf /etc/nginx/conf.d/ota-sync.conf
# 改 server_name 和证书路径
sudo nginx -t && sudo systemctl reload nginx
```

Nginx 配置已经关闭 buffering、拉长 SSE 超时；`/sse`、`/mcp` 都能正常走。

如果不想开新域名，可以挂到现有站点的子路径（例如现有 OTA 证书）：

```nginx
location /ota-counter/sync/ {
    proxy_pass http://127.0.0.1:8787/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 1h;
    proxy_send_timeout 1h;
}
```

App 里地址改成 `https://your.domain/ota-counter/sync`（注意结尾不要多写斜杠，
SyncService 会自己拼 `/api/v1/...`）。Token 不变。MCP 客户端用同一地址的
`/mcp` 或 `/sse`。

App 里地址也可以改成独立域名 `https://sync.example.com`，Token 不变。

> 更省事的私有网络方案：Tailscale / WireGuard。这样不用暴露公网端口，
> 手机和 bot 都能通过虚拟内网 IP 访问。

## 方案 B：systemd + 单文件二进制

适合不想装 Docker 的 VPS（例如当前的 `bgvps`，它只有 systemd + Nginx）：

```bash
tool/build_mcp_server_linux.sh          # 用本地 Docker 交叉编译 linux/amd64
tool/deploy_mcp_server_binary.sh --dry-run
tool/deploy_mcp_server_binary.sh        # 默认 root@bgvps
```

脚本会安装 `ota-sync` 到 `/usr/local/bin`、创建 `ota-sync` 用户、启用
`ota-counter-sync.service`，服务只监听 `127.0.0.1:8787`。之后用 Nginx 挂 HTTPS。

手动部署步骤：

```bash
# 1) 在仓库里编译 Linux 二进制
dart compile exe mcp_server/bin/ota_sync_server.dart -o /tmp/ota-sync

# 2) 上传到服务器
scp /tmp/ota-sync root@server:/usr/local/bin/ota-sync
ssh root@server 'chmod 755 /usr/local/bin/ota-sync'

# 3) 安装 unit
scp mcp_server/deploy/ota-counter-sync.service \
  root@server:/etc/systemd/system/ota-counter-sync.service
ssh root@server '
  useradd --system --home /var/lib/ota-counter-sync --shell /usr/sbin/nologin ota-sync || true
  install -d -o ota-sync -g ota-sync /var/lib/ota-counter-sync
  systemctl daemon-reload
  systemctl enable --now ota-counter-sync
  systemctl status ota-counter-sync --no-pager
'

# 4) 拿 token
ssh root@server 'cat /var/lib/ota-counter-sync/token'
```

默认只监听 `127.0.0.1:8787`，通过 Nginx 对外；如果直接暴露端口，把 unit 里的
`--host 127.0.0.1` 改成 `0.0.0.0` 并配置防火墙。

## 脸照上传的公网入口

设置 `OTA_SYNC_PUBLIC_BASE_URL`，或在启动命令中加 `--public-base-url`（CLI 优先）。不从请求头推导协议/路径，未设置时生成上传链接会报错，原同步 API 不受影响。Docker Compose 会传入 `.env` 中的同名变量；脸照流程建议用 HTTP MCP。当前 JSON 存储是单写者，不能并行运行 stdio 和 HTTP 进程共写同一目录；如离线使用 stdio，需配置相同公开地址并停止后再启动 HTTP 服务。

当前 `hkvps2` 公开入口为 `https://sub.lyszqx.love/ota-sync`，haproxy 剥除路径前缀，且没有可恢复此前缀的 forwarded headers。由部署负责人可靠配置：

systemd unit 已读取可选的 `/etc/ota-counter-sync.env`（`EnvironmentFile=-`），写入即可：

```ini
# /etc/ota-counter-sync.env
OTA_SYNC_PUBLIC_BASE_URL=https://sub.lyszqx.love/ota-sync
```

页面相对路径提交，浏览器保留 `/ota-sync` 前缀，服务端只接收 `/face-upload`。代理需要允许每张最多 15 MiB 的 image body；建议此路由 access log 不记录 query，上传凭证不是同步 token，但仍有 24 小时上传权限。图片写入持久数据目录，成功/失败 ack 后删除；启动及每日扫描清理超过 7 天的图片。同步 token 不进入启动日志。

## 首次配对流程

1. 部署服务，拿到 token。
2. App：首页 `⋮` → **MCP 同步**，填地址和 token，保存。
3. 点“测试连接”，应显示服务端版本号（rev）。
4. 点“一键同步”：先拉取待执行操作，再上传最新快照。
5. AI 端通过 MCP 读取；`record_cheki` 产生的操作会在下一次 App 同步时执行。

## 更新服务

```bash
# Docker
cd mcp_server
docker compose up -d --build

# systemd
dart compile exe mcp_server/bin/ota_sync_server.dart -o /tmp/ota-sync
scp /tmp/ota-sync root@server:/usr/local/bin/ota-sync
ssh root@server 'systemctl restart ota-counter-sync'
```

数据在 `/data` 或 `/var/lib/ota-counter-sync`，更新二进制不会丢快照。

## 常见问题

| 问题 | 处理 |
| --- | --- |
| 手机连不上 | 服务是否 `--host 0.0.0.0` / compose 的 `OTA_SYNC_BIND`；防火墙；用服务器 IP 而非 127.0.0.1 |
| 401 | token 和 App 里填的不一致；重新 cat `/data/token` |
| 413 | 快照超过 32MB；减少记录或调大 Nginx `client_max_body_size` 和服务端限制 |
| SSE 断开 | Nginx 关闭 buffering、增大 `proxy_read_timeout`；配置见 `deploy/nginx-ota-sync.conf` |
| 想换 token | 删除数据目录里的 `token` 后重启，或设置 `OTA_SYNC_TOKEN=<新值>` |
| 服务器重启后数据没了 | 确认 volume/数据目录挂载正确；compose 使用 named volume |
