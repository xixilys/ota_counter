import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ota_counter/services/idol_database_service.dart';
import 'package:ota_counter/models/idol_database_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late HttpServer server;
  Map<String, Object?> payload = {};

  Map<String, Object?> seed(String time, List<Map<String, Object?>> groups) => {
        'sourceUrl': 'https://example.com/community',
        'sourceLabel': 'community',
        'generatedAt': time,
        'groups': groups,
      };
  Map<String, Object?> group(String name, List<String> members) => {
        'name': name,
        'members': [
          for (final name in members) {'name': name, 'status': '现成员'}
        ],
      };

  setUpAll(() async {
    // Exercise the real local HTTP -> JSON -> transaction path.
    HttpOverrides.global = null;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('idol-sync-test-');
    await databaseFactory.setDatabasesPath(directory.path);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(payload));
      await request.response.close();
    });
  });
  setUp(() async {
    final db = await IdolDatabaseService.database;
    await db.delete('idol_members');
    await db.delete('idol_groups');
    await db.delete('idol_people');
    await db.delete('idol_meta');
  });
  tearDownAll(() async {
    await server.close(force: true);
    await (await IdolDatabaseService.database).close();
    await directory.delete(recursive: true);
  });

  Future<void> sync() => IdolDatabaseService.syncFromRemote(
      url: 'http://127.0.0.1:${server.port}/seed.json');

  test('same-name members in different groups are not automatically linked',
      () async {
    payload = seed('2099-01-01T00:00:00Z', [
      group('A', ['同名']),
      group('B', ['同名'])
    ]);
    await sync();
    final members = await IdolDatabaseService.getMembers();
    expect(members, hasLength(2));
    expect(members.every((member) => member.personId == null), isTrue);
    expect(await IdolDatabaseService.getPeople(), isEmpty);
  });

  test('sync preserves explicit identity, local edits, missing members and ids',
      () async {
    payload = seed('2099-01-01T00:00:00Z', [
      group('A', ['成员', '缺页成员'])
    ]);
    await sync();
    final original = await IdolDatabaseService.getMembers();
    final member = original.firstWhere((item) => item.name == '成员');
    await IdolDatabaseService.upsertMember(member.copyWith(
        personName: '手工身份',
        isBuiltIn: false,
        source: 'manual',
        status: '手工状态'));
    final linked = (await IdolDatabaseService.getMembers())
        .firstWhere((item) => item.id == member.id);
    expect(linked.personId, isNotNull);
    payload = seed('2099-01-02T00:00:00Z', [
      group('A', ['成员'])
    ]);
    await sync();
    final after = await IdolDatabaseService.getMembers();
    expect(after, hasLength(2));
    final preserved = after.firstWhere((item) => item.id == member.id);
    expect(preserved.personId, linked.personId);
    expect(preserved.status, '手工状态');
    expect(preserved.source, 'manual');
    expect(after.map((item) => item.id).toSet(),
        original.map((item) => item.id).toSet());
  });

  test('same-name manual upserts preserve group and member ids', () async {
    payload = seed('2099-01-01T00:00:00Z', [
      group('A', ['成员'])
    ]);
    await sync();
    final beforeGroup = (await IdolDatabaseService.getGroups()).single;
    final beforeMember = (await IdolDatabaseService.getMembers()).single;
    final groupId =
        await IdolDatabaseService.upsertGroup(const IdolGroup(name: 'A'));
    expect(groupId, beforeGroup.id);
    final memberId = await IdolDatabaseService.upsertMember(IdolMember(
        groupId: groupId,
        groupName: 'A',
        name: '成员',
        personName: '明确身份',
        status: '手工状态'));
    expect(memberId, beforeMember.id);
    expect((await IdolDatabaseService.getMembers()).single.groupId, groupId);
  });

  test('deleting memberships retains independent people used by counters',
      () async {
    final personId =
        await IdolDatabaseService.upsertPerson(const IdolPerson(name: '独立真人'));
    payload = seed('2099-01-01T00:00:00Z', [
      group('A', ['成员'])
    ]);
    await sync();
    expect((await IdolDatabaseService.getPeople()).single.id, personId);
    final member = (await IdolDatabaseService.getMembers()).single;
    await IdolDatabaseService.upsertMember(
        member.copyWith(personId: personId, personName: '独立真人'));
    await IdolDatabaseService.deleteMember(member.id!);
    expect((await IdolDatabaseService.getPeople()).single.id, personId);
    await IdolDatabaseService.deleteGroup(member.groupId);
    expect((await IdolDatabaseService.getPeople()).single.id, personId);
  });

  test('editing a member status alone does not invent a person identity',
      () async {
    payload = seed('2099-01-01T00:00:00Z', [
      group('A', ['成员'])
    ]);
    await sync();
    final member = (await IdolDatabaseService.getMembers()).single;
    await IdolDatabaseService.upsertMember(
        member.copyWith(status: '前成员', isBuiltIn: false));
    final updated = (await IdolDatabaseService.getMembers()).single;
    expect(updated.personId, isNull);
    expect(updated.personName, isEmpty);
    expect(await IdolDatabaseService.getPeople(), isEmpty);
  });

  test('older bundles and malformed members cannot overwrite a good snapshot',
      () async {
    payload = seed('2099-01-02T00:00:00Z', [
      group('A', ['成员'])
    ]);
    await sync();
    payload = seed('2099-01-01T00:00:00Z', [
      group('A', ['过期成员'])
    ]);
    await expectLater(sync(), throwsFormatException);
    payload = seed('2099-01-03T00:00:00Z', [
      group('A', ['新成员']),
      {
        'name': 'B',
        'members': [
          {'name': 42}
        ]
      }
    ]);
    await expectLater(sync(), throwsFormatException);
    expect((await IdolDatabaseService.getMembers()).single.name, '成员');
    expect((await IdolDatabaseService.getMeta())['generated_at'],
        '2099-01-02T00:00:00Z');
    // A cold start must also retain the newer remote snapshot over the APK asset.
    await IdolDatabaseService.initializeBuiltInDataIfNeeded();
    expect((await IdolDatabaseService.getMembers()).single.name, '成员');
  });
}
