# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

项目知识库（结构、约定、命令、反模式）见 AGENTS.md，以下内容不重复，只补充它没写的部分：

@AGENTS.md

## 补充命令

```bash
flutter test test/xxx_test.dart --plain-name "测试名"   # 跑单个测试
OTA_REAL_BACKUP=/path/to/backup.zip flutter test test/real_backup_restore_counts_test.dart
                                   # 用真实完整备份核对恢复后的首页数字；不设变量时自动跳过
```

## 调试与真机安全

- debug / profile 构建的包名带 `.debug` 后缀，应用名为「OTA Counter Debug」（`android/app/build.gradle`），可以和正式版 `top.huangxuanqi.otacounter` 并排安装。
- **不要在用户的真机上调试**：不要卸载或覆盖正式版，也不要清除它的数据。开发和验证一律用本地模拟器（AVD `ota-counter-api36`、`ota-visual-preview-1023`，arm64，Android 16）。
- 同一台模拟器上不要同时跑 integration test 和手动验证：integration test 会重装同包名的 App，并覆盖 `build/app/outputs/flutter-apk/app-debug.apk`。
- 用户的真实备份含私人照片，只能放在仓库外，不要复制进仓库或提交。

## 首页数字口径

首页总数只在菜单「显示已隐藏项」打开时才包含隐藏成员。这个开关是本机偏好，会随完整备份一起导出、导入：恢复不含该开关的旧备份时，只要备份里有隐藏成员，就自动把开关打开。核对「数字对不上」时先检查这个开关。

## 同步服务部署现状

同步 / MCP 服务实际部署在 `hkvps2`，不是脚本默认的 bgvps：

- 以 systemd 服务 `ota-counter-sync` 运行，监听 `127.0.0.1:8787`。
- 由 haproxy 的 80 端口按 `/ota-sync` 路径转发并去掉前缀。该机 443 端口归代理服务（xray）使用，不要动。
- 外部地址为 `https://sub.lyszqx.love/ota-sync`，经 Cloudflare 提供 HTTPS。
- 重新部署：`OTA_SYNC_SSH_HOST=hkvps2 tool/deploy_mcp_server_binary.sh`。需要的 Linux 可执行文件可在本机交叉编译：`dart compile exe --target-os=linux --target-arch=x64 mcp_server/bin/ota_sync_server.dart -o build/ota-sync-linux-amd64`。

## 项目级 skill

`.claude/skills/` 下有 `ui-ux-pro-max`（含 Flutter 栈规则的设计库）和 `unslop`（去除「AI 味」界面），改界面时使用。
