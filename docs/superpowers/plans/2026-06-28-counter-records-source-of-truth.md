# 计数器记录单一真相源重构实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 将 `activity_records` 重构为唯一真相源，`counters.count*` 只作为可重建缓存，彻底修复多人切串号、删除互相影响、总数漂移和月度统计错误。

**架构：** 写路径只事务化写 `activity_records`，随后从记录派生并重建受影响计数器缓存，禁止任何 `counter.count += delta` 的增量双写。多人切从共享一行改为每参与者一行，通过 `group_record_id` 关联同一事件，并用 `counter_id` / `person_id` 稳定匹配。v17 迁移在打开数据库前备份 v16 文件，迁移时加列、拆分旧多人切、回填系统调整记录并重建缓存。

**技术栈：** Flutter/Dart、sqflite_common_ffi、sqflite、flutter_test、手写模型序列化、静态 `DatabaseService`。

---

## 文件结构

- 修改：`lib/models/activity_record_model.dart` — 新增 `groupRecordId`、`isSystemAdjustment`，支持多人切参与者行生成与序列化兼容。
- 修改：`lib/models/counter_model.dart` — 保留现有字段与 getter，补充只读缓存语义，禁止从 UI 直接增量写缓存。
- 修改：`lib/services/database_service.dart` — schema v17、打开前备份、v17 迁移、缓存重算、事务化记录写入、稳定 ID 匹配与同步路径修复。
- 修改：`lib/main.dart` — 首页与全局总览从 records 派生，移除 `_applyRecordCounterImpact` 双写，旧版导入触发回填记录。
- 修改：`lib/pages/member_detail_page.dart` — 删除/编辑记录只调用事务化 DB API，成员记录匹配改用稳定 ID，不再按名字猜测多人切参与者。
- 修改：`lib/pages/chart_page.dart` — 新增/编辑/删除只写 records，周期统计排除系统调整，多人切统计按 `group_record_id` 去重或按参与者计入。
- 创建：`test/counter_records_source_of_truth_test.dart` — FFI 数据库测试，覆盖 v17 迁移、缓存重算、事务写路径、多人切删除隔离和系统调整过滤。
- 修改：`test/group_cut_logic_test.dart` — 模型层多人切行生成与全局去重语义测试。
- 修改：`test/pricing_behavior_test.dart` — 保持价格行为，补充系统调整记录不影响价格重算的模型断言。

## 执行约束

- 严格 TDD：每个任务先写失败测试，运行确认失败，再实现最少代码，运行确认通过。
- 不引入状态管理、DI、代码生成或 mock 框架；遵循现有 static service + StatefulWidget 风格。
- 所有 DB 测试使用 `sqfliteFfiInit()` 和 `databaseFactory = databaseFactoryFfi`，只用 `flutter_test`。
- 私有迁移/重算逻辑通过 `@visibleForTesting` 的 public wrapper 暴露，例如 `debugMigrateToV17()`、`debugRecalculateCounterTotals()`。
- 每个任务以精确 `git add` 和中文 `git commit -m` 结束；提交前运行该任务指定测试和 `flutter analyze`。
- 不删除用户手动补偿记录，包括 `-9` 记录；只新增 `is_system_adjustment=1` 的迁移回填记录。
- 目标版本为 v1.5.0；schema 从 v16 升到 v17。

---

### 任务 1：模型字段与多人切参与者行

**文件：**
- 修改：`lib/models/activity_record_model.dart:75`
- 修改：`test/group_cut_logic_test.dart:1`

- [ ] **步骤 1：编写失败的模型序列化测试**

在 `test/group_cut_logic_test.dart` 追加以下测试：

```dart
test('activity records preserve group record id and system adjustment flag', () {
  final record = ActivityRecordModel(
    type: ActivityRecordType.counter,
    counterId: 42,
    personId: 7,
    personName: '兔本人',
    subjectName: '兔',
    groupName: '测试团',
    occurredAt: DateTime(2026, 6, 28, 12),
    threeInchCount: 9,
    totalAmount: 0,
    groupRecordId: 'legacy-adjustment-42',
    isSystemAdjustment: true,
  );

  final map = record.toMap();
  expect(map['group_record_id'], 'legacy-adjustment-42');
  expect(map['is_system_adjustment'], 1);

  final restored = ActivityRecordModel.fromMap(map);
  expect(restored.groupRecordId, 'legacy-adjustment-42');
  expect(restored.isSystemAdjustment, isTrue);
});
```

- [ ] **步骤 2：运行测试验证失败**

运行：`flutter test test/group_cut_logic_test.dart --plain-name "activity records preserve group record id and system adjustment flag"`

预期：FAIL，Dart 编译失败，包含 `The named parameter 'groupRecordId' isn't defined` 或 `The getter 'groupRecordId' isn't defined`。

- [ ] **步骤 3：实现字段、copyWith、toMap/fromMap**

在 `lib/models/activity_record_model.dart` 的 `ActivityRecordModel` 中加入字段、构造参数、copyWith 参数和序列化字段：

```dart
  final String? groupRecordId;
  final bool isSystemAdjustment;
```

构造函数中加入：

```dart
    this.groupRecordId,
    this.isSystemAdjustment = false,
```

`copyWith` 参数中加入：

```dart
    String? groupRecordId,
    bool? isSystemAdjustment,
```

`copyWith` 返回对象中加入：

```dart
      groupRecordId: groupRecordId ?? this.groupRecordId,
      isSystemAdjustment: isSystemAdjustment ?? this.isSystemAdjustment,
```

`toMap()` 中加入：

```dart
      'group_record_id': groupRecordId,
      'is_system_adjustment': isSystemAdjustment ? 1 : 0,
```

`fromMap()` 返回对象中加入：

```dart
      groupRecordId: map['group_record_id'] as String? ??
          map['groupRecordId'] as String?,
      isSystemAdjustment: _readBool(
        map['is_system_adjustment'] ?? map['isSystemAdjustment'],
      ),
```

在 `_readDouble` 前加入：

```dart
  static bool _readBool(Object? value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value.toInt() != 0;
    }
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == 'true' || normalized == '1';
    }
    return false;
  }
```

- [ ] **步骤 4：运行测试验证通过**

运行：`flutter test test/group_cut_logic_test.dart --plain-name "activity records preserve group record id and system adjustment flag"`

预期：PASS。

- [ ] **步骤 5：编写失败的多人切拆行测试**

在 `test/group_cut_logic_test.dart` 追加：

```dart
test('multi cut can emit one row per participant with shared group id', () {
  final event = ActivityRecordModel.multiCut(
    participants: const [
      ActivityParticipant(
        memberName: '兔',
        groupName: 'A团',
        personId: 101,
        personName: '兔本人',
      ),
      ActivityParticipant(
        memberName: '萝北',
        groupName: 'B团',
        personId: 202,
        personName: '萝北本人',
      ),
    ],
    field: CounterCountField.fiveInch,
    occurredAt: DateTime(2026, 6, 28, 20),
    quantity: 2,
    totalPrice: 120,
  );

  final rows = event.toParticipantRows(
    groupRecordId: 'multi-evt-1',
    counterIdByParticipant: const {
      101: 11,
      202: 22,
    },
  );

  expect(rows, hasLength(2));
  expect(rows.map((row) => row.groupRecordId).toSet(), {'multi-evt-1'});
  expect(rows.map((row) => row.counterId).toList(), [11, 22]);
  expect(rows.map((row) => row.personId).toList(), [101, 202]);
  expect(rows.map((row) => row.subjectName).toList(), ['兔', '萝北']);
  expect(rows.every((row) => row.participants.length == 1), isTrue);
  expect(rows.every((row) => row.countForField(CounterCountField.fiveInch) == 2), isTrue);
  expect(rows.every((row) => row.totalAmount == 60), isTrue);
});
```

- [ ] **步骤 6：运行测试验证失败**

运行：`flutter test test/group_cut_logic_test.dart --plain-name "multi cut can emit one row per participant with shared group id"`

预期：FAIL，编译失败包含 `The method 'toParticipantRows' isn't defined for the type 'ActivityRecordModel'`。

- [ ] **步骤 7：实现 `toParticipantRows`**

在 `lib/models/activity_record_model.dart` 的 `multiContributionTotal` getter 后加入：

```dart
  List<ActivityRecordModel> toParticipantRows({
    required String groupRecordId,
    Map<int, int> counterIdByParticipant = const {},
  }) {
    if (!isMulti) {
      return [this];
    }

    final normalizedParticipants = effectiveParticipants
        .where((participant) => participant.memberName.trim().isNotEmpty)
        .toList(growable: false);
    if (normalizedParticipants.isEmpty) {
      return [copyWith(groupRecordId: groupRecordId)];
    }

    final amountShare = totalAmount / normalizedParticipants.length;
    return normalizedParticipants.map((participant) {
      final participantPersonId = participant.personId;
      return copyWith(
        id: null,
        groupRecordId: groupRecordId,
        counterId: participantPersonId == null
            ? null
            : counterIdByParticipant[participantPersonId],
        personId: participantPersonId,
        personName: participant.resolvedPersonName,
        subjectName: participant.memberName.trim(),
        secondarySubjectName: '',
        groupName: participant.groupName.trim(),
        totalAmount: amountShare,
        participants: [participant],
      );
    }).toList(growable: false);
  }
```

- [ ] **步骤 8：运行模型测试验证通过**

运行：`flutter test test/group_cut_logic_test.dart`

预期：PASS，现有 `multi group cut records are stored as group cut entries` 仍通过。

- [ ] **步骤 9：Commit**

```bash
git add lib/models/activity_record_model.dart test/group_cut_logic_test.dart
git commit -m "test: 覆盖记录模型真相源字段"
```

---

### 任务 2：schema v17 与打开前备份

**文件：**
- 修改：`lib/services/database_service.dart:16`
- 创建：`test/counter_records_source_of_truth_test.dart`

- [ ] **步骤 1：编写失败的 schema 与备份测试**

创建 `test/counter_records_source_of_truth_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ota_counter/services/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('counter_truth_test_');
    await databaseFactory.setDatabasesPath(tempDir.path);
    dbPath = p.join(tempDir.path, 'counter_app.db');
    DatabaseService.debugResetDatabaseForTesting();
  });

  tearDown(() async {
    await DatabaseService.debugCloseDatabaseForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('v17 schema creates group id and system adjustment columns', () async {
    final db = await DatabaseService.database;
    final columns = await db.rawQuery('PRAGMA table_info(activity_records)');
    final columnNames = columns.map((row) => row['name']).toSet();

    expect(columnNames, contains('group_record_id'));
    expect(columnNames, contains('is_system_adjustment'));
    expect(await db.getVersion(), 17);
  });

  test('opening an existing v16 database creates a v16 backup before migration', () async {
    final legacyDb = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(version: 16),
    );
    await DatabaseService.debugCreateSchemaForTesting(legacyDb);
    await legacyDb.setVersion(16);
    await legacyDb.close();

    final db = await DatabaseService.database;
    expect(await db.getVersion(), 17);

    final backup = File('$dbPath.v16.bak');
    expect(await backup.exists(), isTrue);
    expect(await backup.length(), greaterThan(0));
  });
}
```

- [ ] **步骤 2：运行测试验证失败**

运行：`flutter test test/counter_records_source_of_truth_test.dart --plain-name "v17 schema creates group id and system adjustment columns"`

预期：FAIL，编译失败包含 `debugResetDatabaseForTesting` 未定义，或运行后 `Expected: <17> Actual: <16>`。

- [ ] **步骤 3：实现测试包装器、版本号、schema 列**

在 `lib/services/database_service.dart` 中：

1. 将 `_version` 改为：

```dart
  static const int _version = 17;
```

2. 在 `_createSchema` 的 `activity_records` 建表 SQL 中 `source_record_id TEXT,` 后加入：

```sql
        group_record_id TEXT,
        is_system_adjustment INTEGER NOT NULL DEFAULT 0,
```

3. 在 `_ensureLatestSchema` 的 `activityRecordTableName` 列表中加入：

```dart
        'group_record_id': 'TEXT',
        'is_system_adjustment': 'INTEGER NOT NULL DEFAULT 0',
```

4. 在类内加入测试包装器：

```dart
  @visibleForTesting
  static Future<void> debugResetDatabaseForTesting() async {
    await debugCloseDatabaseForTesting();
  }

  @visibleForTesting
  static Future<void> debugCloseDatabaseForTesting() async {
    final db = _database;
    _database = null;
    await db?.close();
  }

  @visibleForTesting
  static Future<void> debugCreateSchemaForTesting(DatabaseExecutor db) async {
    await _createSchema(db);
  }
```

- [ ] **步骤 4：运行 schema 测试验证通过**

运行：`flutter test test/counter_records_source_of_truth_test.dart --plain-name "v17 schema creates group id and system adjustment columns"`

预期：PASS。

- [ ] **步骤 5：运行备份测试验证失败**

运行：`flutter test test/counter_records_source_of_truth_test.dart --plain-name "opening an existing v16 database creates a v16 backup before migration"`

预期：FAIL，`Expected: true Actual: false`，因为尚未复制 `.v16.bak`。

- [ ] **步骤 6：实现打开前备份**

在 `_initDatabase()` 中计算 `path` 后、`openDatabase` 前加入：

```dart
    await _backupLegacyDatabaseBeforeV17Migration(path);
```

在 `_initDatabase` 后加入：

```dart
  static Future<void> _backupLegacyDatabaseBeforeV17Migration(String path) async {
    if (_version != 17) {
      return;
    }

    final dbFile = File(path);
    if (!await dbFile.exists()) {
      return;
    }

    final backupFile = File('$path.v16.bak');
    if (await backupFile.exists()) {
      return;
    }

    final existingVersion = await _readSqliteUserVersion(path);
    if (existingVersion >= 17) {
      return;
    }

    await dbFile.copy(backupFile.path);
  }

  static Future<int> _readSqliteUserVersion(String path) async {
    final probe = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    try {
      return await probe.getVersion();
    } finally {
      await probe.close();
    }
  }
```

Android 分支使用 sqflite 默认 factory；非 Android 测试使用 FFI。若 `readOnly` 在当前 sqflite 版本不可用，改为 `singleInstance: false` 并保持只读查询：

```dart
options: OpenDatabaseOptions(singleInstance: false),
```

- [ ] **步骤 7：运行备份测试验证通过**

运行：`flutter test test/counter_records_source_of_truth_test.dart --plain-name "opening an existing v16 database creates a v16 backup before migration"`

预期：PASS。

- [ ] **步骤 8：Commit**

```bash
git add lib/services/database_service.dart test/counter_records_source_of_truth_test.dart
git commit -m "test: 覆盖 v17 schema 与迁移备份"
```

---

### 任务 3：从 records 重算 counter 缓存

**文件：**
- 修改：`lib/services/database_service.dart:650`
- 修改：`test/counter_records_source_of_truth_test.dart`
- 修改：`lib/models/counter_model.dart:159`

- [ ] **步骤 1：编写失败的缓存重算测试**

在 `test/counter_records_source_of_truth_test.dart` 追加：

```dart
test('recalculateCounterTotals derives counter cache from records', () async {
  final db = await DatabaseService.database;
  final counterId = await db.insert('counters', {
    'name': '兔',
    'group_name': 'A团',
    'person_id': 101,
    'person_name': '兔本人',
    'count': 99,
    'color': '#ffffff',
    'is_hidden': 0,
    'three_inch_count': 99,
    'five_inch_count': 0,
    'unsigned_three_inch_count': 0,
    'unsigned_five_inch_count': 0,
    'group_cut_count': 0,
    'three_inch_shukudai_count': 0,
    'five_inch_shukudai_count': 0,
  });
  await db.insert('activity_records', {
    'record_type': 'counter',
    'source': 'local',
    'counter_id': counterId,
    'person_id': 101,
    'person_name': '兔本人',
    'subject_name': '兔',
    'group_name': 'A团',
    'occurred_at': DateTime(2026, 6, 28).toIso8601String(),
    'pricing_label': '',
    'three_inch_count': 3,
    'five_inch_count': 2,
    'unsigned_three_inch_count': 0,
    'unsigned_five_inch_count': 0,
    'group_cut_count': 0,
    'three_inch_shukudai_count': 0,
    'five_inch_shukudai_count': 0,
    'multi_cut_quantity': 0,
    'double_cut_quantity': 0,
    'ticket_quantity': 0,
    'total_amount': 0,
    'multi_participants_json': '[]',
    'custom_cheki_counts_json': '[]',
  });

  await DatabaseService.debugRecalculateCounterTotals(counterId);

  final row = (await db.query('counters', where: 'id = ?', whereArgs: [counterId])).single;
  expect(row['count'], 5);
  expect(row['three_inch_count'], 3);
  expect(row['five_inch_count'], 2);
});
```

- [ ] **步骤 2：运行测试验证失败**

运行：`flutter test test/counter_records_source_of_truth_test.dart --plain-name "recalculateCounterTotals derives counter cache from records"`

预期：FAIL，编译失败包含 `debugRecalculateCounterTotals` 未定义。

- [ ] **步骤 3：实现派生与重算方法**

在 `DatabaseService` 中加入：

```dart
  @visibleForTesting
  static Future<void> debugRecalculateCounterTotals(int counterId) async {
    final db = await database;
    await _recalculateCounterTotals(db, counterId);
  }

  static Future<Map<CounterCountField, int>> _deriveCounterTotals(
    DatabaseExecutor db,
    int counterId,
  ) async {
    final rows = await db.query(
      activityRecordTableName,
      where: 'counter_id = ? AND record_type IN (?, ?)',
      whereArgs: [counterId, ActivityRecordType.counter.dbValue, ActivityRecordType.multi.dbValue],
    );
    final totals = {for (final field in CounterCountField.values) field: 0};
    for (final row in rows) {
      final record = ActivityRecordModel.fromMap(row);
      for (final field in CounterCountField.values) {
        totals[field] = (totals[field] ?? 0) + record.countForField(field);
      }
    }
    return totals;
  }

  static Future<void> _recalculateCounterTotals(DatabaseExecutor db, int counterId) async {
    final totals = await _deriveCounterTotals(db, counterId);
    final count = totals.values.fold<int>(0, (sum, value) => sum + value);
    await db.update(
      tableName,
      {
        'count': count,
        'three_inch_count': totals[CounterCountField.threeInch] ?? 0,
        'five_inch_count': totals[CounterCountField.fiveInch] ?? 0,
        'unsigned_three_inch_count': totals[CounterCountField.unsignedThreeInch] ?? 0,
        'unsigned_five_inch_count': totals[CounterCountField.unsignedFiveInch] ?? 0,
        'group_cut_count': totals[CounterCountField.groupCut] ?? 0,
        'three_inch_shukudai_count': totals[CounterCountField.threeInchShukudai] ?? 0,
        'five_inch_shukudai_count': totals[CounterCountField.fiveInchShukudai] ?? 0,
      },
      where: 'id = ?',
      whereArgs: [counterId],
    );
  }
```

在 `lib/models/counter_model.dart` 的 `count` getter 前补充注释：

```dart
  // v17 起这些字段是 activity_records 派生缓存，只能由 DatabaseService 重建。
```

- [ ] **步骤 4：运行测试验证通过**

运行：`flutter test test/counter_records_source_of_truth_test.dart --plain-name "recalculateCounterTotals derives counter cache from records"`

预期：PASS。

- [ ] **步骤 5：Commit**

```bash
git add lib/services/database_service.dart lib/models/counter_model.dart test/counter_records_source_of_truth_test.dart
git commit -m "test: 覆盖记录派生缓存重算"
```


---

### 任务 4：v17 迁移拆分多人切并回填系统调整

**文件：**
- 修改：`lib/services/database_service.dart:69`
- 修改：`test/counter_records_source_of_truth_test.dart`

- [ ] **步骤 1：编写失败的 v17 迁移脏数据测试**

在 `test/counter_records_source_of_truth_test.dart` 追加：

```dart
test('v17 migration splits legacy multi rows and backfills only missing cache deltas', () async {
  final legacyDb = await databaseFactoryFfi.openDatabase(
    dbPath,
    options: OpenDatabaseOptions(version: 16),
  );
  await DatabaseService.debugCreateSchemaForTesting(legacyDb);
  await legacyDb.insert('counters', {
    'name': '兔',
    'group_name': 'A团',
    'person_id': 101,
    'person_name': '兔本人',
    'count': 10,
    'color': '#ffffff',
    'is_hidden': 0,
    'three_inch_count': 10,
    'five_inch_count': 0,
    'unsigned_three_inch_count': 0,
    'unsigned_five_inch_count': 0,
    'group_cut_count': 0,
    'three_inch_shukudai_count': 0,
    'five_inch_shukudai_count': 0,
  });
  await legacyDb.insert('counters', {
    'name': '萝北',
    'group_name': 'B团',
    'person_id': 202,
    'person_name': '萝北本人',
    'count': 1,
    'color': '#eeeeee',
    'is_hidden': 0,
    'three_inch_count': 1,
    'five_inch_count': 0,
    'unsigned_three_inch_count': 0,
    'unsigned_five_inch_count': 0,
    'group_cut_count': 0,
    'three_inch_shukudai_count': 0,
    'five_inch_shukudai_count': 0,
  });
  await legacyDb.insert('activity_records', {
    'record_type': 'multi',
    'source': 'local',
    'counter_id': null,
    'person_id': 101,
    'person_name': '兔本人',
    'subject_name': '兔',
    'secondary_subject_name': '萝北',
    'group_name': '跨团',
    'activity_name': '测试活动',
    'venue_name': '',
    'session_label': '',
    'note': '',
    'occurred_at': DateTime(2026, 6, 1).toIso8601String(),
    'pricing_label': '跨团多人切',
    'three_inch_count': 1,
    'five_inch_count': 0,
    'unsigned_three_inch_count': 0,
    'unsigned_five_inch_count': 0,
    'group_cut_count': 0,
    'three_inch_shukudai_count': 0,
    'five_inch_shukudai_count': 0,
    'multi_cut_quantity': 1,
    'double_cut_quantity': 1,
    'ticket_quantity': 0,
    'three_inch_price': 0,
    'five_inch_price': 0,
    'unsigned_three_inch_price': 0,
    'unsigned_five_inch_price': 0,
    'group_cut_price': 0,
    'double_cut_unit_price': 0,
    'three_inch_shukudai_price': 0,
    'five_inch_shukudai_price': 0,
    'ticket_unit_price': 0,
    'total_amount': 100,
    'multi_participants_json': '[{"memberName":"兔","groupName":"A团","personId":101,"personName":"兔本人"},{"memberName":"萝北","groupName":"B团","personId":202,"personName":"萝北本人"}]',
    'custom_cheki_counts_json': '[]',
  });
  await legacyDb.setVersion(16);
  await legacyDb.close();

  final db = await DatabaseService.database;
  final multiRows = await db.query('activity_records', where: 'record_type = ?', whereArgs: ['multi']);
  final adjustmentRows = await db.query('activity_records', where: 'is_system_adjustment = ?', whereArgs: [1]);
  final counters = await db.query('counters', orderBy: 'id ASC');

  expect(multiRows, hasLength(2));
  expect(multiRows.map((row) => row['group_record_id']).toSet(), hasLength(1));
  expect(multiRows.map((row) => row['counter_id']).toSet(), {1, 2});
  expect(multiRows.map((row) => row['person_id']).toSet(), {101, 202});
  expect(adjustmentRows, hasLength(1));
  expect(adjustmentRows.single['counter_id'], 1);
  expect(adjustmentRows.single['three_inch_count'], 9);
  expect(counters[0]['three_inch_count'], 10);
  expect(counters[1]['three_inch_count'], 1);
});
```

- [ ] **步骤 2：运行测试验证失败**

运行：`flutter test test/counter_records_source_of_truth_test.dart --plain-name "v17 migration splits legacy multi rows and backfills only missing cache deltas"`

预期：FAIL，`multiRows` 仍为 1 或没有 `is_system_adjustment` 回填记录。

- [ ] **步骤 3：接入 `_migrateToV17`**

在 `_onUpgrade` 中 `if (oldVersion < 16)` 后、`await _ensureLatestSchema(db);` 前加入：

```dart
    if (oldVersion < 17) {
      await _migrateToV17(db);
    }
```

在 `_migrateToV16` 后加入：

```dart
  static Future<void> _migrateToV17(Database db) async {
    await _ensureColumns(
      db,
      activityRecordTableName,
      {
        'group_record_id': 'TEXT',
        'is_system_adjustment': 'INTEGER NOT NULL DEFAULT 0',
      },
    );
    await _splitLegacyMultiRows(db);
    await _backfillSystemAdjustments(db);
    await _recalculateAllCounterTotals(db);
  }

  @visibleForTesting
  static Future<void> debugMigrateToV17(Database db) async {
    await _migrateToV17(db);
  }
```

- [ ] **步骤 4：实现拆分旧多人切行**

在 `database_service.dart` 加入：

```dart
  static Future<void> _splitLegacyMultiRows(DatabaseExecutor db) async {
    final rows = await db.query(
      activityRecordTableName,
      where: 'record_type = ? AND (group_record_id IS NULL OR group_record_id = \'\')',
      whereArgs: [ActivityRecordType.multi.dbValue],
      orderBy: 'id ASC',
    );

    final counters = (await db.query(tableName)).map(CounterModel.fromMap).toList(growable: false);
    for (final row in rows) {
      final record = ActivityRecordModel.fromMap(row);
      final recordId = record.id;
      if (recordId == null) {
        continue;
      }

      final groupRecordId = 'multi:$recordId';
      final counterIdByPersonId = <int, int>{};
      for (final counter in counters) {
        if (counter.id != null && counter.personId != null) {
          counterIdByPersonId[counter.personId!] = counter.id!;
        }
      }

      final participantRows = record.toParticipantRows(
        groupRecordId: groupRecordId,
        counterIdByParticipant: counterIdByPersonId,
      );
      await db.delete(activityRecordTableName, where: 'id = ?', whereArgs: [recordId]);
      for (final participantRecord in participantRows) {
        final values = await _filterValuesForTable(db, activityRecordTableName, _recordToDatabaseMap(participantRecord));
        await db.insert(activityRecordTableName, values, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
  }
```

- [ ] **步骤 5：实现系统调整回填和全量缓存重算**

在 `database_service.dart` 加入：

```dart
  static Future<void> _backfillSystemAdjustments(DatabaseExecutor db) async {
    final counters = (await db.query(tableName)).map(CounterModel.fromMap).toList(growable: false);
    for (final counter in counters) {
      if (counter.id == null) {
        continue;
      }
      final derived = await _deriveCounterTotals(db, counter.id!);
      final deltas = <CounterCountField, int>{};
      for (final field in CounterCountField.values) {
        final delta = counter.countForField(field) - (derived[field] ?? 0);
        if (delta != 0) {
          deltas[field] = delta;
        }
      }
      if (deltas.isEmpty) {
        continue;
      }
      final adjustment = ActivityRecordModel.counterAdjustment(
        counter: counter,
        occurredAt: DateTime.fromMillisecondsSinceEpoch(0),
        deltas: deltas,
        note: 'v17 迁移期初余额',
      ).copyWith(isSystemAdjustment: true);
      final values = await _filterValuesForTable(db, activityRecordTableName, _recordToDatabaseMap(adjustment));
      await db.insert(activityRecordTableName, values, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  static Future<void> _recalculateAllCounterTotals(DatabaseExecutor db) async {
    final counters = (await db.query(tableName)).map(CounterModel.fromMap).toList(growable: false);
    for (final counter in counters) {
      if (counter.id != null) {
        await _recalculateCounterTotals(db, counter.id!);
      }
    }
  }
```

本步骤引用的 `_deriveCounterTotals` 和 `_recalculateCounterTotals` 已在任务 3 实现（任务 3 现已前置于本任务），可直接调用。

- [ ] **步骤 6：运行迁移测试验证通过**

运行：`flutter test test/counter_records_source_of_truth_test.dart --plain-name "v17 migration splits legacy multi rows and backfills only missing cache deltas"`

预期：PASS。

- [ ] **步骤 7：Commit**

```bash
git add lib/services/database_service.dart test/counter_records_source_of_truth_test.dart
git commit -m "test: 覆盖 v17 脏数据迁移"
```

---
### 任务 5：事务化记录写入并禁止增量双写

**文件：**
- 修改：`lib/services/database_service.dart:812`
- 修改：`test/counter_records_source_of_truth_test.dart`

- [ ] **步骤 1：编写失败的 insert/update/delete 重算测试**

在 `test/counter_records_source_of_truth_test.dart` 追加：

```dart
test('record insert update and delete rebuild affected counter cache transactionally', () async {
  final counterId = await DatabaseService.insertCounter(
    CounterModel(
      name: '兔',
      groupName: 'A团',
      personId: 101,
      personName: '兔本人',
      color: '#ffffff',
    ),
  );

  final firstId = await DatabaseService.insertActivityRecord(
    ActivityRecordModel.counterAdjustment(
      counter: CounterModel(
        id: counterId,
        name: '兔',
        groupName: 'A团',
        personId: 101,
        personName: '兔本人',
        color: '#ffffff',
      ),
      occurredAt: DateTime(2026, 6, 28),
      deltas: const {CounterCountField.threeInch: 4},
    ),
  );
  expect((await DatabaseService.getCounters()).single.threeInchCount, 4);

  await DatabaseService.updateActivityRecord(
    firstId,
    ActivityRecordModel.counterAdjustment(
      counter: CounterModel(
        id: counterId,
        name: '兔',
        groupName: 'A团',
        personId: 101,
        personName: '兔本人',
        color: '#ffffff',
      ),
      occurredAt: DateTime(2026, 6, 28),
      deltas: const {CounterCountField.fiveInch: 2},
    ),
  );
  final afterUpdate = (await DatabaseService.getCounters()).single;
  expect(afterUpdate.threeInchCount, 0);
  expect(afterUpdate.fiveInchCount, 2);

  await DatabaseService.deleteActivityRecord(firstId);
  expect((await DatabaseService.getCounters()).single.count, 0);
});
```

在文件顶部补充导入：

```dart
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
```

- [ ] **步骤 2：运行测试验证失败**

运行：`flutter test test/counter_records_source_of_truth_test.dart --plain-name "record insert update and delete rebuild affected counter cache transactionally"`

预期：FAIL，插入记录后 counter 缓存仍为 0。

- [ ] **步骤 3：实现受影响 counter 收集和事务化写入**

在 `DatabaseService` 中加入：

```dart
  static Set<int> _affectedCounterIdsFromRecords(Iterable<ActivityRecordModel> records) {
    return records
        .map((record) => record.counterId)
        .whereType<int>()
        .toSet();
  }
```

将 `insertActivityRecord` 改为事务：

```dart
  static Future<int> insertActivityRecord(ActivityRecordModel record) async {
    final db = await database;
    return db.transaction((txn) async {
      final values = await _filterValuesForTable(txn, activityRecordTableName, _recordToDatabaseMap(record));
      final id = await txn.insert(activityRecordTableName, values, conflictAlgorithm: ConflictAlgorithm.replace);
      for (final counterId in _affectedCounterIdsFromRecords([record])) {
        await _recalculateCounterTotals(txn, counterId);
      }
      return id;
    });
  }
```

将 `updateActivityRecord` 改为先读旧记录再重算旧/新受影响 counter：

```dart
  static Future<void> updateActivityRecord(int id, ActivityRecordModel record) async {
    final db = await database;
    await db.transaction((txn) async {
      final oldRows = await txn.query(activityRecordTableName, where: 'id = ?', whereArgs: [id], limit: 1);
      final oldRecord = oldRows.isEmpty ? null : ActivityRecordModel.fromMap(oldRows.first);
      final values = await _filterValuesForTable(txn, activityRecordTableName, _recordToDatabaseMap(record));
      await txn.update(activityRecordTableName, values, where: 'id = ?', whereArgs: [id]);
      final affected = _affectedCounterIdsFromRecords([
        if (oldRecord != null) oldRecord,
        record,
      ]);
      for (final counterId in affected) {
        await _recalculateCounterTotals(txn, counterId);
      }
    });
  }
```

将 `deleteActivityRecord` 改为删除后重算旧记录 counter：

```dart
  static Future<void> deleteActivityRecord(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      final oldRows = await txn.query(activityRecordTableName, where: 'id = ?', whereArgs: [id], limit: 1);
      final oldRecord = oldRows.isEmpty ? null : ActivityRecordModel.fromMap(oldRows.first);
      await _deleteActivityRecordMediaRows(txn, recordIds: [id]);
      await txn.delete(activityRecordTableName, where: 'id = ?', whereArgs: [id]);
      for (final counterId in _affectedCounterIdsFromRecords([if (oldRecord != null) oldRecord])) {
        await _recalculateCounterTotals(txn, counterId);
      }
    });
  }
```

- [ ] **步骤 4：运行测试验证通过**

运行：`flutter test test/counter_records_source_of_truth_test.dart --plain-name "record insert update and delete rebuild affected counter cache transactionally"`

预期：PASS。

- [ ] **步骤 5：Commit**

```bash
git add lib/services/database_service.dart test/counter_records_source_of_truth_test.dart
git commit -m "test: 覆盖记录写入事务化重算"
```

---

### 任务 6：多人切按参与者创建并稳定 ID 匹配

**文件：**
- 修改：`lib/services/database_service.dart:812`
- 修改：`lib/main.dart:884`
- 修改：`lib/pages/member_detail_page.dart:351`
- 修改：`lib/pages/chart_page.dart:652`
- 修改：`test/counter_records_source_of_truth_test.dart`

- [ ] **步骤 1：编写失败的多人切插入和单人删除测试**

在 `test/counter_records_source_of_truth_test.dart` 追加：

```dart
test('multi cut insert creates participant rows and deleting one row does not affect others', () async {
  final rabbitId = await DatabaseService.insertCounter(CounterModel(
    name: '兔',
    groupName: 'A团',
    personId: 101,
    personName: '兔本人',
    color: '#ffffff',
  ));
  final luobeiId = await DatabaseService.insertCounter(CounterModel(
    name: '萝北',
    groupName: 'B团',
    personId: 202,
    personName: '萝北本人',
    color: '#eeeeee',
  ));

  await DatabaseService.insertActivityRecord(
    ActivityRecordModel.multiCut(
      participants: const [
        ActivityParticipant(memberName: '兔-旧名', groupName: 'A团', personId: 101, personName: '兔本人'),
        ActivityParticipant(memberName: '萝北', groupName: 'B团', personId: 202, personName: '萝北本人'),
      ],
      field: CounterCountField.threeInch,
      occurredAt: DateTime(2026, 6, 28),
      quantity: 1,
      totalPrice: 100,
    ),
  );

  final rows = (await DatabaseService.getActivityRecords()).where((record) => record.isMulti).toList();
  expect(rows, hasLength(2));
  expect(rows.map((record) => record.groupRecordId).toSet(), hasLength(1));
  expect(rows.map((record) => record.counterId).toSet(), {rabbitId, luobeiId});

  await DatabaseService.deleteActivityRecord(rows.firstWhere((record) => record.counterId == rabbitId).id!);
  final counters = await DatabaseService.getCounters();
  expect(counters.firstWhere((counter) => counter.id == rabbitId).count, 0);
  expect(counters.firstWhere((counter) => counter.id == luobeiId).count, 1);
  expect((await DatabaseService.getActivityRecords()).where((record) => record.isMulti), hasLength(1));
});
```

- [ ] **步骤 2：运行测试验证失败**

运行：`flutter test test/counter_records_source_of_truth_test.dart --plain-name "multi cut insert creates participant rows and deleting one row does not affect others"`

预期：FAIL，插入仍为 1 行或无法通过 personId 匹配 counter。

- [ ] **步骤 3：实现稳定 ID counter 查找与多人切批量插入**

在 `DatabaseService` 中加入：

```dart
  static Future<Map<int, int>> _counterIdByPersonId(DatabaseExecutor db) async {
    final rows = await db.query(tableName, columns: ['id', 'person_id']);
    return {
      for (final row in rows)
        if (row['id'] != null && row['person_id'] != null)
          (row['person_id'] as num).toInt(): (row['id'] as num).toInt(),
    };
  }

  static String _newGroupRecordId() {
    return 'multi:${DateTime.now().microsecondsSinceEpoch}';
  }
```

修改 `insertActivityRecord`：当 `record.isMulti && record.effectiveParticipants.length > 1 && record.groupRecordId == null`，在同一事务中调用 `record.toParticipantRows(groupRecordId: _newGroupRecordId(), counterIdByParticipant: await _counterIdByPersonId(txn))`，逐行 insert，返回第一行 id，并重算所有参与者 counter。

关键实现片段：

```dart
      final recordsToInsert = record.isMulti && record.effectiveParticipants.length > 1 && record.groupRecordId == null
          ? record.toParticipantRows(
              groupRecordId: _newGroupRecordId(),
              counterIdByParticipant: await _counterIdByPersonId(txn),
            )
          : [record];
      int? firstId;
      for (final item in recordsToInsert) {
        final values = await _filterValuesForTable(txn, activityRecordTableName, _recordToDatabaseMap(item));
        final insertedId = await txn.insert(activityRecordTableName, values, conflictAlgorithm: ConflictAlgorithm.replace);
        firstId ??= insertedId;
      }
      for (final counterId in _affectedCounterIdsFromRecords(recordsToInsert)) {
        await _recalculateCounterTotals(txn, counterId);
      }
      return firstId ?? 0;
```

- [ ] **步骤 4：移除页面双写调用**

在 `lib/pages/member_detail_page.dart` 中删除 `_applyRecordCounterImpact` 方法，并把 `_editRecord` try 块改为：

```dart
    try {
      await DatabaseService.updateActivityRecord(record.id!, updatedRecord);
      _dirty = true;
      await _loadData();
```

把 `_deleteRecord` try 块改为：

```dart
    try {
      await DatabaseService.deleteActivityRecord(record.id!);
      _dirty = true;
      await _loadData();
```

在 `lib/pages/chart_page.dart` 中删除 `_applyRecordCounterImpact` 方法，并把 `_saveNewRecord`、`_editRecord`、`_deleteRecord` 改为只调用 `DatabaseService.insertActivityRecord` / `updateActivityRecord` / `deleteActivityRecord` 后 `_loadData()`。

在 `lib/main.dart` 中保留 `_recordCounterChange` 创建记录，但不再在 `_saveCounter` 和 `_editCounter` 里先 `updateCounter` 后写记录；改为先 `insertActivityRecord`，再 `_loadCounters()` 或等待 DB 重算。

- [ ] **步骤 5：替换 `_findCounterForParticipantIn` 稳定 ID 匹配**

在 `lib/pages/member_detail_page.dart` 将 `_findCounterForParticipantIn` 改为：

```dart
  CounterModel? _findCounterForParticipantIn(
    List<CounterModel> counters,
    ActivityParticipant participant,
  ) {
    final personId = participant.personId;
    if (personId != null) {
      for (final counter in counters) {
        if (counter.personId == personId) {
          return counter;
        }
      }
    }

    final normalizedPersonName = _normalizedLookupPart(participant.personName);
    if (normalizedPersonName.isNotEmpty) {
      for (final counter in counters) {
        if (_normalizedLookupPart(counter.personName) == normalizedPersonName) {
          return counter;
        }
      }
    }

    return null;
  }
```

在 `lib/main.dart` 中所有多人切参与者聚合同样优先使用 `personId` / `personName`，不使用成员名 fallback 进行跨团合并。

- [ ] **步骤 6：运行测试验证通过**

运行：`flutter test test/counter_records_source_of_truth_test.dart --plain-name "multi cut insert creates participant rows and deleting one row does not affect others"`

预期：PASS。

- [ ] **步骤 7：运行受影响现有测试**

运行：`flutter test test/group_cut_logic_test.dart test/pricing_behavior_test.dart`

预期：PASS。

- [ ] **步骤 8：Commit**

```bash
git add lib/services/database_service.dart lib/main.dart lib/pages/member_detail_page.dart lib/pages/chart_page.dart test/counter_records_source_of_truth_test.dart
git commit -m "fix: 多人切按参与者行事务化写入"
```

---

### 任务 7：首页全局总览按 `group_record_id` 去重

**文件：**
- 修改：`lib/main.dart:486`
- 修改：`test/counter_records_source_of_truth_test.dart`

- [ ] **步骤 1：编写失败的全局去重测试**

在 `test/counter_records_source_of_truth_test.dart` 追加纯函数式测试辅助前，先在 `DatabaseService` 测试中验证 DB 派生事实：

```dart
test('global overview counts multi cut group record once while member cards count each participant', () async {
  final rabbitId = await DatabaseService.insertCounter(CounterModel(name: '兔', groupName: 'A团', personId: 101, personName: '兔本人', color: '#ffffff'));
  final luobeiId = await DatabaseService.insertCounter(CounterModel(name: '萝北', groupName: 'B团', personId: 202, personName: '萝北本人', color: '#eeeeee'));
  await DatabaseService.insertActivityRecord(ActivityRecordModel.multiCut(
    participants: const [
      ActivityParticipant(memberName: '兔', groupName: 'A团', personId: 101, personName: '兔本人'),
      ActivityParticipant(memberName: '萝北', groupName: 'B团', personId: 202, personName: '萝北本人'),
    ],
    field: CounterCountField.threeInch,
    occurredAt: DateTime(2026, 6, 28),
    quantity: 1,
    totalPrice: 100,
  ));

  final counters = await DatabaseService.getCounters();
  final memberCardTotal = counters.fold<int>(0, (sum, counter) => sum + counter.count);
  final records = await DatabaseService.getActivityRecords();
  final globalTotal = DatabaseService.debugGlobalOverviewTotalForTesting(records);

  expect(counters.firstWhere((counter) => counter.id == rabbitId).count, 1);
  expect(counters.firstWhere((counter) => counter.id == luobeiId).count, 1);
  expect(memberCardTotal, 2);
  expect(globalTotal, 1);
});
```

- [ ] **步骤 2：运行测试验证失败**

运行：`flutter test test/counter_records_source_of_truth_test.dart --plain-name "global overview counts multi cut group record once while member cards count each participant"`

预期：FAIL，编译失败包含 `debugGlobalOverviewTotalForTesting` 未定义。

- [ ] **步骤 3：实现可测试去重算法**

在 `DatabaseService` 中加入：

```dart
  @visibleForTesting
  static int debugGlobalOverviewTotalForTesting(List<ActivityRecordModel> records) {
    final seenMultiGroups = <String>{};
    var total = 0;
    for (final record in records) {
      if (record.isTicket) {
        continue;
      }
      if (record.isMulti) {
        final groupKey = record.groupRecordId?.trim().isNotEmpty == true
            ? record.groupRecordId!.trim()
            : 'multi-row:${record.id ?? record.hashCode}';
        if (seenMultiGroups.add(groupKey)) {
          total += record.multiTotalCount;
        }
        continue;
      }
      total += record.counterCountTotal;
    }
    return total;
  }
```

在 `lib/main.dart` 中重写 `_overviewTypeTotals` 和 `_overviewTotal`：

- counter records 直接累加。
- multi records 使用 `groupRecordId` 去重；每个 group 只贡献一次 `multiTotalCount` 到 `multiCountField.aggregatedBaseField`。
- 成员卡片 `_memberTotal` 保持按 counter cache 求和，因此多人切每参与者 +1。

核心代码形状：

```dart
    final seenMultiGroups = <String>{};
    for (final record in _activityRecords.where((record) => record.isMulti)) {
      final key = record.groupRecordId?.trim().isNotEmpty == true
          ? record.groupRecordId!.trim()
          : 'multi-row:${record.id ?? record.hashCode}';
      if (!seenMultiGroups.add(key)) {
        continue;
      }
      final field = record.multiCountField?.aggregatedBaseField;
      if (field != null) {
        totals[field] = (totals[field] ?? 0) + record.multiTotalCount;
      }
    }
```

- [ ] **步骤 4：运行测试验证通过**

运行：`flutter test test/counter_records_source_of_truth_test.dart --plain-name "global overview counts multi cut group record once while member cards count each participant"`

预期：PASS。

- [ ] **步骤 5：Commit**

```bash
git add lib/main.dart lib/services/database_service.dart test/counter_records_source_of_truth_test.dart
git commit -m "fix: 首页总览按多人切事件去重"
```

---

### 任务 8：周期统计排除系统调整，多人切汇总按事件归并

**文件：**
- 修改：`lib/pages/chart_page.dart:1019`
- 修改：`test/counter_records_source_of_truth_test.dart`
- 修改：`test/pricing_behavior_test.dart`

- [ ] **步骤 1：编写失败的周期统计过滤测试**

在 `test/counter_records_source_of_truth_test.dart` 追加：

```dart
test('period stats exclude system adjustment records but all-time totals keep them', () async {
  final counterId = await DatabaseService.insertCounter(CounterModel(
    name: '兔',
    groupName: 'A团',
    personId: 101,
    personName: '兔本人',
    color: '#ffffff',
  ));
  final counter = CounterModel(id: counterId, name: '兔', groupName: 'A团', personId: 101, personName: '兔本人', color: '#ffffff');
  await DatabaseService.insertActivityRecord(ActivityRecordModel.counterAdjustment(
    counter: counter,
    occurredAt: DateTime.fromMillisecondsSinceEpoch(0),
    deltas: const {CounterCountField.threeInch: 9},
    note: 'v17 迁移期初余额',
  ).copyWith(isSystemAdjustment: true));
  await DatabaseService.insertActivityRecord(ActivityRecordModel.counterAdjustment(
    counter: counter,
    occurredAt: DateTime(2026, 6, 28),
    deltas: const {CounterCountField.threeInch: -9},
    note: '用户手动补偿',
  ));

  final records = await DatabaseService.getActivityRecords();
  final juneRecords = DatabaseService.debugFilterPeriodRecordsForTesting(
    records,
    startInclusive: DateTime(2026, 6, 1),
    endExclusive: DateTime(2026, 7, 1),
  );

  expect((await DatabaseService.getCounters()).single.count, 0);
  expect(juneRecords, hasLength(1));
  expect(juneRecords.single.note, '用户手动补偿');
  expect(juneRecords.single.isSystemAdjustment, isFalse);
});
```

- [ ] **步骤 2：运行测试验证失败**

运行：`flutter test test/counter_records_source_of_truth_test.dart --plain-name "period stats exclude system adjustment records but all-time totals keep them"`

预期：FAIL，编译失败包含 `debugFilterPeriodRecordsForTesting` 未定义。

- [ ] **步骤 3：实现周期过滤辅助与 chart_page 过滤**

在 `DatabaseService` 中加入测试辅助：

```dart
  @visibleForTesting
  static List<ActivityRecordModel> debugFilterPeriodRecordsForTesting(
    List<ActivityRecordModel> records, {
    required DateTime startInclusive,
    required DateTime endExclusive,
  }) {
    return records.where((record) {
      if (record.isSystemAdjustment) {
        return false;
      }
      return !record.occurredAt.isBefore(startInclusive) &&
          record.occurredAt.isBefore(endExclusive);
    }).toList(growable: false);
  }
```

在 `lib/pages/chart_page.dart` 中找到 `_filteredRecords` 或构建 `filteredRecords` 的位置，确保当筛选范围是日/周/月/年时排除 `record.isSystemAdjustment`：

```dart
      if (record.isSystemAdjustment && _selectedRange != ChartRange.all) {
        return false;
      }
```

如果该页面没有 `ChartRange.all` 名称，使用现有的全量范围枚举值，保持语义为“全部不排除，周期排除”。

- [ ] **步骤 4：修正多人切汇总按 `group_record_id` 归并**

在 `chart_page.dart` 的 `multiSummaries` key 从：

```dart
final key = '$dateKey|$labelKey';
```

改为：

```dart
final key = record.groupRecordId?.trim().isNotEmpty == true
    ? record.groupRecordId!.trim()
    : '$dateKey|$labelKey|${record.id ?? record.hashCode}';
```

在计算 `summary.quantity` 时，同一 `group_record_id` 只增加一次全局数量；成员排行仍按参与者行逐个计入。

- [ ] **步骤 5：补充 pricing 测试确认系统调整仍保留价格行为**

在 `test/pricing_behavior_test.dart` 追加：

```dart
test('system adjustment flag does not change counter amount calculation', () {
  final record = ActivityRecordModel.counterAdjustment(
    counter: CounterModel(name: '测试成员', groupName: '测试团', color: '#ffffff'),
    occurredAt: DateTime.fromMillisecondsSinceEpoch(0),
    deltas: const {CounterCountField.threeInch: 3},
    pricing: GroupPricingModel.unconfigured('测试团'),
  ).copyWith(isSystemAdjustment: true);

  expect(record.isSystemAdjustment, isTrue);
  expect(record.counterCountTotal, 3);
  expect(record.shouldResolveWithCurrentPricing, isTrue);
});
```

- [ ] **步骤 6：运行测试验证通过**

运行：`flutter test test/counter_records_source_of_truth_test.dart --plain-name "period stats exclude system adjustment records but all-time totals keep them"`

预期：PASS。

运行：`flutter test test/pricing_behavior_test.dart --plain-name "system adjustment flag does not change counter amount calculation"`

预期：PASS。

- [ ] **步骤 7：Commit**

```bash
git add lib/pages/chart_page.dart lib/services/database_service.dart test/counter_records_source_of_truth_test.dart test/pricing_behavior_test.dart
git commit -m "fix: 周期统计排除系统调整记录"
```

---

### 任务 9：旧版导入与远程同步改为记录真相源

**文件：**
- 修改：`lib/main.dart:1594`
- 修改：`lib/services/database_service.dart:1059`
- 修改：`test/counter_records_source_of_truth_test.dart`

- [ ] **步骤 1：编写失败的旧版导入回填测试**

在 `test/counter_records_source_of_truth_test.dart` 追加：

```dart
test('legacy counter import creates system adjustment records instead of count-only truth', () async {
  await DatabaseService.importLegacyCountersAsAdjustmentsForTesting([
    CounterModel(
      name: '兔',
      groupName: 'A团',
      personId: 101,
      personName: '兔本人',
      color: '#ffffff',
      threeInchCount: 6,
      fiveInchCount: 2,
    ),
  ]);

  final counters = await DatabaseService.getCounters();
  final records = await DatabaseService.getActivityRecords();

  expect(counters.single.count, 8);
  expect(records, hasLength(1));
  expect(records.single.isSystemAdjustment, isTrue);
  expect(records.single.threeInchCount, 6);
  expect(records.single.fiveInchCount, 2);
});
```

- [ ] **步骤 2：运行测试验证失败**

运行：`flutter test test/counter_records_source_of_truth_test.dart --plain-name "legacy counter import creates system adjustment records instead of count-only truth"`

预期：FAIL，编译失败包含 `importLegacyCountersAsAdjustmentsForTesting` 未定义。

- [ ] **步骤 3：实现旧版导入 helper**

在 `DatabaseService` 中加入：

```dart
  @visibleForTesting
  static Future<void> importLegacyCountersAsAdjustmentsForTesting(List<CounterModel> counters) async {
    await importLegacyCountersAsAdjustments(counters);
  }

  static Future<void> importLegacyCountersAsAdjustments(List<CounterModel> counters) async {
    final db = await database;
    await db.transaction((txn) async {
      for (final counter in counters) {
        final counterValues = await _filterValuesForTable(txn, tableName, _toDatabaseMap(counter));
        final counterId = await txn.insert(tableName, counterValues, conflictAlgorithm: ConflictAlgorithm.replace);
        final persisted = counter.copyWith(id: counterId);
        final deltas = {
          for (final field in CounterCountField.values)
            if (persisted.countForField(field) != 0) field: persisted.countForField(field),
        };
        if (deltas.isNotEmpty) {
          final adjustment = ActivityRecordModel.counterAdjustment(
            counter: persisted,
            occurredAt: DateTime.fromMillisecondsSinceEpoch(0),
            deltas: deltas,
            note: '旧版备份导入期初余额',
          ).copyWith(isSystemAdjustment: true);
          final recordValues = await _filterValuesForTable(txn, activityRecordTableName, _recordToDatabaseMap(adjustment));
          await txn.insert(activityRecordTableName, recordValues, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await _recalculateCounterTotals(txn, counterId);
      }
    });
  }
```

在 `lib/main.dart` 的旧版导入处将：

```dart
        for (final counter in payload.counters) {
          await DatabaseService.insertCounter(counter);
        }
```

替换为：

```dart
        await DatabaseService.importLegacyCountersAsAdjustments(payload.counters);
```

- [ ] **步骤 4：修正远程同步增量双写**

在 `syncActivityRecordsToCounters` 中停止使用 `existingCounter.copyWith(threeInchCount: existing + record...)` 的增量累加。改为：

1. 确保 counter 存在并写入 `record.counterId`。
2. 只更新 `activity_records.counter_id/person_id/person_name` 和 `counter_sync_log`。
3. 每个受影响 counter 最后调用 `_recalculateCounterTotals(txn, counterId)`。

核心片段：

```dart
        final affectedCounterIds = <int>{};
        // 创建或更新 counter 身份与颜色，不写 count 字段增量
        // 更新 record.counter_id 后：
        affectedCounterIds.add(persistedCounter.id!);
        // transaction 末尾：
        for (final counterId in affectedCounterIds) {
          await _recalculateCounterTotals(txn, counterId);
        }
```

- [ ] **步骤 5：运行测试验证通过**

运行：`flutter test test/counter_records_source_of_truth_test.dart --plain-name "legacy counter import creates system adjustment records instead of count-only truth"`

预期：PASS。

- [ ] **步骤 6：Commit**

```bash
git add lib/main.dart lib/services/database_service.dart test/counter_records_source_of_truth_test.dart
git commit -m "fix: 旧版导入回填系统调整记录"
```

---

### 任务 10：最终验证与静态检查

**文件：**
- 修改：`lib/models/activity_record_model.dart`
- 修改：`lib/models/counter_model.dart`
- 修改：`lib/services/database_service.dart`
- 修改：`lib/main.dart`
- 修改：`lib/pages/member_detail_page.dart`
- 修改：`lib/pages/chart_page.dart`
- 修改：`test/group_cut_logic_test.dart`
- 修改：`test/pricing_behavior_test.dart`
- 创建：`test/counter_records_source_of_truth_test.dart`

- [ ] **步骤 1：运行聚焦测试套件**

运行：

```bash
flutter test test/counter_records_source_of_truth_test.dart test/group_cut_logic_test.dart test/pricing_behavior_test.dart
```

预期：PASS，所有新增和受影响模型/DB 测试通过。

- [ ] **步骤 2：运行现有 widget 启动测试**

运行：

```bash
flutter test test/widget_test.dart
```

预期：PASS，首页仍显示 `切奇总览`，最近提交记录入口仍可打开。

- [ ] **步骤 3：运行静态分析**

运行：

```bash
flutter analyze
```

预期：退出码 0，无新增 error。若出现旧有 warning，不修改无关文件，只修复本次变更导致的问题。

- [ ] **步骤 4：运行全量测试**

运行：

```bash
flutter test
```

预期：PASS。

- [ ] **步骤 5：检查双写残留**

运行：

```bash
rg "_applyRecordCounterImpact|changeCount\(|threeInchCount:\s*\(existingCounter|fiveInchCount:\s*\(existingCounter|groupCutCount:\s*\(existingCounter" lib test
```

预期：没有 `_applyRecordCounterImpact`；没有在记录写路径中对 `existingCounter` 的 count 字段增量累加。`CounterModel.changeCount` 方法本身可以保留给 UI 草稿使用，但不能在 `DatabaseService` 记录同步路径中命中。

- [ ] **步骤 6：Commit**

```bash
git add lib/models/activity_record_model.dart lib/models/counter_model.dart lib/services/database_service.dart lib/main.dart lib/pages/member_detail_page.dart lib/pages/chart_page.dart test/group_cut_logic_test.dart test/pricing_behavior_test.dart test/counter_records_source_of_truth_test.dart
git commit -m "test: 完成记录真相源重构验证"
```

---

## 自检清单

- 规格覆盖度：任务 1 覆盖模型字段与多人切行；任务 2 覆盖 schema v17 与备份；任务 3 覆盖迁移拆行、系统调整和缓存重建；任务 4 覆盖派生重算；任务 5 覆盖事务写路径；任务 6 覆盖稳定 ID 匹配和删除隔离；任务 7 覆盖全局去重；任务 8 覆盖周期统计排除系统调整；任务 9 覆盖旧版导入和远程同步；任务 10 覆盖验证。
- 占位符扫描：计划中没有“TODO”“待补充”“类似任务”“添加适当错误处理”等占位写法；每个代码步骤都给出可执行 Dart 或命令。
- 类型一致性：字段统一为 `groupRecordId` / `isSystemAdjustment`，数据库列统一为 `group_record_id` / `is_system_adjustment`，测试 wrapper 统一为 `debugMigrateToV17`、`debugRecalculateCounterTotals`、`debugResetDatabaseForTesting`、`debugCloseDatabaseForTesting`、`debugCreateSchemaForTesting`。
- 锁定决策：`activity_records` 是唯一真相源，`counters.count*` 只重建；多人切每人一行共享 `group_record_id`；全局按事件去重，成员卡每人 +1；系统调整计总数但排除周期统计；用户手动 `-9` 不删除；v17 打开前备份；目标 v1.5.0。

---

计划已完成并保存到 `docs/superpowers/plans/2026-06-28-counter-records-source-of-truth.md`。两种执行方式：

**1. 子代理驱动（推荐）** - 每个任务调度一个新的子代理，任务间进行审查，快速迭代

**2. 内联执行** - 在当前会话中使用 executing-plans 执行任务，批量执行并设有检查点

选哪种方式？

如果选择子代理驱动：必需子技能为 superpowers:subagent-driven-development，每个任务一个新子代理并进行两阶段审查。

如果选择内联执行：必需子技能为 superpowers:executing-plans，批量执行并设置检查点供审查。
