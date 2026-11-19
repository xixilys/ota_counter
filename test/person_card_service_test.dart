import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/idol_database_models.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/idol_database_service.dart';
import 'package:ota_counter/services/person_card_service.dart';

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

  Future<(CounterModel, CounterModel)> seedTwoGroups() async {
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
    final a = members.singleWhere((m) => m.groupName == '跨团 A');
    final b = members.singleWhere((m) => m.groupName == '跨团 B');
    final aId = await DatabaseService.insertCounter(CounterModel(
      name: a.name,
      groupName: a.groupName,
      personId: a.personId,
      personName: a.resolvedPersonName,
      color: '#FFE135',
    ));
    final bId = await DatabaseService.insertCounter(CounterModel(
      name: b.name,
      groupName: b.groupName,
      personId: b.personId,
      personName: b.resolvedPersonName,
      color: '#8B6CF0',
    ));
    final counters = await DatabaseService.getCounters();
    final cardA = counters.singleWhere((c) => c.id == aId);
    final cardB = counters.singleWhere((c) => c.id == bId);
    await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.counterAdjustment(
        counter: cardA,
        occurredAt: DateTime(2026, 1, 1),
        deltas: {CounterCountField.threeInch: 1},
      ),
    );
    await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.counterAdjustment(
        counter: cardB,
        occurredAt: DateTime(2026, 6, 1),
        deltas: {CounterCountField.fiveInch: 2},
      ),
    );
    return (
      (await DatabaseService.getCounters()).singleWhere((c) => c.id == aId),
      (await DatabaseService.getCounters()).singleWhere((c) => c.id == bId),
    );
  }

  test('overview groups cards by person and remembers the current card',
      () async {
    final (a, b) = await seedTwoGroups();
    var overview = await PersonCardService.loadOverview(a);
    expect(overview.personId, a.personId);
    expect(overview.cards, hasLength(2));
    expect(overview.displayName, '真人P');
    expect(overview.cards.map((card) => card.groupLabel).toSet(),
        {'跨团 A', '跨团 B'});
    // Latest activity is the default current card when the user has not chosen.
    expect(overview.currentCard!.counter.id, b.id);

    await PersonCardService.setCurrentCard(a, a.id);
    overview = await PersonCardService.loadOverview(a);
    expect(overview.currentCard!.counter.id, a.id);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('person_current_cards'), contains('${a.personId}'));

    await PersonCardService.setPast(a, true);
    overview = await PersonCardService.loadOverview(a);
    expect(
      overview.cards.singleWhere((card) => card.counter.id == a.id).isPast,
      isTrue,
    );
    await PersonCardService.setPast(a, false);
  });

  test('link / unlink keeps counters and historical records untouched',
      () async {
    final (a, b) = await seedTwoGroups();
    await PersonCardService.unlinkCounter(b);
    final unlinked = (await DatabaseService.getCounters())
        .singleWhere((counter) => counter.id == b.id);
    expect(unlinked.personId, isNull);
    expect(unlinked.personName, isEmpty);
    expect(unlinked.fiveInchCount, 2,
        reason: '解除真人关联不能改计数');
    expect((await DatabaseService.getActivityRecords())
        .where((record) => record.personId == b.personId), isNotEmpty,
        reason: '历史流水的真人身份保留');

    final person = await PersonCardService.ensurePerson('真人P');
    await PersonCardService.linkCounterToPerson(unlinked, person);
    final linked = (await DatabaseService.getCounters())
        .singleWhere((counter) => counter.id == b.id);
    expect(linked.personId, person.id);
    expect(linked.personName, '真人P');

    final overview = await PersonCardService.loadOverview(a);
    expect(overview.cards, hasLength(2));
  });

  test('same-name unlinked card is offered for an explicit merge only',
      () async {
    final (a, b) = await seedTwoGroups();
    final unlinkedId = await DatabaseService.insertCounter(CounterModel(
      name: a.name,
      groupName: '跨团 C',
      color: '#21B6A8',
    ));
    final overview = await PersonCardService.loadOverview(a);
    expect(overview.sameNameCards.map((card) => card.id), [unlinkedId]);

    final person = await PersonCardService.mergeCardsIntoPerson(
      a,
      [(await DatabaseService.getCounters()).singleWhere((c) => c.id == unlinkedId)],
    );
    final merged = (await DatabaseService.getCounters())
        .singleWhere((counter) => counter.id == unlinkedId);
    expect(merged.personId, person.id);
    expect(merged.personName, '真人P');
    final after = await PersonCardService.loadOverview(a);
    expect(after.sameNameCards, isEmpty);
    expect(after.cards.map((card) => card.counter.id), contains(unlinkedId));
    expect(b.id, isNotNull);
  });
  test('legacy counter records without counter_id still date the card', () async {
    final (a, _) = await seedTwoGroups();
    await DatabaseService.insertActivityRecord(
      ActivityRecordModel.counterAdjustment(
        counter: a,
        occurredAt: DateTime(2026, 12, 1),
        deltas: {CounterCountField.threeInch: 1},
      ).copyWith(counterId: null),
    );
    final overview = await PersonCardService.loadOverview(a);
    final card = overview.cards.singleWhere((item) => item.counter.id == a.id);
    expect(card.lastActivity, DateTime(2026, 12, 1));
  });

}
