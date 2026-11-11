import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show ConflictAlgorithm;

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/idol_database_service.dart';

import 'support/isolated_test_databases.dart';

/// Regressions for the 2026-11 counting audit: every case here once let the
/// cached counter columns drift away from a full replay of activity_records.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await useIsolatedTestDatabases();
    SharedPreferences.setMockInitialValues({});
  });
  setUp(() async => DatabaseService.clearAppData());
  tearDown(() async => DatabaseService.clearAppData());

  Future<CounterModel> counterNamed(String name) async =>
      (await DatabaseService.getCounters()).singleWhere((c) => c.name == name);

  /// Cached counts must equal what "从记录重算计数" would produce.
  Future<void> expectCountersMatchReplay() async {
    Map<int, Map<String, int>> snapshot(List<CounterModel> counters) => {
          for (final counter in counters)
            counter.id!: {
              for (final field in CounterCountField.values)
                field.key: counter.countForField(field),
            },
        };
    final before = snapshot(await DatabaseService.getCounters());
    await DatabaseService.recalculateCountersFromActivityRecords();
    final after = snapshot(await DatabaseService.getCounters());
    expect(after, before, reason: 'cached counts drifted from record replay');
  }

  test('updating counter metadata never overwrites counts with a stale copy',
      () async {
    await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.counterAdjustment(
        counter: CounterModel(name: 'A', groupName: 'G', color: '#ffffff'),
        occurredAt: DateTime(2026, 11, 1),
        deltas: const {CounterCountField.threeInch: 2},
      ),
    );
    // The home page holds this copy while a background sync adds 3 more.
    final staleCopy = await counterNamed('A');
    await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.counterAdjustment(
        counter: staleCopy,
        occurredAt: DateTime(2026, 11, 2),
        deltas: const {CounterCountField.threeInch: 3},
      ),
    );

    // Hiding / editing the card writes the stale copy back.
    await DatabaseService.updateCounter(
      staleCopy.id!,
      staleCopy.copyWith(isHidden: true, color: '#000000'),
    );

    final stored = await counterNamed('A');
    expect(stored.isHidden, isTrue);
    expect(stored.color, '#000000');
    expect(stored.threeInchCount, 5);
    await expectCountersMatchReplay();
  });

  test('renaming a member keeps their multi-cut records linked', () async {
    await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.multiCut(
        participants: const [
          ActivityParticipant(memberName: 'A', groupName: 'G'),
          ActivityParticipant(memberName: 'B', groupName: 'G'),
        ],
        field: CounterCountField.threeInch,
        occurredAt: DateTime(2026, 11, 1),
        quantity: 2,
      ),
    );
    final a = await counterNamed('A');
    await DatabaseService.updateCounter(a.id!, a.copyWith(name: 'A2'));

    final renamed = await counterNamed('A2');
    expect(renamed.threeInchCount, 2);
    // Replay must keep the photo on the renamed card instead of recreating
    // an "A" card and zeroing A2.
    await expectCountersMatchReplay();
    expect((await DatabaseService.getCounters()).map((c) => c.name).toSet(),
        {'A2', 'B'});

    final multi = (await DatabaseService.getActivityRecords()).single;
    expect(
      DatabaseService.resolveCounterForParticipant(
        await DatabaseService.getCounters(),
        multi.effectiveParticipants.first,
      )?.id,
      renamed.id,
    );

    // Deleting the multi-cut must roll back both members.
    await DatabaseService.deleteActivityRecordWithCounterImpact(multi.id!);
    expect((await counterNamed('A2')).threeInchCount, 0);
    expect((await counterNamed('B')).threeInchCount, 0);
  });

  test('re-importing a deleted OTA history record counts it again', () async {
    final imported = ActivityRecordModel(
      type: ActivityRecordType.counter,
      source: 'ota_site',
      sourceRecordId: 'ota-1',
      subjectName: '测试成员甲',
      groupName: '测试团体甲',
      occurredAt: DateTime(2026, 10, 1),
      threeInchCount: 2,
      totalAmount: 0,
    );
    await DatabaseService.insertActivityRecord(imported);
    await DatabaseService.syncActivityRecordsToCounters('ota_site');
    expect((await counterNamed('测试成员甲')).threeInchCount, 2);

    final recordId = (await DatabaseService.getActivityRecords()).single.id!;
    await DatabaseService.deleteActivityRecordWithCounterImpact(recordId);
    expect((await counterNamed('测试成员甲')).threeInchCount, 0);

    // Importing the same OTA file again brings the record back...
    await DatabaseService.insertActivityRecord(imported);
    await DatabaseService.syncActivityRecordsToCounters('ota_site');

    // ...so its count must come back as well.
    expect((await counterNamed('测试成员甲')).threeInchCount, 2);
    await expectCountersMatchReplay();
  });

  test('a free ticket never carries a paid amount', () {
    final ticket = ActivityRecordModel.ticket(
      eventName: '公演',
      occurredAt: DateTime(2026, 11, 1),
      quantity: 2,
      unitPrice: 80,
      isFree: true,
    );
    expect(ticket.ticketUnitPrice, 0);
    expect(ticket.totalAmount, 0);
    expect(ticket.resolvedTicketIsFree, isTrue);
  });
  test('auto theme colors never roll back counts saved meanwhile', () async {
    final idolDb = await IdolDatabaseService.database;
    await idolDb.delete('idol_members');
    await idolDb.delete('idol_groups');
    final groupId = await idolDb.insert('idol_groups', {'name': '色团'});
    await idolDb.insert('idol_members',
        {'name': '红', 'group_id': groupId, 'status': '#FF0000'});
    await idolDb.insert(
        'idol_meta', {'key': 'generated_at', 'value': '2099-01-01T00:00:00Z'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    final id = await DatabaseService.insertCounter(
      CounterModel(name: '红', groupName: '色团', color: '#FFE135'),
    );
    final counter = await counterNamed('红');

    // Theme colors run after imports / syncs that create cards, while the
    // user may already be counting. Hold the idol database so the colour
    // lookup is slow, exactly like the real seed scan, and save a count while
    // the auto-colouring is between its read and its write.
    final releaseIdolDb = Completer<void>();
    final idolDbHeld = Completer<void>();
    final holder = idolDb.transaction((txn) async {
      idolDbHeld.complete();
      await releaseIdolDb.future;
    });
    await idolDbHeld.future;
    final assign = DatabaseService.autoAssignCounterThemeColors();
    // Queued after the auto-colouring read of the counters.
    await DatabaseService.getCounters();
    await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.counterAdjustment(
        counter: counter,
        occurredAt: DateTime(2026, 11, 1),
        deltas: const {CounterCountField.threeInch: 2},
      ),
    );
    releaseIdolDb.complete();
    await holder;
    await assign;

    final stored = await counterNamed('红');
    expect(stored.id, id);
    expect(stored.color.toUpperCase(), '#FF0000');
    expect(stored.threeInchCount, 2);
    await expectCountersMatchReplay();
  });
}
