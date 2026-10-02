import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ota_counter/main.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/idol_database_service.dart';
import 'package:ota_counter/widgets/add_counter_dialog.dart';
import 'package:ota_counter/widgets/counter_card.dart';
import 'package:ota_counter/widgets/add_activity_record_dialog.dart';
import 'package:ota_counter/widgets/counter_count_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('identity-picker-');
    await databaseFactory.setDatabasesPath(directory.path);
    SharedPreferences.setMockInitialValues({});
    final db = await IdolDatabaseService.database;
    // A remote seed has display names and affiliations, but no verified identity.
    for (final name in ['测试团 A', '测试团 B']) {
      final id =
          await db.insert('idol_groups', {'name': name, 'is_builtin': 1});
      await db.insert(
          'idol_members', {'name': '同名成员', 'group_id': id, 'is_builtin': 1});
    }
    await db.insert(
        'idol_meta', {'key': 'generated_at', 'value': '2099-01-01T00:00:00Z'});
  });
  tearDownAll(() async {
    await (await IdolDatabaseService.database).close();
    await (await DatabaseService.database).close();
    await directory.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    // FFI resolves outside the fake widget clock; yield to actual I/O while
    // advancing route animations rather than waiting on loading animations.
    for (var index = 0; index < 6; index++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets(
      'selecting two same-name seed members keeps independent home cards',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final selected = <CounterModel>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                      onPressed: () async {
                        final result = await showDialog<CounterDialogResult>(
                            context: context,
                            builder: (_) => const AddCounterDialog());
                        if (result != null) {
                          selected.add(result.counter);
                          await DatabaseService.insertCounter(result.counter);
                        }
                      },
                      child: const Text('打开添加'),
                    )))));

    for (final group in ['测试团 A', '测试团 B']) {
      await tester.tap(find.text('打开添加'));
      await settle(tester);
      await tester.tap(find.text('从内置偶像库快速选择'));
      await settle(tester);
      await tester.tap(find.text('点击搜索团体'));
      await settle(tester);
      await tester.tap(find.text(group));
      await settle(tester);
      await tester.tap(find.text('点击搜索成员'));
      await settle(tester);
      await tester.tap(find.text('同名成员'));
      await settle(tester);
      final personField = find.byWidgetPredicate((widget) =>
          widget is TextField && widget.decoration?.labelText == '真人主档名');
      expect(tester.widget<TextField>(personField).controller!.text, isEmpty);
      await tester.tap(find.text('确定'));
      await settle(tester);
    }
    expect(selected, hasLength(2));
    expect(
        selected.every((counter) =>
            counter.personId == null && counter.personName.isEmpty),
        isTrue);
    expect(await tester.runAsync(IdolDatabaseService.getPeople), isEmpty);
    await tester.runAsync(DatabaseService.autoAssignCounterThemeColors);
    final persisted = await tester.runAsync(DatabaseService.getCounters);
    expect(persisted, hasLength(2));
    expect(
        persisted!.every((counter) =>
            counter.personId == null && counter.personName.isEmpty),
        isTrue);
    await tester.pumpWidget(const MyApp());
    await settle(tester);
    expect(find.byType(CounterCard), findsNWidgets(2));
  });
  testWidgets(
      'multi participant picker retains affiliation without invented identity',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    ActivityRecordDraft? result;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                      onPressed: () async {
                        result = await showDialog<ActivityRecordDraft>(
                            context: context,
                            builder: (_) => const AddActivityRecordDialog(
                                counters: [], pricings: []));
                      },
                      child: const Text('打开记录'),
                    )))));
    await tester.tap(find.text('打开记录'));
    await settle(tester);
    await tester.tap(find.text('多人切'));
    await settle(tester);
    for (final group in ['测试团 A', '测试团 B']) {
      await tester.tap(find.text('添加参与成员'));
      await settle(tester);
      await tester.tap(
          find.ancestor(of: find.text(group), matching: find.byType(ListTile)));
      await settle(tester);
    }
    await tester.tap(find.text('保存记录'));
    await settle(tester);
    expect(result, isNotNull);
    expect(result!.multiParticipants, hasLength(2));
    expect(
        result!.multiParticipants.every((participant) =>
            participant.personId == null && participant.personName.isEmpty),
        isTrue);
    expect(
        result!.multiParticipants
            .map((participant) => participant.groupName)
            .toSet(),
        {'测试团 A', '测试团 B'});
  });

  testWidgets(
      'count sheet does not offer unlinked namesakes as another affiliation',
      (tester) async {
    final current = CounterModel(
        name: '同名成员',
        groupName: '测试团 A',
        personId: 123,
        personName: '同名成员',
        color: '#FFE135');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CounterCountSheet(
      counter: current,
      allCounters: [current],
      onCounterChanged: (updated, occurredAt,
              {activityName = '', venueName = '', sessionLabel = ''}) async =>
          updated,
    ))));
    await settle(tester);
    expect(find.text('记录到团体'), findsNothing);
  });
}
