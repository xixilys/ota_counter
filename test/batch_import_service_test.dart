import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/activity_record_media_model.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/face_sample_model.dart';
import 'package:ota_counter/services/batch_import_service.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/export_import_service.dart';
import 'package:ota_counter/services/face/face_models.dart';
import 'package:ota_counter/services/face/face_recognition_rules.dart';
import 'package:ota_counter/services/face/face_sample_service.dart';
import 'package:ota_counter/services/record_scan_service.dart';

import 'support/isolated_test_databases.dart';

Float32List _vec(int axis, {double similarity = 1}) {
  final v = Float32List(8);
  v[axis] = similarity;
  v[7] = math.sqrt(math.max(0, 1 - similarity * similarity));
  return v;
}

FaceAnalysis _face(Float32List embedding, {double size = 40}) => FaceAnalysis(
      face: FaceDetection(
        x: 10,
        y: 10,
        width: size,
        height: size,
        landmarks: const [
          FacePoint(20, 20),
          FacePoint(40, 20),
          FacePoint(30, 30),
          FacePoint(22, 40),
          FacePoint(38, 40),
        ],
        score: 0.9,
      ),
      embedding: embedding,
    );

final Uint8List _jpeg =
    Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 8)));

const _quad = RecordScanQuad(
  topLeftX: 0,
  topLeftY: 0,
  topRightX: 10,
  topRightY: 0,
  bottomLeftX: 0,
  bottomLeftY: 10,
  bottomRightX: 10,
  bottomRightY: 10,
);

BatchCard _card(List<FaceAnalysis> faces,
        {RecordScanCardSize size = RecordScanCardSize.mini}) =>
    BatchCard(
      bytes: _jpeg,
      fileExtension: '.jpg',
      processingMode: ActivityRecordMediaProcessingMode.antiGlareBasic,
      quad: _quad,
      sizeClass: size,
      confidence: 0.9,
      splitFromMerged: false,
      faces: faces,
    );

FaceSampleModel _sample(Float32List e,
        {CounterModel? counter, bool self = false}) =>
    FaceSampleModel(
      counterId: counter?.id,
      personId: counter?.personId,
      personName: counter?.name ?? '',
      isSelf: self,
      embedding: e,
      source: self ? FaceSampleSource.self : FaceSampleSource.bootstrap,
      createdAt: DateTime(2026, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory documents;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final dir = await useIsolatedTestDatabases();
    documents = Directory('${dir.path}/documents')..createSync();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => documents.path,
    );
  });

  tearDown(() async {
    await DatabaseService.clearAppData();
    await FaceSampleService.clearAll();
  });

  final day = DateTime(2026, 3, 14);

  Future<(CounterModel, CounterModel, ActivityRecordModel)> seed() async {
    final aId = await DatabaseService.insertCounter(
        CounterModel(name: '小树', groupName: 'P', color: '#22C55E'));
    final bId = await DatabaseService.insertCounter(
        CounterModel(name: '小雪', groupName: 'K', color: '#67E8F9'));
    final counters = await DatabaseService.getCounters();
    final a = counters.firstWhere((c) => c.id == aId);
    final b = counters.firstWhere((c) => c.id == bId);
    await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.counterAdjustment(
        counter: a,
        occurredAt: day,
        deltas: {CounterCountField.threeInch: 3},
      ),
    );
    final ticketId =
        await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.ticket(
        eventName: '春日公演',
        occurredAt: DateTime(2026, 3, 14, 18),
      ),
    );
    final ticket = (await DatabaseService.getActivityRecords())
        .firstWhere((r) => r.id == ticketId);
    return (a, b, ticket);
  }

  Future<(BatchDayContext, List<FaceMember>, List<BatchReviewCard>)> review(
    CounterModel a,
    CounterModel b,
  ) async {
    final context = await BatchImportService.loadDayContext(day);
    final candidates = buildCandidateMembers(
      dayMembers: context.dayMembers,
      sessionGroupMembers:
          await BatchImportService.membersOfGroups(['K'], context.counters),
      allMembers: BatchImportService.allMembers(context.counters),
    );
    await FaceSampleService.addSamples([
      _sample(_vec(0), counter: a),
      _sample(_vec(1), counter: b),
      _sample(_vec(2), self: true),
    ]);
    final source = BatchSourceResult(
      photo: BatchSourcePhoto(
        path: '/tmp/desk.jpg',
        capturedAt: DateTime(2026, 3, 14, 22, 30),
        fromCamera: true,
      ),
      sourceHash: 'abc123',
      cards: [
        _card([_face(_vec(0, similarity: 0.9))]),
        _card([
          _face(_vec(0, similarity: 0.85)),
          _face(_vec(2, similarity: 0.95)), // 我
        ]),
        _card([_face(_vec(1, similarity: 0.8))]),
        _card(const []),
      ],
    );
    final cards = BatchImportService.recognize(
      sources: [source],
      candidates: candidates,
      samples: await FaceSampleService.getSamples(),
      day: context,
    );
    return (context, candidates, cards);
  }

  test('day context: members, sessions, caps', () async {
    final (a, b, ticket) = await seed();
    final context = await BatchImportService.loadDayContext(day);
    expect(context.records.length, 2);
    expect(context.dayMembers.single.counterId, a.id);
    expect(context.sessions.single.ticket?.id, ticket.id);
    expect(context.dayCap(FaceSampleService.memberFromCounter(a)), 3);
    expect(context.dayCap(FaceSampleService.memberFromCounter(b)), isNull);
    // A record at 02:00 the next morning still belongs to the 14th.
    await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.counterAdjustment(
        counter: b,
        occurredAt: DateTime(2026, 3, 15, 2),
        deltas: {CounterCountField.threeInch: 1},
      ),
    );
    final late = await BatchImportService.loadDayContext(day);
    expect(late.dayMembers.map((m) => m.counterId), containsAll([a.id, b.id]));
    expect(await BatchImportService.daysWithRecords(), {day});
  });

  test('recognition drops 我 and suggests members', () async {
    final (a, b, _) = await seed();
    final (_, _, cards) = await review(a, b);
    expect(cards.length, 4);
    expect(cards[0].members.single.counterId, a.id);
    expect(cards[0].status, FaceMatchStatus.auto);
    expect(cards[1].faceMatches.length, 1, reason: '我 is dropped');
    expect(cards[1].members.single.counterId, a.id);
    expect(cards[2].members.single.counterId, b.id);
    expect(cards[3].status, FaceMatchStatus.unknown);
  });

  test('group suggestion counts non-self faces and does not choose the type',
      () {
    final counters = [
      for (var i = 0; i < 4; i++)
        CounterModel(
            id: i + 1, name: '成员$i', groupName: '一团', color: '#22C55E'),
    ];
    final members = counters.map(FaceSampleService.memberFromCounter).toList();
    final source = BatchSourceResult(
      photo: const BatchSourcePhoto(
          path: '/tmp/group-suggestion.jpg',
          capturedAt: null,
          fromCamera: false),
      sourceHash: 'group-suggestion',
      cards: [
        _card([_face(_vec(0)), _face(_vec(1)), _face(_vec(2)), _face(_vec(4))]),
        _card([
          _face(_vec(0)),
          _face(_vec(1)),
          _face(_vec(2)),
          _face(_vec(3)),
          _face(_vec(4))
        ]),
      ],
    );
    final recognized = BatchImportService.recognize(
      sources: [source],
      candidates: members,
      samples: [
        for (var i = 0; i < 3; i++) _sample(_vec(i), counter: counters[i]),
        _sample(_vec(4), self: true),
      ],
    );
    expect(recognized.first.faceMatches, hasLength(3));
    expect(recognized.first.groupSuggested, isTrue);
    expect(recognized.first.suggestedGroupName, '一团');
    expect(recognized.first.cutType, BatchCutType.multi);
    final unknown = BatchImportService.recognize(
      sources: [source],
      candidates: const [],
      samples: [_sample(_vec(4), self: true)],
    );
    expect(unknown.first.faceMatches, hasLength(3));
    expect(unknown.first.groupSuggested, isFalse);
    expect(unknown.last.faceMatches, hasLength(4));
    expect(unknown.last.groupSuggested, isTrue);
    expect(unknown.last.cutType, BatchCutType.single);
  });

  test('recognition retains separate affiliations for group coverage', () {
    final counters = [
      CounterModel(
          id: 1, personId: 1, name: '甲', groupName: 'P团', color: '#22C55E'),
      CounterModel(
          id: 2, personId: 2, name: '乙', groupName: 'Q团', color: '#22C55E'),
      CounterModel(
          id: 3, personId: 3, name: '丙', groupName: 'Q团', color: '#22C55E'),
      CounterModel(
          id: 4, personId: 4, name: '丁', groupName: 'Q团', color: '#22C55E'),
    ];
    final members = counters.map(FaceSampleService.memberFromCounter).toList();
    final source = BatchSourceResult(
      photo: const BatchSourcePhoto(
          path: '/tmp/affiliations.jpg', capturedAt: null, fromCamera: false),
      sourceHash: 'affiliations',
      cards: [
        _card([_face(_vec(0)), _face(_vec(1)), _face(_vec(2))])
      ],
    );
    final cards = BatchImportService.recognize(
      sources: [source],
      candidates: members,
      groupCandidates: [
        ...members,
        const FaceMember(personId: 1, name: '甲', groupName: 'Q团'),
      ],
      samples: [
        for (var i = 0; i < 3; i++) _sample(_vec(i), counter: counters[i])
      ],
    );
    expect(cards.single.members, hasLength(3));
    expect(cards.single.groupSuggested, isTrue);
    expect(cards.single.suggestedGroupName, 'Q团');
    expect(cards.single.cutType, BatchCutType.multi);
  });

  test('save: attach when the ledger has enough, +N otherwise', () async {
    final (a, b, _) = await seed();
    final (context, candidates, cards) = await review(a, b);
    final memberB = candidates.firstWhere((m) => m.counterId == b.id);

    await expectLater(
      BatchImportService.buildSavePlan(cards: cards, day: context),
      throwsStateError,
      reason: 'an unassigned polaroid blocks saving',
    );
    cards[3]
      ..members = [memberB]
      ..edited = true;

    final entries = BatchImportService.planEntries(cards, context);
    final lineA = entries.firstWhere((e) => e.members.single.counterId == a.id);
    final lineB = entries.firstWhere((e) => e.members.single.counterId == b.id);
    expect(lineA.line.photoCount, 2);
    expect(lineA.line.existingCount, 3);
    expect(lineA.line.supplement, 0);
    expect(lineB.line.photoCount, 2);
    expect(lineB.line.supplement, 2);

    final plan =
        await BatchImportService.buildSavePlan(cards: cards, day: context);
    expect(plan.newRecords.length, 1);
    final summary = await BatchImportService.save(plan);
    expect(summary.photos, 4);
    expect(summary.newRecords, 1);
    expect(summary.learnedFaces, 3, reason: 'card 4 had no face');

    final counters = await DatabaseService.getCounters();
    expect(counters.firstWhere((c) => c.id == a.id).threeInchCount, 3);
    expect(counters.firstWhere((c) => c.id == b.id).threeInchCount, 2);

    final records = await DatabaseService.getActivityRecords();
    final supplement =
        records.firstWhere((r) => r.note == BatchImportService.supplementNote);
    expect(supplement.threeInchCount, 2);
    expect(supplement.counterId, b.id);
    expect(recordActivityDay(supplement.occurredAt), day);

    final media = await DatabaseService.getActivityRecordMedia();
    expect(media.length, 4);
    final aRecord =
        context.recordsFor([FaceSampleService.memberFromCounter(a)]).single;
    expect(media.where((m) => m.recordId == aRecord.id).length, 2);
    expect(media.where((m) => m.recordId == supplement.id).length, 2);
    expect(media.every((m) => m.sourceHash == 'abc123'), isTrue);
    expect(media.every((m) => m.capturedAt == DateTime(2026, 3, 14, 22, 30)),
        isTrue);
    expect(media.every((m) => m.cropQuadJson.contains('"brx"')), isTrue);
    expect(media.where((m) => m.ownerPersonName == '小树').length, 2);
    for (final m in media) {
      expect(File(m.path).existsSync(), isTrue);
    }
    expect(await DatabaseService.countMediaBySourceHash(['abc123']),
        {'abc123': 4});

    final confirmed = (await FaceSampleService.getSamples(isSelf: false))
        .where((s) => s.source == FaceSampleSource.confirmed)
        .toList();
    expect(confirmed.length, 3);
    expect(confirmed.every((s) => s.mediaId != null), isTrue);
  });

  test('switching a +N off attaches to the session ticket instead', () async {
    final (a, b, ticket) = await seed();
    final (context, candidates, cards) = await review(a, b);
    cards.removeAt(3);
    final lineB = BatchImportService.planEntries(cards, context)
        .firstWhere((e) => e.members.single.counterId == b.id);
    final session = context.sessions.single;
    final plan = await BatchImportService.buildSavePlan(
      cards: cards,
      day: context,
      session: session,
      disabledLines: {lineB.line.lineKey},
    );
    expect(plan.newRecords, isEmpty);
    await BatchImportService.save(plan, learnFaces: false);
    final counters = await DatabaseService.getCounters();
    expect(counters.firstWhere((c) => c.id == b.id).threeInchCount, 0,
        reason: 'no count changes without a supplement');
    final media = await DatabaseService.getActivityRecordMedia();
    final onTicket = media.where((m) => m.recordId == ticket.id).toList();
    expect(onTicket.single.ownerPersonName, '小雪');
    expect(await FaceSampleService.getSamples(isSelf: false), hasLength(2));

    // Without a session there is nowhere to put B's photo.
    await expectLater(
      BatchImportService.buildSavePlan(
        cards: cards,
        day: context,
        disabledLines: {lineB.line.lineKey},
      ),
      throwsStateError,
    );
  });

  test('five-inch and multi-member cuts get their own lines', () async {
    final (a, b, _) = await seed();
    final (context, candidates, cards) = await review(a, b);
    final memberA = candidates.firstWhere((m) => m.counterId == a.id);
    final memberB = candidates.firstWhere((m) => m.counterId == b.id);
    cards[0].size = ChekiSize.fiveInch;
    cards[3]
      ..members = [memberA, memberB]
      ..edited = true;
    final plan =
        await BatchImportService.buildSavePlan(cards: cards, day: context);
    // A five-inch +1, B three-inch +1, A+B multi +1; A three-inch attaches.
    expect(plan.newRecords.length, 3);
    await BatchImportService.save(plan, learnFaces: false);
    final counters = await DatabaseService.getCounters();
    final ca = counters.firstWhere((c) => c.id == a.id);
    final cb = counters.firstWhere((c) => c.id == b.id);
    expect(ca.threeInchCount, 3 + 1, reason: 'multi cut counts for each');
    expect(ca.fiveInchCount, 1);
    expect(cb.threeInchCount, 1 + 1);
    final multi = (await DatabaseService.getActivityRecords())
        .firstWhere((r) => r.isMulti);
    expect(multi.effectiveParticipants.length, 2);
  });

  test(
      'group cuts share a group line, supplement the difference and attach photos',
      () async {
    final ids = <int>[];
    for (final name in ['甲', '乙', '丙']) {
      ids.add(await DatabaseService.insertCounter(
          CounterModel(name: name, groupName: '一团', color: '#22C55E')));
    }
    var counters = await DatabaseService.getCounters();
    final members = counters.map(FaceSampleService.memberFromCounter).toList();
    final oldId = await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.multiCut(
        participants: [
          for (final m in members.take(2))
            ActivityParticipant(memberName: m.name, groupName: m.groupName),
        ],
        field: CounterCountField.groupCut,
        occurredAt: day,
        quantity: 2,
      ),
    );
    final context = await BatchImportService.loadDayContext(day);
    final source = BatchSourceResult(
      photo: const BatchSourcePhoto(
          path: '/tmp/group.jpg', capturedAt: null, fromCamera: false),
      sourceHash: 'group',
      cards: [_card([]), _card([]), _card([]), _card([])],
    );
    final cards = BatchImportService.recognize(
        sources: [source], candidates: members, samples: [], day: context);
    for (var i = 0; i < cards.length; i++) {
      cards[i]
        ..cutType = BatchCutType.group
        ..groupName = '一团'
        ..members = [members[i % members.length]];
    }
    cards.last.size = ChekiSize.fiveInch;
    final entry = BatchImportService.planEntries(cards, context).single;
    expect(entry.line.photoCount, 4);
    expect(entry.line.existingCount, 2);
    expect(entry.line.supplement, 2);
    expect(entry.members, hasLength(3));

    final plan =
        await BatchImportService.buildSavePlan(cards: cards, day: context);
    expect(plan.newRecords, hasLength(2));
    expect(
        plan.newRecords
            .every((r) => r.multiCountField == CounterCountField.groupCut),
        isTrue);
    expect(plan.newRecords.every((r) => r.effectiveMultiQuantity == 1), isTrue);
    expect(plan.newRecords.every((r) => r.groupName == '一团'), isTrue);
    expect(
        plan.newRecords
            .map((r) => r.effectiveParticipants.single.memberName)
            .toSet(),
        {members[0].name, members[2].name});
    await BatchImportService.save(plan, learnFaces: false);
    final media = await DatabaseService.getActivityRecordMedia();
    final newRecords = (await DatabaseService.getActivityRecords())
        .where((r) => r.note == BatchImportService.supplementNote)
        .toList();
    expect(media.where((m) => m.recordId == oldId), hasLength(2));
    expect(media.where((m) => newRecords.any((r) => r.id == m.recordId)),
        hasLength(2));
    counters = await DatabaseService.getCounters();
    expect(counters.firstWhere((c) => c.id == ids[0]).groupCutCount, 3);
    expect(counters.firstWhere((c) => c.id == ids[1]).groupCutCount, 2);
    expect(counters.firstWhere((c) => c.id == ids[2]).groupCutCount, 1);

    final withoutSupplement = await BatchImportService.buildSavePlan(
      cards: cards,
      day: context,
      disabledLines: {entry.line.lineKey},
    );
    expect(withoutSupplement.newRecords, isEmpty);
    expect(withoutSupplement.media.every((m) => m.recordId == oldId), isTrue);
    final enough = await BatchImportService.buildSavePlan(
        cards: cards.take(2).toList(), day: context);
    expect(enough.newRecords, isEmpty);
    expect(enough.media.every((m) => m.recordId == oldId), isTrue);
  });

  test('group cut can have no recognised members but needs a group record',
      () async {
    final context = BatchDayContext(
      day: day,
      records: const [],
      sessions: const [],
      dayMembers: const [],
      counters: const [],
    );
    final source = BatchSourceResult(
      photo: const BatchSourcePhoto(
          path: '/tmp/group.jpg', capturedAt: null, fromCamera: false),
      sourceHash: 'empty-group',
      cards: [_card([])],
    );
    final card = BatchImportService.recognize(
        sources: [source], candidates: [], samples: []).single
      ..cutType = BatchCutType.group
      ..groupName = '一团';
    final plan =
        await BatchImportService.buildSavePlan(cards: [card], day: context);
    expect(plan.newRecords.single.groupName, '一团');
    expect(plan.newRecords.single.effectiveParticipants, isEmpty);
    expect(plan.newRecords.single.multiCountField, CounterCountField.groupCut);
    await BatchImportService.save(plan, learnFaces: false);
    final saved = (await DatabaseService.getActivityRecords()).single;
    expect(saved.groupName, '一团');
    expect(saved.multiDisplayName, '一团 团切');
    expect(saved.effectiveParticipants, isEmpty);
    expect((await DatabaseService.getActivityRecordMedia()).single.recordId,
        saved.id);
    await expectLater(
      BatchImportService.buildSavePlan(
        cards: [card],
        day: context,
        disabledLines: {groupLedgerLineKey('一团')},
      ),
      throwsStateError,
    );
  });

  test('group supplements charge only the members of each photo', () async {
    final counters = <CounterModel>[];
    for (final name in ['甲', '乙', '丙']) {
      final id = await DatabaseService.insertCounter(
          CounterModel(name: name, groupName: '一团', color: '#22C55E'));
      counters.add(
          (await DatabaseService.getCounters()).singleWhere((c) => c.id == id));
    }
    final members = counters.map(FaceSampleService.memberFromCounter).toList();
    final context = await BatchImportService.loadDayContext(day);
    final source = BatchSourceResult(
      photo: const BatchSourcePhoto(
          path: '/tmp/group.jpg', capturedAt: null, fromCamera: false),
      sourceHash: 'group-sets',
      cards: [_card([]), _card([]), _card([])],
    );
    final cards = BatchImportService.recognize(
        sources: [source], candidates: members, samples: []);
    for (final card in cards) {
      card
        ..cutType = BatchCutType.group
        ..groupName = '一团';
    }
    cards[0].members = [members[0], members[1]];
    cards[1].members = [members[0], members[2]];
    cards[2].members = [members[1], members[0]];
    final plan =
        await BatchImportService.buildSavePlan(cards: cards, day: context);
    expect(plan.newRecords, hasLength(2));
    expect(
        plan.newRecords.map((r) => r.effectiveMultiQuantity).toList()..sort(),
        [1, 2]);
    await BatchImportService.save(plan, learnFaces: false);
    final saved = await DatabaseService.getCounters();
    expect(saved.firstWhere((c) => c.id == counters[0].id).groupCutCount, 3);
    expect(saved.firstWhere((c) => c.id == counters[1].id).groupCutCount, 2);
    expect(saved.firstWhere((c) => c.id == counters[2].id).groupCutCount, 1);
  });

  test(
      'group supplement applies to the selected affiliation of a shared person',
      () async {
    final pId = await DatabaseService.insertCounter(CounterModel(
        name: '甲', groupName: 'P团', personId: 101, color: '#22C55E'));
    final qId = await DatabaseService.insertCounter(CounterModel(
        name: '甲', groupName: 'Q团', personId: 101, color: '#67E8F9'));
    final counters = await DatabaseService.getCounters();
    final q = FaceSampleService.memberFromCounter(
        counters.singleWhere((counter) => counter.id == qId));
    final source = BatchSourceResult(
      photo: const BatchSourcePhoto(
          path: '/tmp/group.jpg', capturedAt: null, fromCamera: false),
      sourceHash: 'affiliation-ledger',
      cards: [_card([])],
    );
    final card = BatchImportService.recognize(
        sources: [source], candidates: [q], samples: []).single
      ..cutType = BatchCutType.group
      ..groupName = 'Q团'
      ..members = [q];
    final plan = await BatchImportService.buildSavePlan(
        cards: [card], day: await BatchImportService.loadDayContext(day));
    await BatchImportService.save(plan, learnFaces: false);
    final saved = await DatabaseService.getCounters();
    expect(saved.singleWhere((counter) => counter.id == pId).groupCutCount, 0);
    expect(saved.singleWhere((counter) => counter.id == qId).groupCutCount, 1);
  });

  test(
      'manual change with one face learns even for a multi cut; group only learns unchanged matches',
      () async {
    final (a, b, _) = await seed();
    final context = await BatchImportService.loadDayContext(day);
    final members = [
      FaceSampleService.memberFromCounter(a),
      FaceSampleService.memberFromCounter(b),
    ];
    final source = BatchSourceResult(
      photo: const BatchSourcePhoto(
          path: '/tmp/faces.jpg', capturedAt: null, fromCamera: false),
      sourceHash: 'faces',
      cards: [
        _card([_face(_vec(0))]),
        _card([_face(_vec(0)), _face(_vec(1))]),
      ],
    );
    final cards = BatchImportService.recognize(
      sources: [source],
      candidates: members,
      samples: [_sample(_vec(0), counter: a), _sample(_vec(1), counter: b)],
    );
    cards[0]
      ..cutType = BatchCutType.multi
      ..members = [members[1]]
      ..edited = true;
    expect(cards[0].confirmedFaces.single.member.counterId, b.id);
    final multiPlan =
        await BatchImportService.buildSavePlan(cards: [cards[0]], day: context);
    expect(multiPlan.newRecords.single.isMulti, isTrue);
    await BatchImportService.save(multiPlan);
    final learned = await FaceSampleService.getSamples(isSelf: false);
    expect(learned.single.counterId, b.id);
    expect(learned.single.source, FaceSampleSource.confirmed);

    cards[1]
      ..cutType = BatchCutType.multi
      ..members = [members[0]]
      ..edited = true;
    expect(cards[1].confirmedFaces, isEmpty);
    cards[1]
      ..cutType = BatchCutType.group
      ..groupName = members[0].groupName;
    expect(cards[1].confirmedFaces.single.member.counterId, a.id);
  });

  test('sample cap keeps 30 per member', () async {
    final (a, _, _) = await seed();
    await FaceSampleService.addSamples([
      for (var i = 0; i < 35; i++)
        _sample(_vec(i % 7, similarity: 0.5 + i / 100), counter: a),
    ]);
    expect(await FaceSampleService.getSamples(isSelf: false), hasLength(30));
  });

  test('learn from archive: one non-self face per owned photo', () async {
    final (a, b, ticket) = await seed();
    final aRecord = (await DatabaseService.getActivityRecords())
        .firstWhere((r) => r.counterId == a.id);
    Future<int> addMedia(int recordId, String tag, {String owner = ''}) async {
      final media = await DatabaseService.saveActivityRecordMediaBytes(
        recordId: recordId,
        bytes: utf8.encode(tag),
        owner: owner.isEmpty
            ? null
            : const ActivityRecordMediaOwnerScope(
                personName: '小雪', groupName: 'K'),
      );
      return media.id!;
    }

    final single = await addMedia(aRecord.id!, 'single');
    final withSelf = await addMedia(aRecord.id!, 'withself');
    await addMedia(aRecord.id!, 'two');
    await addMedia(ticket.id!, 'ticket-no-owner');
    final ownedOnTicket = await addMedia(ticket.id!, 'owned', owner: 'b');
    await FaceSampleService.addSamples([_sample(_vec(2), self: true)]);

    FaceSampleService.analyzer = (bytes) async => switch (utf8.decode(bytes)) {
          'single' => [_face(_vec(0))],
          'withself' => [_face(_vec(0)), _face(_vec(2))],
          'two' => [_face(_vec(0)), _face(_vec(1))],
          'owned' => [_face(_vec(1))],
          _ => [_face(_vec(3))],
        };
    addTearDown(() => FaceSampleService.analyzer = (_) async => const []);

    final result = await FaceSampleService.learnFromArchive();
    expect(result.scanned, 5);
    expect(result.learned, 3);
    expect(result.notSingleFace, 1);
    expect(result.noOwner, 1);
    final samples = await FaceSampleService.getSamples(isSelf: false);
    expect(samples.map((s) => s.mediaId).toSet(),
        {single, withSelf, ownedOnTicket});
    expect(
        samples.every((s) => s.source == FaceSampleSource.bootstrap), isTrue);
    expect(
        samples.firstWhere((s) => s.mediaId == ownedOnTicket).personName, '小雪');
    expect(samples.firstWhere((s) => s.mediaId == single).counterId, a.id);

    final again = await FaceSampleService.learnFromArchive();
    expect(again.learned, 0);
    expect(again.alreadyLearned, 3);
    expect(b.id, isNotNull);
  });

  test('full backup never contains face samples', () async {
    final (a, _, _) = await seed();
    await FaceSampleService.addSamples([
      _sample(_vec(0), counter: a),
      _sample(_vec(2), self: true),
    ]);
    final bundle = await ExportImportService.buildFullBackupBundle();
    expect(bundle.mainDatabase.keys,
        isNot(contains(DatabaseService.faceSamplesTableName)));
    expect(jsonEncode(bundle.toManifest()), isNot(contains('embedding')));
    expect(bundle.mainDatabase[DatabaseService.tableName], isNotEmpty);
  });

  test('clearing app data keeps 我 but drops member samples', () async {
    final (a, _, _) = await seed();
    await FaceSampleService.addSamples([
      _sample(_vec(0), counter: a),
      _sample(_vec(2), self: true),
    ]);
    await DatabaseService.clearAppData();
    final left = await FaceSampleService.getSamples();
    expect(left.single.isSelf, isTrue);
  });

  test('a photo without a polaroid border becomes one whole-frame card',
      () async {
    final picture = img.Image(width: 300, height: 400);
    img.fill(picture, color: img.ColorRgb8(180, 150, 120));
    img.fillCircle(picture,
        x: 150, y: 180, radius: 70, color: img.ColorRgb8(230, 200, 170));
    final file = File('${documents.path}/already_cropped.jpg')
      ..writeAsBytesSync(img.encodeJpg(picture));
    final result = await BatchImportService.processPhoto(BatchSourcePhoto(
      path: file.path,
      capturedAt: null,
      fromCamera: false,
    ));
    expect(result.error, isNull);
    expect(result.cards, hasLength(1));
    expect(result.cards.single.sizeClass, RecordScanCardSize.uncertain);
    expect(result.cards.single.quad.bottomRightX, 300);
    expect(result.cards.single.quad.bottomRightY, 400);
    expect(
        result.warnings, isNot(contains(RecordScanMultiWarning.noneDetected)));
    file.deleteSync();
  });
}
