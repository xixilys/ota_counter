import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ota_counter/models/activity_record_media_model.dart';
import 'package:ota_counter/models/idol_database_models.dart';
import 'package:ota_counter/pages/batch_review_page.dart';
import 'package:ota_counter/services/batch_import_service.dart';
import 'package:ota_counter/services/face/face_models.dart';
import 'package:ota_counter/services/face/face_recognition_rules.dart';
import 'package:ota_counter/services/record_scan_service.dart';
import 'package:ota_counter/services/idol_database_service.dart';

import 'support/isolated_test_databases.dart';

void main() {
  setUpAll(() async => useIsolatedTestDatabases());

  testWidgets(
      'corrected member stays corrected when accepting or reselecting a group',
      (tester) async {
    await tester.runAsync(() async {
      final id =
          await IdolDatabaseService.upsertGroup(const IdolGroup(name: '一团'));
      await IdolDatabaseService.upsertGroup(const IdolGroup(name: '无候选的团'));
      await IdolDatabaseService.upsertMember(
          IdolMember(groupId: id, groupName: '一团', name: '丙'));
    });
    const a = FaceMember(counterId: 1, name: '甲', groupName: '一团');
    const b = FaceMember(counterId: 2, name: '乙', groupName: '一团');
    final face = FaceAnalysis(
      face: FaceDetection(
        x: 0,
        y: 0,
        width: 10,
        height: 10,
        score: 0.9,
        landmarks: const [
          FacePoint(1, 1),
          FacePoint(3, 1),
          FacePoint(2, 2),
          FacePoint(1, 3),
          FacePoint(3, 3)
        ],
      ),
      embedding: Float32List.fromList([1, 0]),
    );
    final card = BatchCard(
      bytes:
          Uint8List.fromList(img.encodeJpg(img.Image(width: 10, height: 10))),
      fileExtension: '.jpg',
      processingMode: ActivityRecordMediaProcessingMode.antiGlareBasic,
      quad: const RecordScanQuad(
        topLeftX: 0,
        topLeftY: 0,
        topRightX: 10,
        topRightY: 0,
        bottomLeftX: 0,
        bottomLeftY: 10,
        bottomRightX: 10,
        bottomRightY: 10,
      ),
      sizeClass: RecordScanCardSize.mini,
      confidence: 1,
      splitFromMerged: false,
      faces: [face],
    );
    final source = BatchSourceResult(
      photo: const BatchSourcePhoto(
          path: '/tmp/unused', capturedAt: null, fromCamera: false),
      sourceHash: 'test',
      cards: [card],
    );
    final review = BatchReviewCard(
      source: source,
      card: card,
      members: [a],
      status: FaceMatchStatus.review,
      suggestions: [a, b],
      size: ChekiSize.threeInch,
      sizeUncertain: false,
      faceMatches: [(face: face, member: a)],
      groupSuggested: true,
      suggestedGroupName: '一团',
    );
    final day = BatchDayContext(
        day: DateTime(2026, 3, 14),
        records: const [],
        sessions: const [],
        dayMembers: const [],
        counters: const []);
    await tester.pumpWidget(MaterialApp(
        home: BatchReviewPage(
      cards: [review],
      day: day,
      session: null,
      candidates: const [a, b],
      allMembers: const [a, b],
    )));
    expect(review.cutType, BatchCutType.single);
    expect(find.text('建议团切'), findsOneWidget);

    await tester.tap(find.text('甲'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, '甲').first);
    await tester.tap(find.widgetWithText(CheckboxListTile, '乙').first);
    await tester.tap(find.byKey(const ValueKey('member_picker_done')));
    await tester.pumpAndSettle();
    expect(review.members.single.name, '乙');

    await tester.tap(find.text('建议团切'));
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && find.text('无候选的团').evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('无候选的团'), findsOneWidget);
    await tester.tap(find.text('一团'));
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && review.cutType != BatchCutType.group; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(review.cutType, BatchCutType.group);
    expect(review.members.map((m) => m.name), ['乙']);
    expect(review.confirmedFaces, isEmpty);

    // The selected group can include an idol-database member without a
    // homepage counter or a place in the day's initial candidate list.
    await tester.tap(find.textContaining('一团 · 乙'));
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && find.text('丙').evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(find.widgetWithText(CheckboxListTile, '丙'), findsWidgets);
    await tester.tap(find.widgetWithText(CheckboxListTile, '丙').first);
    await tester.tap(find.byKey(const ValueKey('member_picker_done')));
    await tester.pumpAndSettle();
    expect(review.members.map((m) => m.name), ['乙', '丙']);

    await tester.tap(find.text('团切 ▾'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('团切').last);
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && find.text('无候选的团').evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('一团'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(review.members.map((m) => m.name), ['乙', '丙']);
    expect(review.confirmedFaces, isEmpty);
  });

  testWidgets('group choice restores the recognised person in that affiliation',
      (tester) async {
    const p = FaceMember(personId: 101, name: '甲', groupName: 'P团');
    const q = FaceMember(personId: 101, name: '甲', groupName: 'Q团');
    final face = FaceAnalysis(
      face: FaceDetection(
          x: 0, y: 0, width: 10, height: 10, score: 0.9, landmarks: const []),
      embedding: Float32List.fromList([1, 0]),
    );
    final card = BatchCard(
      bytes:
          Uint8List.fromList(img.encodeJpg(img.Image(width: 10, height: 10))),
      fileExtension: '.jpg',
      processingMode: ActivityRecordMediaProcessingMode.antiGlareBasic,
      quad: const RecordScanQuad(
        topLeftX: 0,
        topLeftY: 0,
        topRightX: 10,
        topRightY: 0,
        bottomLeftX: 0,
        bottomLeftY: 10,
        bottomRightX: 10,
        bottomRightY: 10,
      ),
      sizeClass: RecordScanCardSize.mini,
      confidence: 1,
      splitFromMerged: false,
      faces: [face],
    );
    final source = BatchSourceResult(
      photo: const BatchSourcePhoto(
          path: '/tmp/unused', capturedAt: null, fromCamera: false),
      sourceHash: 'affiliation',
      cards: [card],
    );
    final review = BatchReviewCard(
      source: source,
      card: card,
      members: [p],
      status: FaceMatchStatus.auto,
      suggestions: const [],
      size: ChekiSize.threeInch,
      sizeUncertain: false,
      faceMatches: [(face: face, member: p)],
    );
    await tester.pumpWidget(MaterialApp(
        home: BatchReviewPage(
      cards: [review],
      day: BatchDayContext(
          day: DateTime(2026, 3, 14),
          records: const [],
          sessions: const [],
          dayMembers: const [],
          counters: const []),
      session: null,
      candidates: const [p],
      allMembers: const [p],
      groupCandidates: const [p, q],
    )));
    await tester.tap(find.text('单人 ▾'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('团切').last);
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && find.text('Q团').evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Q团'));
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && review.cutType != BatchCutType.group; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(review.members.single.groupName, 'Q团');
    expect(review.members.single.personId, 101);
    expect(review.confirmedFaces.single.member.personId, 101);
  });

  testWidgets('picker keeps an off-list suggestion and offers adding a member',
      (tester) async {
    const onDay = FaceMember(counterId: 1, name: '甲', groupName: '一团');
    const offDay = FaceMember(counterId: 3, name: '丁', groupName: '二团');
    final card = BatchCard(
      bytes:
          Uint8List.fromList(img.encodeJpg(img.Image(width: 10, height: 10))),
      fileExtension: '.jpg',
      processingMode: ActivityRecordMediaProcessingMode.antiGlareBasic,
      quad: const RecordScanQuad(
        topLeftX: 0,
        topLeftY: 0,
        topRightX: 10,
        topRightY: 0,
        bottomLeftX: 0,
        bottomLeftY: 10,
        bottomRightX: 10,
        bottomRightY: 10,
      ),
      sizeClass: RecordScanCardSize.mini,
      confidence: 1,
      splitFromMerged: false,
      faces: const [],
    );
    final review = BatchReviewCard(
      source: BatchSourceResult(
        photo: const BatchSourcePhoto(
            path: '/tmp/unused', capturedAt: null, fromCamera: false),
        sourceHash: 'test',
        cards: [card],
      ),
      card: card,
      members: [offDay],
      status: FaceMatchStatus.review,
      suggestions: [offDay],
      size: ChekiSize.threeInch,
      sizeUncertain: false,
      faceMatches: const [],
      groupSuggested: false,
    );
    await tester.pumpWidget(MaterialApp(
        home: BatchReviewPage(
      cards: [review],
      day: BatchDayContext(
          day: DateTime(2026, 3, 14),
          records: const [],
          sessions: const [],
          dayMembers: const [onDay],
          counters: const []),
      session: null,
      candidates: const [onDay],
      allMembers: const [onDay, offDay],
    )));

    await tester.tap(find.text('丁'));
    await tester.pumpAndSettle();
    expect(find.text('最像的'), findsOneWidget);
    // Listed once, under 最像的, even though 丁 is not on the day's list.
    expect(find.byKey(ValueKey('member_${offDay.key}')), findsOneWidget);
    expect(find.byKey(const ValueKey('member_picker_add_new')), findsOneWidget);
  });

  testWidgets('unassigned cards are skipped on save and cards can be deleted',
      (tester) async {
    const a = FaceMember(counterId: 1, name: '甲', groupName: '一团');
    BatchReviewCard make(List<FaceMember> members) {
      final card = BatchCard(
        bytes:
            Uint8List.fromList(img.encodeJpg(img.Image(width: 10, height: 10))),
        fileExtension: '.jpg',
        processingMode: ActivityRecordMediaProcessingMode.antiGlareBasic,
        quad: const RecordScanQuad(
          topLeftX: 0,
          topLeftY: 0,
          topRightX: 10,
          topRightY: 0,
          bottomLeftX: 0,
          bottomLeftY: 10,
          bottomRightX: 10,
          bottomRightY: 10,
        ),
        sizeClass: RecordScanCardSize.mini,
        confidence: 1,
        splitFromMerged: false,
        faces: const [],
      );
      return BatchReviewCard(
        source: BatchSourceResult(
          photo: const BatchSourcePhoto(
              path: '/tmp/unused', capturedAt: null, fromCamera: false),
          sourceHash: 'test',
          cards: [card],
        ),
        card: card,
        members: members,
        status:
            members.isEmpty ? FaceMatchStatus.unknown : FaceMatchStatus.auto,
        suggestions: const [],
        size: ChekiSize.threeInch,
        sizeUncertain: false,
        faceMatches: const [],
        groupSuggested: false,
      );
    }

    await tester.pumpWidget(MaterialApp(
        home: BatchReviewPage(
      cards: [
        make([a]),
        make(const [])
      ],
      day: BatchDayContext(
          day: DateTime(2026, 3, 14),
          records: const [],
          sessions: const [],
          dayMembers: const [],
          counters: const []),
      session: null,
      candidates: const [a],
      allMembers: const [a],
    )));
    FilledButton save() =>
        tester.widget<FilledButton>(find.byKey(const ValueKey('batch_save')));
    expect(find.text('保存 1 张，跳过 1 张未指定'), findsOneWidget);
    expect(save().onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('batch_card_delete')).last);
    await tester.pumpAndSettle();
    expect(find.text('确认保存 1 张'), findsOneWidget);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(find.text('保存 1 张，跳过 1 张未指定'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('batch_card_delete')).first);
    await tester.pumpAndSettle();
    expect(find.text('先给至少一张指定成员或团体'), findsOneWidget);
    expect(save().onPressed, isNull);
  });
}
