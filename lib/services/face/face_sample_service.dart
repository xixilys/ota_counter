import 'dart:io';
import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../models/activity_record_media_model.dart';
import '../../models/activity_record_model.dart';
import '../../models/counter_model.dart';
import '../../models/face_sample_model.dart';
import '../database_service.dart';
import 'face_engine.dart';
import 'face_models.dart';
import 'face_recognition_rules.dart';

/// Turns encoded image bytes into faces + embeddings. Production uses
/// [FaceEngine.analyzeImageBytes] (onnxruntime); host tests, which have no
/// onnxruntime, inject reference features instead.
typedef FaceAnalyzer = Future<List<FaceAnalysis>> Function(Uint8List bytes);

class ArchiveLearnResult {
  /// Archived photos looked at.
  final int scanned;

  /// New member samples written.
  final int learned;

  /// Photos skipped because their owner is unknown (e.g. multi-member cut).
  final int noOwner;

  /// Photos skipped because they did not show exactly one non-"我" face.
  final int notSingleFace;

  /// Photos already learned from earlier.
  final int alreadyLearned;

  /// Missing or unreadable files.
  final int failed;

  const ArchiveLearnResult({
    required this.scanned,
    required this.learned,
    required this.noOwner,
    required this.notSingleFace,
    required this.alreadyLearned,
    required this.failed,
  });
}

/// Face samples (table `face_samples`): "我" plus per-member embeddings.
class FaceSampleService {
  FaceSampleService._();

  static FaceAnalyzer analyzer = FaceEngine.analyzeImageBytes;

  /// Image dimensions for normalizing face boxes in chat enrollment feedback.
  /// Injected in tests because synthetic bytes are not decodable images.
  static Future<({int width, int height})> Function(Uint8List bytes) imageSize =
      (bytes) async {
    final image = await FaceEngine.decodeImageBytes(bytes);
    return (width: image.width, height: image.height);
  };

  static Future<List<FaceSampleModel>> getSamples({bool? isSelf}) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      DatabaseService.faceSamplesTableName,
      where: isSelf == null ? 'model_id = ?' : 'model_id = ? AND is_self = ?',
      whereArgs: [
        FaceSampleModel.currentModelId,
        if (isSelf != null) isSelf ? 1 : 0,
      ],
      orderBy: 'created_at ASC, id ASC',
    );
    return rows
        .map(FaceSampleModel.fromMap)
        .where((s) => s.embedding.isNotEmpty)
        .toList();
  }

  static Future<({int self, int members, int people})> getStats() async {
    final samples = await getSamples();
    return (
      self: samples.where((s) => s.isSelf).length,
      members: samples.length - samples.where((s) => s.isSelf).length,
      people: _membersWithCounts(samples).length,
    );
  }

  /// Current-model samples belonging to this member (shared across aliases
  /// that have the same person id, just like recognition).
  static Future<List<FaceSampleModel>> getMemberSamples(
          FaceMember member) async =>
      (await getSamples(isSelf: false))
          .where((sample) => _sameMemberIdentity(member, _sampleOwner(sample)))
          .toList();

  static Future<void> clearMember(FaceMember member) async {
    final samples = await getMemberSamples(member);
    if (samples.isEmpty) return;
    final db = await DatabaseService.database;
    await db.delete(
      DatabaseService.faceSamplesTableName,
      where: 'id IN (${List.filled(samples.length, '?').join(', ')})',
      whereArgs: [for (final sample in samples) sample.id],
    );
  }

  static Future<List<({FaceMember member, int count})>>
      getKnownMembers() async =>
          _membersWithCounts(await getSamples(isSelf: false));

  static List<({FaceMember member, int count})> _membersWithCounts(
    List<FaceSampleModel> samples,
  ) {
    final result = <({FaceMember member, int count})>[];
    for (final sample in samples.where((sample) => !sample.isSelf)) {
      final member = _sampleOwner(sample);
      final index =
          result.indexWhere((item) => _sameMemberIdentity(item.member, member));
      if (index < 0) {
        result.add((member: member, count: 1));
      } else {
        final previous = result[index];
        result[index] = (
          member: previous.member.mergedWith(member),
          count: previous.count + 1
        );
      }
    }
    result
        .sort((a, b) => a.member.identityName.compareTo(b.member.identityName));
    return result;
  }

  /// Manual enrolment puts the largest non-"我" face first. Multiple faces
  /// remain in the list so the UI can require an explicit choice instead of
  /// silently labelling somebody else.
  static List<FaceAnalysis> memberFaces(
    List<FaceAnalysis> faces,
    Iterable<List<double>> selfSamples,
  ) =>
      faces.where((face) => !isSelfFace(face.embedding, selfSamples)).toList()
        ..sort((a, b) => (b.face.width * b.face.height)
            .compareTo(a.face.width * a.face.height));

  /// Faces ordered left to right by box center x; ties keep detector order.
  static List<int> faceOrderFromLeft(List<FaceAnalysis> faces) {
    final order = [for (var i = 0; i < faces.length; i++) i];
    order.sort((a, b) {
      final ax = faces[a].face.x + faces[a].face.width / 2;
      final bx = faces[b].face.x + faces[b].face.width / 2;
      final compare = ax.compareTo(bx);
      return compare != 0 ? compare : a.compareTo(b);
    });
    return order;
  }

  /// Automatic chat enrollment, returning the original zero-based face index.
  /// `auto` follows the photo-enrollment rules (drop "我", then similarity,
  /// then a clearly largest face). `largest` picks the largest non-"我" face.
  /// `left_N` picks the Nth face counted left to right, including "我".
  /// Null means no pick (zero/ambiguous faces or an out-of-range left_N).
  static int? selectEnrollmentFace(
    List<FaceAnalysis> faces, {
    String face = 'auto',
    Iterable<List<double>> selfSamples = const [],
    Iterable<List<double>> memberSamples = const [],
  }) {
    final candidates = [
      for (var i = 0; i < faces.length; i++)
        if (!isSelfFace(faces[i].embedding, selfSamples)) i,
    ];
    if (face == 'largest') {
      if (candidates.isEmpty) return null;
      candidates.sort((a, b) {
        final compare = (faces[b].face.width * faces[b].face.height)
            .compareTo(faces[a].face.width * faces[a].face.height);
        return compare != 0 ? compare : a.compareTo(b);
      });
      return candidates.first;
    }
    final leftIndex = RegExp(r'^left_(\d+)$').firstMatch(face);
    if (leftIndex != null) {
      final index = int.tryParse(leftIndex.group(1)!);
      final order = faceOrderFromLeft(faces);
      if (index == null || index < 1 || index > order.length) return null;
      return order[index - 1];
    }
    if (face != 'auto') {
      throw ArgumentError.value(face, 'face', 'Unknown face selector');
    }
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.single;
    final scores = {
      for (final i in candidates)
        i: maxSimilarity(faces[i].embedding, memberSamples),
    };
    final bySimilarity = [...candidates]
      ..sort((a, b) => scores[b]!.compareTo(scores[a]!));
    final best = bySimilarity.first;
    if (scores[best]! >= FaceMatchThresholds.reviewMin &&
        scores[best]! - scores[bySimilarity[1]]! >=
            FaceMatchThresholds.reviewMargin) {
      return best;
    }
    candidates.sort((a, b) => (faces[b].face.width * faces[b].face.height)
        .compareTo(faces[a].face.width * faces[a].face.height));
    final largest = faces[candidates[0]].face;
    final next = faces[candidates[1]].face;
    return largest.width * largest.height >= 1.5 * next.width * next.height
        ? candidates[0]
        : null;
  }

  static Future<void> clearAll() async {
    final db = await DatabaseService.database;
    await db.delete(DatabaseService.faceSamplesTableName);
  }

  static Future<void> clearSelf() async {
    final db = await DatabaseService.database;
    await db.delete(DatabaseService.faceSamplesTableName, where: 'is_self = 1');
  }

  static FaceMember _sampleOwner(FaceSampleModel sample) => FaceMember(
        counterId: sample.counterId,
        personId: sample.personId,
        name: sample.personName,
      );

  /// An explicit distinct identity must never be merged just because names
  /// match. Name fallback remains available for legacy samples missing ids.
  static bool _sameMemberIdentity(FaceMember a, FaceMember b) {
    if (a.personId != null && b.personId != null) {
      return a.personId == b.personId;
    }
    if (a.counterId != null && b.counterId != null) {
      return a.counterId == b.counterId;
    }
    return a.isSamePerson(name: b.identityName, groupName: b.groupName);
  }

  static bool _sameOwner(FaceSampleModel a, FaceSampleModel b) {
    if (a.isSelf || b.isSelf) return a.isSelf && b.isSelf;
    return _sameMemberIdentity(_sampleOwner(a), _sampleOwner(b));
  }

  /// Inserts [samples]; whenever an owner goes over
  /// [FaceMatchThresholds.maxSamplesPerMember], the most redundant sample of
  /// that owner is dropped ([pickSampleToEvict]) — possibly the new one.
  /// Returns how many of [samples] were kept.
  static Future<int> addSamples(
    List<FaceSampleModel> samples, {
    Transaction? transaction,
  }) async {
    if (samples.isEmpty) return 0;
    Future<int> write(DatabaseExecutor txn) async {
      final existing = (await txn.query(
        DatabaseService.faceSamplesTableName,
        where: 'model_id = ?',
        whereArgs: [FaceSampleModel.currentModelId],
        orderBy: 'created_at ASC, id ASC',
      ))
          .map(FaceSampleModel.fromMap)
          .toList();
      var kept = 0;
      for (final sample in samples) {
        final id = await txn.insert(
          DatabaseService.faceSamplesTableName,
          sample.toMap()..remove('id'),
        );
        final stored = FaceSampleModel.fromMap({...sample.toMap(), 'id': id});
        existing.add(stored);
        final group = existing.where((s) => _sameOwner(s, stored)).toList();
        final evict = pickSampleToEvict([for (final s in group) s.embedding]);
        if (evict >= 0) {
          final victim = group[evict];
          await txn.delete(
            DatabaseService.faceSamplesTableName,
            where: 'id = ?',
            whereArgs: [victim.id],
          );
          existing.removeWhere((s) => s.id == victim.id);
          if (victim.id != id) kept++;
        } else {
          kept++;
        }
      }
      return kept;
    }

    if (transaction != null) return write(transaction);
    final db = await DatabaseService.database;
    return db.transaction<int>(write);
  }

  static FaceSampleModel sampleFromAnalysis(
    FaceAnalysis analysis, {
    required FaceSampleSource source,
    FaceMember? owner,
    int? mediaId,
  }) {
    final face = analysis.face;
    return FaceSampleModel(
      personId: owner?.personId,
      personName: owner?.identityName ?? '',
      counterId: owner?.counterId,
      isSelf: source == FaceSampleSource.self,
      mediaId: mediaId,
      faceBoxJson: FaceSampleModel.encodeFaceBox(
        x: face.x,
        y: face.y,
        width: face.width,
        height: face.height,
        score: face.score,
      ),
      embedding: analysis.embedding,
      quality: face.score,
      source: source,
      createdAt: DateTime.now(),
    );
  }

  /// Enrols "我" from selfies: the largest face of each photo. Returns the
  /// number of photos that yielded a face.
  static Future<int> enrollSelf(List<Uint8List> photos) async {
    final samples = <FaceSampleModel>[];
    for (final bytes in photos) {
      final faces = await analyzer(bytes);
      if (faces.isEmpty) continue;
      faces.sort((a, b) => (b.face.width * b.face.height)
          .compareTo(a.face.width * a.face.height));
      samples
          .add(sampleFromAnalysis(faces.first, source: FaceSampleSource.self));
    }
    await addSamples(samples);
    return samples.length;
  }

  static FaceMember memberFromCounter(CounterModel counter) => FaceMember(
        counterId: counter.id,
        personId: counter.personId,
        name: counter.name,
        personName: counter.personName,
        groupName: counter.groupName,
      );

  /// Owner of an archived photo, or null when it is not one known person.
  static FaceMember? ownerOfMedia(
    ActivityRecordMediaModel media,
    ActivityRecordModel? record,
    List<CounterModel> counters,
  ) {
    FaceMember? owner;
    if (media.ownerPersonId != null ||
        media.ownerPersonName.trim().isNotEmpty) {
      owner = FaceMember(
        personId: media.ownerPersonId,
        name: media.ownerPersonName,
        groupName: media.ownerGroupName,
      );
    } else if (record == null) {
      return null;
    } else if (record.isCounter) {
      CounterModel? counter;
      for (final c in counters) {
        if (c.id != null && c.id == record.counterId) counter = c;
      }
      counter ??= resolveCounterForActivityRecord(counters, record);
      if (counter != null) return memberFromCounter(counter);
      owner = FaceMember(
        personId: record.personId,
        name: record.subjectName,
        personName: record.personName,
        groupName: record.groupName,
      );
    } else if (record.isMulti && record.effectiveParticipants.length == 1) {
      final p = record.effectiveParticipants.single;
      owner = FaceMember(
        personId: p.personId,
        name: p.memberName,
        personName: p.personName,
        groupName: p.groupName,
      );
    } else {
      return null;
    }
    for (final counter in counters) {
      final member = memberFromCounter(counter);
      if (member.sameAs(owner)) return member.mergedWith(owner);
    }
    return owner;
  }

  /// 「从已归档照片学习」: every archived photo with a known owner that shows
  /// exactly one face other than "我" becomes a sample of that owner
  /// (source = bootstrap). Photos learned before are skipped, so it can be
  /// run again after new photos are archived or a backup is restored.
  static Future<ArchiveLearnResult> learnFromArchive({
    void Function(int done, int total)? onProgress,
  }) async {
    final media = await DatabaseService.getActivityRecordMedia();
    final records = {
      for (final r in await DatabaseService.getActivityRecords())
        if (r.id != null) r.id!: r,
    };
    final counters = await DatabaseService.getCounters();
    final selfSamples = [
      for (final s in await getSamples(isSelf: true)) s.embedding,
    ];
    final learnedMedia = {
      for (final s in await getSamples(isSelf: false))
        if (s.mediaId != null) s.mediaId!,
    };
    var learned = 0, noOwner = 0, notSingle = 0, already = 0, failed = 0;
    final pending = <FaceSampleModel>[];
    for (var i = 0; i < media.length; i++) {
      onProgress?.call(i, media.length);
      final item = media[i];
      if (item.id != null && learnedMedia.contains(item.id)) {
        already++;
        continue;
      }
      final record = records[item.recordId];
      // A group-cut photo may show people missing from its participant list,
      // even when the media has an owner label. That label does not confirm
      // which face belongs to whom; only batch-confirmed or manual faces learn.
      if (record != null &&
          record.isMulti &&
          record.multiCountField == CounterCountField.groupCut) {
        noOwner++;
        continue;
      }
      final owner = ownerOfMedia(item, record, counters);
      if (owner == null) {
        noOwner++;
        continue;
      }
      List<FaceAnalysis> faces;
      try {
        faces = await analyzer(await File(item.path).readAsBytes());
      } catch (_) {
        failed++;
        continue;
      }
      final others =
          faces.where((f) => !isSelfFace(f.embedding, selfSamples)).toList();
      if (others.length != 1) {
        notSingle++;
        continue;
      }
      pending.add(sampleFromAnalysis(
        others.single,
        source: FaceSampleSource.bootstrap,
        owner: owner,
        mediaId: item.id,
      ));
    }
    learned = await addSamples(pending);
    onProgress?.call(media.length, media.length);
    return ArchiveLearnResult(
      scanned: media.length,
      learned: learned,
      noOwner: noOwner,
      notSingleFace: notSingle,
      alreadyLearned: already,
      failed: failed,
    );
  }

  /// Samples of every enrolled member who is not one of [candidates], one
  /// list per member. Recognition compares faces against them too, so a face
  /// that looks more like someone outside the day's candidates is not
  /// pre-filled as a candidate.
  static List<List<List<double>>> rivalSamples(
    List<FaceMember> candidates,
    List<FaceSampleModel> samples,
  ) {
    final owners = <FaceMember>[];
    final groups = <List<List<double>>>[];
    for (final s in samples) {
      if (s.isSelf) continue;
      final owner = _sampleOwner(s);
      if (candidates.any((c) => _sameMemberIdentity(c, owner))) continue;
      final index = owners.indexWhere((o) => _sameMemberIdentity(o, owner));
      if (index < 0) {
        owners.add(owner);
        groups.add([s.embedding]);
      } else {
        groups[index].add(s.embedding);
      }
    }
    return groups;
  }

  /// Samples of each member, in [members] order.
  static List<List<List<double>>> samplesByMember(
    List<FaceMember> members,
    List<FaceSampleModel> samples,
  ) {
    return [
      for (final member in members)
        [
          for (final s in samples)
            if (!s.isSelf && _sameMemberIdentity(member, _sampleOwner(s)))
              s.embedding,
        ],
    ];
  }
}
