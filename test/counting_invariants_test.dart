import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/services/database_service.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await useIsolatedTestDatabases();
  });

  setUp(() async => DatabaseService.clearAppData());
  tearDown(() async => DatabaseService.clearAppData());

  test('random insert/update/delete keeps cached counts equal to a full replay',
      () async {
    final random = Random(20261101);
    final counters = <CounterModel>[];
    for (var i = 0; i < 4; i++) {
      final id = await DatabaseService.insertCounter(
        CounterModel(
          name: '成员$i',
          groupName: '团体${i % 2}',
          color: '#FFE135',
        ),
      );
      counters.add(
        (await DatabaseService.getCounters()).singleWhere((c) => c.id == id),
      );
    }

    final fields = CounterCountField.multiSelectableValues;
    for (var i = 0; i < 28; i++) {
      final counter = counters[random.nextInt(counters.length)];
      final deltas = <CounterCountField, int>{};
      final first = CounterCountField.values[random.nextInt(4)];
      deltas[first] = 1 + random.nextInt(2);
      if (random.nextBool()) {
        deltas[CounterCountField.values[random.nextInt(4)]] =
            1 + random.nextInt(2);
      }
      await DatabaseService.insertActivityRecordWithCounterImpact(
        ActivityRecordModel.counterAdjustment(
          counter: counter,
          occurredAt:
              DateTime(2026, 10, 1).add(Duration(days: random.nextInt(20))),
          deltas: deltas,
          note: 'fuzz-$i',
        ),
      );
    }

    for (var i = 0; i < 18; i++) {
      final participants = <ActivityParticipant>[];
      final participantCount = 2 + random.nextInt(2);
      final picked = <int>{};
      while (participants.length < participantCount) {
        final index = random.nextInt(counters.length);
        if (!picked.add(index)) continue;
        final counter = counters[index];
        participants.add(
          ActivityParticipant(
            memberName: counter.name,
            groupName: counter.groupName,
            personId: counter.personId,
            personName: counter.personName,
          ),
        );
      }
      await DatabaseService.insertActivityRecordWithCounterImpact(
        ActivityRecordModel.multiCut(
          participants: participants,
          field: fields[random.nextInt(fields.length)],
          occurredAt:
              DateTime(2026, 10, 1).add(Duration(days: random.nextInt(20))),
          quantity: 1 + random.nextInt(3),
          totalPrice: 100,
          note: 'multi-$i',
        ),
      );
    }

    // Tickets are intentionally count-neutral, but must still survive replay.
    for (var i = 0; i < 6; i++) {
      await DatabaseService.insertActivityRecord(
        ActivityRecordModel.ticket(
          eventName: '演出$i',
          occurredAt: DateTime(2026, 10, 10),
          quantity: 1,
          unitPrice: 80,
        ),
      );
    }

    for (var round = 0; round < 14; round++) {
      final records = await DatabaseService.getActivityRecords();
      final mutable = records
          .where((record) => record.isCounter || record.isMulti)
          .toList(growable: false);
      if (mutable.isEmpty) break;
      final record = mutable[random.nextInt(mutable.length)];
      if (record.id == null) continue;

      if (record.isCounter) {
        final counter = counters.firstWhere(
          (item) => item.id == record.counterId,
          orElse: () =>
              counters.firstWhere((item) => item.name == record.subjectName),
        );
        final updated = ActivityRecordModel.counterAdjustment(
          id: record.id,
          counter: counter,
          occurredAt: record.occurredAt,
          deltas: {
            CounterCountField.values[random.nextInt(4)]: 1 + random.nextInt(3),
          },
          note: 'updated-$round',
        );
        await DatabaseService.updateActivityRecordWithCounterImpact(
          record.id!,
          updated,
        );
      } else {
        final updated = ActivityRecordModel.multiCut(
          id: record.id,
          participants: record.effectiveParticipants,
          field: fields[random.nextInt(fields.length)],
          occurredAt: record.occurredAt,
          quantity: 1 + random.nextInt(3),
          totalPrice: 100,
          note: 'updated-$round',
        );
        await DatabaseService.updateActivityRecordWithCounterImpact(
          record.id!,
          updated,
        );
      }
    }

    for (var round = 0; round < 5; round++) {
      final records = await DatabaseService.getActivityRecords();
      final mutable = records
          .where((record) =>
              record.id != null && (record.isCounter || record.isMulti))
          .toList(growable: false);
      if (mutable.isEmpty) break;
      try {
        await DatabaseService.deleteActivityRecordWithCounterImpact(
          mutable[random.nextInt(mutable.length)].id!,
        );
      } on StateError {
        // Deleting a correction that would underflow is correctly rejected.
      }
    }

    final beforeReplay = {
      for (final counter in await DatabaseService.getCounters())
        counter.id!: {
          for (final field in CounterCountField.values)
            field.key: counter.countForField(field),
        },
    };
    await DatabaseService.recalculateCountersFromActivityRecords();
    final afterReplay = {
      for (final counter in await DatabaseService.getCounters())
        counter.id!: {
          for (final field in CounterCountField.values)
            field.key: counter.countForField(field),
        },
    };

    expect(afterReplay.keys.toSet(), beforeReplay.keys.toSet());
    for (final id in afterReplay.keys) {
      expect(afterReplay[id], beforeReplay[id],
          reason: 'counter $id drifted from record replay');
      for (final value in afterReplay[id]!.values) {
        expect(value, greaterThanOrEqualTo(0));
      }
    }
    expect(
      await DatabaseService.getActivityRecordCount(),
      (await DatabaseService.getActivityRecords()).length,
    );
  });
}
