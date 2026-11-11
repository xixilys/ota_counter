# OTA Counter

面向 OTA / 切奇记录的 Flutter 计数器应用。

当前版本：`v1.6.1`
Android build：`1.6.1+22`

## 主要功能

- 成员卡片计数，首页展示 `3寸`、`5寸`、`3寸宿题`、`5寸宿题`；`团切` 在卡片详情里查看
- 支持“单成员多团 / 兼任 / 重生改名”场景：同一个真人可以绑定多个团籍，首页按真人聚合为同一张卡片，不会因为换团或改名被拆散
- 支持手动绑定或解绑真人主档，不再只靠名字猜测；填同一个真人主档名，或并入已有真人卡片后，就能把跨团时期接到一起
- 快捷计数支持切换“记录到团体”，同一个真人在不同团的切可以分别落到对应团籍，默认仍用当前团
- 支持“团体是否启用无签”开关；录入时可区分有签 / 无签，首页仍按 `3寸`、`5寸` 聚合展示
- 支持多人切和多张团切，成员可来自不同团体；总览按照片张数计数，每位参与成员各计入对应张数，费用按每条流水总价保存
- 统计与流水支持日 / 周 / 月 / 年 / 全部范围查看
- 统计页会保存价格快照；旧的 0 价记录会按当前团价补算显示金额
- 支持门票记录，支持同一天多场次；可区分免费/付费、选择票种（预售/现场/学生/女性/特典/VIP…）；演出名单会从 MineCool 文案里尽量解析“免费入场/预售/现场/VIP”等票价，解析不到时再用同场次上次价格 → 票种默认价（本地学习）；文案价格不是结构化字段，识别不到的场次仍可手填
- 首页有 LIVE TICKETS 票根卡，统计页有免费/付费/票种/门票金额明细；从统计页或演出名单右上角进入“门票价格”可维护票种和默认价
- 支持从 MineCool 偶活行程缓存中选择场次，通过 HTTPS 缓存自动填入活动名 / 场地 / 日期
- 内置中国偶像数据库，可搜索、编辑、补充团体 / 团籍 / 真人主档；通过 HTTPS 更新社区 Wiki 与人工补充资料，保留用户编辑和真人绑定，不凭跨团同名自动合并
- 首页 `⋮` 或偶像数据库右上角可打开“演出名单”，查看 MineCool 缓存场次、同步最新名单、按活动/城市/场地/团体搜索，并显示文案解析出的票价
- 演出名单票价依赖 `tool/generate_idol_activity_events.py` 新版本；线上 feed 需要重新部署 updater 并生成一次
- 首页品牌与总览重做：切奇簿 / 我的切奇，深色模式、加载骨架、空状态、下拉刷新
- 自动从偶像资料里识别担当色，并同步到成员卡片配色
- 支持导入旧版计数器备份，以及 OTA 后台导出的历史 bundle
- 支持导出当前数据
- 支持隐藏不想在首页看到的成员卡片
- 删除计数器时，会一并删除对应的单成员流水记录

## UI 与设计

首页、成员卡片、深色模式和统计页已做一轮统一视觉刷新，关键截图和 review
清单见 [docs/UI_REVIEW.md](docs/UI_REVIEW.md)。

```bash
# 重新生成 UI review 截图（本机需要 Python fontTools + 系统中文字体）
python3 tool/ui_preview/prepare_font.py
flutter test tool/ui_preview/ui_preview_test.dart --update-goldens
```

## MCP / AI 同步

App 可以通过一个本地同步服务把数据接到 Grok Bot / Hermes / Claude Desktop 等
MCP 客户端。服务端在 `mcp_server/`，纯 Dart、无需额外依赖；App 侧入口是
首页 `⋮` → **MCP 同步**。支持 Docker Compose / systemd / Nginx HTTPS
生产部署，见 [mcp_server/DEPLOY.md](mcp_server/DEPLOY.md)。

```bash
# 电脑上启动（手机需能访问时加 --host 0.0.0.0）
dart mcp_server/bin/ota_sync_server.dart serve --host 0.0.0.0

# 给桌面 MCP 客户端用的 stdio 模式
dart mcp_server/bin/ota_sync_server.dart mcp

# 查看 token
dart mcp_server/bin/ota_sync_server.dart token

# 一键部署到已有 Docker 的服务器（默认 root@bgvps）
tool/deploy_mcp_server.sh --dry-run
tool/deploy_mcp_server.sh

# 目标只有 systemd / 没有 Docker（例如 bgvps）：
tool/build_mcp_server_linux.sh
tool/deploy_mcp_server_binary.sh --dry-run
tool/deploy_mcp_server_binary.sh
```

完整配置、工具列表、REST 接口和安全说明见
[mcp_server/README.md](mcp_server/README.md)。Mac 文件夹批量导入脸照见
[docs/face-inbox-import.md](docs/face-inbox-import.md)。

## 开发环境

在仓库根目录执行：

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

> 测试默认并行：每个测试文件通过 `test/support/isolated_test_databases.dart`
> 使用独立的临时数据库目录。新增数据库相关测试时在 `setUpAll` 里调用
> `useIsolatedTestDatabases()`。

如果本地 Flutter / Android SDK 不在系统默认路径，请先自行配置环境变量，例如 `ANDROID_HOME`、`ANDROID_SDK_ROOT`。

## 开发约定

- 日常开发默认在 `codex/v1.5-prep` 分支进行，不直接在 `main` 上开发
- 需要发版或推 GitHub Release 时，默认先把 `codex/v1.5-prep` 合并到 `main`，除非明确说明“不要合并”
- release 完成后默认切回 `codex/v1.5-prep`，后续继续在开发分支推进
- Android 发版时同步递增 `pubspec.yaml` 里的版本号，并保持 GitHub release 标题、tag、APK 文件名三者一致
- 可运行 `dart run tool/release_metadata.dart` 获取当前统一的 release 元信息，避免手写出错

## Android Release

正式包构建命令：

```bash
flutter build apk --release --target-platform android-arm64
```

正式包只含 64 位 ARM（`arm64-v8a`），32 位和 x86 手机装不了；原因是端侧人脸模型的运行库每种架构约 37MB。

构建完成后，`build/app/outputs/flutter-apk/` 目录下会同时看到：

- Flutter 默认产物：`app-release.apk`
- `build/app/outputs/flutter-apk/OTA-Counter-v1.6.1.apk`

GitHub Release 建议继续保持：

- release 标题：`OTA Counter v1.6.1`
- tag：`v1.6.1`
- APK 资产：`OTA-Counter-v1.6.1.apk`

也可以直接用脚本读取：

```bash
dart run tool/release_metadata.dart
dart run tool/release_metadata.dart --field=releaseTitle
dart run tool/release_metadata.dart --field=tag
dart run tool/release_metadata.dart --field=apkFileName
```

当前仓库已接入 `android/key.properties` 形式的本地签名配置：

- 示例文件：`android/key.properties.example`
- 本地配置文件：`android/key.properties`（已加入 `.gitignore`）
- `storeFile` 建议填写相对路径，例如 `../secrets/ota_counter-release.jks`

想让后续 APK 可以覆盖升级，必须同时满足这三点：

1. 始终使用同一个 keystore
2. 保持同一个 Android `applicationId`
3. 每次发版递增 `versionCode`

当前 Android `applicationId` 为 `top.huangxuanqi.otacounter`。当前版本号为 `1.6.1+22`。

更新站点发布可直接使用：

```bash
tool/deploy_update_site.sh
```

这条命令会通过 SSH / SCP 把以下文件推到 `bgvps` 的
`/var/www/ota-counter`，对外更新地址是 `https://ota-counter.huangxuanqi.top/ota-counter/`：

- `release/update_site/index.html`
- `release/update_site/latest.json`
- `build/app/outputs/flutter-apk/OTA-Counter-v1.6.1.apk`

支持的辅助参数：

```bash
tool/deploy_update_site.sh --dry-run
tool/deploy_update_site.sh --skip-apk
```

如果后续更换服务器或目录，可通过环境变量覆盖：

```bash
OTA_UPDATE_SSH_USER=your-user \
OTA_UPDATE_SSH_HOST=your-host \
OTA_UPDATE_REMOTE_DIR=/your/remote/path \
tool/deploy_update_site.sh
```

## 数据脚本

重新生成内置偶像数据库：

```bash
python3 tool/generate_china_idols_seed.py
```

把偶像数据库自动更新任务部署到 `bgvps`：

```bash
tool/deploy_idol_seed_updater.sh
```

部署后，服务器会通过 systemd timer 每天运行 2 次爬虫。`bgvps` 使用 UTC 时区，
当前计划时间是 `00:20` 和 `12:20`，折合北京时间 `08:20` 和 `20:20`，并带
`RandomizedDelaySec=30m` 的随机延迟。生成结果会发布到：

```text
https://ota-counter.huangxuanqi.top/ota-counter/data/china_idols_seed.json
```

辅助命令：

```bash
tool/deploy_idol_seed_updater.sh --dry-run
tool/deploy_idol_seed_updater.sh --no-run-now
python3 tool/validate_china_idols_seed.py assets/data/china_idols_seed.json
```

从 OTA 后台导出历史数据 bundle：

```bash
python3 tool/export_ota_history.py --admin-key YOUR_ADMIN_KEY
```

脚本会输出：

- 一个可直接导入 App 的 JSON bundle
- 一份 latest JSON
- 团体 / 成员 / 流水 CSV

## 许可证

MIT，见 [LICENSE](LICENSE)。
