import 'dart:math' as math;

import 'face_math.dart';

/// Every number the batch-import recognition uses, in one place.
///
/// 待用真实数据校准：these are first guesses from the SFace paper's cosine
/// threshold (0.363) moved up for polaroid photos (glare, small faces) and
/// from a handful of the owner's labelled cheki. Re-tune them with
/// test/batch_face_real_backup_test.dart once more labelled photos exist.
class FaceMatchThresholds {
  FaceMatchThresholds._();

  /// A face at least this similar to any "我" sample is the user and is
  /// dropped before matching members.
  static const double self = 0.50;

  /// Auto-accept: best member >= [autoMin] and ahead of the runner-up by
  /// at least [autoMargin].
  static const double autoMin = 0.60;
  static const double autoMargin = 0.08;

  /// Auto-accept bar while some candidate has no samples yet: that member
  /// cannot be ruled out, so a look-alike must clear a higher score. The
  /// leave-one-out run on the owner's backup auto-assigned a sample-less
  /// member's photo to someone else at 0.62.
  static const double autoMinWithUnsampled = 0.70;

  /// Below this nothing is suggested (未认出); between this and [autoMin],
  /// or with too small a lead, the face needs confirmation (待确认).
  static const double reviewMin = 0.45;

  /// A 待确认 face below [autoMin] is only pre-filled with its best member
  /// when it leads the next free member by this much; otherwise it stays
  /// 未认出 with suggestions. On the 2026-11-08 desk photos every pre-filled
  /// pick with a lead under 0.08 was a stranger matched to an enrolled
  /// member (leads 0.02–0.07), while true matches led by 0.08–0.32.
  static const double reviewMargin = 0.08;

  /// Gain lost when a face is assigned beyond a member's known count for
  /// the day (soft cap). Such faces are always shown as 待确认.
  static const double overCapPenalty = 0.08;

  /// Samples kept per member (and for "我"); see [pickSampleToEvict].
  static const int maxSamplesPerMember = 30;

  /// Faces offered for confirmation.
  static const int reviewChoices = 3;

  /// Suggest a group cut when at least three recognised members cover 75% of
  /// one group's candidates for the day, or at least four non-self faces are
  /// detected. The user still chooses the type on the review screen.
  static const double groupCutCandidateCoverage = 0.75;
  static const int groupCutMinRecognized = 3;
  static const int groupCutMinNonSelfFaces = 4;
}

// ---------------------------------------------------------------------------
// Activity day

/// Photos taken before this hour belong to the previous activity day
/// (after-party shots, late re-scans of the night's cheki).
const int activityDayStartHour = 6;

DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// Activity day of a photo capture time: 00:00–05:59 counts as the day
/// before.
DateTime activityDayOf(DateTime capturedAt) {
  final day = dateOnly(capturedAt);
  if (capturedAt.hour < activityDayStartHour) {
    return DateTime(day.year, day.month, day.day - 1);
  }
  return day;
}

/// Activity day of a ledger record. Records entered with a date only are
/// stored at exactly 00:00 and belong to that date; any other time follows
/// [activityDayOf].
DateTime recordActivityDay(DateTime occurredAt) {
  final isDateOnly = occurredAt.hour == 0 &&
      occurredAt.minute == 0 &&
      occurredAt.second == 0 &&
      occurredAt.millisecond == 0 &&
      occurredAt.microsecond == 0;
  return isDateOnly ? dateOnly(occurredAt) : activityDayOf(occurredAt);
}

/// Default answer to 「这批是哪天的切？」.
///
/// 1. The activity day most photos were taken on (ties: the later day);
///    photos without a capture time are ignored, and with none at all
///    [now]'s activity day is used.
/// 2. If that day has no record / session, cheki were probably re-shot
///    later: take the latest day before it in [daysWithData]. If there is
///    none, keep the photo day.
DateTime inferDefaultActivityDay({
  required Iterable<DateTime?> captureTimes,
  required Iterable<DateTime> daysWithData,
  required DateTime now,
}) {
  final counts = <DateTime, int>{};
  for (final time in captureTimes) {
    if (time == null) continue;
    final day = activityDayOf(time);
    counts[day] = (counts[day] ?? 0) + 1;
  }
  DateTime base;
  if (counts.isEmpty) {
    base = activityDayOf(now);
  } else {
    base = counts.entries.reduce((a, b) {
      if (a.value != b.value) return a.value > b.value ? a : b;
      return a.key.isAfter(b.key) ? a : b;
    }).key;
  }
  final days = daysWithData.map(dateOnly).toSet();
  if (days.contains(base)) return base;
  DateTime? previous;
  for (final day in days) {
    if (day.isBefore(base) && (previous == null || day.isAfter(previous))) {
      previous = day;
    }
  }
  return previous ?? base;
}

// ---------------------------------------------------------------------------
// Members

String _normalizeName(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[\s·•・_\-~/\\\(\)\[\]\{\}]+'), '');

/// A member a polaroid can be assigned to: a home-page counter, or an idol
/// database member that has no counter yet ([counterId] null).
class FaceMember {
  final int? counterId;
  final int? personId;

  /// Card / member display name.
  final String name;
  final String personName;
  final String groupName;

  const FaceMember({
    this.counterId,
    this.personId,
    required this.name,
    this.personName = '',
    this.groupName = '',
  });

  String get identityName =>
      personName.trim().isNotEmpty ? personName.trim() : name.trim();

  String get displayLabel {
    final group = groupName.trim();
    return group.isEmpty ? name.trim() : '${name.trim()} · $group';
  }

  /// Stable key used to merge duplicates and key ledger lines.
  String get key {
    if (personId != null) return 'p:$personId';
    if (counterId != null) return 'c:$counterId';
    return 'n:${_normalizeName(groupName)}|${_normalizeName(identityName)}';
  }

  /// Same real person: counter id, then person id, then normalised name
  /// (groups must not contradict each other).
  bool sameAs(FaceMember other) => isSamePerson(
        counterId: other.counterId,
        personId: other.personId,
        name: other.identityName,
        groupName: other.groupName,
      );

  bool isSamePerson({
    int? counterId,
    int? personId,
    required String name,
    String groupName = '',
  }) {
    if (counterId != null && this.counterId != null) {
      if (counterId == this.counterId) return true;
    }
    if (personId != null && this.personId != null) {
      return personId == this.personId;
    }
    final a = _normalizeName(identityName);
    final b = _normalizeName(name);
    if (a.isEmpty || a != b) return false;
    final ga = _normalizeName(this.groupName);
    final gb = _normalizeName(groupName);
    return ga.isEmpty || gb.isEmpty || ga == gb;
  }

  /// Fills ids / names this one lacks from [other] (same person).
  FaceMember mergedWith(FaceMember other) => FaceMember(
        counterId: counterId ?? other.counterId,
        personId: personId ?? other.personId,
        name: name.trim().isNotEmpty ? name : other.name,
        personName:
            personName.trim().isNotEmpty ? personName : other.personName,
        groupName: groupName.trim().isNotEmpty ? groupName : other.groupName,
      );

  @override
  String toString() => 'FaceMember($displayLabel, $key)';
}

List<FaceMember> _mergeMembers(Iterable<FaceMember> members) {
  final result = <FaceMember>[];
  for (final member in members) {
    final index = result.indexWhere((m) => m.sameAs(member));
    if (index == -1) {
      result.add(member);
    } else {
      result[index] = result[index].mergedWith(member);
    }
  }
  return result;
}

/// Candidates for one batch: members with ledger records that day, then
/// members of the chosen session's groups; when both are empty, everyone.
/// Members outside the list can still be picked by hand in the UI.
List<FaceMember> buildCandidateMembers({
  required Iterable<FaceMember> dayMembers,
  required Iterable<FaceMember> sessionGroupMembers,
  required Iterable<FaceMember> allMembers,
}) {
  final merged = _mergeMembers([...dayMembers, ...sessionGroupMembers]);
  if (merged.isNotEmpty) return merged;
  return _mergeMembers(allMembers);
}

/// A suggestion is informational: it never changes the card's saved type.
/// When possible, also suggest the group with the most recognised members.
({bool suggested, String? groupName}) suggestGroupCut({
  required List<FaceMember> candidates,
  required List<FaceMember> recognized,
  required int nonSelfFaceCount,
}) {
  final byGroup = <String, List<FaceMember>>{};
  for (final candidate in candidates) {
    final key = _normalizeName(candidate.groupName);
    if (key.isEmpty) continue;
    final members = byGroup.putIfAbsent(key, () => []);
    if (!members.any((m) => m.sameAs(candidate))) members.add(candidate);
  }
  String? bestGroup;
  var bestRecognized = 0;
  var coversGroup = false;
  for (final members in byGroup.values) {
    final n = members.where((m) => recognized.any((r) => r.sameAs(m))).length;
    if (n > bestRecognized) {
      bestRecognized = n;
      bestGroup = members.first.groupName.trim();
    }
    if (n >= FaceMatchThresholds.groupCutMinRecognized &&
        n / members.length >= FaceMatchThresholds.groupCutCandidateCoverage) {
      coversGroup = true;
      bestGroup = members.first.groupName.trim();
      break;
    }
  }
  return (
    suggested: coversGroup ||
        nonSelfFaceCount >= FaceMatchThresholds.groupCutMinNonSelfFaces,
    groupName: bestGroup,
  );
}

// ---------------------------------------------------------------------------
// Scoring

/// Highest cosine similarity of [embedding] to any of [samples]; -1 when
/// there are none.
double maxSimilarity(List<double> embedding, Iterable<List<double>> samples) {
  var best = -1.0;
  for (final sample in samples) {
    final value = FaceMath.cosineSimilarity(embedding, sample);
    if (value > best) best = value;
  }
  return best;
}

/// Whether a face is the user ("我").
bool isSelfFace(List<double> embedding, Iterable<List<double>> selfSamples) =>
    maxSimilarity(embedding, selfSamples) >= FaceMatchThresholds.self;

// ---------------------------------------------------------------------------
// Assignment

enum FaceMatchStatus {
  auto,
  review,
  unknown;

  String get label => switch (this) {
        FaceMatchStatus.auto => '自动',
        FaceMatchStatus.review => '待确认',
        FaceMatchStatus.unknown => '未认出',
      };
}

/// Result for one (non-self) face.
class FaceAssignment {
  /// Index into the candidate list, or null (未认出).
  final int? candidate;
  final double score;
  final FaceMatchStatus status;

  /// Assigned beyond the member's known count for the day.
  final bool overCap;

  /// Best candidates by score (at most [FaceMatchThresholds.reviewChoices]),
  /// for the 待确认 picker.
  final List<int> topCandidates;

  const FaceAssignment({
    required this.candidate,
    required this.score,
    required this.status,
    required this.overCap,
    required this.topCandidates,
  });
}

/// Per-card summary of its face assignments.
class CardAssignment {
  final List<FaceAssignment> faces;

  const CardAssignment(this.faces);

  /// Distinct assigned candidates, in face order.
  List<int> get candidates {
    final out = <int>[];
    for (final face in faces) {
      final c = face.candidate;
      if (c != null && !out.contains(c)) out.add(c);
    }
    return out;
  }

  /// unknown: no face assigned; auto: every assigned face auto; otherwise
  /// review. Unassigned extra faces (bystanders, un-enrolled self) do not
  /// block auto.
  FaceMatchStatus get status {
    final assigned = faces.where((f) => f.candidate != null).toList();
    if (assigned.isEmpty) return FaceMatchStatus.unknown;
    return assigned.every((f) => f.status == FaceMatchStatus.auto)
        ? FaceMatchStatus.auto
        : FaceMatchStatus.review;
  }

  /// Best candidates of the card's most uncertain assigned face (or of its
  /// first face when nothing was assigned).
  List<int> get topCandidates {
    for (final face in faces) {
      if (face.status != FaceMatchStatus.auto) return face.topCandidates;
    }
    return faces.isEmpty ? const [] : faces.first.topCandidates;
  }
}

/// Global polaroid ↔ member assignment.
///
/// [cards] holds, per polaroid, per non-self face, the score of every
/// candidate ([maxSimilarity] over that member's samples; -1 = no samples).
/// [caps] is the known number of polaroids per candidate for the day (soft
/// limit); candidates missing from it are unlimited.
///
/// Solved as one rectangular assignment (Hungarian algorithm) maximising the
/// total similarity: rows are faces, columns are member "slots" — up to the
/// cap at full gain, beyond it at a [FaceMatchThresholds.overCapPenalty]
/// discount (faces there become 待确认 instead of being pushed to another
/// member) — plus one "nobody" column per face. Pairs scoring below
/// [FaceMatchThresholds.reviewMin] are not allowed. One member appears at
/// most once per polaroid (a multi-member cut has distinct members): any
/// clash is resolved by forbidding the weaker face that member and solving
/// again.
List<CardAssignment> assignFacesToMembers({
  required List<List<List<double>>> cards,
  required int candidateCount,
  Map<int, int> caps = const {},
}) {
  final faces = <({int card, int face, List<double> scores})>[];
  for (var c = 0; c < cards.length; c++) {
    for (var f = 0; f < cards[c].length; f++) {
      final scores = cards[c][f];
      assert(scores.length == candidateCount);
      faces.add((card: c, face: f, scores: scores));
    }
  }
  final forbidden = <int, Set<int>>{}; // face row -> candidates

  bool allowed(int row, int candidate) =>
      faces[row].scores[candidate] >= FaceMatchThresholds.reviewMin &&
      !(forbidden[row]?.contains(candidate) ?? false);

  List<({int? candidate, bool overCap})> solve() {
    // Column layout.
    final columns = <({int? candidate, bool overCap})>[];
    for (var m = 0; m < candidateCount; m++) {
      var demand = 0;
      for (var r = 0; r < faces.length; r++) {
        if (allowed(r, m)) demand++;
      }
      if (demand == 0) continue;
      final cap = caps[m];
      final normal = cap == null ? demand : math.min(math.max(cap, 0), demand);
      for (var i = 0; i < normal; i++) {
        columns.add((candidate: m, overCap: false));
      }
      for (var i = normal; i < demand; i++) {
        columns.add((candidate: m, overCap: true));
      }
    }
    for (var r = 0; r < faces.length; r++) {
      columns.add((candidate: null, overCap: false));
    }
    const blocked = -1e6;
    final gain = [
      for (var r = 0; r < faces.length; r++)
        [
          for (final column in columns)
            if (column.candidate == null)
              0.0
            else if (!allowed(r, column.candidate!))
              blocked
            else
              faces[r].scores[column.candidate!] -
                  (column.overCap ? FaceMatchThresholds.overCapPenalty : 0),
        ],
    ];
    final picked = hungarianMaximize(gain);
    return [for (final c in picked) columns[c]];
  }

  var result = solve();
  for (var guard = 0; guard < faces.length * candidateCount + 1; guard++) {
    // Find a polaroid with the same member on two faces.
    int? weaker;
    int? clashCandidate;
    final seen = <(int, int), int>{};
    for (var r = 0; r < faces.length && weaker == null; r++) {
      final m = result[r].candidate;
      if (m == null) continue;
      final key = (faces[r].card, m);
      final other = seen[key];
      if (other == null) {
        seen[key] = r;
        continue;
      }
      weaker = faces[r].scores[m] < faces[other].scores[m] ? r : other;
      clashCandidate = m;
    }
    if (weaker == null) break;
    forbidden.putIfAbsent(weaker, () => {}).add(clashCandidate!);
    result = solve();
  }

  final perCard = [
    for (var c = 0; c < cards.length; c++) <FaceAssignment>[],
  ];
  // Members another face on the same polaroid was given: not a real
  // alternative when judging how clearly a face picked its member.
  Set<int> takenElsewhere(int row) => {
        for (var o = 0; o < faces.length; o++)
          if (o != row &&
              faces[o].card == faces[row].card &&
              result[o].candidate != null)
            result[o].candidate!,
      };
  for (var r = 0; r < faces.length; r++) {
    final scores = faces[r].scores;
    final order = [for (var m = 0; m < candidateCount; m++) m]
      ..sort((a, b) => scores[b].compareTo(scores[a]));
    final top = order
        .where((m) => scores[m] >= 0)
        .take(FaceMatchThresholds.reviewChoices)
        .toList(growable: false);
    var m = result[r].candidate;
    if (m != null &&
        !result[r].overCap &&
        scores[m] < FaceMatchThresholds.autoMin) {
      final taken = takenElsewhere(r);
      var nextFree = -1.0;
      for (var other = 0; other < candidateCount; other++) {
        if (other != m && !taken.contains(other) && scores[other] > nextFree) {
          nextFree = scores[other];
        }
      }
      if (scores[m] - nextFree < FaceMatchThresholds.reviewMargin) m = null;
    }
    if (m == null) {
      perCard[faces[r].card].add(FaceAssignment(
        candidate: null,
        score: order.isEmpty ? -1 : scores[order.first],
        status: FaceMatchStatus.unknown,
        overCap: false,
        topCandidates: top,
      ));
      continue;
    }
    final score = scores[m];
    var runnerUp = -1.0;
    for (var other = 0; other < candidateCount; other++) {
      if (other != m && scores[other] > runnerUp) runnerUp = scores[other];
    }
    final overCap = result[r].overCap;
    final someoneUnsampled = scores.any((value) => value < 0);
    final isAuto = !overCap &&
        score >=
            (someoneUnsampled
                ? FaceMatchThresholds.autoMinWithUnsampled
                : FaceMatchThresholds.autoMin) &&
        score - runnerUp >= FaceMatchThresholds.autoMargin;
    perCard[faces[r].card].add(FaceAssignment(
      candidate: m,
      score: score,
      status: isAuto ? FaceMatchStatus.auto : FaceMatchStatus.review,
      overCap: overCap,
      topCandidates: top.contains(m) ? top : [m, ...top.take(top.length - 1)],
    ));
  }
  return [for (final faces in perCard) CardAssignment(faces)];
}

/// Rectangular assignment, rows <= columns: returns for each row the column
/// it gets so that the sum of [gain] is maximal. O(rows² · columns)
/// (Hungarian algorithm with potentials, e-maxx formulation).
List<int> hungarianMaximize(List<List<double>> gain) {
  final n = gain.length;
  if (n == 0) return const [];
  final m = gain.first.length;
  if (m < n) {
    throw ArgumentError('hungarianMaximize needs rows <= columns');
  }
  // 1-based arrays; cost = -gain.
  final u = List<double>.filled(n + 1, 0);
  final v = List<double>.filled(m + 1, 0);
  final p = List<int>.filled(m + 1, 0); // column -> row
  final way = List<int>.filled(m + 1, 0);
  for (var i = 1; i <= n; i++) {
    p[0] = i;
    var j0 = 0;
    final minv = List<double>.filled(m + 1, double.infinity);
    final used = List<bool>.filled(m + 1, false);
    do {
      used[j0] = true;
      final i0 = p[j0];
      var delta = double.infinity;
      var j1 = 0;
      for (var j = 1; j <= m; j++) {
        if (used[j]) continue;
        final cur = -gain[i0 - 1][j - 1] - u[i0] - v[j];
        if (cur < minv[j]) {
          minv[j] = cur;
          way[j] = j0;
        }
        if (minv[j] < delta) {
          delta = minv[j];
          j1 = j;
        }
      }
      for (var j = 0; j <= m; j++) {
        if (used[j]) {
          u[p[j]] += delta;
          v[j] -= delta;
        } else {
          minv[j] -= delta;
        }
      }
      j0 = j1;
    } while (p[j0] != 0);
    do {
      final j1 = way[j0];
      p[j0] = p[j1];
      j0 = j1;
    } while (j0 != 0);
  }
  final result = List<int>.filled(n, -1);
  for (var j = 1; j <= m; j++) {
    if (p[j] != 0) result[p[j] - 1] = j - 1;
  }
  return result;
}

// ---------------------------------------------------------------------------
// Ledger

enum ChekiSize {
  threeInch,
  fiveInch;

  String get label => switch (this) {
        ChekiSize.threeInch => '三寸',
        ChekiSize.fiveInch => '五寸',
      };
}

enum BatchCutType {
  single,
  multi,
  group;

  String get label => switch (this) {
        BatchCutType.single => '单人',
        BatchCutType.multi => '多人切',
        BatchCutType.group => '团切',
      };
}

/// One line of 「将要保存」: the polaroids of one member (or one multi-member
/// set) in one size, and what happens to the ledger.
class LedgerLine {
  /// Sorted member keys; more than one = multi-member cut.
  final List<String> memberKeys;
  final ChekiSize size;

  /// Polaroids of this line in the batch.
  final int photoCount;

  /// What the ledger already has for that day.
  final int existingCount;
  final bool multiCut;
  final String groupName;

  const LedgerLine({
    required this.memberKeys,
    required this.size,
    required this.photoCount,
    required this.existingCount,
    this.multiCut = false,
    this.groupName = '',
  });

  bool get isGroup => groupName.isNotEmpty;
  bool get isMulti => multiCut || memberKeys.length > 1;

  /// Polaroids not yet in the ledger. 0 = only attach the photos.
  int get supplement => math.max(0, photoCount - existingCount);

  String get lineKey => isGroup
      ? groupLedgerLineKey(groupName)
      : '${isMulti && memberKeys.length == 1 ? 'multi:' : ''}${memberKeys.join('+')}#${size.name}';
}

String groupLedgerLineKey(String groupName) =>
    'group:${_normalizeName(groupName)}';

/// The book-keeping rule: when the ledger already has at least as many
/// polaroids of that size for the member that day, photos are only
/// attached; otherwise the difference is proposed as a local record
/// (`+N`), which the user can switch off per line. Nothing else changes
/// counts.
///
/// [cards] are (member keys, size) per polaroid. [existing] maps
/// [LedgerLine.lineKey] (built from sorted keys) to the day's count.
List<LedgerLine> planLedger({
  required Iterable<({List<String> memberKeys, ChekiSize size})> cards,
  required Map<String, int> existing,
}) {
  final counts = <String, ({List<String> keys, ChekiSize size, int n})>{};
  for (final card in cards) {
    if (card.memberKeys.isEmpty) continue;
    final keys = card.memberKeys.toSet().toList()..sort();
    final lineKey = '${keys.join('+')}#${card.size.name}';
    final previous = counts[lineKey];
    counts[lineKey] = (keys: keys, size: card.size, n: (previous?.n ?? 0) + 1);
  }
  return [
    for (final entry in counts.entries)
      LedgerLine(
        memberKeys: entry.value.keys,
        size: entry.value.size,
        photoCount: entry.value.n,
        existingCount: existing[entry.key] ?? 0,
      ),
  ];
}

String ledgerLineKey(Iterable<String> memberKeys, ChekiSize size) {
  final keys = memberKeys.toSet().toList()..sort();
  return '${keys.join('+')}#${size.name}';
}

// ---------------------------------------------------------------------------
// Sample cap

/// When a member has more than [FaceMatchThresholds.maxSamplesPerMember]
/// samples, drop the most redundant one: the sample whose highest
/// similarity to any other sample is largest (it adds the least new
/// appearance). Ties go to the earlier (older) index. Returns -1 when
/// nothing needs to go.
int pickSampleToEvict(
  List<List<double>> embeddings, {
  int limit = FaceMatchThresholds.maxSamplesPerMember,
}) {
  if (embeddings.length <= limit) return -1;
  var worst = -1;
  var worstScore = -double.infinity;
  for (var i = 0; i < embeddings.length; i++) {
    var best = -double.infinity;
    for (var j = 0; j < embeddings.length; j++) {
      if (i == j) continue;
      final s = FaceMath.cosineSimilarity(embeddings[i], embeddings[j]);
      if (s > best) best = s;
    }
    if (best > worstScore) {
      worstScore = best;
      worst = i;
    }
  }
  return worst;
}
