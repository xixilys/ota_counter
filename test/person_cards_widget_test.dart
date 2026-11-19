import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/idol_database_models.dart';
import 'package:ota_counter/pages/member_detail_page.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/idol_database_service.dart';
import 'package:ota_counter/services/person_card_service.dart';
import 'package:ota_counter/theme/app_theme.dart';
import 'package:ota_counter/widgets/person/person_cards_sheet.dart';
import 'package:ota_counter/widgets/counter_count_sheet.dart';
import 'package:ota_counter/widgets/person/person_group_switcher.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await useIsolatedTestDatabases();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PersonCardService.load();
    await DatabaseService.clearAppData();
    final db = await IdolDatabaseService.database;
    await db.delete('idol_members');
    await db.delete('idol_groups');
    await db.delete('idol_people');
    await db.delete('idol_meta');
  });

  tearDown(() async {
    await DatabaseService.clearAppData();
  });

  tearDownAll(() async {
    await (await DatabaseService.database).close();
    await (await IdolDatabaseService.database).close();
  });

  Future<List<CounterModel>> seed() async {
    final groupAId =
        await IdolDatabaseService.upsertGroup(const IdolGroup(name: '跨团 A'));
    final groupBId =
        await IdolDatabaseService.upsertGroup(const IdolGroup(name: '跨团 B'));
    await IdolDatabaseService.upsertMember(IdolMember(
      groupId: groupAId,
      groupName: '跨团 A',
      name: 'P在A',
      personName: '真人P',
    ));
    await IdolDatabaseService.upsertMember(IdolMember(
      groupId: groupBId,
      groupName: '跨团 B',
      name: 'P在B',
      personName: '真人P',
    ));
    final members = await IdolDatabaseService.getMembers();
    final a = members.singleWhere((member) => member.groupName == '跨团 A');
    final b = members.singleWhere((member) => member.groupName == '跨团 B');
    await DatabaseService.insertCounter(CounterModel(
      name: a.name,
      groupName: a.groupName,
      personId: a.personId,
      personName: '真人P',
      color: '#F0427A',
      threeInchCount: 4,
    ));
    await DatabaseService.insertCounter(CounterModel(
      name: b.name,
      groupName: b.groupName,
      personId: b.personId,
      personName: '真人P',
      color: '#3B8BEB',
      fiveInchCount: 3,
    ));
    return DatabaseService.getCounters();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('also-in switcher shows every group and switches the card',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final counters = await tester.runAsync(seed) ?? const [];
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) {
            var selected = counters.first;
            return StatefulBuilder(
              builder: (context, setState) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PersonGroupSwitcher(
                    cards: counters,
                    selected: selected,
                    onSelected: (card) => setState(() => selected = card),
                    onManage: () {},
                  ),
                  Text('当前：${selected.groupName}'),
                ],
              ),
            );
          },
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('也在'), findsOneWidget);
    expect(find.text('跨团 A'), findsOneWidget);
    expect(find.text('跨团 B'), findsOneWidget);
    expect(find.text('当前：跨团 A'), findsOneWidget);

    await tester.tap(find.text('跨团 B'));
    await tester.pump();
    expect(find.text('当前：跨团 B'), findsOneWidget);
  });

  testWidgets('manager lists both cards, current / past and recent activity',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final counters = await tester.runAsync(seed) ?? const [];
    await tester.runAsync(() => PersonCardService.setCurrentCard(
          counters.first,
          counters.last.id,
        ));
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: SizedBox(
          height: 700,
          child: PersonCardsPanel(anchor: counters.first),
        ),
      ),
    ));
    await settle(tester);

    expect(find.text('真人P'), findsOneWidget);
    expect(find.textContaining('同一真人 · 2 个团籍'), findsOneWidget);
    expect(find.text('跨团 A'), findsOneWidget);
    expect(find.text('跨团 B'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
    expect(find.textContaining('张切奇'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('sheet opens from a home-like card action and closes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final counters = await tester.runAsync(seed) ?? const [];
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => showPersonCardsSheet(
                context,
                anchor: counters.first,
              ),
              child: const Text('打开跨团'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开跨团'));
    await settle(tester);
    expect(find.text('真人P'), findsWidgets);
    expect(find.textContaining('同一真人 · 2 个团籍'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('member detail shows the also-in switcher without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final counters = await tester.runAsync(seed) ?? const [];
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: MemberDetailPage(
        displayCounter: counters.first.copyWith(
          name: '真人P',
          groupName: '跨团 A / 跨团 B',
        ),
        primaryCounter: counters.first,
        sourceCounters: counters,
        onCounterChanged: (updated, occurredAt,
                {activityName = '',
                venueName = '',
                sessionLabel = '',
                baseCounter}) async =>
            CounterSaveResult(counter: updated),
      ),
    ));
    await settle(tester);
    expect(find.text('也在'), findsOneWidget);
    expect(find.text('跨团 A'), findsOneWidget);
    expect(find.text('跨团 B'), findsOneWidget);
    expect(find.byIcon(Icons.groups_2_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
