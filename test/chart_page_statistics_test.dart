import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ota_counter/models/activity_record_media_model.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/pages/chart_page.dart';
import 'package:ota_counter/theme/app_theme.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/face/face_recognition_rules.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ota_counter/widgets/add_activity_record_dialog.dart';

import 'support/isolated_test_databases.dart';

Finder component(String type) =>
    find.byWidgetPredicate((widget) => widget.runtimeType.toString() == type);

Finder section(String title) => find.byWidgetPredicate((widget) =>
    widget.runtimeType.toString() == '_SectionCard' &&
    (widget as dynamic).title == title);

void expectSummary(String label, String value) {
  final card =
      find.ancestor(of: find.text(label), matching: component('_SummaryCard'));
  expect(find.descendant(of: card, matching: find.text(value)), findsOneWidget);
}

Future<void> openChart(WidgetTester tester,
    {double textScale = 1, ThemeData? theme}) async {
  // Large test surface keeps all aggregate sections mounted; no emulator or
  // screenshot is involved. Production layout still goes through real widgets.
  await tester.binding.setSurfaceSize(const Size(1400, 14000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.runAsync(() async {
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const ChartPage(),
    ));
    for (var i = 0;
        i < 200 && component('_CalendarDayDetailCard').evaluate().isEmpty;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  });
  await tester.pumpAndSettle();
  expect(component('_CalendarDayDetailCard'), findsOneWidget);
}

void main() {
  setUpAll(() async => useIsolatedTestDatabases());
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService.clearAppData();
  });

  testWidgets(
      'calendar, selected records and scans share the ledger activity day',
      (tester) async {
    final day = activityDayOf(DateTime.now());
    ActivityRecordModel entry(String name, DateTime at) => ActivityRecordModel(
        type: ActivityRecordType.counter,
        subjectName: name,
        occurredAt: at,
        threeInchCount: 1,
        usesCurrentPricing: false,
        totalAmount: 10);
    final records = [
      entry('仅日期', day),
      entry('当天清晨归昨日', DateTime(day.year, day.month, day.day, 5, 59)),
      entry('六点归当天', DateTime(day.year, day.month, day.day, 6)),
      entry('次日清晨归当天', DateTime(day.year, day.month, day.day + 1, 5, 59)),
    ];
    await tester.runAsync(() async {
      final db = await DatabaseService.database;
      for (final record in records) {
        final id = await DatabaseService.insertActivityRecord(record);
        await db.insert(
            DatabaseService.activityRecordMediaTableName,
            ActivityRecordMediaModel(
                    recordId: id,
                    path: '/not-a-real-image/${record.subjectName}.jpg',
                    createdAt: day.add(const Duration(days: 5)),
                    mediaType: ActivityRecordMediaType.scan)
                .toMap());
      }
    });
    await openChart(tester);
    final detail = component('_CalendarDayDetailCard');
    for (final name in ['仅日期', '六点归当天', '次日清晨归当天']) {
      expect(find.descendant(of: detail, matching: find.text(name)),
          findsNWidgets(2));
    }
    expect(find.descendant(of: detail, matching: find.text('当天清晨归昨日')),
        findsNothing);
    final images = tester
        .widgetList<Image>(
            find.descendant(of: detail, matching: find.byType(Image)))
        .toList();
    expect(images, hasLength(3));
    expect(
        images
            .map((image) => (image.image as ResizeImage).imageProvider)
            .whereType<FileImage>()
            .map((image) => image.file.path),
        isNot(contains('/not-a-real-image/当天清晨归昨日.jpg')));
    expectSummary('记录数', '3');
    expectSummary('拍切总数', '3');
    expectSummary('总金额', '¥30');
    expect(tester.takeException(), isNull);
  });

  for (final showHidden in [false, true]) {
    testWidgets(
        'hidden preference=$showHidden applies to calendar, contributions and amounts',
        (tester) async {
      SharedPreferences.setMockInitialValues(
          {'show_hidden_counters': showHidden});
      final day = activityDayOf(DateTime.now());
      late ActivityRecordModel partial;
      final visible = CounterModel(
          name: '可见', groupName: '可见团', personId: 1, color: '#ffffff');
      final hidden = CounterModel(
          name: '隐藏',
          groupName: '隐藏团',
          personId: 2,
          color: '#ffffff',
          isHidden: true);
      await tester.runAsync(() async {
        final visibleId = await DatabaseService.insertCounter(visible);
        final hiddenId = await DatabaseService.insertCounter(hidden);
        ActivityRecordModel single(CounterModel counter, int quantity) =>
            ActivityRecordModel.counterAdjustment(
                    counter: counter,
                    occurredAt: day,
                    deltas: {CounterCountField.threeInch: quantity})
                .copyWith(usesCurrentPricing: false, totalAmount: 0);
        const a = ActivityParticipant(memberName: '可见', groupName: '可见团');
        const b = ActivityParticipant(
            memberName: '隐藏', groupName: '隐藏团', personId: 2);
        partial = ActivityRecordModel.multiCut(
            participants: [
              a,
              const ActivityParticipant(
                  memberName: '可见别名', groupName: '可见团', personId: 1),
              b
            ],
            field: CounterCountField.threeInch,
            occurredAt: day,
            quantity: 2,
            totalPrice: 120);
        final allHidden = ActivityRecordModel.multiCut(
            participants: [b],
            field: CounterCountField.threeInch,
            occurredAt: day,
            quantity: 4,
            totalPrice: 80);
        final empty = ActivityRecordModel.multiCut(
                participants: [],
                field: CounterCountField.groupCut,
                occurredAt: day,
                quantity: 2,
                totalPrice: 100)
            .copyWith(groupName: '空团');
        for (final record in [
          single(visible.copyWith(id: visibleId), 2),
          single(hidden.copyWith(id: hiddenId), 3),
          single(CounterModel(name: '未知', color: '#ffffff'), 7),
          partial,
          allHidden,
          empty,
          ActivityRecordModel.ticket(
              eventName: '演出', occurredAt: day, unitPrice: 50)
        ]) {
          await DatabaseService.insertActivityRecord(record);
        }
      });
      await openChart(tester);
      expectSummary('记录数', showHidden ? '7' : '5');
      expectSummary('拍切总数', showHidden ? '12' : '9');
      expectSummary('多人切总数', showHidden ? '8' : '4');
      expectSummary('切奇合计', showHidden ? '20' : '13');
      expect(find.byType(PieChart), findsNWidgets(2));
      expect(find.text('本周期含负数修正，暂不显示占比'), findsNothing);
      expectSummary('门票总数', '1');
      expectSummary('总金额', showHidden ? '¥350' : '¥270');
      final members = section('成员贡献');
      expect(find.descendant(of: members, matching: find.text('未知')),
          findsOneWidget);
      expect(find.descendant(of: members, matching: find.text('隐藏')),
          showHidden ? findsOneWidget : findsNothing);
      final progress = tester.widgetList<LinearProgressIndicator>(
          find.descendant(
              of: members, matching: find.byType(LinearProgressIndicator)));
      expect(progress.map((bar) => bar.value),
          showHidden ? [9 / 20, 7 / 20, 4 / 20] : [7 / 11, 4 / 11]);
      final groups = section('团体统计');
      expect(find.descendant(of: groups, matching: find.text('¥100')),
          findsOneWidget);
      expect(find.descendant(of: groups, matching: find.text('¥60')),
          findsOneWidget);
      expect(find.descendant(of: groups, matching: find.text('隐藏团')),
          showHidden ? findsOneWidget : findsNothing);
      final detail = component('_CalendarDayDetailCard');
      expect(find.descendant(of: detail, matching: find.text('隐藏')),
          showHidden ? findsNWidgets(3) : findsNothing);
      final ledger = section('流水明细');
      final tile = find.ancestor(
          of: find.descendant(
              of: ledger, matching: find.text(partial.multiDisplayName)),
          matching: find.byType(ListTile));
      await tester
          .tap(find.descendant(of: tile, matching: find.byTooltip('记录操作')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pump();
      final editor = tester.widget<AddActivityRecordDialog>(
          find.byType(AddActivityRecordDialog));
      expect(editor.counters, hasLength(2));
      expect(
          editor.counters.where((counter) => counter.isHidden), hasLength(1));
      expect(
          editor.initialDraft!.multiParticipants
              .map((participant) => participant.toMap()),
          partial.effectiveParticipants
              .map((participant) => participant.toMap()));
      expect(editor.initialDraft!.multiParticipants, hasLength(3));
      expect(editor.initialDraft!.multiTotalPrice, 120);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'real summary widgets separate casts/specs/venues and merge renamed members',
      (tester) async {
    final day = activityDayOf(DateTime.now());
    final current =
        CounterModel(name: '新名', groupName: 'G', personId: 1, color: '#ffffff');
    await tester.runAsync(() async {
      final id = await DatabaseService.insertCounter(current);
      final twinId =
          await DatabaseService.insertCounter(current.copyWith(personId: 2));
      for (final record in [
        ActivityRecordModel.counterAdjustment(
            counter: current.copyWith(id: id, name: '旧名'),
            occurredAt: day,
            deltas: {CounterCountField.threeInch: 2}),
        ActivityRecordModel.counterAdjustment(
            counter: current.copyWith(id: id),
            occurredAt: day,
            deltas: {CounterCountField.threeInch: 3}),
        ActivityRecordModel.counterAdjustment(
            counter: current.copyWith(id: twinId, personId: 2),
            occurredAt: day,
            deltas: {CounterCountField.threeInch: 4}),
      ]) {
        await DatabaseService.insertActivityRecord(record);
      }
      const a = ActivityParticipant(memberName: 'A', groupName: 'G');
      const b = ActivityParticipant(memberName: 'B', groupName: 'G');
      const c = ActivityParticipant(memberName: 'C', groupName: 'G');
      const d = ActivityParticipant(memberName: 'D', groupName: 'G');
      for (final cast in [
        [a, b, c],
        [c, b, a],
        [a, b, d]
      ]) {
        await DatabaseService.insertActivityRecord(ActivityRecordModel.multiCut(
            participants: cast,
            field: CounterCountField.threeInch,
            occurredAt: day,
            totalPrice: 30));
      }
      await DatabaseService.insertActivityRecord(ActivityRecordModel.multiCut(
          participants: [a, b, c],
          field: CounterCountField.fiveInch,
          occurredAt: day,
          totalPrice: 60));
      for (final venue in ['场馆X', '场馆Y']) {
        await DatabaseService.insertActivityRecord(ActivityRecordModel.ticket(
            eventName: '同名巡演',
            venueName: venue,
            sessionLabel: '夜场',
            occurredAt: day,
            unitPrice: 50));
      }
    });
    await openChart(tester);
    final members = section('成员贡献');
    expect(find.descendant(of: members, matching: find.text('新名')),
        findsNWidgets(2));
    expect(
        find.descendant(of: members, matching: find.text('旧名')), findsNothing);
    final multiTiles = tester
        .widgetList<ListTile>(find.descendant(
            of: section('多人切'), matching: find.byType(ListTile)))
        .toList();
    expect(multiTiles, hasLength(3));
    expect(multiTiles.map((tile) => (tile.trailing as Text).data),
        contains('2 次\n¥60'));
    final ticketTiles = tester
        .widgetList<ListTile>(find.descendant(
            of: section('门票场次'), matching: find.byType(ListTile)))
        .toList();
    expect(ticketTiles, hasLength(2));
    expect(ticketTiles.map((tile) => (tile.subtitle as Text).data),
        containsAll([contains('场馆X'), contains('场馆Y')]));
    expect(find.text('按参与人数统计'), findsNothing);
    expect(find.text('按记录快照价格统计'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  for (final change in ['group', 'person', 'rename']) {
    testWidgets('real updateCounter preserves historical $change statistics',
        (tester) async {
      final day = activityDayOf(DateTime.now());
      late CounterModel before;
      late CounterModel after;
      await tester.runAsync(() async {
        before = CounterModel(
            name: '旧成员',
            groupName: 'G1',
            personId: 101,
            personName: '旧人',
            color: '#ffffff');
        final id = await DatabaseService.insertCounter(before);
        before = before.copyWith(id: id);
        await DatabaseService.insertActivityRecordWithCounterImpact(
            ActivityRecordModel.counterAdjustment(
                counter: before,
                occurredAt: day,
                deltas: {CounterCountField.threeInch: 2}));
        after = switch (change) {
          'group' => before.copyWith(groupName: 'G2'),
          'person' =>
            before.copyWith(name: '新成员', personId: 202, personName: '新人'),
          _ => before.copyWith(name: '新成员'),
        };
        await DatabaseService.updateCounter(id, after);
        after = (await DatabaseService.getCounters()).single;
        await DatabaseService.insertActivityRecordWithCounterImpact(
            ActivityRecordModel.counterAdjustment(
                counter: after,
                occurredAt: day,
                deltas: {CounterCountField.threeInch: 3}));
        final stored = await DatabaseService.getActivityRecords();
        final historical =
            stored.singleWhere((record) => record.threeInchCount == 2);
        expect(historical.counterId, id);
        expect(historical.groupName, 'G1');
        expect(historical.personId, 101);
        expect(historical.subjectName, '旧成员');
      });
      await openChart(tester);
      final members = section('成员贡献');
      final counts = change == 'rename' ? ['5'] : ['2', '3'];
      for (final count in counts) {
        expect(find.descendant(of: members, matching: find.text(count)),
            findsOneWidget);
      }
      if (change == 'group') {
        for (final group in ['G1', 'G2']) {
          expect(find.descendant(of: members, matching: find.text(group)),
              findsOneWidget);
          expect(
              find.descendant(of: section('团体统计'), matching: find.text(group)),
              findsOneWidget);
        }
      } else if (change == 'person') {
        expect(find.descendant(of: members, matching: find.text('旧成员')),
            findsOneWidget);
        expect(find.descendant(of: members, matching: find.text('新成员')),
            findsOneWidget);
      } else {
        expect(find.descendant(of: members, matching: find.text('新成员')),
            findsOneWidget);
        expect(find.descendant(of: members, matching: find.text('旧成员')),
            findsNothing);
      }
      await tester.tap(find.text('按真人'));
      await tester.pumpAndSettle();
      final people = section('真人贡献');
      for (final count in change == 'person' ? ['2', '3'] : ['5']) {
        expect(find.descendant(of: people, matching: find.text(count)),
            findsOneWidget);
      }
      if (change == 'person') {
        expect(find.descendant(of: people, matching: find.text('旧人')),
            findsOneWidget);
        expect(find.descendant(of: people, matching: find.text('新人')),
            findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'real updateCounter unlinking and renaming preserves historical labels',
      (tester) async {
    final day = activityDayOf(DateTime.now());
    await tester.runAsync(() async {
      final before = CounterModel(
          name: '旧成员', groupName: 'G1', personId: 101, color: '#ffffff');
      final id = await DatabaseService.insertCounter(before);
      await DatabaseService.insertActivityRecordWithCounterImpact(
          ActivityRecordModel.counterAdjustment(
              counter: before.copyWith(id: id),
              occurredAt: day,
              deltas: {CounterCountField.threeInch: 2}));
      // Like AddCounterDialog, construct a new counter so null really unlinks
      // the person; copyWith(personId: null) would retain the existing ID.
      await DatabaseService.updateCounter(id,
          CounterModel(id: id, name: '新成员', groupName: 'G1', color: '#ffffff'));
      final unlinked = (await DatabaseService.getCounters()).single;
      expect(unlinked.personId, isNull);
      expect(unlinked.personName, isEmpty);
      await DatabaseService.insertActivityRecordWithCounterImpact(
          ActivityRecordModel.counterAdjustment(
              counter: unlinked,
              occurredAt: day,
              deltas: {CounterCountField.threeInch: 3}));
      final old = (await DatabaseService.getActivityRecords())
          .singleWhere((record) => record.threeInchCount == 2);
      expect(old.personId, 101);
      expect(old.personName, isEmpty);
      expect(old.subjectName, '旧成员');
    });
    await openChart(tester);
    for (final mode in ['成员贡献', '真人贡献']) {
      if (mode == '真人贡献') {
        await tester.tap(find.text('按真人'));
        await tester.pumpAndSettle();
      }
      final members = section(mode);
      for (final pair in [('旧成员', '2'), ('新成员', '3')]) {
        final label =
            find.descendant(of: members, matching: find.text(pair.$1));
        expect(label, findsOneWidget);
        final row = find.ancestor(of: label, matching: find.byType(Row)).first;
        expect(find.descendant(of: row, matching: find.text(pair.$2)),
            findsOneWidget);
      }
    }
    expect(tester.takeException(), isNull);
  });

  for (final reverse in [false, true]) {
    testWidgets(
        'alias order=$reverse keeps person totals and cross-group shares',
        (tester) async {
      final day = activityDayOf(DateTime.now());
      await tester.runAsync(() async {
        final a = CounterModel(
            name: 'A',
            groupName: 'G1',
            personId: 101,
            personName: '真人A',
            color: '#ffffff');
        final b = CounterModel(
            name: 'B',
            groupName: 'G2',
            personId: 102,
            personName: '真人B',
            color: '#ffffff');
        final id = await DatabaseService.insertCounter(a);
        await DatabaseService.insertCounter(b);
        await DatabaseService.insertActivityRecordWithCounterImpact(
            ActivityRecordModel.counterAdjustment(
                    counter: a.copyWith(id: id),
                    occurredAt: day,
                    deltas: {CounterCountField.threeInch: 3})
                .copyWith(totalAmount: 0, usesCurrentPricing: false));
        const byName = ActivityParticipant(memberName: 'A', groupName: 'G1');
        const byId = ActivityParticipant(memberName: '别名A', personId: 101);
        const other = ActivityParticipant(
            memberName: 'B', groupName: 'G2', personId: 102);
        final record = ActivityRecordModel.multiCut(
            participants:
                reverse ? [byId, byName, other] : [byName, byId, other],
            field: CounterCountField.threeInch,
            occurredAt: day,
            quantity: 2,
            totalPrice: 120);
        await DatabaseService.insertActivityRecordWithCounterImpact(record);
        final stored = (await DatabaseService.getActivityRecords())
            .singleWhere((record) => record.isMulti);
        expect(stored.effectiveParticipants, hasLength(3));
        expect(
            stored.effectiveParticipants.first.groupName, reverse ? '' : 'G1');
      });
      await openChart(tester);
      final groups = section('团体统计');
      expect(
          find.descendant(of: groups, matching: find.text('跨团')), findsNothing);
      expect(find.descendant(of: groups, matching: find.text('¥60')),
          findsNWidgets(2));
      final multiChips = find.byWidgetPredicate((widget) =>
          widget.runtimeType.toString() == '_MetricChip' &&
          (widget as dynamic).label == '多人切');
      expect(
          tester
              .widgetList(multiChips)
              .map((widget) => (widget as dynamic).value),
          ['2', '2']);
      await tester.tap(find.text('按真人'));
      await tester.pumpAndSettle();
      final people = section('真人贡献');
      expect(find.descendant(of: people, matching: find.text('真人A')),
          findsOneWidget);
      expect(find.descendant(of: people, matching: find.text('5')),
          findsOneWidget);
      expect(find.descendant(of: people, matching: find.text('真人B')),
          findsOneWidget);
      expect(find.descendant(of: people, matching: find.text('2')),
          findsOneWidget);
      expect(
          tester
              .widgetList<LinearProgressIndicator>(find.descendant(
                  of: people, matching: find.byType(LinearProgressIndicator)))
              .map((bar) => bar.value),
          [5 / 7, 2 / 7]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('pie palette labels choose the higher black-white contrast',
      (tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 6; i++) {
        await DatabaseService.insertActivityRecord(ActivityRecordModel(
            type: ActivityRecordType.counter,
            subjectName: '成员$i',
            totalAmount: 0,
            groupName: '团$i',
            occurredAt: activityDayOf(DateTime.now()),
            threeInchCount: 1));
      }
    });
    await openChart(tester);
    final sections = tester
        .widgetList<PieChart>(find.byType(PieChart))
        .expand((chart) => chart.data.sections)
        .toList();
    for (final color in [
      const Color(0xFF4E8DF5),
      const Color(0xFF0F9E8E),
      const Color(0xFFE85D7A)
    ]) {
      final matching = sections.where((slice) => slice.color == color).toList();
      expect(matching, isNotEmpty);
      for (final slice in matching) {
        expect(slice.titleStyle!.color, Colors.black);
      }
    }
    for (final slice in sections) {
      final background = slice.color.computeLuminance();
      final foreground = slice.titleStyle!.color!.computeLuminance();
      final contrast = foreground > background
          ? (foreground + 0.05) / (background + 0.05)
          : (background + 0.05) / (foreground + 0.05);
      expect(contrast, greaterThanOrEqualTo(4.5));
      expect(
          contrast,
          greaterThanOrEqualTo((slice.titleStyle!.color == Colors.black)
              ? 1.05 / (background + 0.05)
              : (background + 0.05) / 0.05));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('negative member net suppresses only member proportions',
      (tester) async {
    final day = activityDayOf(DateTime.now());
    await tester.runAsync(() async {
      for (final pair in [('正数', 10), ('负数', -5)]) {
        final counter =
            CounterModel(name: pair.$1, groupName: '同团', color: '#ffffff');
        final id = await DatabaseService.insertCounter(counter);
        await DatabaseService.insertActivityRecord(
            ActivityRecordModel.counterAdjustment(
          counter: counter.copyWith(id: id),
          occurredAt: day,
          deltas: {CounterCountField.threeInch: pair.$2},
        ));
      }
    });
    await openChart(tester);
    expectSummary('切奇合计', '5');
    expect(find.byType(PieChart), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    final members = section('成员贡献');
    expect(find.descendant(of: members, matching: find.text('-5')),
        findsOneWidget);
    expect(find.text('本周期含负数修正，暂不显示占比'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('negative group net suppresses only group proportions',
      (tester) async {
    final day = activityDayOf(DateTime.now());
    await tester.runAsync(() async {
      for (final pair in [('正团', 10), ('负团', -5)]) {
        final counter = CounterModel(
            name: '同一人', groupName: pair.$1, personId: 123, color: '#ffffff');
        final id = await DatabaseService.insertCounter(counter);
        await DatabaseService.insertActivityRecord(
            ActivityRecordModel.counterAdjustment(
          counter: counter.copyWith(id: id),
          occurredAt: day,
          deltas: {CounterCountField.threeInch: pair.$2},
        ));
      }
    });
    await openChart(tester);
    await tester.tap(find.text('按真人'));
    await tester.pumpAndSettle();
    expect(find.byType(PieChart), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('本周期含负数修正，暂不显示占比'), findsOneWidget);
    expect(find.descendant(of: section('团体统计'), matching: find.text('-5')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('periods and add entry remain accessible on a phone',
      (tester) async {
    await openChart(tester, textScale: 1.5);
    final grid = find.byType(GridView);
    await tester.tap(find.descendant(of: grid, matching: find.text('1')));
    await tester.pumpAndSettle();
    expect(
        (tester.widget(component('_CalendarDayDetailCard')) as dynamic)
            .date
            .day,
        1);
    await tester.tap(find.text('统计口径'));
    await tester.pumpAndSettle();
    expect(find.textContaining('06:00 前的记录归前一天'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(360, 800));
    await tester.pumpAndSettle();
    for (final label in ['日统计', '周统计', '月统计', '年统计', '全部']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    expect(find.byType(FloatingActionButton), findsNothing);
    await tester.tap(find.byTooltip('新增记录'));
    await tester.pumpAndSettle();
    expect(find.byType(AddActivityRecordDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('large text keeps a populated chart usable at narrow width',
      (tester) async {
    final counter = CounterModel(
        name: '很长很长的成员名称测试', groupName: '很长很长的团体名称测试', color: '#ffffff');
    await tester.runAsync(() async {
      final id = await DatabaseService.insertCounter(counter);
      await DatabaseService.insertActivityRecord(
          ActivityRecordModel.counterAdjustment(
        counter: counter.copyWith(id: id),
        occurredAt: activityDayOf(DateTime.now()),
        deltas: {CounterCountField.threeInch: 3},
      ));
    });
    await openChart(tester, textScale: 1.5);
    await tester.binding.setSurfaceSize(const Size(320, 800));
    await tester.pumpAndSettle();
    for (var i = 0; i < 12; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -500));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });
  for (final dark in [false, true]) {
    testWidgets(
        'calendar text contrasts against composited backgrounds dark=$dark',
        (tester) async {
      final now = activityDayOf(DateTime.now());
      await tester.runAsync(() async {
        for (final day in [10, 11]) {
          await DatabaseService.insertActivityRecord(ActivityRecordModel(
            type: ActivityRecordType.counter,
            subjectName: '测试',
            totalAmount: 0,
            groupName: '团',
            occurredAt: DateTime(now.year, now.month, day),
            threeInchCount: 1,
          ));
        }
      });
      final theme = dark ? AppTheme.dark() : AppTheme.light();
      await openChart(tester, theme: theme);
      final grid = find.byType(GridView);
      Finder date(int n) =>
          find.descendant(of: grid, matching: find.text('$n'));
      Future<void> select(int n) async {
        await tester.tap(date(n));
        await tester.pumpAndSettle();
      }

      void check(int n) {
        final target = date(n);
        final text = tester.widget<Text>(target);
        final circle = tester.widget<Container>(find
            .ancestor(
                of: target,
                matching: find.byWidgetPredicate((w) =>
                    w is Container &&
                    w.decoration is BoxDecoration &&
                    (w.decoration as BoxDecoration).shape == BoxShape.circle))
            .first);
        final ink = tester.widget<Ink>(
            find.ancestor(of: target, matching: find.byType(Ink)).first);
        final cell =
            (ink.decoration as BoxDecoration).color ?? Colors.transparent;
        final overlay =
            (circle.decoration as BoxDecoration).color ?? Colors.transparent;
        final background = Color.alphaBlend(
            overlay, Color.alphaBlend(cell, theme.colorScheme.surface));
        final a = text.style!.color!.computeLuminance();
        final b = background.computeLuminance();
        final ratio = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
        expect(ratio, greaterThanOrEqualTo(4.5), reason: 'day $n dark=$dark');
      }

      await select(10);
      check(10); // selected with records
      check(11); // unselected with records
      check(12); // unselected without records
      await select(12);
      check(12); // selected without records
      expect(
          find.byWidgetPredicate((w) =>
              w is Semantics && w.properties.label == '${now.month}月11日，有记录'),
          findsOneWidget);
      expect(
          find.byWidgetPredicate((w) =>
              w is Semantics && w.properties.label == '${now.month}月12日，无记录'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('small pie slices retain ordered non-color mapping',
      (tester) async {
    await tester.runAsync(() async {
      for (final item in [('大', 99), ('小', 1)]) {
        await DatabaseService.insertActivityRecord(ActivityRecordModel(
          type: ActivityRecordType.counter,
          subjectName: item.$1,
          totalAmount: 0,
          groupName: item.$1,
          occurredAt: activityDayOf(DateTime.now()),
          threeInchCount: item.$2,
        ));
      }
    });
    await openChart(tester);
    expect(find.text('扇区从顶部起顺时针排列，与下方编号顺序一致。'), findsNWidgets(2));
    for (final chart in tester.widgetList<PieChart>(find.byType(PieChart))) {
      expect(chart.data.startDegreeOffset, -90);
      expect(chart.data.sections.map((s) => s.value), [99, 1]);
      expect(chart.data.sections.last.title, isEmpty);
    }
    expect(find.textContaining('1. 大'), findsWidgets);
    expect(find.textContaining('2. 小'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
