import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/main.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/idol_database_service.dart';
import 'package:ota_counter/widgets/counter_card.dart';

import 'support/isolated_test_databases.dart';

/// Quick count goes home page -> member detail -> count sheet. The sheet sends
/// absolute counter values; these tests pin that the saved records add up to
/// exactly the taps the user made, even when the home page's cached counters
/// are stale or a save is still in flight.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await useIsolatedTestDatabases();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'OTA Counter',
      packageName: 'test.ota',
      version: 'test',
      buildNumber: '0',
      buildSignature: '',
    );
    await DatabaseService.clearAppData();
    final idolDb = await IdolDatabaseService.database;
    await idolDb.delete('idol_members');
    await idolDb.delete('idol_groups');
    await idolDb.delete('idol_people');
    await idolDb.delete('idol_meta');
  });
  tearDown(() async => DatabaseService.clearAppData());

  // sqflite FFI completes on the real event loop, but the app code awaiting it
  // runs in the fake test zone and only advances when pumped. A save chain
  // (transaction + theme colors + reload) needs many such hops, so alternate
  // short real waits with pumps generously before reading the database.
  Future<void> settle(WidgetTester tester, {int hops = 40}) async {
    for (var i = 0; i < hops; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> openHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => tester.pumpWidget(const MyApp()));
    await settle(tester);
    expect(find.text('我的切奇'), findsOneWidget);
  }

  Future<void> openQuickCountFor(WidgetTester tester, String name) async {
    await tester.tap(find.byWidgetPredicate(
        (widget) => widget is CounterCard && widget.counter.name == name));
    await settle(tester);
    await tester.tap(find.widgetWithText(FloatingActionButton, '快捷计数'));
    await settle(tester);
  }

  Future<Map<String, int>> storedThreeInch() async {
    final counters = await DatabaseService.getCounters();
    return {
      for (final counter in counters)
        '${counter.groupName}/${counter.name}': counter.threeInchCount,
    };
  }

  Future<void> expectReplayUnchanged(WidgetTester tester) async {
    await tester.runAsync(() async {
      final before = await storedThreeInch();
      await DatabaseService.recalculateCountersFromActivityRecords();
      expect(await storedThreeInch(), before);
    });
  }

  testWidgets('quick count adds exactly one when the home page cache is stale',
      (tester) async {
    await tester.runAsync(() async {
      await DatabaseService.insertActivityRecordWithCounterImpact(
        ActivityRecordModel.counterAdjustment(
          counter: CounterModel(name: 'A', groupName: 'G', color: '#ffffff'),
          occurredAt: DateTime(2026, 11, 1),
          deltas: const {CounterCountField.threeInch: 2},
        ),
      );
    });
    await openHome(tester);

    // A record added behind the home page's back (background MCP sync, or an
    // edit made inside the member detail page that home has not reloaded).
    await tester.runAsync(() async {
      final a = (await DatabaseService.getCounters()).single;
      await DatabaseService.insertActivityRecordWithCounterImpact(
        ActivityRecordModel.counterAdjustment(
          counter: a,
          occurredAt: DateTime(2026, 11, 2),
          deltas: const {CounterCountField.threeInch: 3},
        ),
      );
    });

    await openQuickCountFor(tester, 'A');
    await tester.tap(find.text('+1').first);
    await settle(tester);

    expect(await tester.runAsync(storedThreeInch), {'G/A': 6});
    await expectReplayUnchanged(tester);
  });

  testWidgets(
      'rapid taps on another affiliation without a card are counted once each',
      (tester) async {
    await tester.runAsync(() async {
      final idolDb = await IdolDatabaseService.database;
      final personId = await idolDb.insert('idol_people', {'name': '甲'});
      for (final group in ['团一', '团二']) {
        final groupId = await idolDb.insert('idol_groups', {'name': group});
        await idolDb.insert('idol_members',
            {'name': '甲', 'group_id': groupId, 'person_id': personId});
      }
      await idolDb.insert('idol_meta',
          {'key': 'generated_at', 'value': '2099-01-01T00:00:00Z'});
      await DatabaseService.insertActivityRecordWithCounterImpact(
        ActivityRecordModel.counterAdjustment(
          counter: CounterModel(
            name: '甲',
            groupName: '团一',
            personId: personId,
            personName: '甲',
            color: '#ffffff',
          ),
          occurredAt: DateTime(2026, 11, 1),
          deltas: const {CounterCountField.threeInch: 1},
        ),
      );
    });
    await openHome(tester);
    await openQuickCountFor(tester, '甲');

    await tester.tap(find.text('团一 · 甲 · 当前卡片'));
    await settle(tester);
    await tester.tap(find.text('团二 · 甲').last);
    await settle(tester);

    // Second tap lands while the first save (which creates the card) is
    // still being written.
    await tester.tap(find.text('+1').first);
    await tester.pump();
    await tester.tap(find.text('+1').first);
    await tester.pump();
    await settle(tester);

    expect(await tester.runAsync(storedThreeInch), {'团一/甲': 1, '团二/甲': 2});
    await expectReplayUnchanged(tester);
  });
}
