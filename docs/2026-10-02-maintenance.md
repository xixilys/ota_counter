# 计数、资料更新与扫描修复

目标：审核并修复团切/总切数、团体与成员资料更新、拍立得扫描，验证后提交并发布 Android 更新。

基线：已发布 v1.5.2（7352ac2）；当前工作树原为 v1.4.2，已建立 `codex/count-source-scan-fixes` 接续已发布版本。保留其他工作树的未提交内容。

本轮规则：
- 总览与图表按照片张数统计，多人切每张只算一次，成员各自计入；团切支持多张。
- 计数修改按事务内净变化处理，负数下溢拒绝并回滚；不猜测历史余额，不自动重算用户旧计数，不启动历史 v17 迁移设计。
- 负数修正表示张数修正；更改多人切的成员归属应编辑该条记录的参与者。
- 资料同步保留用户修改和明确绑定，不凭跨团同名建立真人关联，不用旧内置数据覆盖新下载数据，不以缺失成员推断离团或删除。
- 扫描优化覆盖实际 basic/manual 入口；合成图和桌面基准不能代表真实手机拍照质量。

已确认：线上 APK/站点在 `bgvps:/var/www/ota-counter`，资料 updater 仍在 hk-ares 旧目录，公开资料 URL 返回 404。需要恢复公开资料更新，并保留原配置备份。

当前阶段：已完成。修复、独立复审、构建、覆盖安装、扫描交互及发布均通过；更新站与 GitHub 的完整 APK 下载均与本地正式包 SHA-256 一致，线上 page/manifest 与发布文件一致。

已完成验证：
- `flutter analyze --no-pub`：无问题。
- `flutter test --no-pub --concurrency=1`：97 项通过。现有 FFI 测试共享数据库，因此全套串行执行。
- `python3 -m unittest discover -s tool/tests -v`：11 项通过。
- 真实首页 Widget 覆盖总数、团切数量编辑、隐藏范围、无流水旧计数、重复参与者及同名不同身份。
- SQL 失败注入验证删除事务回滚保留照片、批量成员删除不会部分成功。
- 资料录入 Widget 覆盖两团同名未关联成员保持独立卡片；HTTP→SQLite 覆盖保留用户修改/ID、拒绝旧快照。
- 新 HTTPS 资料渠道首次 systemd 运行成功，694 团/4336 团籍；偶活接口同样迁至 HTTPS，3768 条场次。旧 hk-ares 按原目录保留任务，但旧 APK 写死的 103.240.198.11 请求超时，需要更新 APK 获得新入口。
- 新站原 page/manifest 备份：`bgvps:/root/ota-counter-backups/v1.5.3-before-update`；旧 updater/资料备份：`hk-ares:/root/ota-counter-backups/v1.5.3-before-data-update`。

扫描基准：同一 1200×1600 合成图各 3 轮，basic 中位 673→488 ms，manual 1567→381 ms；manual 10ms 定时器最大延迟 800–1568→12–13 ms。桌面并行负载会影响耗时，不作为手机加速比。10 项扫描测试覆盖 EXIF 旋转、放大画布四角坐标、非法四边形、横版、无边框、互补反光。

发布完成前：独立审阅、Flutter/Python 回归、Android 正式包签名与升级验证、备份服务器原文件，先上传 APK 再发布 manifest，验证网站及 GitHub 下载。

已知历史限制：旧版团切保存时丢失的原始输入数量无法从现有记录自动恢复。

补充验收：Android 正式包构建通过，applicationId 保持 top.huangxuanqi.otacounter，versionCode=19。apksigner 校验与 v1.5.2 签名一致；Android API 36 模拟器由旧版覆盖升级后，实际录入的 UpgradeCheck 5 张及 1 条流水保留。

Android 实际交互：API 36 模拟器从相册选择合成拍立得图片，进入手动框选，拖动角点、生成并保存成功，存图页显示“扫描切图 1”。正式包再次安装后原卡片与 5 张计数保留。App 内点击服务器同步，快照时间从打包的 11:06 更新为线上 11:15，验证实际 HTTPS 同步路径。

发布：`fe8a45b` 实现修复，`4025b77` 补齐偶活来源；已合入并推送 `main`、`codex/v1.5-prep` 和本任务分支。GitHub Release `v1.5.3` 的 APK 为 65,595,284 bytes，原签名一致，旧 APK 文件保留在站点。原始验证日志与模拟器截图保留在本工作树 `.buildlog/2026-10-02/`（未提交）。

原工作树 `/Volumes/remote/project/ota_counter` 未变更，原有 `.omo/` 保留；当前任务工作树保留修复分支。测试专用模拟器已停止并删除。
