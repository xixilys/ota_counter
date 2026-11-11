import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/face_sample_model.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/activity_record_media_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/pages/face_recognition_settings_page.dart';
import 'package:ota_counter/pages/member_face_enrollment_page.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/face/face_models.dart';
import 'package:ota_counter/services/face/face_recognition_rules.dart';
import 'package:ota_counter/services/face/face_sample_service.dart';
import 'package:ota_counter/services/settings_service.dart';

import 'support/isolated_test_databases.dart';

FaceAnalysis _face(int axis, double width, double height) => FaceAnalysis(
      face: FaceDetection(
        x: 4,
        y: 4,
        width: width,
        height: height,
        landmarks: const [],
        score: 0.9,
      ),
      embedding: Float32List.fromList([
        for (var i = 0; i < 4; i++) i == axis ? 1 : 0,
      ]),
    );

const _member = FaceMember(
  personId: 101,
  counterId: 11,
  name: '小树',
  groupName: 'P',
);
const _other = FaceMember(personId: 102, counterId: 12, name: '小雪');

FaceSampleModel _sample(int axis, {FaceMember? owner, bool self = false}) =>
    FaceSampleService.sampleFromAnalysis(
      _face(axis, 20, 20),
      source: self ? FaceSampleSource.self : FaceSampleSource.manual,
      owner: owner ?? _member,
    );

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  }
  await tester.pump();
  expect(ready(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;

  setUpAll(() async {
    temporary = await useIsolatedTestDatabases();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() async {
    await DatabaseService.clearAppData();
    await FaceSampleService.clearAll();
  });

  test('登记人脸排除我后按面积选最大脸，并保留其他脸供点选', () {
    final self = _face(0, 100, 100);
    final small = _face(1, 10, 10);
    final largest = _face(2, 30, 20);
    final wide = _face(3, 40, 5);
    final input = [small, self, wide, largest];
    final faces = FaceSampleService.memberFaces(input, [self.embedding]);
    expect(faces, [largest, wide, small]);
    expect(input, [small, self, wide, largest]);
    expect(FaceSampleService.memberFaces([self], [self.embedding]), isEmpty);
    expect(FaceSampleService.memberFaces([], []), isEmpty);
  });

  test('未登记我时按照片最大脸排序；只一张非我脸时取该脸', () {
    final a = _face(1, 10, 20);
    final b = _face(2, 40, 40);
    expect(FaceSampleService.memberFaces([a, b], []).first, same(b));
    expect(FaceSampleService.memberFaces([a, b], [b.embedding]), [a]);
  });

  test('manual source 序列化和 SQLite 读写兼容旧 source 值', () async {
    final manual = _sample(1);
    expect(manual.toMap()['source'], 'manual');
    final restored = FaceSampleModel.fromMap(manual.toMap());
    expect(restored.source, FaceSampleSource.manual);
    expect(restored.embedding, manual.embedding);
    expect(FaceSampleSource.fromDb('bootstrap'), FaceSampleSource.bootstrap);
    expect(FaceSampleSource.fromDb('self'), FaceSampleSource.self);
    expect(FaceSampleSource.fromDb('confirmed'), FaceSampleSource.confirmed);
    expect(FaceSampleSource.fromDb('old_unknown'), FaceSampleSource.confirmed);
    await FaceSampleService.addSamples([manual]);
    final db = await DatabaseService.database;
    expect(
        (await db.query(DatabaseService.faceSamplesTableName)).single['source'],
        'manual');
    final stored = (await FaceSampleService.getMemberSamples(_member)).single;
    expect(stored.source, FaceSampleSource.manual);
    expect(stored.personId, 101);
    expect(stored.counterId, 11);
    expect(stored.isSelf, isFalse);
  });

  test('已认识名单按真人合并，清除成员不影响我和其他成员', () async {
    const alias = FaceMember(personId: 101, counterId: 21, name: '小树新团籍');
    await FaceSampleService.addSamples([
      _sample(0, self: true),
      _sample(1),
      _sample(2, owner: alias),
      _sample(3, owner: _other),
    ]);
    final roster = await FaceSampleService.getKnownMembers();
    expect(roster, hasLength(2));
    expect(roster.singleWhere((item) => item.member.personId == 101).count, 2);
    expect(await FaceSampleService.getMemberSamples(alias), hasLength(2));
    await FaceSampleService.clearMember(_member);
    expect(await FaceSampleService.getMemberSamples(alias), isEmpty);
    expect(await FaceSampleService.getMemberSamples(_other), hasLength(1));
    expect(await FaceSampleService.getSamples(isSelf: true), hasLength(1));
  });

  test('同名不同 counter 的名单、清除和样本上限互不影响', () async {
    const a = FaceMember(counterId: 31, name: '同名成员');
    const b = FaceMember(counterId: 32, name: '同名成员');
    await FaceSampleService.addSamples([
      for (var i = 0; i < 33; i++) _sample(1, owner: a),
      for (var i = 0; i < 33; i++) _sample(2, owner: b),
    ]);
    final roster = await FaceSampleService.getKnownMembers();
    expect(roster, hasLength(2));
    expect(roster.singleWhere((item) => item.member.counterId == 31).count, 30);
    expect(roster.singleWhere((item) => item.member.counterId == 32).count, 30);
    expect((await FaceSampleService.getStats()).people, 2);
    expect(await FaceSampleService.getMemberSamples(a), hasLength(30));
    expect(await FaceSampleService.getMemberSamples(b), hasLength(30));
    final recognitionSamples = FaceSampleService.samplesByMember(
        [a, b], await FaceSampleService.getSamples());
    expect(recognitionSamples[0], hasLength(30));
    expect(recognitionSamples[1], hasLength(30));
    expect(
        recognitionSamples[0].every((embedding) => embedding[1] == 1), isTrue);
    expect(
        recognitionSamples[1].every((embedding) => embedding[2] == 1), isTrue);
    await FaceSampleService.clearMember(a);
    expect(await FaceSampleService.getMemberSamples(a), isEmpty);
    expect(await FaceSampleService.getMemberSamples(b), hasLength(30));
  });

  test('缺少身份 ID 的旧姓名样本仍可匹配和管理', () async {
    const legacy = FaceMember(name: '小树');
    await FaceSampleService.addSamples([_sample(1, owner: legacy), _sample(2)]);
    expect(await FaceSampleService.getMemberSamples(_member), hasLength(2));
    final roster = await FaceSampleService.getKnownMembers();
    expect(roster.single.member.personId, _member.personId);
    expect(roster.single.count, 2);
    await FaceSampleService.clearMember(_member);
    expect(await FaceSampleService.getSamples(isSelf: false), isEmpty);
  });

  test('手动登记同 personId 跨 counter 仍共用 30 个样本上限', () async {
    const alias = FaceMember(personId: 101, counterId: 21, name: '小树新团籍');
    await FaceSampleService.addSamples([
      for (var i = 0; i < 33; i++)
        _sample(1, owner: i.isEven ? _member : alias),
    ]);
    final samples = await FaceSampleService.getMemberSamples(_member);
    expect(samples, hasLength(30));
    expect(samples.every((sample) => sample.source == FaceSampleSource.manual),
        isTrue);
  });

  test('归档学习不从团切单个 participant 或媒体 owner 自动推断人脸', () async {
    final db = await DatabaseService.database;
    final path = '${temporary.path}/archive-synthetic.txt';
    await File(path).writeAsString('synthetic');
    final originalAnalyzer = FaceSampleService.analyzer;
    FaceSampleService.analyzer = (_) async => [_face(1, 30, 30)];
    addTearDown(() => FaceSampleService.analyzer = originalAnalyzer);
    final mediaIds = <int>[];
    for (var i = 0; i < 3; i++) {
      final record = ActivityRecordModel.multiCut(
        participants: const [
          ActivityParticipant(memberName: '小树', personId: 101, groupName: 'P')
        ],
        field: i < 2 ? CounterCountField.groupCut : CounterCountField.threeInch,
        occurredAt: DateTime(2026, 11, 7),
      );
      final id = await db.insert(DatabaseService.activityRecordTableName,
          record.toMap()..remove('id'));
      mediaIds.add(await db.insert(
          DatabaseService.activityRecordMediaTableName,
          ActivityRecordMediaModel(
            recordId: id,
            path: path,
            createdAt: DateTime(2026, 11, 7),
            ownerPersonId: i == 1 ? 101 : null,
            ownerPersonName: i == 1 ? '小树' : '',
          ).toMap()
            ..remove('id')));
    }
    final result = await FaceSampleService.learnFromArchive();
    expect(result.scanned, 3);
    expect(result.noOwner, 2);
    expect(result.learned, 1);
    final samples = await FaceSampleService.getSamples(isSelf: false);
    expect(samples.single.mediaId, mediaIds.last);
    expect(samples.single.source, FaceSampleSource.bootstrap);
  });

  testWidgets('登记页显示已有样本数，清除需确认且只清除该成员', (tester) async {
    await tester.runAsync(() async {
      await FaceSampleService.addSamples([
        _sample(1),
        _sample(2, owner: _other),
      ]);
      await tester.pumpWidget(const MaterialApp(
        home: MemberFaceEnrollmentPage(member: _member),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    expect(find.text('已有 1 个样本'), findsOneWidget);
    await tester.tap(find.text('清除这位成员的样本'));
    await tester.pumpAndSettle();
    expect(find.text('清除小树的人脸样本？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
        await tester
            .runAsync(() => FaceSampleService.getMemberSamples(_member)),
        hasLength(1));
    await tester.tap(find.text('清除这位成员的样本'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('清除'));
      await tester.pump(const Duration(milliseconds: 400));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await _pumpUntil(tester, () => find.text('已有 0 个样本').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.text('已有 0 个样本'), findsOneWidget);
    expect(
        await tester.runAsync(() => FaceSampleService.getMemberSamples(_other)),
        hasLength(1));
  });

  testWidgets('设置页列出已认识成员及各自样本数', (tester) async {
    await tester.runAsync(() async {
      await FaceSampleService.addSamples([_sample(1), _sample(2)]);
      await tester.pumpWidget(const MaterialApp(
        home: FaceRecognitionSettingsPage(),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    expect(find.text('已认识的成员及样本数'), findsOneWidget);
    expect(find.text('小树'), findsOneWidget);
    expect(find.text('2 个样本'), findsOneWidget);
  });

  testWidgets('设置名单为同名不同成员显示各自团体，personId 可找回换团后团体', (tester) async {
    await tester.runAsync(() async {
      final aId = await DatabaseService.insertCounter(
          CounterModel(name: '同名成员', groupName: 'P团', color: '#22C55E'));
      final bId = await DatabaseService.insertCounter(
          CounterModel(name: '同名成员', groupName: 'K团', color: '#67E8F9'));
      await DatabaseService.insertCounter(CounterModel(
          name: '新团籍名字', groupName: 'R团', personId: 301, color: '#67E8F9'));
      await FaceSampleService.addSamples([
        _sample(1, owner: FaceMember(counterId: aId, name: '同名成员')),
        _sample(2, owner: FaceMember(counterId: bId, name: '同名成员')),
        _sample(3, owner: FaceMember(counterId: bId, name: '同名成员')),
        _sample(1,
            owner: const FaceMember(
                counterId: 777, personId: 301, name: '保存的真人姓名')),
      ]);
      await tester
          .pumpWidget(const MaterialApp(home: FaceRecognitionSettingsPage()));
    });
    await _pumpUntil(tester, () => find.text('P团').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.text('同名成员'), findsNWidgets(2));
    final pRow =
        find.ancestor(of: find.text('P团'), matching: find.byType(ListTile));
    final kRow =
        find.ancestor(of: find.text('K团'), matching: find.byType(ListTile));
    expect(find.descendant(of: pRow, matching: find.text('1 个样本')),
        findsOneWidget);
    expect(find.descendant(of: kRow, matching: find.text('2 个样本')),
        findsOneWidget);
    final rRow =
        find.ancestor(of: find.text('R团'), matching: find.byType(ListTile));
    expect(find.descendant(of: rRow, matching: find.text('保存的真人姓名')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('开启说明被登记入口复用；取消不会开启', (tester) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      return Scaffold(
          body: TextButton(
        onPressed: () async {
          result = await FaceRecognitionSettingsPage.ensureEnabled(context);
        },
        child: const Text('登记人脸'),
      ));
    })));
    await tester.tap(find.text('登记人脸'));
    await tester.pumpAndSettle();
    expect(find.text('开启人脸识别'), findsOneWidget);
    expect(find.textContaining('识别只在这台手机上进行'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(await SettingsService.getFaceRecognitionEnabled(), isFalse);
  });

  testWidgets('相册多选后显示非我脸缩略图，手动点选的脸存为 manual', (tester) async {
    final photo = File('${temporary.path}/manual-synthetic.jpg');
    await tester.runAsync(() =>
        photo.writeAsBytes(img.encodeJpg(img.Image(width: 100, height: 100))));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/image_picker'),
      (call) async => call.method == 'pickMultiImage' ? [photo.path] : null,
    );
    final originalAnalyzer = FaceSampleService.analyzer;
    FaceSampleService.analyzer = (_) async => [
          _face(0, 70, 70), // Me: largest overall, excluded.
          _face(
              1, 40, 40), // Largest non-self, shown first but not preselected.
          _face(2, 20, 20), // User selects this one.
        ];
    addTearDown(() {
      FaceSampleService.analyzer = originalAnalyzer;
      messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/image_picker'), null);
    });
    await tester.runAsync(() async {
      await FaceSampleService.addSamples([_sample(0, self: true)]);
      await tester.pumpWidget(const MaterialApp(
        home: MemberFaceEnrollmentPage(member: _member),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('从相册选择照片（可多选）'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await _pumpUntil(
        tester,
        () =>
            find.byType(LinearProgressIndicator).evaluate().isEmpty ||
            find.text('哪张脸是小树？').evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('哪张脸是小树？'), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.text('最大'), findsOneWidget);
    final confirmButton = find.widgetWithText(FilledButton, '登记这张脸');
    expect(tester.widget<FilledButton>(confirmButton).onPressed, isNull);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 812);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(812, 375);
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pump();
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(375, 812);
    tester.platformDispatcher.textScaleFactorTestValue = 1;
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('人脸 2'));
    await tester.pump();
    expect(tester.widget<FilledButton>(confirmButton).onPressed, isNotNull);
    await tester.runAsync(() async {
      await tester.tap(find.text('登记这张脸'));
      await tester.pump(const Duration(milliseconds: 400));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await _pumpUntil(tester, () => find.text('已有 1 个样本').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    final stored = await tester
        .runAsync(() => FaceSampleService.getMemberSamples(_member));
    expect(stored, hasLength(1));
    expect(stored!.single.source, FaceSampleSource.manual);
    expect(stored.single.embedding, _face(2, 20, 20).embedding);
    expect(find.text('已有 1 个样本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
