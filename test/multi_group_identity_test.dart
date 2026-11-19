import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/chart_stats_helpers.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/idol_database_models.dart';
import 'package:ota_counter/models/person_identity.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/idol_database_service.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await useIsolatedTestDatabases();
  });

  setUp(() async {
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

  Future<(IdolMember, IdolMember)> seedSharedPerson({
    required String personName,
    required String nameInA,
    required String nameInB,
    String groupA = '测试团 A',
    String groupB = '测试团 B',
  }) async {
    final groupAId = await IdolDatabaseService.upsertGroup(
      IdolGroup(name: groupA),
    );
    final groupBId = await IdolDatabaseService.upsertGroup(
      IdolGroup(name: groupB),
    );
    await IdolDatabaseService.upsertMember(IdolMember(
      groupId: groupAId,
      groupName: groupA,
      name: nameInA,
      personName: personName,
    ));
    await IdolDatabaseService.upsertMember(IdolMember(
      groupId: groupBId,
      groupName: groupB,
      name: nameInB,
      personName: personName,
    ));
    final membersA = await IdolDatabaseService.getMembers(groupId: groupAId);
    final membersB = await IdolDatabaseService.getMembers(groupId: groupBId);
    return (
      membersA.singleWhere((member) => member.name == nameInA),
      membersB.singleWhere((member) => member.name == nameInB),
    );
  }

  test('兼任: two group cards aggregate as one person without losing group',
      () async {
    final (memberA, memberB) = await seedSharedPerson(
      personName: '真人 P',
      nameInA: 'P在A',
      nameInB: 'P在B',
      groupA: '兼任团 A',
      groupB: '兼任团 B',
    );
    expect(memberA.personId, isNotNull);
    expect(memberB.personId, memberA.personId);

    final cardA = await DatabaseService.insertCounter(CounterModel(
      name: memberA.name,
      groupName: memberA.groupName,
      personId: memberA.personId,
      personName: memberA.resolvedPersonName,
      color: '#FFE135',
    ));
    final cardB = await DatabaseService.insertCounter(CounterModel(
      name: memberB.name,
      groupName: memberB.groupName,
      personId: memberB.personId,
      personName: memberB.resolvedPersonName,
      color: '#FFE135',
    ));

    await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.counterAdjustment(
        counter: (await DatabaseService.getCounters())
            .singleWhere((counter) => counter.id == cardA),
        occurredAt: DateTime(2026, 5, 1),
        deltas: {CounterCountField.threeInch: 2},
      ),
    );
    await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.counterAdjustment(
        counter: (await DatabaseService.getCounters())
            .singleWhere((counter) => counter.id == cardB),
        occurredAt: DateTime(2026, 5, 2),
        deltas: {CounterCountField.fiveInch: 3},
      ),
    );

    final counters = await DatabaseService.getCounters();
    final ownCards =
        counters.where((counter) => counter.personId == memberA.personId);
    expect(ownCards.map((counter) => counter.groupName).toSet(),
        {'兼任团 A', '兼任团 B'});
    expect(ownCards.fold<int>(0, (sum, card) => sum + card.count), 5);

    final records = await DatabaseService.getActivityRecords();
    final scope = ChartRecordScope(
      counters: counters,
      records: records,
      showHiddenCounters: false,
    );
    // 按团籍: each record stays in its group.
    final byGroup = {
      for (final record in records)
        if (record.isCounter)
          record.groupName: scope.identityForRecord(record).memberKey,
    };
    expect(byGroup.keys.toSet(), {'兼任团 A', '兼任团 B'});
    // 按真人: one key for both groups.
    final personKeys = {
      for (final record in records)
        if (record.isCounter) scope.identityForRecord(record).personKey,
    };
    expect(personKeys, {'person:${memberA.personId}'});
  });

  test('转团: moving a card keeps multi-record historical group attributable',
      () async {
    final groupAId =
        await IdolDatabaseService.upsertGroup(const IdolGroup(name: '旧团 X'));
    final groupBId =
        await IdolDatabaseService.upsertGroup(const IdolGroup(name: '新团 Y'));
    await IdolDatabaseService.upsertMember(IdolMember(
      groupId: groupAId,
      groupName: '旧团 X',
      name: '转团成员',
      personName: '转团真人',
    ));
    final member = (await IdolDatabaseService.getMembers(groupId: groupAId))
        .singleWhere((item) => item.name == '转团成员');
    await IdolDatabaseService.upsertMember(IdolMember(
      groupId: groupBId,
      groupName: '新团 Y',
      name: '转团成员',
      personName: '转团真人',
    ));

    final counterId = await DatabaseService.insertCounter(CounterModel(
      name: '转团成员',
      groupName: '旧团 X',
      personId: member.personId,
      personName: '转团真人',
      color: '#FFE135',
    ));

    final multiRecordId = await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.multiCut(
        participants: [
          ActivityParticipant(
            memberName: '转团成员',
            groupName: '旧团 X',
            personId: member.personId,
            personName: '转团真人',
          ),
        ],
        field: CounterCountField.threeInch,
        occurredAt: DateTime(2026, 3, 1),
        quantity: 2,
      ).copyWith(groupName: '旧团 X'),
    );

    final oldCounter =
        (await DatabaseService.getCounters()).singleWhere((c) => c.id == counterId);
    // Simulate 转团 by renaming the card's group (the app's edit flow).
    await DatabaseService.updateCounter(
      counterId,
      oldCounter.copyWith(groupName: '新团 Y'),
    );

    final counters = await DatabaseService.getCounters();
    final records = await DatabaseService.getActivityRecords();
    final movedRecord =
        records.singleWhere((record) => record.id == multiRecordId);
    expect(movedRecord.effectiveParticipants.single.groupName, '旧团 X',
        reason: '历史流水必须保留旧团籍');
    expect(movedRecord.effectiveParticipants.single.personId, member.personId);

    final scope = ChartRecordScope(
      counters: counters,
      records: records,
      showHiddenCounters: false,
    );
    expect(scope.identityForParticipant(
      movedRecord.effectiveParticipants.single,
      fallbackGroupName: movedRecord.groupName,
    ).groupName, '旧团 X');

    // The card moved, so deleting the historical record must still decrement
    // the card whose counts contain it, without asking the user to recreate it.
    await DatabaseService.deleteActivityRecordWithCounterImpact(multiRecordId);
    final afterDelete =
        (await DatabaseService.getCounters()).singleWhere((c) => c.id == counterId);
    expect(afterDelete.threeInchCount, 0);
  });

  test('same stage name in two groups is never merged without an explicit link',
      () async {
    final groupAId =
        await IdolDatabaseService.upsertGroup(const IdolGroup(name: '同名团 A'));
    final groupBId =
        await IdolDatabaseService.upsertGroup(const IdolGroup(name: '同名团 B'));
    await IdolDatabaseService.upsertMember(IdolMember(
      groupId: groupAId,
      groupName: '同名团 A',
      name: '同名成员',
    ));
    await IdolDatabaseService.upsertMember(IdolMember(
      groupId: groupBId,
      groupName: '同名团 B',
      name: '同名成员',
    ));

    final member = (await IdolDatabaseService.getMembers(groupId: groupAId))
        .singleWhere((item) => item.name == '同名成员');
    final counterId = await DatabaseService.insertCounter(CounterModel(
      name: '同名成员',
      groupName: '同名团 A',
      personId: member.personId,
      personName: member.personId == null ? '' : member.resolvedPersonName,
      color: '#FFE135',
    ));
    await DatabaseService.insertCounter(CounterModel(
      name: '同名成员',
      groupName: '同名团 B',
      color: '#FFE135',
    ));

    final counters = await DatabaseService.getCounters();
    expect(counters, hasLength(2));
    final a = counters.singleWhere((c) => c.id == counterId);
    final b = counters.singleWhere((c) => c.groupName == '同名团 B');
    expect(a.personId, member.personId);
    expect(b.personId, isNull,
        reason: '同名不能自动证明是同一人');
    expect(
      counterPersonEntryKey(a),
      isNot(counterPersonEntryKey(b)),
    );
  });
  test('不同团用不同艺名时，已有真人 id 不会被同团同名成员抢走', () async {
    final groupAId =
        await IdolDatabaseService.upsertGroup(const IdolGroup(name: '艺名团 A'));
    final groupBId =
        await IdolDatabaseService.upsertGroup(const IdolGroup(name: '艺名团 B'));
    await IdolDatabaseService.upsertMember(IdolMember(
      groupId: groupAId,
      groupName: '艺名团 A',
      name: '本名成员',
      personName: '真人 P',
    ));
    // Another person happens to use "新艺名" in group B. A card that already
    // has person P's id must keep it when its stage name changes.
    await IdolDatabaseService.upsertMember(IdolMember(
      groupId: groupBId,
      groupName: '艺名团 B',
      name: '新艺名',
      personName: '另一位真人',
    ));
    final personP = (await IdolDatabaseService.getMembers(groupId: groupAId))
        .singleWhere((member) => member.name == '本名成员')
        .personId;
    final cardId = await DatabaseService.insertCounter(CounterModel(
      name: '新艺名',
      groupName: '艺名团 B',
      personId: personP,
      personName: '新艺名',
      color: '#FFE135',
    ));
    // Force the full identity scan with an unrelated stale id.
    await DatabaseService.insertCounter(CounterModel(
      name: '失联旧卡',
      groupName: '艺名团 A',
      personId: 9999999,
      personName: '',
      color: '#FFE135',
    ));

    await DatabaseService.reconcileCounterIdentities();

    final cards = await DatabaseService.getCounters();
    final card = cards.singleWhere((counter) => counter.id == cardId);
    expect(card.personId, personP,
        reason: '有效的 person id 比艺名更可靠，不能被同团同名的另一个人覆盖');
    expect(
      counterPersonEntryKey(card),
      'person-id:$personP',
    );
  });

}
