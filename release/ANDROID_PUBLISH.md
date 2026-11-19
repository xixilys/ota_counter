# Android 双渠道发布

先准备一份可公开的源码，再构建、验收，最后用同一个 APK 更新 GitHub Release 和 OTA 站点。

1. 从官方远端 `fork/main` 建立独立发布工作区。只把审过的功能与依赖、相关测试和发布文件加入一个提交。不要直接合并临时分支或在含有取证文件的历史上打 tag；GitHub Release 会自动提供 tag 的源码归档。源码 diff 不应含用户照片、数据、备份、私有日志或预览取证。
2. 从这份提交构建 arm64 release APK，使用本机现有签名。覆盖安装到指定真机并验收；记录当时用于安装的 APK 的 SHA-256 和源码提交。验收后不得重新构建或拿同版本的另一份 APK 替代。
3. 从发布工作区运行以下命令。默认只做读检查；看过输出并获得正式发布授权后，原命令加 `--publish`：

   ```sh
   tool/publish_android_release.sh \
     --source=<完整的源码提交ID> \
     --apk=/absolute/path/to/phone-accepted.apk \
     --accepted-sha256=<真机验收APK的SHA-256>
   ```

本机使用已登录的 GitHub CLI 和配置好的 `root@bgvps` SSH；Android SDK 由 `ANDROID_HOME` 定位，`apksigner` 需要可用的 Java。无需传入密钥或 token。

发布时先快进 `xixilys/ota_counter` 的 `main` 并推送 tag，再建立正式 GitHub Release 并核对公开下载的 APK。GitHub 备链就绪后才更新 OTA；站点先放 APK 和下载页，最后启用 `latest.json`。入口最后从公众入口核对 APK、页面和 manifest。此次只发 Android，站点原有 iOS 引导不变。

若 GitHub 已成功而 OTA 尚未更新，保留同一个源码提交和 APK，排除报错后重跑同一入口。入口会复用内容一致的正式 Release，不会覆盖不同资产或强推 tag；如遇未完成的 GitHub 草稿，由发布人检查该草稿。更新站点前保存旧页面和 manifest 的路径会打印在终端；旧版本的 APK 不会删除。
