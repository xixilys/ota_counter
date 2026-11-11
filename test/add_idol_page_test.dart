import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/idol_database_models.dart';
import 'package:ota_counter/pages/add_idol_page.dart';
import 'package:ota_counter/services/idol_database_service.dart';
import 'package:ota_counter/theme/app_theme.dart';

import 'support/isolated_test_databases.dart';

class _AddPageHost extends StatefulWidget {
  final List<CounterModel> existingCounters;

  const _AddPageHost({super.key, required this.existingCounters});

  @override
  State<_AddPageHost> createState() => _AddPageHostState();
}

class _AddPageHostState extends State<_AddPageHost> {
  List<CounterModel>? result;

  void _open() {
    Navigator.of(context)
        .push<List<CounterModel>>(
          MaterialPageRoute(
            builder: (context) => AddIdolPage(
              existingCounters: widget.existingCounters,
              autoSync: false,
              autoFocusSearch: false,
            ),
          ),
        )
        .then((value) {
      if (!mounted) {
        return;
      }
      setState(() {
        result = value;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: _open,
          child: const Text('打开添加偶像'),
        ),
      ),
    );
  }
}

final _existingCounters = <CounterModel>[
  CounterModel(
    id: 1,
    name: '早川',
    groupName: '终到站Terminus',
    personId: 7,
    personName: '早川',
    color: '#FFE135',
  ),
  CounterModel(
    id: 2,
    name: '夏小米',
    groupName: 'PokaPokaTime',
    color: '#8B6CF0',
  ),
];

Future<_AddPageHostState> _openAddPage(WidgetTester tester) async {
  final hostKey = GlobalKey<_AddPageHostState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: _AddPageHost(key: hostKey, existingCounters: _existingCounters),
    ),
  );
  await tester.tap(find.text('打开添加偶像'));
  await tester.pump();
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      break;
    }
  }
  await tester.pump(const Duration(milliseconds: 300));
  return hostKey.currentState!;
}

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField).first, query);
  await tester.pump();
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await useIsolatedTestDatabases();
  });

  setUp(() async {
    final db = await IdolDatabaseService.database;
    await db.delete('idol_members');
    await db.delete('idol_groups');
    await db.delete('idol_people');
    await db.delete('idol_meta');

    final terminus = await IdolDatabaseService.upsertGroup(
      const IdolGroup(name: '终到站Terminus', isBuiltIn: true),
    );
    final another = await IdolDatabaseService.upsertGroup(
      const IdolGroup(name: '另一团', isBuiltIn: true),
    );
    final poka = await IdolDatabaseService.upsertGroup(
      const IdolGroup(name: 'PokaPokaTime', isBuiltIn: true),
    );
    for (final name in ['早川', '一绪', '盈盈', '透']) {
      await IdolDatabaseService.upsertMember(
        IdolMember(groupId: terminus, groupName: '终到站Terminus', name: name),
      );
    }
    for (final name in ['早川', '小满']) {
      await IdolDatabaseService.upsertMember(
        IdolMember(groupId: another, groupName: '另一团', name: name),
      );
    }
    for (final name in ['夏小米', '皮皮猪']) {
      await IdolDatabaseService.upsertMember(
        IdolMember(groupId: poka, groupName: 'PokaPokaTime', name: name),
      );
    }

    // Stop initializeBuiltInDataIfNeeded from merging the full APK seed: it
    // only re-seeds when the asset snapshot is newer than this marker.
    await db.insert(
      'idol_meta',
      {'key': 'generated_at', 'value': '2099-01-01T00:00:00Z'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  });

  testWidgets('add page shortcuts show followed groups and missing members', (
    tester,
  ) async {
    await _openAddPage(tester);

    expect(find.text('添加偶像'), findsOneWidget);
    expect(find.text('继续添加'), findsOneWidget);
    expect(find.text('终到站Terminus'), findsOneWidget);
    expect(find.text('PokaPokaTime'), findsOneWidget);
    // 早川 is already on the home page, so only the other three are shortcuts.
    expect(find.text('一绪'), findsOneWidget);
    expect(find.text('早川'), findsNothing);
    expect(find.text('皮皮猪'), findsOneWidget);
    expect(find.text('夏小米'), findsNothing);
  });

  testWidgets('search matches member names, group names and initials', (
    tester,
  ) async {
    await _openAddPage(tester);

    await _search(tester, '早川');
    expect(find.text('早川 · 终到站Terminus'), findsOneWidget);
    expect(find.text('早川 · 另一团'), findsOneWidget);
    expect(find.text('已添加'), findsOneWidget);
    expect(find.text('已选 0 位'), findsNothing);

    await _search(tester, '终到站');
    expect(find.text('团体「终到站Terminus」 · 4 位成员'), findsOneWidget);
    expect(find.text('一绪 · 终到站Terminus'), findsOneWidget);
    expect(find.text('盈盈 · 终到站Terminus'), findsOneWidget);
    expect(find.text('透 · 终到站Terminus'), findsOneWidget);

    await _search(tester, 'zdz');
    expect(find.text('一绪 · 终到站Terminus'), findsOneWidget);
    expect(find.text('盈盈 · 终到站Terminus'), findsOneWidget);

    await _search(tester, 'xm');
    expect(find.text('夏小米 · PokaPokaTime'), findsOneWidget);

    await _search(tester, 'yx');
    expect(find.text('一绪 · 终到站Terminus'), findsOneWidget);
    await tester.tap(find.text('一绪 · 终到站Terminus'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 位'), findsOneWidget);
  });

  testWidgets('multi-select adds every chosen member from one group', (
    tester,
  ) async {
    final host = await _openAddPage(tester);
    await _search(tester, '终到站');

    await tester.tap(find.text('一绪 · 终到站Terminus'));
    await tester.pump();
    await tester.tap(find.text('盈盈 · 终到站Terminus'));
    await tester.pump();
    expect(find.text('已选 2 位'), findsOneWidget);
    expect(find.text('添加 2 位'), findsOneWidget);

    await tester.tap(find.text('添加 2 位'));
    await tester.pumpAndSettle();

    expect(host.result, isNotNull);
    expect(host.result, hasLength(2));
    expect(
      host.result!.map((counter) => counter.name).toSet(),
      {'一绪', '盈盈'},
    );
    expect(
      host.result!.map((counter) => counter.groupName).toSet(),
      {'终到站Terminus'},
    );
  });

  testWidgets('already added member is disabled and cannot be selected', (
    tester,
  ) async {
    await _openAddPage(tester);
    await _search(tester, '早川');

    final addedTile = find.ancestor(
      of: find.text('早川 · 终到站Terminus'),
      matching: find.byType(ListTile),
    );
    expect(tester.widget<ListTile>(addedTile).enabled, isFalse);
    expect(find.text('已添加'), findsOneWidget);

    await tester.tap(find.text('早川 · 终到站Terminus'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选'), findsNothing);
  });

  testWidgets('manual add fallback collects a name and group', (tester) async {
    final host = await _openAddPage(tester);
    await _search(tester, '不存在的人');

    expect(find.text('没有找到「不存在的人」'), findsOneWidget);
    await tester.tap(find.text('库里没有？手动添加'));
    await tester.pumpAndSettle();

    expect(find.text('手动添加'), findsOneWidget);
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), '小满');
    await tester.enterText(fields.at(1), '自定义团体');
    await tester.tap(find.text('添加到已选'));
    await tester.pumpAndSettle();

    expect(find.text('小满 · 自定义团体'), findsOneWidget);
    await tester.tap(find.text('添加 1 位'));
    await tester.pumpAndSettle();

    expect(host.result, hasLength(1));
    expect(host.result!.single.name, '小满');
    expect(host.result!.single.groupName, '自定义团体');
  });

  testWidgets('same-person choice stays off by default', (tester) async {
    final host = await _openAddPage(tester);
    await _search(tester, '另一团');

    await tester.tap(find.text('早川 · 另一团'));
    await tester.pumpAndSettle();
    final choice = find.text('和已有的「早川（终到站Terminus）」算同一个人');
    expect(choice, findsOneWidget);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isFalse,
    );

    await tester.tap(find.text('添加 1 位'));
    await tester.pumpAndSettle();

    expect(host.result, hasLength(1));
    expect(host.result!.single.personId, isNull);
    expect(host.result!.single.personName, isEmpty);
  });

  testWidgets('same-person choice links to the existing person when checked', (
    tester,
  ) async {
    final host = await _openAddPage(tester);
    await _search(tester, '另一团');

    await tester.tap(find.text('早川 · 另一团'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isTrue,
    );

    await tester.tap(find.text('添加 1 位'));
    await tester.pumpAndSettle();

    expect(host.result, hasLength(1));
    expect(host.result!.single.personId, 7);
    expect(host.result!.single.personName, '早川');
  });
}
