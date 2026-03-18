# OTA Counter

面向 OTA / 切奇记录的 Flutter 计数器应用。

当前版本：`v1.2.2`  
Android build：`1.2.2+6`

## 主要功能

- 成员卡片计数，首页展示 `3寸`、`5寸`、`3寸宿题`、`5寸宿题`、`团切`
- 支持“单成员多团 / 兼任 / 重生改名”场景：同一个真人可以绑定多个团籍，首页按真人聚合为同一张卡片，不会因为换团或改名被拆散
- 支持手动绑定或解绑真人主档，不再只靠名字猜测；填同一个真人主档名，或并入已有真人卡片后，就能把跨团时期接到一起
- 快捷计数支持切换“记录到团体”，同一个真人在不同团的切可以分别落到对应团籍，默认仍用当前团
- 支持“团体是否启用无签”开关；录入时可区分有签 / 无签，首页仍按 `3寸`、`5寸` 聚合展示
- 支持多人切，成员可来自不同团体；录入总价后会按总价保存流水，并给每个参与成员同步加数
- 统计与流水支持日 / 周 / 月 / 年 / 全部范围查看
- 统计页会保存价格快照；旧的 0 价记录会按当前团价补算显示金额
- 支持门票记录，支持同一天多场次
- 内置中国偶像数据库，可搜索、编辑、补充团体 / 团籍 / 真人主档
- 自动从偶像资料里识别担当色，并同步到成员卡片配色
- 支持导入旧版计数器备份，以及 OTA 后台导出的历史 bundle
- 支持导出当前数据
- 支持隐藏不想在首页看到的成员卡片
- 删除计数器时，会一并删除对应的单成员流水记录

## 开发环境

在仓库根目录执行：

```bash
flutter pub get
flutter analyze
flutter run
```

如果本地 Flutter / Android SDK 不在系统默认路径，请先自行配置环境变量，例如 `ANDROID_HOME`、`ANDROID_SDK_ROOT`。

## Android Release

正式包构建命令：

```bash
flutter build apk --release
```

构建完成后，`build/app/outputs/flutter-apk/` 目录下会同时看到：

- Flutter 默认产物：`app-release.apk`
- `build/app/outputs/flutter-apk/OTA-Counter-v1.2.2.apk`

GitHub Release 建议继续保持：

- release 标题：`OTA Counter v1.2.2`
- tag：`v1.2.2`
- APK 资产：`OTA-Counter-v1.2.2.apk`

当前仓库已接入 `android/key.properties` 形式的本地签名配置：

- 示例文件：`android/key.properties.example`
- 本地配置文件：`android/key.properties`（已加入 `.gitignore`）
- `storeFile` 建议填写相对路径，例如 `../secrets/ota_counter-release.jks`

想让后续 APK 可以覆盖升级，必须同时满足这三点：

1. 始终使用同一个 keystore
2. 保持同一个 Android `applicationId`
3. 每次发版递增 `versionCode`

当前 Android `applicationId` 为 `top.huangxuanqi.otacounter`。当前版本号为 `1.2.2+6`。

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
