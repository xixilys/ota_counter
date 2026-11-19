import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/pages/member_detail_page.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/theme/app_theme.dart';
import 'package:ota_counter/widgets/counter_count_sheet.dart';

import 'support/isolated_test_databases.dart';

Widget _app(CounterModel counter) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: MemberDetailPage(
      displayCounter: counter,
      primaryCounter: counter,
      sourceCounters: [counter],
      onCounterChanged: (updatedCounter, occurredAt,
              {activityName = '',
              venueName = '',
              sessionLabel = '',
              baseCounter}) async =>
          CounterSaveResult(counter: updatedCounter),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => useIsolatedTestDatabases());

  setUp(() async {
    await DatabaseService.clearAppData();
  });

  test('legacy missing dates are recognised as unknown', () {
    expect(isUnknownActivityRecordDay(DateTime(1970, 1, 1)), isTrue);
    expect(isUnknownActivityRecordDay(DateTime(1970, 1, 1, 7, 30)), isTrue);
    expect(isUnknownActivityRecordDay(DateTime(1969, 12, 31)), isTrue);
    expect(isUnknownActivityRecordDay(DateTime(2026, 3, 14)), isFalse);
    expect(isUnknownActivityRecordDay(DateTime(2025, 11, 9, 10, 55)), isFalse);
  });

  testWidgets(
      'member detail shows a missing date as 日期未知 sorted last, without rewriting the record',
      (tester) async {
    final counter = CounterModel(
      name: 'Remi',
      groupName: 'PromisedLand',
      personId: 8,
      personName: 'Remi',
      color: '#F472B6',
      threeInchCount: 246,
      groupCutCount: 1,
      threeInchShukudaiCount: 1,
    );
    final counterId = await tester.runAsync(
      () => DatabaseService.insertCounter(counter),
    );

    final known = ActivityRecordModel(
      type: ActivityRecordType.counter,
      subjectName: 'Remi',
      groupName: 'PromisedLand',
      personId: 8,
      personName: 'Remi',
      occurredAt: DateTime(2025, 11, 9, 10, 55),
      threeInchCount: 246,
      totalAmount: 14760,
    );
    final legacy = ActivityRecordModel(
      type: ActivityRecordType.counter,
      subjectName: 'Remi',
      groupName: 'PromisedLand',
      personId: 8,
      personName: 'Remi',
      occurredAt: DateTime(1970, 1, 1, 7, 30),
      threeInchCount: 246,
      totalAmount: 14960,
      note: 'v17 迁移期初余额',
    );
    await tester.runAsync(() async {
      await DatabaseService.insertActivityRecord(known);
      await DatabaseService.insertActivityRecord(legacy);
    });

    tester.view.physicalSize = const Size(600, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final saved = counter.copyWith(id: counterId);
    await tester.runAsync(() async {
      await tester.pumpWidget(_app(saved));
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();

    expect(find.text('2025-11-09'), findsOneWidget);
    expect(find.text('日期未知'), findsOneWidget);
    expect(find.textContaining('1970-01-01'), findsNothing);
    expect(find.text('v17 迁移期初余额'), findsNothing,
        reason: 'the summary row may clip but the note remains in stored data');

    final knownY = tester.getTopLeft(find.text('2025-11-09')).dy;
    final unknownY = tester.getTopLeft(find.text('日期未知')).dy;
    expect(unknownY, greaterThan(knownY),
        reason: 'unknown-date journal page must sort last');

    final stored = await tester.runAsync(DatabaseService.getActivityRecords);
    final legacyRows = stored!.where(
      (record) => record.note == 'v17 迁移期初余额',
    );
    expect(legacyRows, hasLength(1));
    expect(legacyRows.first.occurredAt.year, 1970,
        reason: 'display must not rewrite the stored date');

    expect(tester.takeException(), isNull);
  });
}
