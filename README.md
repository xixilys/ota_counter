# OTA Counter

面向 OTA / 切奇记录的 Flutter 计数器应用。

## 功能

- 成员卡片计数，分别记录 `3寸`、`5寸`、`3寸宿题`、`5寸宿题`、`团切`
- 日 / 周 / 月 / 年 / 全部统计
- 团体价格表，流水记录会保存当时价格快照，后续改价也不会污染历史金额
- 支持双人切记录，单人 / 双人 / 门票统计分开展示
- 门票记录，支持同一天多场次
- 内置中国偶像数据库，可搜索、编辑、补充成员
- 自动从偶像资料里识别担当色，并同步到成员卡片配色
- 支持导入旧版计数器备份，以及 OTA 后台导出的历史 bundle
- 支持导出当前计数器数据
- 支持隐藏不想在首页看到的成员卡片

## 开发环境

这个仓库默认配合远程磁盘上的 Flutter / Android 环境使用：

```bash
source /Volumes/remote/app/bin/ota_counter_env.sh
flutter pub get
flutter analyze
flutter run
```

## Android Release

正式包构建命令：

```bash
source /Volumes/remote/app/bin/ota_counter_env.sh
flutter build apk --release
```

当前仓库已接入 `android/key.properties` 形式的本地签名配置：

- 示例文件：`android/key.properties.example`
- 实际签名文件：`android/key.properties`（已加入 `.gitignore`）
- 当前本机 release keystore：`/Volumes/remote/app/keystores/ota_counter-release.jks`

想让后续 APK 可以覆盖升级，必须同时满足这三点：

1. 始终使用同一个 keystore
2. 保持同一个 Android `applicationId`
3. 每次发版递增 `versionCode`

当前 Android `applicationId` 为 `top.huangxuanqi.otacounter`。本次版本号为 `1.2.0+3`。

## 数据脚本

重新生成内置偶像数据库：

```bash
python3 tool/generate_china_idols_seed.py
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
