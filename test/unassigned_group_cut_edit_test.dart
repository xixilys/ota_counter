import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ota_counter/services/idol_database_service.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/pages/recent_records_page.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/widgets/add_activity_record_dialog.dart';

import 'support/isolated_test_databases.dart';

ActivityRecordModel unassignedGroupCut() => ActivityRecordModel(
      type: ActivityRecordType.multi,
      subjectName: '',
      groupName: 'G',
      occurredAt: DateTime(2026, 11, 10, 19, 23, 45),
      groupCutCount: 2,
      multiCutQuantity: 2,
      totalAmount: 200,
      note: '原备注',
      pricingLabel: '历史团切价',
    );

Finder textField(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );

Future<void> settleDatabaseWidgets(WidgetTester tester) async {
  // SQLite I/O needs the real event loop, interleaved with widget frames.
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await useIsolatedTestDatabases();
    SharedPreferences.setMockInitialValues({});
    await IdolDatabaseService.initializeBuiltInDataIfNeeded();
    await DatabaseService.database;
  });

  test('无成员团切经过编辑草稿 copyWith 和重建仍保留原团体', () {
    final original = unassignedGroupCut();
    final rebuilt = ActivityRecordDraft.fromRecord(original)
        .copyWith(note: '新备注')
        .toActivityRecord(pricings: const [])!;
    expect(rebuilt.groupName, original.groupName);
    expect(rebuilt.effectiveParticipants, isEmpty);
    expect(rebuilt.groupCutCount, 2);
    expect(rebuilt.effectiveMultiQuantity, 2);
    expect(rebuilt.totalAmount, 200);
    expect(rebuilt.occurredAt, original.occurredAt);
    expect(rebuilt.note, '新备注');
    expect(
      ActivityRecordDraft.fromRecord(original).preservedGroupCutGroupName,
      'G',
    );
  });

  test('空团名已有团切和普通新建草稿具有不同的保留状态', () {
    final original = ActivityRecordModel.multiCut(
      participants: const [],
      field: CounterCountField.groupCut,
      occurredAt: DateTime(2026, 11, 10),
      quantity: 2,
      totalPrice: 200,
    );
    final existingDraft =
        ActivityRecordDraft.fromRecord(original).copyWith(note: '新备注');
    expect(existingDraft.preservedGroupCutGroupName, '');
    final newDraft = ActivityRecordDraft(
      type: ActivityRecordType.multi,
      occurredAt: original.occurredAt,
      multiAsGroupCut: true,
    );
    expect(newDraft.preservedGroupCutGroupName, isNull);
    final rebuilt = existingDraft.toActivityRecord(pricings: const [])!;
    expect(rebuilt.groupName, '');
    expect(rebuilt.effectiveParticipants, isEmpty);
    expect(rebuilt.groupCutCount, 2);
    expect(rebuilt.totalAmount, 200);
    expect(rebuilt.occurredAt, original.occurredAt);
    expect(rebuilt.note, '新备注');
  });

  for (final hasGroupName in [true, false]) {
    testWidgets('数据库${hasGroupName ? '有' : '空'}团名无成员团切仅改备注可保存往返',
        (tester) async {
      final original = hasGroupName
          ? unassignedGroupCut()
          : ActivityRecordModel.multiCut(
              participants: const [],
              field: CounterCountField.groupCut,
              occurredAt: DateTime(2026, 11, 10, 20, 23, 45),
              quantity: 2,
              totalPrice: 200,
              note: '空团名原备注',
              pricingLabel: '历史团切价',
            );
      final id = await tester.runAsync(
        () => DatabaseService.insertActivityRecordWithCounterImpact(
          original,
        ),
      );
      await tester.pumpWidget(const MaterialApp(home: RecentRecordsPage()));
      await settleDatabaseWidgets(tester);
      final recordRow = find.textContaining(original.note);
      expect(recordRow, findsOneWidget);
      await tester.tap(recordRow);
      await settleDatabaseWidgets(tester);
      expect(find.text('编辑记录'), findsOneWidget);
      await tester.ensureVisible(textField('备注'));
      await tester.enterText(textField('备注'), '新备注');
      await tester.tap(find.text('保存修改'));
      await settleDatabaseWidgets(tester);
      expect(find.text('编辑记录'), findsNothing);
      expect(find.text('记录已更新'), findsOneWidget);
      final records = await tester.runAsync(DatabaseService.getActivityRecords);
      final saved = records!.singleWhere((record) => record.id == id);
      expect(saved.groupName, original.groupName);
      expect(saved.effectiveParticipants, isEmpty);
      expect(saved.multiCountField, CounterCountField.groupCut);
      expect(saved.groupCutCount, 2);
      expect(saved.multiCutQuantity, 2);
      expect(saved.totalAmount, 200);
      expect(saved.occurredAt, original.occurredAt);
      expect(saved.pricingLabel, '历史团切价');
      expect(saved.note, '新备注');
    });
  }

  for (final groupCut in [false, true]) {
    for (final count in [0, 1, 2]) {
      testWidgets('普通${groupCut ? '团切' : '多人切'}新建 $count 人仍按至少两人校验',
          (tester) async {
        ActivityRecordDraft? result;
        final draft = ActivityRecordDraft(
          type: ActivityRecordType.multi,
          occurredAt: DateTime(2026, 11, 10),
          multiAsGroupCut: groupCut,
          multiQuantity: 2,
          multiTotalPrice: 200,
          multiParticipants: [
            for (var i = 0; i < count; i++)
              ActivityParticipant(memberName: '成员$i', groupName: 'G'),
          ],
        );
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: Builder(builder: (context) {
            return TextButton(
              onPressed: () async {
                result = await showDialog<ActivityRecordDraft>(
                  context: context,
                  builder: (_) => AddActivityRecordDialog(
                    counters: const [],
                    pricings: const [],
                    initialDraft: draft,
                  ),
                );
              },
              child: const Text('open'),
            );
          })),
        ));
        await tester.tap(find.text('open'));
        await settleDatabaseWidgets(tester);
        await tester.tap(find.text('保存记录'));
        await tester.pumpAndSettle();
        if (count < 2) {
          expect(result, isNull);
          expect(find.byType(AddActivityRecordDialog), findsOneWidget);
        } else {
          expect(result, isNotNull);
          expect(result!.multiParticipants, hasLength(2));
          expect(find.byType(AddActivityRecordDialog), findsNothing);
        }
      });
    }
  }
}
