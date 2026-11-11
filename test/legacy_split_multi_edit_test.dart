import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/group_pricing_model.dart';
import 'package:ota_counter/pages/recent_records_page.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/idol_database_service.dart';
import 'package:ota_counter/widgets/add_activity_record_dialog.dart';

import 'support/isolated_test_databases.dart';

ActivityRecordModel splitRow(int index, {bool explicitParticipants = true}) {
  final participant = ActivityParticipant(
    memberName: '拆行成员$index',
    groupName: '拆行团',
    personId: 9000 + index,
    personName: '真人$index',
  );
  return ActivityRecordModel(
    type: ActivityRecordType.multi,
    groupRecordId: 'legacy-split',
    subjectName: participant.memberName,
    groupName: participant.groupName,
    personId: participant.personId,
    personName: participant.personName,
    occurredAt: DateTime(2026, 11, 10, 19, 23, 45),
    activityName: '历史活动',
    venueName: '历史场地',
    sessionLabel: '夜场',
    note: '拆行原备注$index',
    pricingLabel: '历史多人价',
    threeInchCount: 1,
    threeInchPrice: 60,
    doubleCutUnitPrice: 60,
    multiCutQuantity: 1,
    totalAmount: 60,
    participants: explicitParticipants ? [participant] : const [],
  );
}

Finder textField(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );

Future<void> settleDatabaseWidgets(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }
}

GroupPricingModel currentPricing() => GroupPricingModel.unconfigured('拆行团')
    .copyWith(label: '当前价（不得覆盖历史空标签）', doubleCutPrice: 240);

Future<ActivityRecordDraft> editDialog(
  WidgetTester tester,
  ActivityRecordDraft draft, {
  String note = '新备注',
  CounterCountField? selectField,
}) async {
  ActivityRecordDraft? result;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: Builder(builder: (context) {
      return TextButton(
        onPressed: () async {
          result = await showDialog<ActivityRecordDraft>(
            context: context,
            builder: (_) => AddActivityRecordDialog(
              counters: const [],
              pricings: [currentPricing()],
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
  if (draft.preserveUnspecifiedMultiField) {
    expect(
        tester
            .widgetList<ChoiceChip>(find.byType(ChoiceChip))
            .every((chip) => !chip.selected),
        isTrue);
  }
  if (selectField != null) {
    final chip = find.widgetWithText(ChoiceChip, selectField.label);
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pump();
  }
  await tester.ensureVisible(textField('备注'));
  await tester.enterText(textField('备注'), note);
  await tester.tap(find.text('保存记录'));
  await tester.pumpAndSettle();
  expect(find.byType(AddActivityRecordDialog), findsNothing);
  expect(result, isNotNull);
  return result!;
}

Future<List<ActivityRecordModel>> seedPair(ActivityRecordModel original) async {
  final db = await DatabaseService.database;
  await db.delete(DatabaseService.activityRecordTableName);
  await DatabaseService.insertActivityRecordWithCounterImpact(original);
  await DatabaseService.insertActivityRecordWithCounterImpact(splitRow(1));
  return DatabaseService.getActivityRecords();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await useIsolatedTestDatabases();
    SharedPreferences.setMockInitialValues({});
    await IdolDatabaseService.initializeBuiltInDataIfNeeded();
    await DatabaseService.database;
  });

  test('拆行草稿 copyWith 保留分组及历史金额元数据', () {
    final original = splitRow(0).copyWith(
      id: 123,
      groupRecordId: ' legacy-split ',
    );
    final rebuilt = ActivityRecordDraft.fromRecord(original)
        .copyWith(note: '新备注')
        .toActivityRecord(pricings: const [], id: original.id)!;
    expect(rebuilt.toMap(), original.toMap()..['note'] = '新备注');
  });

  for (final explicitParticipants in [true, false]) {
    testWidgets('单人拆行${explicitParticipants ? '明确' : '旧字段'}参与者编辑保存只更新原行',
        (tester) async {
      final ids = <int>[];
      await tester.runAsync(() async {
        // Each scenario has exactly two physical DB rows, sharing one group id.
        final db = await DatabaseService.database;
        await db.delete(DatabaseService.activityRecordTableName);
        for (var i = 0; i < 2; i++) {
          ids.add(await DatabaseService.insertActivityRecordWithCounterImpact(
            splitRow(i, explicitParticipants: explicitParticipants),
          ));
        }
      });
      final before =
          (await tester.runAsync(DatabaseService.getActivityRecords))!;
      expect(before, hasLength(2));
      expect(before.map((r) => r.groupRecordId).toSet(), {'legacy-split'});
      expect(before.every((r) => r.effectiveParticipants.length == 1), isTrue);
      final countersBefore = await tester.runAsync(DatabaseService.getCounters);

      await tester.pumpWidget(const MaterialApp(home: RecentRecordsPage()));
      await settleDatabaseWidgets(tester);
      await tester.tap(find.textContaining('拆行原备注0'));
      await settleDatabaseWidgets(tester);
      expect(find.text('编辑记录'), findsOneWidget);
      await tester.ensureVisible(textField('备注'));
      await tester.enterText(textField('备注'), '拆行修改后');
      await tester.tap(find.text('保存修改'));
      await settleDatabaseWidgets(tester);
      expect(find.text('编辑记录'), findsNothing);
      expect(find.text('记录已更新'), findsOneWidget);

      final after =
          (await tester.runAsync(DatabaseService.getActivityRecords))!;
      expect(after, hasLength(2));
      for (final original in before) {
        final saved = after.singleWhere((r) => r.id == original.id);
        expect(
            saved.toMap(),
            original.toMap()
              ..['note'] = original.id == ids.first ? '拆行修改后' : original.note);
        expect(saved.effectiveMultiQuantity, 1);
        expect(saved.totalAmount, 60);
      }
      final countersAfter = await tester.runAsync(DatabaseService.getCounters);
      expect(countersAfter!.map((c) => c.toMap()).toList(),
          countersBefore!.map((c) => c.toMap()).toList());

      // A later quantity/price change still edits only this row, even when
      // it no longer matches its sibling's projection values.
      final edited = after.singleWhere((r) => r.id == ids.first);
      final changed = ActivityRecordDraft.fromRecord(edited)
          .copyWith(multiQuantity: 2, multiTotalPrice: 90)
          .toActivityRecord(pricings: const [], id: edited.id)!;
      await tester.runAsync(
        () => DatabaseService.updateActivityRecordWithCounterImpact(
          edited.id!,
          changed,
        ),
      );
      final changedRows =
          (await tester.runAsync(DatabaseService.getActivityRecords))!;
      expect(changedRows, hasLength(2));
      final changedRow = changedRows.singleWhere((r) => r.id == ids.first);
      expect(changedRow.groupRecordId, 'legacy-split');
      expect(changedRow.effectiveMultiQuantity, 2);
      expect(changedRow.totalAmount, 90);
      expect(changedRows.singleWhere((r) => r.id == ids.last).toMap(),
          before.singleWhere((r) => r.id == ids.last).toMap());

      // The existing delete path must also remain scoped to the chosen row ID.
      await tester.runAsync(
        () => DatabaseService.deleteActivityRecordWithCounterImpact(ids.first),
      );
      final remaining =
          (await tester.runAsync(DatabaseService.getActivityRecords))!;
      expect(remaining, hasLength(1));
      expect(remaining.single.toMap(),
          before.singleWhere((r) => r.id == ids.last).toMap());
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('拆行增员保存后再次改备注仍保留关联及全部历史价格元数据', (tester) async {
    final before = (await tester.runAsync(() => seedPair(splitRow(0))))!;
    final original = before.singleWhere((r) => r.subjectName == '拆行成员0');
    final brother = before.singleWhere((r) => r.id != original.id);
    final secondParticipant = splitRow(2).effectiveParticipants.single;
    final firstDraft = ActivityRecordDraft.fromRecord(original).copyWith(
      multiParticipants: [...original.effectiveParticipants, secondParticipant],
    );
    final submitted = await editDialog(tester, firstDraft, note: '增员');
    final firstEdit = submitted.toActivityRecord(
      pricings: [currentPricing()],
      id: original.id,
    )!;
    await tester
        .runAsync(() => DatabaseService.updateActivityRecordWithCounterImpact(
              original.id!,
              firstEdit,
            ));
    final firstRows =
        (await tester.runAsync(DatabaseService.getActivityRecords))!;
    final firstSaved = firstRows.singleWhere((r) => r.id == original.id);
    final expected = original.copyWith(
      note: '增员',
      secondarySubjectName: secondParticipant.memberName,
      participants: [...original.effectiveParticipants, secondParticipant],
    );
    expect(firstSaved.toMap(), expected.toMap());
    expect(firstRows.singleWhere((r) => r.id == brother.id).toMap(),
        brother.toMap());

    final secondDraft = await editDialog(
      tester,
      ActivityRecordDraft.fromRecord(firstSaved).copyWith(note: '二次编辑'),
      note: '二次编辑',
    );
    final secondEdit = secondDraft.toActivityRecord(
      pricings: [currentPricing()],
      id: original.id,
    )!;
    await tester
        .runAsync(() => DatabaseService.updateActivityRecordWithCounterImpact(
              original.id!,
              secondEdit,
            ));
    final secondRows =
        (await tester.runAsync(DatabaseService.getActivityRecords))!;
    expect(secondRows, hasLength(2));
    expect(secondRows.singleWhere((r) => r.id == original.id).toMap(),
        expected.toMap()..['note'] = '二次编辑');
    expect(secondRows.singleWhere((r) => r.id == brother.id).toMap(),
        brother.toMap());
  });

  testWidgets('无规格空价格标签旧拆行备注编辑不补规格，明确选择后才记录规格', (tester) async {
    final before = (await tester.runAsync(() => seedPair(
          splitRow(0).copyWith(threeInchCount: 0, pricingLabel: ''),
        )))!;
    final original = before.singleWhere((r) => r.subjectName == '拆行成员0');
    final brother = before.singleWhere((r) => r.id != original.id);
    expect(original.multiCountField, isNull);
    final draft =
        ActivityRecordDraft.fromRecord(original).copyWith(note: '新备注');
    expect(
        draft.toActivityRecord(
            pricings: [currentPricing()], id: original.id)!.toMap(),
        original.toMap()..['note'] = '新备注');
    final submitted = await editDialog(tester, draft);
    final edited = submitted.toActivityRecord(
      pricings: [currentPricing()],
      id: original.id,
    )!;
    await tester
        .runAsync(() => DatabaseService.updateActivityRecordWithCounterImpact(
              original.id!,
              edited,
            ));
    final after = (await tester.runAsync(DatabaseService.getActivityRecords))!;
    final saved = after.singleWhere((r) => r.id == original.id);
    expect(saved.toMap(), original.toMap()..['note'] = '新备注');
    expect(saved.multiCountField, isNull);
    expect(
        after.singleWhere((r) => r.id == brother.id).toMap(), brother.toMap());

    final selected = await editDialog(
        tester, ActivityRecordDraft.fromRecord(saved),
        selectField: CounterCountField.threeInch);
    final selectedRecord = selected.toActivityRecord(
      pricings: [currentPricing()],
      id: original.id,
    )!;
    expect(selectedRecord.toMap(), saved.toMap()..['three_inch_count'] = 1);
  });

  final linkedFixtures = <String, ActivityRecordModel>{
    '已有双人空标签 multi': splitRow(0).copyWith(
      pricingLabel: '',
      secondarySubjectName: '拆行成员2',
      participants: [
        splitRow(0).effectiveParticipants.single,
        splitRow(2).effectiveParticipants.single
      ],
    ),
    '无人团切': ActivityRecordModel.multiCut(
      participants: const [],
      field: CounterCountField.groupCut,
      occurredAt: DateTime(2026, 11, 10),
      quantity: 2,
      totalPrice: 200,
    ).copyWith(groupRecordId: 'legacy-split', groupName: '拆行团'),
    'counter历史价': ActivityRecordModel.counterAdjustment(
      counter: CounterModel(name: '计数成员', groupName: '拆行团', color: '#FFE135'),
      occurredAt: DateTime(2026, 11, 10),
      deltas: const {CounterCountField.threeInch: 1},
      pricing: currentPricing(),
    ).copyWith(groupRecordId: 'legacy-split'),
    'counter当前价': ActivityRecordModel.counterAdjustment(
      counter: CounterModel(name: '当前价成员', groupName: '拆行团', color: '#FFE135'),
      occurredAt: DateTime(2026, 11, 10),
      deltas: const {CounterCountField.threeInch: 1},
      pricing: currentPricing(),
    ).copyWith(groupRecordId: 'legacy-split', usesCurrentPricing: true),
    'ticket': ActivityRecordModel.ticket(
      eventName: '门票活动',
      occurredAt: DateTime(2026, 11, 10),
      quantity: 1,
      unitPrice: 60,
      isFree: false,
    ).copyWith(groupRecordId: 'legacy-split'),
  };
  for (final entry in linkedFixtures.entries) {
    testWidgets('${entry.key} 草稿及 UI 保存不清空 groupid，完整 DB 往返', (tester) async {
      final before = (await tester.runAsync(() => seedPair(entry.value)))!;
      final original = before.singleWhere(
        (r) => r.subjectName == entry.value.subjectName,
      );
      final brother = before.singleWhere((r) => r.id != original.id);
      final draft =
          ActivityRecordDraft.fromRecord(original).copyWith(note: '新备注');
      expect(
          draft.toActivityRecord(
              pricings: [currentPricing()], id: original.id)!.toMap(),
          original.toMap()..['note'] = '新备注');
      final submitted = await editDialog(tester, draft);
      final edited = submitted.toActivityRecord(
        pricings: [currentPricing()],
        id: original.id,
      )!;
      await tester
          .runAsync(() => DatabaseService.updateActivityRecordWithCounterImpact(
                original.id!,
                edited,
              ));
      final after =
          (await tester.runAsync(DatabaseService.getActivityRecords))!;
      expect(after, hasLength(2));
      expect(after.singleWhere((r) => r.id == original.id).toMap(),
          original.toMap()..['note'] = '新备注');
      expect(after.singleWhere((r) => r.id == brother.id).toMap(),
          brother.toMap());
    });
  }

  for (final groupRecordId in [null, '', '   ']) {
    testWidgets('无明确分组标识的已有单人 multi 仍不能保存 ($groupRecordId)', (tester) async {
      final row = ActivityRecordModel.fromMap(
        splitRow(0).copyWith(id: 123).toMap()
          ..['group_record_id'] = groupRecordId,
      );
      ActivityRecordDraft? result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Builder(builder: (context) {
          return TextButton(
            onPressed: () async {
              result = await showDialog<ActivityRecordDraft>(
                context: context,
                builder: (_) => AddActivityRecordDialog(
                  counters: const [],
                  pricings: const [],
                  initialDraft: ActivityRecordDraft.fromRecord(row),
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
      expect(result, isNull);
      expect(find.byType(AddActivityRecordDialog), findsOneWidget);
    });
  }

  for (final id in [null, 0, -1]) {
    testWidgets('未持久化的带分组标识单人 multi 不能借编辑入口新建 ($id)', (tester) async {
      final row = splitRow(0).copyWith(id: id);
      await tester.pumpWidget(MaterialApp(
        home: AddActivityRecordDialog(
          counters: const [],
          pricings: const [],
          initialDraft: ActivityRecordDraft.fromRecord(row),
        ),
      ));
      await settleDatabaseWidgets(tester);
      await tester.tap(find.text('保存记录'));
      await tester.pumpAndSettle();
      expect(find.byType(AddActivityRecordDialog), findsOneWidget);
    });
  }
}
