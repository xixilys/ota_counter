# PROJECT KNOWLEDGE BASE

**Generated:** 2026-06-27
**Commit:** d489021
**Branch:** codex/v1.3-prep

## OVERVIEW
Flutter/Dart OTA切奇计数器。中文 UI，sqflite 持久化，自建 OTA 更新分发。

## STRUCTURE
```
lib/
├── main.dart          # 入口 + MyHomePage 主页面 (2339行)
├── app_metadata.dart  # 常量 (名称/URL)
├── models/            # 7 文件: 数据模型, 手动 toMap/fromMap
├── services/          # 8 文件: 全静态服务类, 3 个独立 SQLite DB
├── pages/             # 10 文件: 各页面 StatefulWidget
└── widgets/           # 7 文件: 可复用组件
test/                  # 8 文件, flat, flutter_test only
tool/                  # 部署/数据脚本 (shell + Python)
```

## WHERE TO LOOK
| 任务 | 位置 | 备注 |
|------|------|------|
| 入口/首页逻辑 | lib/main.dart | _MyHomePageState 包含全部业务逻辑 |
| 数据库操作 | lib/services/database_service.dart | 1649行, 16次 schema 迁移, counter_app.db |
| 偶像数据库 | lib/services/idol_database_service.dart | idol_database.db, 种子: assets/data/china_idols_seed.json |
| 数据模型 | lib/models/counter_model.dart | 手动序列化, snake_case+camelCase 双键兼容 |
| 统计图表 | lib/pages/chart_page.dart | 3140行, fl_chart |
| 成员详情 | lib/pages/member_detail_page.dart | 1138行 |
| 导出导入 | lib/services/export_import_service.dart | 749行, 支持旧版/OTA bundle/ZIP |
| 计数器添加 | lib/widgets/add_counter_dialog.dart | 1228行 |
| 测试样例 | test/widget_test.dart | FFI 初始化模式参考 |

## CONVENTIONS
### 架构 (与 .cursorrules 不一致!)
- ❌ 无状态管理框架 — 纯 StatefulWidget + setState()
- ❌ 无 DI/服务定位器 — 服务类全部 static 方法 + private static Database? 懒加载单例
- ❌ 无路由包 — 裸 Navigator.push(MaterialPageRoute(...))
- ❌ 无代码生成 — 手动 toMap()/fromMap()/copyWith(), 无 build_runner/freezed
- ⚠️ .cursorrules 声称用 GetX/build_runner/clean architecture, 但代码中均不存在。以代码为准。

### 数据模型
- 字段全部 `final`, 手动 `copyWith()`
- `Map<String, dynamic> toMap()` — snake_case 列名
- `factory fromMap(Map<String, dynamic> map)` — 同时兼容 snake_case/camelCase 双键
- 私有辅助: `_readInt()`, `_readNullableInt()`, `_readBool()` 处理类型安全+键名回退

### 服务层
- 全部 static 方法, 无实例化
- 数据库服务通过 private static field 懒加载单例
- 3 个独立 DB: counter_app.db (v16), idol_database.db (v2), images.db

### 国际化
- 硬编码 `Locale('zh', 'CN')`, 无 ARB 文件
- UI 字符串直接中文内联

### 测试
- 文件命名: `_test.dart`, flat 在 test/ 下
- 测试描述: 中英混合 ("app boots to home page")
- 框架: flutter_test only, 无 mock/mocktail
- DB 相关 Widget 测试: setUpAll 中 `sqfliteFfiInit()` + `databaseFactory = databaseFactoryFfi`
- 测试数据全内联构造, 无 fixture 文件

### 构建
- 阿里云 Maven 镜像 (android/build.gradle)
- Android 签名: key.properties (gitignored, ../secrets/)
- APK 自定义命名: OTA-Counter-v{version}.apk
- CMake 任务禁用 (Flutter 3.41 兼容)
- 无 CI — 测试手动执行

### 发布
- 开发分支: codex/v1.3-prep
- 发版: merge 到 main → build APK → tag vX.Y.Z → deploy update site
- 版本元数据: `dart run tool/release_metadata.dart`
- 自建 OTA 更新: SSH 部署到 hk-ares, manifest 在 latest.json
- 偶像种子: systemd timer 每日 2 次爬取 Wiki, 发布到 ota-counter.huangxuanqi.top

## ANTI-PATTERNS (本项目特有)
- **God widget**: main.dart _MyHomePageState 2339 行, 包含全部首页逻辑/导航/CRUD/聚合/排序
- **chart_page.dart 3140 行** — 第二个巨型页面
- **死代码**: lib/pages/image_page.dart:113-117 注释掉的自动标记功能
- **重复 FFI 初始化**: widget_test.dart 和 group_cut_display_test.dart 各自复制同一段 sqflite FFI 引导代码
- **服务层无抽象**: 直接调用 DatabaseService.staticMethod(), 不可 mock, 紧耦合
- **.cursorrules 与代码不符**: rules 声明的 GetX/build_runner 不存在, 不要按 rules 开发

## COMMANDS
```bash
flutter pub get          # 安装依赖
flutter analyze          # 静态分析
flutter test             # 运行测试
flutter build apk --release  # 构建正式 APK
dart run tool/release_metadata.dart  # 读取版本信息
python3 tool/generate_china_idols_seed.py  # 重新生成偶像种子
```

## NOTES
- 非 Android 平台需要 sqflite FFI 初始化 (见 main.dart main())
- 新增模型需同时兼容 snake_case + camelCase 键名 (旧数据兼容)
- 新增服务方法保持 static 风格, 除非统一引入 DI
- test/ 目录下新增测试直接用 flutter_test, 不加 mock 框架
