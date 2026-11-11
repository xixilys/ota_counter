import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/pages/recent_records_page.dart';
import 'package:ota_counter/services/database_service.dart';

import 'support/isolated_test_databases.dart';

void main() {
  setUpAll(() async => useIsolatedTestDatabases());
  tearDown(() async => DatabaseService.clearAppData());

  testWidgets('group cut with no identified members remains visible',
      (tester) async {
    final record = ActivityRecordModel.multiCut(
      participants: const [],
      field: CounterCountField.groupCut,
      occurredAt: DateTime(2026, 3, 14),
      quantity: 2,
    ).copyWith(groupName: '一团');
    await tester.runAsync(() async {
      await DatabaseService.insertActivityRecordWithCounterImpact(record);
      await tester.pumpWidget(const MaterialApp(home: RecentRecordsPage()));
      for (var i = 0; i < 100 && find.text('一团 团切').evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('一团 团切'), findsOneWidget);
    expect(find.textContaining('成员待补'), findsOneWidget);
    expect(find.textContaining('2 张'), findsOneWidget);
    expect(find.textContaining('每人 2'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
