import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ota_counter/models/activity_record_media_model.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/idol_activity_event_model.dart';
import 'package:ota_counter/services/batch_import_service.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/face/face_recognition_rules.dart';
import 'package:ota_counter/services/face/face_sample_service.dart';
import 'package:ota_counter/services/record_scan_service.dart';

import 'support/isolated_test_databases.dart';

final _day = DateTime(2026, 11, 15);
final _a = CounterModel(
    id: 1, personId: 9, name: '小树', groupName: '旧团', color: '#000000');
final _b = CounterModel(
    id: 2, personId: 9, name: '小树', groupName: '新团', color: '#000000');
FaceMember _member(CounterModel c) => FaceSampleService.memberFromCounter(c);

ActivityRecordModel _record(CounterModel c, int? id, int count,
        {String name = '',
        String venue = '',
        String label = '',
        bool five = false}) =>
    ActivityRecordModel.counterAdjustment(
        id: id,
        counter: c,
        occurredAt: _day,
        deltas: {
          five ? CounterCountField.fiveInch : CounterCountField.threeInch: count
        },
        activityName: name,
        venueName: venue,
        sessionLabel: label);

BatchSession _session(String label,
        {int? id = 99, String name = '北京公演', String venue = '北京会场'}) =>
    BatchSession(
        title: '$name $label',
        ticket: ActivityRecordModel.ticket(
            id: id,
            eventName: name,
            venueName: venue,
            sessionLabel: label,
            occurredAt: DateTime(2026, 11, 15, 18)));

BatchDayContext _context(List<ActivityRecordModel> records,
        {List<BatchSession> sessions = const [],
        List<CounterModel>? counters}) =>
    BatchDayContext(
        day: _day,
        records: records,
        sessions: sessions,
        dayMembers: const [],
        counters: counters ?? [_a, _b]);

BatchReviewCard _card(List<FaceMember> members,
    {BatchCutType type = BatchCutType.single, String group = ''}) {
  final raw = BatchCard(
      bytes: Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 8))),
      fileExtension: '.jpg',
      processingMode: ActivityRecordMediaProcessingMode.manualAssist,
      quad: const RecordScanQuad(
          topLeftX: 0,
          topLeftY: 0,
          topRightX: 8,
          topRightY: 0,
          bottomLeftX: 0,
          bottomLeftY: 8,
          bottomRightX: 8,
          bottomRightY: 8),
      sizeClass: RecordScanCardSize.mini,
      confidence: 1,
      splitFromMerged: false);
  return BatchReviewCard(
      source: BatchSourceResult(
          photo: const BatchSourcePhoto(
              path: '/not-read.jpg', capturedAt: null, fromCamera: false),
          sourceHash: 'ledger-scope',
          cards: [raw]),
      card: raw,
      members: members,
      status: FaceMatchStatus.auto,
      suggestions: const [],
      size: ChekiSize.threeInch,
      sizeUncertain: false,
      faceMatches: const [])
    ..cutType = type
    ..groupName = group;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final dir = await useIsolatedTestDatabases();
    final documents = Directory('${dir.path}/documents')..createSync();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => documents.path);
  });
  tearDown(() async => DatabaseService.clearAppData());

  test(
      'same person in two groups gets separate preview lines and attachment records',
      () async {
    final day = _context([_record(_a, 10, 8), _record(_b, 20, 1)]);
    final cards = [
      _card([_member(_a)]),
      _card([_member(_b)]),
      _card([_member(_b)])
    ];
    final lines = BatchImportService.planEntries(cards, day);
    expect(lines, hasLength(2));
    expect(lines.map((e) => e.line.lineKey).toSet(), hasLength(2));
    expect(lines.map((e) => e.line.existingCount), [8, 1]);
    expect(lines.map((e) => e.line.supplement), [0, 1]);
    final plan = await BatchImportService.buildSavePlan(cards: cards, day: day);
    expect(plan.media.map((m) => m.recordId), [10, 20, null]);
    expect(plan.media.last.newRecordIndex, 0);
    expect(plan.newRecords.single.groupName, '新团');
    expect(plan.newRecords.single.threeInchCount, 1);
  });

  test('historic group wins over the counter current affiliation', () {
    final old = _record(_a, 10, 8).copyWith(counterId: _b.id);
    final day = _context([old], counters: [_b]);
    expect(day.existingCount([_member(_b)], ChekiSize.threeInch), 0);
    expect(day.existingCount([_member(_a)], ChekiSize.threeInch), 8);
  });

  test(
      'selected session scopes preview, attachments and supplementary metadata',
      () async {
    final early = _session('午场');
    final late = _session('晚场');
    final day = _context([
      _record(_b, 10, 10, name: '北京公演', venue: '北京会场', label: '午场'),
      _record(_b, 20, 1, name: '北京公演', venue: '北京会场', label: '晚场'),
      _record(_a, 30, 10, name: '北京公演', venue: '北京会场', label: '晚场'),
    ], sessions: [
      early,
      late
    ]);
    final cards = [
      _card([_member(_b)]),
      _card([_member(_b)])
    ];
    final line =
        BatchImportService.planEntries(cards, day, session: late).single.line;
    expect(line.existingCount, 1);
    expect(line.supplement, 1);
    final plan = await BatchImportService.buildSavePlan(
        cards: cards, day: day, session: late);
    expect(plan.media.first.recordId, 20);
    expect(plan.media.last.newRecordIndex, 0);
    final added = plan.newRecords.single;
    expect(added.threeInchCount, line.supplement);
    expect(added.groupName, '新团');
    expect(added.activityName, '北京公演');
    expect(added.venueName, '北京会场');
    expect(added.sessionLabel, '晚场');
    expect(added.occurredAt, late.ticket!.occurredAt);
  });

  test(
      'without selecting a session same-day counts remain pooled within the group',
      () async {
    final day = _context([
      _record(_b, 10, 2, name: '北京公演', label: '午场'),
      _record(_b, 20, 1, name: '北京公演', label: '晚场'),
      _record(_a, 30, 9, name: '北京公演', label: '晚场'),
    ]);
    final cards = [
      _card([_member(_b)]),
      _card([_member(_b)])
    ];
    expect(BatchImportService.planEntries(cards, day).single.line.existingCount,
        3);
    final plan = await BatchImportService.buildSavePlan(cards: cards, day: day);
    expect(plan.newRecords, isEmpty);
    expect(plan.media.every((m) => m.recordId == 10), isTrue);
  });

  test('legacy absent metadata and compatible partial metadata remain eligible',
      () async {
    final selected = _session('晚场');
    final day = _context([
      _record(_b, 10, 1),
      _record(_b, 20, 1, name: '北京公演'),
      _record(_b, 30, 8, name: '别的演出', label: '晚场'),
      _record(_b, 40, 8, name: '北京公演', venue: '上海会场', label: '晚场'),
    ]);
    expect(day.recordsFor([_member(_b)], session: selected).map((r) => r.id),
        [10, 20]);
    final cards = [
      _card([_member(_b)]),
      _card([_member(_b)])
    ];
    expect(
        BatchImportService.planEntries(cards, day, session: selected)
            .single
            .line
            .supplement,
        0);
    final plan = await BatchImportService.buildSavePlan(
        cards: cards, day: day, session: selected);
    expect(plan.newRecords, isEmpty);
    expect(
        plan.media.every((m) => m.recordId == 10 || m.recordId == 20), isTrue);
  });

  test('ambiguous partial session does not absorb known early/late records',
      () {
    final selected = _session('');
    final day = _context([
      _record(_b, 10, 8, name: '北京公演', label: '午场'),
      _record(_b, 20, 8, name: '北京公演', label: '晚场'),
      _record(_b, 30, 1),
    ], sessions: [
      _session('午场'),
      _session('晚场')
    ]);
    expect(day.recordsFor([_member(_b)], session: selected).map((r) => r.id),
        [30]);
  });

  test(
      'disabled supplement cannot attach via wrong-size record of another group/session',
      () async {
    final selected = _session('晚场');
    final day = _context([
      _record(_b, 10, 5, name: '北京公演', label: '午场', five: true),
      _record(_a, 20, 5, name: '北京公演', label: '晚场', five: true),
    ]);
    final cards = [
      _card([_member(_b)])
    ];
    final line = BatchImportService.planEntries(cards, day, session: selected)
        .single
        .line;
    expect(line.existingCount, 0);
    final plan = await BatchImportService.buildSavePlan(
        cards: cards,
        day: day,
        session: selected,
        disabledLines: {line.lineKey});
    expect(plan.newRecords, isEmpty);
    expect(plan.media.single.recordId, selected.ticket!.id);
    final withoutSession = await BatchImportService.buildSavePlan(
        cards: cards, day: day, disabledLines: {line.lineKey});
    expect(withoutSession.media.single.recordId, 10,
        reason:
            'without a selected session, same-day wrong-size fallback is preserved');
    await expectLater(
        BatchImportService.buildSavePlan(
            cards: cards,
            day: day,
            session: _session('晚场', id: null),
            disabledLines: {line.lineKey}),
        throwsStateError,
        reason:
            'without an eligible ledger row or selected ticket, do not attach elsewhere');
  });

  for (final type in [BatchCutType.multi, BatchCutType.group]) {
    test('$type scopes counts and attachments to group and session', () async {
      ActivityRecordModel multi(int id, CounterModel c, String label, int n) =>
          ActivityRecordModel.multiCut(
                  id: id,
                  participants: [
                    ActivityParticipant(
                        memberName: c.name,
                        personId: c.personId,
                        groupName: c.groupName)
                  ],
                  field: type == BatchCutType.group
                      ? CounterCountField.groupCut
                      : CounterCountField.threeInch,
                  occurredAt: _day,
                  activityName: '北京公演',
                  sessionLabel: label,
                  quantity: n)
              .copyWith(groupName: c.groupName);
      final selected = _session('晚场');
      final day = _context([
        multi(10, _b, '午场', 8),
        multi(20, _b, '晚场', 1),
        multi(30, _a, '晚场', 8)
      ]);
      final cards = [
        _card([_member(_b)], type: type, group: '新团'),
        _card([_member(_b)], type: type, group: '新团')
      ];
      final line = BatchImportService.planEntries(cards, day, session: selected)
          .single
          .line;
      expect(line.existingCount, 1);
      expect(line.supplement, 1);
      final plan = await BatchImportService.buildSavePlan(
          cards: cards, day: day, session: selected);
      expect(plan.media.first.recordId, 20);
      expect(plan.media.last.newRecordIndex, 0);
      expect(plan.newRecords.single.effectiveMultiQuantity, 1);
      expect(plan.newRecords.single.sessionLabel, '晚场');
      expect(
          plan.newRecords.single.effectiveParticipants.single.groupName, '新团');
    });
  }

  test('event-only selected session uses identical matching and saved metadata',
      () async {
    final selected = BatchSession(
        title: '晚场',
        event: IdolActivityEvent(
            sourceEventId: 'local-test',
            eventDate: _day,
            eventName: '北京公演',
            venue: '北京会场',
            startTime: '18:00',
            syncedAt: _day));
    final day = _context([_record(_b, 10, 8, name: '北京公演', label: '13:00')]);
    final cards = [
      _card([_member(_b)])
    ];
    expect(
        BatchImportService.planEntries(cards, day, session: selected)
            .single
            .line
            .supplement,
        1);
    final plan = await BatchImportService.buildSavePlan(
        cards: cards, day: day, session: selected);
    expect(plan.media.single.newRecordIndex, 0);
    expect(plan.newRecords.single.activityName, '北京公演');
    expect(plan.newRecords.single.venueName, '北京会场');
    expect(plan.newRecords.single.sessionLabel, '18:00');
  });

  test('actual save leaves old group and early session untouched', () async {
    final oldId = await DatabaseService.insertCounter(CounterModel(
        name: 'Liumoo',
        personName: 'Liumoo',
        groupName: '旧团',
        color: '#000000'));
    final old =
        (await DatabaseService.getCounters()).singleWhere((c) => c.id == oldId);
    final newId = await DatabaseService.insertCounter(CounterModel(
        name: 'Liumoo',
        personName: 'Liumoo',
        personId: old.personId,
        groupName: '新团',
        color: '#000000'));
    final current =
        (await DatabaseService.getCounters()).singleWhere((c) => c.id == newId);
    final oldRecord =
        await DatabaseService.insertActivityRecordWithCounterImpact(
            _record(old, null, 8, name: '北京公演', label: '晚场'));
    final earlyRecord =
        await DatabaseService.insertActivityRecordWithCounterImpact(
            _record(current, null, 5, name: '北京公演', label: '午场'));
    final lateRecord =
        await DatabaseService.insertActivityRecordWithCounterImpact(
            _record(current, null, 1, name: '北京公演', label: '晚场'));
    final day = await BatchImportService.loadDayContext(_day);
    final cards = [
      _card([_member(current)]),
      _card([_member(current)])
    ];
    final selected = _session('晚场');
    final line = BatchImportService.planEntries(cards, day, session: selected)
        .single
        .line;
    expect(line.existingCount, 1);
    final plan = await BatchImportService.buildSavePlan(
        cards: cards, day: day, session: selected);
    await BatchImportService.save(plan, learnFaces: false);
    final media = await DatabaseService.getActivityRecordMedia();
    expect(
        media
            .where((m) => m.recordId == oldRecord || m.recordId == earlyRecord),
        isEmpty);
    expect(media.where((m) => m.recordId == lateRecord), hasLength(1));
    final records = await DatabaseService.getActivityRecords();
    final added =
        records.singleWhere((r) => r.note == BatchImportService.supplementNote);
    expect(added.counterId, newId);
    expect(added.groupName, '新团');
    expect(added.sessionLabel, '晚场');
    expect(added.threeInchCount, line.supplement);
    expect(media.where((m) => m.recordId == added.id), hasLength(1));
    final counters = await DatabaseService.getCounters();
    expect(counters.singleWhere((c) => c.id == oldId).threeInchCount, 8);
    expect(counters.singleWhere((c) => c.id == newId).threeInchCount, 7);
  });
}
