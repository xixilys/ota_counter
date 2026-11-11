import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/main.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/custom_cheki_type_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/widgets/counter_card.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await useIsolatedTestDatabases();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // A zero build disables the automatic network update check.
    PackageInfo.setMockInitialValues(
      appName: 'OTA Counter',
      packageName: 'test.ota',
      version: 'test',
      buildNumber: '0',
      buildSignature: '',
    );
    await DatabaseService.clearAppData();
  });
  tearDown(() async => DatabaseService.clearAppData());

  Future<void> settleDatabase(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> openHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => tester.pumpWidget(const MyApp()));
    await settleDatabase(tester);
    expect(find.text('我的切奇'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }

  void expectMetric(WidgetTester tester, String label, int quantity) {
    final column = find
        .ancestor(of: find.text(label), matching: find.byType(Column))
        .first;
    expect(find.descendant(of: column, matching: find.text('$quantity')),
        findsOneWidget);
  }

  Map<String, int> cardCounts(WidgetTester tester) => {
        for (final card
            in tester.widgetList<CounterCard>(find.byType(CounterCard)))
          card.counter.name: card.totalCount,
      };

  Future<int> seedMixedCounts() async {
    await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.counterAdjustment(
        counter: CounterModel(name: 'A', groupName: 'G', color: '#ffffff'),
        occurredAt: DateTime(2026, 3, 18),
        deltas: const {CounterCountField.threeInch: 2},
      ),
    );
    return DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.multiCut(
        participants: const [
          ActivityParticipant(memberName: 'A', groupName: 'G'),
          ActivityParticipant(memberName: 'B', groupName: 'G'),
        ],
        field: CounterCountField.groupCut,
        occurredAt: DateTime(2026, 3, 18),
        quantity: 3,
      ),
    );
  }

  testWidgets(
      'home loads physical totals and refreshes edited group quantities',
      (tester) async {
    final recordId = (await tester.runAsync(seedMixedCounts))!;
    await openHome(tester);
    expectMetric(tester, '累计切奇', 5);
    expectMetric(tester, '团切', 3);
    expect(cardCounts(tester), {'A': 5, 'B': 3});

    // Return from a real records route to exercise the home reload path.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最近提交记录'));
    await settleDatabase(tester);
    await tester.runAsync(() async {
      final original = (await DatabaseService.getActivityRecords())
          .singleWhere((r) => r.id == recordId);
      await DatabaseService.updateActivityRecordWithCounterImpact(
        recordId,
        ActivityRecordModel.multiCut(
          id: recordId,
          participants: original.effectiveParticipants,
          field: CounterCountField.groupCut,
          occurredAt: original.occurredAt,
          quantity: 2,
        ),
      );
    });
    await tester.tap(find.byType(BackButton));
    await settleDatabase(tester);
    expectMetric(tester, '累计切奇', 4);
    expectMetric(tester, '团切', 2);
    expect(cardCounts(tester), {'A': 4, 'B': 2});
  });

  testWidgets('hidden participant scope keeps each physical group photo once',
      (tester) async {
    await tester.runAsync(() async {
      await seedMixedCounts();
      final b = (await DatabaseService.getCounters())
          .singleWhere((c) => c.name == 'B');
      await DatabaseService.updateCounter(b.id!, b.copyWith(isHidden: true));
    });
    await openHome(tester);
    expectMetric(tester, '累计切奇', 5);
    expectMetric(tester, '团切', 3);
    expect(cardCounts(tester), {'A': 5});
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示已隐藏项'));
    await tester.pumpAndSettle();
    expectMetric(tester, '累计切奇', 5);
    expectMetric(tester, '团切', 3);
    expect(cardCounts(tester), {'A': 5, 'B': 3});
  });

  testWidgets('all hidden members contribute only when hidden scope is enabled',
      (tester) async {
    await tester.runAsync(() async {
      await seedMixedCounts();
      for (final counter in await DatabaseService.getCounters()) {
        await DatabaseService.updateCounter(
            counter.id!, counter.copyWith(isHidden: true));
      }
    });
    await openHome(tester);
    expectMetric(tester, '累计切奇', 0);
    expectMetric(tester, '团切', 0);
    expect(cardCounts(tester), isEmpty);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示已隐藏项'));
    await tester.pumpAndSettle();
    expectMetric(tester, '累计切奇', 5);
    expectMetric(tester, '团切', 3);
    expect(cardCounts(tester), {'A': 5, 'B': 3});
  });

  for (final mixedIdentity in [false, true]) {
    testWidgets(
        'imported duplicate participants count once (mixed identity: $mixedIdentity)',
        (tester) async {
      await tester.runAsync(() async {
        final raw = ActivityRecordModel(
          type: ActivityRecordType.multi,
          subjectName: 'A',
          groupName: 'G',
          occurredAt: DateTime(2026, 3, 18),
          groupCutCount: 3,
          multiCutQuantity: 3,
          totalAmount: 600,
        ).toMap();
        raw['multi_participants_json'] = jsonEncode([
          {
            'memberName': 'A',
            'groupName': 'G',
            'personId': 1,
            'personName': '真人A'
          },
          {
            'memberName': mixedIdentity ? 'A别名' : 'A',
            'groupName': 'G',
            if (!mixedIdentity) 'personId': 1,
            'personName': '真人A'
          },
          {'memberName': 'B', 'groupName': 'G', 'personId': 2},
        ]);
        final imported = ActivityRecordModel.fromMap(raw);
        expect(imported.effectiveParticipants, hasLength(2));
        expect(imported.multiContributionTotal, 6);
        expect(imported.multiParticipantAmountShare, 300);
        await DatabaseService.insertActivityRecordWithCounterImpact(imported);
      });
      await openHome(tester);
      expectMetric(tester, '累计切奇', 3);
      expectMetric(tester, '团切', 3);
      expect(cardCounts(tester), {'A': 3, 'B': 3});
    });
  }

  for (final hiddenCount in [0, 1, 2]) {
    testWidgets(
        'explicit homonym IDs beat visible anonymous fallback ($hiddenCount hidden)',
        (tester) async {
      await tester.runAsync(() async {
        await DatabaseService.insertCounter(CounterModel(
          name: '同名',
          groupName: 'G',
          color: '#ffffff',
        ));
        for (final personId in [1, 2]) {
          await DatabaseService.insertCounter(CounterModel(
            name: '同名',
            groupName: 'G',
            personId: personId,
            color: '#ffffff',
            isHidden: personId <= hiddenCount,
          ));
        }
        await DatabaseService.insertActivityRecordWithCounterImpact(
            ActivityRecordModel.multiCut(
          participants: const [
            ActivityParticipant(memberName: '同名', groupName: 'G', personId: 1),
            ActivityParticipant(memberName: '同名', groupName: 'G', personId: 2),
          ],
          field: CounterCountField.groupCut,
          occurredAt: DateTime(2026, 3, 18),
        ));
      });
      await openHome(tester);
      expectMetric(tester, '累计切奇', hiddenCount == 2 ? 0 : 1);
      expectMetric(tester, '团切', hiddenCount == 2 ? 0 : 1);
      final cards = tester.widgetList<CounterCard>(find.byType(CounterCard));
      expect(
          cards.singleWhere((c) => c.counter.personId == null).totalCount, 0);
      expect(
          cards
              .where((c) => c.counter.personId != null)
              .map((c) => c.totalCount),
          everyElement(1));
    });
  }

  for (final hiddenCount in [0, 1, 2]) {
    for (final showHidden in [false, true]) {
      testWidgets(
          'linked split rows: hidden=$hiddenCount show=$showHidden count one physical photo',
          (tester) async {
        SharedPreferences.setMockInitialValues(
            {'show_hidden_counters': showHidden});
        late List<ActivityRecordModel> before;
        await tester.runAsync(() async {
          for (var i = 0; i < 2; i++) {
            final member = i == 0 ? 'A' : 'B';
            await DatabaseService.insertCounter(CounterModel(
                name: member,
                groupName: 'G',
                color: '#ffffff',
                isHidden: i < hiddenCount));
            final raw = ActivityRecordModel.multiCut(
                    participants: [
                  ActivityParticipant(memberName: member, groupName: 'G')
                ],
                    field: CounterCountField.groupCut,
                    occurredAt: DateTime(2026, 3, 18),
                    quantity: 1,
                    totalPrice: 60)
                .toMap()
              ..['group_record_id'] = 'same-photo'
              ..['multi_participants_json'] = null;
            await DatabaseService.insertActivityRecordWithCounterImpact(
                ActivityRecordModel.fromMap(raw));
          }
          before = await DatabaseService.getActivityRecords();
        });
        await openHome(tester);
        final visible = showHidden ? 2 : 2 - hiddenCount;
        expectMetric(tester, '累计切奇', visible == 0 ? 0 : 1);
        expectMetric(tester, '团切', visible == 0 ? 0 : 1);
        final cards = cardCounts(tester);
        expect(cards, hasLength(visible));
        expect(cards.values, everyElement(1));
        final after =
            (await tester.runAsync(DatabaseService.getActivityRecords))!;
        expect(after.map((r) => r.toMap()), before.map((r) => r.toMap()));
        final counters = (await tester.runAsync(DatabaseService.getCounters))!;
        expect(counters.map((c) => c.groupCutCount), [1, 1]);
      });
    }
  }

  testWidgets(
      'linked events do not deduplicate independent ids, ordinary multis or opening counters',
      (tester) async {
    await tester.runAsync(() async {
      // Existing card counts are the baseline, never reconstructed from rows.
      for (final member in ['A', 'B']) {
        await DatabaseService.insertCounter(CounterModel(
            name: member, groupName: 'G', color: '#ffffff', threeInchCount: 7));
      }
      for (final groupId in ['first', 'second']) {
        for (final member in ['A', 'B']) {
          final raw = ActivityRecordModel.multiCut(
                  participants: [
                ActivityParticipant(memberName: member, groupName: 'G')
              ],
                  field: CounterCountField.unsignedThreeInch,
                  occurredAt: DateTime(2026, 3, 18),
                  totalPrice: 60)
              .toMap()
            ..['group_record_id'] = groupId;
          await DatabaseService.insertActivityRecordWithCounterImpact(
              ActivityRecordModel.fromMap(raw));
        }
      }
      // Same date and cast without linkage still mean separate ordinary events.
      for (var i = 0; i < 2; i++) {
        await DatabaseService.insertActivityRecordWithCounterImpact(
            ActivityRecordModel.multiCut(
                participants: const [
              ActivityParticipant(memberName: 'A', groupName: 'G'),
              ActivityParticipant(memberName: 'B', groupName: 'G')
            ],
                field: CounterCountField.threeInch,
                occurredAt: DateTime(2026, 3, 18),
                totalPrice: 120));
      }
    });
    await openHome(tester);
    expectMetric(tester, '累计切奇', 18); // opening 14 + linked 2 + ordinary 2
    expectMetric(
        tester, '3寸', 18); // unsigned specs aggregate into the base field
    expect(cardCounts(tester), {'A': 11, 'B': 11});
    final records =
        (await tester.runAsync(DatabaseService.getActivityRecords))!;
    expect(records, hasLength(6));
    expect(records.fold<double>(0, (sum, r) => sum + r.totalAmount), 480);
  });

  testWidgets('legacy counters without records retain their group cut totals',
      (tester) async {
    await tester.runAsync(() => DatabaseService.insertCounter(
          CounterModel(
              name: '旧成员', groupName: '旧团', color: '#ffffff', groupCutCount: 7),
        ));
    await openHome(tester);
    expectMetric(tester, '累计切奇', 7);
    expectMetric(tester, '团切', 7);
    expect(cardCounts(tester), {'旧成员': 7});
    expect(await tester.runAsync(DatabaseService.getActivityRecords), isEmpty);
  });

  testWidgets('legacy multi quantity without a count field does not undercount',
      (tester) async {
    await tester.runAsync(() async {
      await DatabaseService.insertCounter(CounterModel(
        name: 'A',
        groupName: 'G',
        color: '#ffffff',
        threeInchCount: 1,
      ));
      await DatabaseService.insertCounter(CounterModel(
        name: 'B',
        groupName: 'G',
        color: '#ffffff',
        threeInchCount: 1,
      ));
      final raw = ActivityRecordModel(
        type: ActivityRecordType.multi,
        subjectName: 'A',
        groupName: 'G',
        occurredAt: DateTime(2026, 3, 18),
        multiCutQuantity: 2,
        totalAmount: 0,
        participants: const [
          ActivityParticipant(memberName: 'A', groupName: 'G'),
          ActivityParticipant(memberName: 'B', groupName: 'G'),
        ],
      );
      await DatabaseService.insertActivityRecordWithCounterImpact(raw);
    });
    await openHome(tester);
    expectMetric(tester, '累计切奇', 2);
    expect(cardCounts(tester), {'A': 1, 'B': 1});
  });

  testWidgets('custom cheki counts are included in home totals',
      (tester) async {
    await tester.runAsync(() async {
      await DatabaseService.insertCounter(CounterModel(
        name: 'A',
        groupName: 'G',
        color: '#ffffff',
      ));
      final counter = (await DatabaseService.getCounters()).single;
      await DatabaseService.insertActivityRecordWithCounterImpact(
        ActivityRecordModel.counterAdjustment(
          counter: counter,
          occurredAt: DateTime(2026, 3, 18),
          deltas: const {CounterCountField.threeInch: 1},
          customChekiCounts: const [
            ActivityRecordCustomChekiCount(
              typeId: 'sign',
              label: '签绘',
              count: 2,
              unitPrice: 30,
            ),
          ],
        ),
      );
    });
    await openHome(tester);
    expectMetric(tester, '累计切奇', 3);
    expectMetric(tester, '签绘', 2);
    expect(cardCounts(tester), {'A': 3});
    expect(find.text('签绘'), findsNWidgets(2));
  });
}
