import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/idol_database_models.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/idol_database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('ota-idol-identity-');
    await databaseFactory.setDatabasesPath(directory.path);
  });

  setUp(() async {
    final db = await IdolDatabaseService.database;
    await db.delete('idol_members');
    await db.delete('idol_groups');
    await db.delete('idol_people');
    await db.delete('idol_meta');
    await DatabaseService.clearAppData();
  });

  tearDownAll(() async {
    await (await IdolDatabaseService.database).close();
    await (await DatabaseService.database).close();
    await directory.delete(recursive: true);
  });

  test(
      'renaming one membership never renames a shared person; clearing unlinks',
      () async {
    final groupId =
        await IdolDatabaseService.upsertGroup(const IdolGroup(name: '测试团'));

    final firstId = await IdolDatabaseService.upsertMember(
      IdolMember(
        groupId: groupId,
        groupName: '测试团',
        name: '成员A',
        personName: '共享真人',
      ),
    );
    final secondId = await IdolDatabaseService.upsertMember(
      IdolMember(
        groupId: groupId,
        groupName: '测试团',
        name: '成员B',
        personName: '共享真人',
      ),
    );

    var members = await IdolDatabaseService.getMembers(groupId: groupId);
    final first = members.singleWhere((member) => member.id == firstId);
    final second = members.singleWhere((member) => member.id == secondId);
    final sharedPersonId = first.personId;
    expect(sharedPersonId, isNotNull);
    expect(second.personId, sharedPersonId);
    expect(await IdolDatabaseService.getPeople(), hasLength(1));

    final counterId = await DatabaseService.insertCounter(
      CounterModel(
        name: '成员A',
        groupName: '测试团',
        personId: sharedPersonId,
        personName: '共享真人',
        color: '#FFE135',
      ),
    );
    addTearDown(() => DatabaseService.deleteCounter(counterId));

    // Simulate the old UI passing the previous personId while changing the
    // person name. This used to rename the shared person row in place.
    await IdolDatabaseService.upsertMember(
      IdolMember(
        id: firstId,
        groupId: groupId,
        groupName: '测试团',
        name: '成员A',
        personId: sharedPersonId,
        personName: '新真人',
        source: 'manual',
        isBuiltIn: false,
      ),
    );

    members = await IdolDatabaseService.getMembers(groupId: groupId);
    final renamed = members.singleWhere((member) => member.id == firstId);
    final untouched = members.singleWhere((member) => member.id == secondId);
    expect(renamed.personId, isNotNull);
    expect(renamed.personId, isNot(sharedPersonId));
    expect(untouched.personId, sharedPersonId);
    final people = await IdolDatabaseService.getPeople();
    expect(people, hasLength(2));
    expect(
      people.singleWhere((person) => person.id == sharedPersonId).name,
      '共享真人',
    );
    expect(
      (await DatabaseService.getCounters()).single.personId,
      sharedPersonId,
    );

    await IdolDatabaseService.upsertMember(
      IdolMember(
        id: firstId,
        groupId: groupId,
        groupName: '测试团',
        name: '成员A',
        personId: renamed.personId,
        personName: '',
        source: 'manual',
        isBuiltIn: false,
      ),
      unlinkPerson: true,
    );

    members = await IdolDatabaseService.getMembers(groupId: groupId);
    expect(
      members.singleWhere((member) => member.id == firstId).personId,
      isNull,
    );
    expect(
      (await DatabaseService.getCounters()).single.personId,
      sharedPersonId,
      reason: 'unlinking a membership must not detach existing counters',
    );
  });
}
