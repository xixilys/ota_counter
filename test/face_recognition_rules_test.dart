import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ota_counter/services/face/face_recognition_rules.dart';

/// Unit vector pointing mostly along [axis], with [similarity] to that axis.
List<double> _vec(int axis, {double similarity = 1, int other = 1}) {
  final v = List<double>.filled(8, 0);
  v[axis] = similarity;
  v[other] = math.sqrt(math.max(0, 1 - similarity * similarity));
  return v;
}

void main() {
  group('activity day', () {
    test('before 06:00 belongs to the previous day', () {
      expect(
          activityDayOf(DateTime(2026, 3, 15, 5, 59)), DateTime(2026, 3, 14));
      expect(activityDayOf(DateTime(2026, 3, 15, 6, 0)), DateTime(2026, 3, 15));
      expect(activityDayOf(DateTime(2026, 3, 1, 0, 30)), DateTime(2026, 2, 28));
      expect(activityDayOf(DateTime(2026, 1, 1, 2)), DateTime(2025, 12, 31));
    });

    test('date-only records keep their date, timed ones follow the rule', () {
      expect(recordActivityDay(DateTime(2026, 3, 15)), DateTime(2026, 3, 15));
      expect(recordActivityDay(DateTime(2026, 3, 15, 1, 0)),
          DateTime(2026, 3, 14));
      expect(recordActivityDay(DateTime(2026, 3, 15, 19, 0)),
          DateTime(2026, 3, 15));
    });
  });

  group('default day', () {
    final now = DateTime(2026, 4, 1, 12);

    test('majority photo day when it has records', () {
      final day = inferDefaultActivityDay(
        captureTimes: [
          DateTime(2026, 3, 14, 20),
          DateTime(2026, 3, 15, 2), // still the 14th
          DateTime(2026, 3, 16, 10),
          null,
        ],
        daysWithData: [DateTime(2026, 3, 14), DateTime(2026, 3, 16)],
        now: now,
      );
      expect(day, DateTime(2026, 3, 14));
    });

    test('re-shot later: falls back to the latest earlier day with data', () {
      final day = inferDefaultActivityDay(
        captureTimes: [DateTime(2026, 3, 20, 14), DateTime(2026, 3, 20, 15)],
        daysWithData: [
          DateTime(2026, 3, 10),
          DateTime(2026, 3, 18),
          DateTime(2026, 3, 25),
        ],
        now: now,
      );
      expect(day, DateTime(2026, 3, 18));
    });

    test('no earlier data keeps the photo day; no times uses now', () {
      expect(
        inferDefaultActivityDay(
          captureTimes: [DateTime(2026, 3, 20, 14)],
          daysWithData: [DateTime(2026, 3, 25)],
          now: now,
        ),
        DateTime(2026, 3, 20),
      );
      expect(
        inferDefaultActivityDay(
          captureTimes: [null, null],
          daysWithData: [DateTime(2026, 4, 1)],
          now: DateTime(2026, 4, 2, 3),
        ),
        DateTime(2026, 4, 1),
      );
    });

    test('ties prefer the later day', () {
      expect(
        inferDefaultActivityDay(
          captureTimes: [DateTime(2026, 3, 1, 12), DateTime(2026, 3, 2, 12)],
          daysWithData: [DateTime(2026, 3, 1), DateTime(2026, 3, 2)],
          now: now,
        ),
        DateTime(2026, 3, 2),
      );
    });
  });

  group('candidate members', () {
    const a = FaceMember(counterId: 1, name: '小树', groupName: 'PokaPokaTime');
    const aByPerson = FaceMember(
        personId: 1776,
        name: '小树',
        personName: '小树',
        groupName: 'PokaPokaTime');
    const b =
        FaceMember(counterId: 2, personId: 715, name: '小雪', groupName: '風時計');
    const c = FaceMember(counterId: 3, name: 'Liumoo', groupName: 'Meguri');

    test('day members + session group members, merged', () {
      final list = buildCandidateMembers(
        dayMembers: [a, b],
        sessionGroupMembers: [aByPerson],
        allMembers: [a, b, c],
      );
      expect(list.length, 2);
      final tree = list.firstWhere((m) => m.name == '小树');
      expect(tree.counterId, 1);
      expect(tree.personId, 1776);
    });

    test('empty falls back to everyone', () {
      final list = buildCandidateMembers(
        dayMembers: const [],
        sessionGroupMembers: const [],
        allMembers: [a, b, c],
      );
      expect(list.map((m) => m.name), ['小树', '小雪', 'Liumoo']);
    });

    test('same name in different groups is not merged', () {
      const other = FaceMember(name: '小树', groupName: 'Other');
      expect(a.sameAs(other), isFalse);
      expect(a.sameAs(const FaceMember(name: '小树')), isTrue);
    });
  });

  group('group cut suggestion', () {
    const members = [
      FaceMember(counterId: 1, name: '甲', groupName: '一团'),
      FaceMember(counterId: 2, name: '乙', groupName: '一团'),
      FaceMember(counterId: 3, name: '丙', groupName: '一团'),
      FaceMember(counterId: 4, name: '丁', groupName: '一团'),
      FaceMember(counterId: 5, name: '戊', groupName: '二团'),
    ];

    test('three recognised out of four candidates suggests the group', () {
      final result = suggestGroupCut(
        candidates: members,
        recognized: members.take(3).toList(),
        nonSelfFaceCount: 3,
      );
      expect(result.suggested, isTrue);
      expect(result.groupName, '一团');
    });

    test('four non-self faces suggest a group even when none is recognised',
        () {
      final result = suggestGroupCut(
        candidates: members,
        recognized: const [],
        nonSelfFaceCount: 4,
      );
      expect(result.suggested, isTrue);
      expect(result.groupName, isNull);
    });

    test('coverage below 75% or fewer than three does not suggest', () {
      expect(
        suggestGroupCut(
          candidates: members,
          recognized: members.take(2).toList(),
          nonSelfFaceCount: 2,
        ).suggested,
        isFalse,
      );
      const extra = FaceMember(counterId: 6, name: '己', groupName: '一团');
      expect(
        suggestGroupCut(
          candidates: [...members, extra],
          recognized: members.take(3).toList(),
          nonSelfFaceCount: 3,
        ).suggested,
        isFalse,
      );
    });

    test('shared people retain their separate group affiliations for coverage',
        () {
      const aP = FaceMember(personId: 1, name: '甲', groupName: 'P团');
      const aQ = FaceMember(personId: 1, name: '甲', groupName: 'Q团');
      const b = FaceMember(personId: 2, name: '乙', groupName: 'Q团');
      const c = FaceMember(personId: 3, name: '丙', groupName: 'Q团');
      const d = FaceMember(personId: 4, name: '丁', groupName: 'Q团');
      const eP = FaceMember(personId: 5, name: '戊', groupName: 'P团');
      const eQ = FaceMember(personId: 5, name: '戊', groupName: 'Q团');
      final coverage = suggestGroupCut(
        candidates: const [aP, aQ, b, c, d],
        recognized: const [aP, b, c],
        nonSelfFaceCount: 3,
      );
      expect(coverage.suggested, isTrue);
      expect(coverage.groupName, 'Q团');
      expect(
        suggestGroupCut(
          candidates: const [aP, eP, aQ, b, c, d, eQ],
          recognized: const [b, c, d],
          nonSelfFaceCount: 3,
        ).suggested,
        isFalse,
      );
    });
  });

  group('three-band decision', () {
    List<CardAssignment> one(List<double> scores) => assignFacesToMembers(
          cards: [
            [scores],
          ],
          candidateCount: scores.length,
        );

    test('auto needs >= 0.60 and a 0.08 lead', () {
      final r = one([0.70, 0.55, 0.10]).single;
      expect(r.status, FaceMatchStatus.auto);
      expect(r.candidates, [0]);
    });

    test('lead too small -> review with top-3', () {
      final r = one([0.70, 0.65, 0.50, 0.20]).single;
      expect(r.status, FaceMatchStatus.review);
      expect(r.candidates, [0]);
      expect(r.topCandidates, [0, 1, 2]);
    });

    test('a candidate without samples raises the auto bar to 0.70', () {
      // Real case: a member with no samples yet, look-alike scored 0.62.
      final unsure = one([0.62, 0.51, -1]).single;
      expect(unsure.status, FaceMatchStatus.review);
      expect(unsure.candidates, [0]);
      final sure = one([0.72, 0.51, -1]).single;
      expect(sure.status, FaceMatchStatus.auto);
    });

    test('0.45-0.60 -> review', () {
      final r = one([0.50, 0.10]).single;
      expect(r.status, FaceMatchStatus.review);
      expect(r.candidates, [0]);
    });

    test('weak and barely ahead -> not pre-filled, still suggested', () {
      // 2026-11-08 desk photos: strangers matched to enrolled members.
      for (final scores in [
        [0.49, 0.42, 0.10],
        [0.58, 0.56, 0.10],
        [0.45, 0.43, 0.10],
      ]) {
        final r = one(scores).single;
        expect(r.status, FaceMatchStatus.unknown, reason: '$scores');
        expect(r.candidates, isEmpty);
        expect(r.topCandidates, [0, 1, 2]);
      }
      // A clear lead below the auto bar is still pre-filled.
      final clear = one([0.58, 0.42]).single;
      expect(clear.status, FaceMatchStatus.review);
      expect(clear.candidates, [0]);
    });

    test('below 0.45 -> unknown', () {
      final r = one([0.44, 0.30]).single;
      expect(r.status, FaceMatchStatus.unknown);
      expect(r.candidates, isEmpty);
      expect(r.topCandidates, [0, 1]);
    });

    test('a card without faces is unknown', () {
      final r = assignFacesToMembers(
        cards: const [[]],
        candidateCount: 2,
      ).single;
      expect(r.status, FaceMatchStatus.unknown);
    });

    test('self faces are recognised by the 0.50 threshold', () {
      final self = [_vec(0)];
      expect(isSelfFace(_vec(0, similarity: 0.6), self), isTrue);
      expect(isSelfFace(_vec(0, similarity: 0.4), self), isFalse);
    });
  });

  group('hungarian assignment', () {
    test('maximises total gain', () {
      final r = hungarianMaximize([
        [0.9, 0.8, 0.0],
        [0.85, 0.1, 0.0],
      ]);
      expect(r, [1, 0]);
    });

    test('multi-member cut gets two distinct members', () {
      final r = assignFacesToMembers(
        cards: [
          [
            [0.80, 0.70], // face 1: A best
            [0.75, 0.50], // face 2: also A best, but B is the only choice
          ],
        ],
        candidateCount: 2,
      ).single;
      expect(r.candidates.toSet(), {0, 1});
      // face 2 got B at 0.50 -> review; face 1 A at 0.80 (lead 0.10) auto.
      expect(r.faces[0].candidate, 0);
      expect(r.faces[0].status, FaceMatchStatus.auto);
      expect(r.faces[1].candidate, 1);
      expect(r.faces[1].status, FaceMatchStatus.review);
      expect(r.status, FaceMatchStatus.review);
    });

    test('one member may own many polaroids without a cap', () {
      final r = assignFacesToMembers(
        cards: [
          for (var i = 0; i < 4; i++)
            [
              [0.8, 0.1],
            ],
        ],
        candidateCount: 2,
      );
      expect(r.every((c) => c.candidates.single == 0), isTrue);
      expect(r.every((c) => c.status == FaceMatchStatus.auto), isTrue);
    });

    test('soft cap: weakest over-cap polaroid becomes review, not reassigned',
        () {
      final r = assignFacesToMembers(
        cards: [
          [
            [0.90, 0.20],
          ],
          [
            [0.85, 0.20],
          ],
          [
            [0.70, 0.20],
          ],
        ],
        candidateCount: 2,
        caps: const {0: 2},
      );
      expect(r.map((c) => c.candidates.single), [0, 0, 0]);
      expect(r[0].status, FaceMatchStatus.auto);
      expect(r[1].status, FaceMatchStatus.auto);
      expect(r[2].status, FaceMatchStatus.review);
      expect(r[2].faces.single.overCap, isTrue);
    });

    test('soft cap moves a polaroid when another member fits almost as well',
        () {
      final r = assignFacesToMembers(
        cards: [
          [
            [0.90, 0.10],
          ],
          [
            [0.66, 0.62],
          ],
        ],
        candidateCount: 2,
        caps: const {0: 1},
      );
      expect(r[0].candidates, [0]);
      expect(r[1].candidates, [1]);
      expect(r[1].status, FaceMatchStatus.review);
    });
  });

  group('ledger', () {
    test('existing >= photos only attaches; otherwise +difference', () {
      final lines = planLedger(
        cards: [
          (memberKeys: ['a'], size: ChekiSize.threeInch),
          (memberKeys: ['a'], size: ChekiSize.threeInch),
          (memberKeys: ['a'], size: ChekiSize.fiveInch),
          (memberKeys: ['b'], size: ChekiSize.threeInch),
          (memberKeys: ['b', 'a'], size: ChekiSize.threeInch),
        ],
        existing: {
          ledgerLineKey(['a'], ChekiSize.threeInch): 3,
          ledgerLineKey(['a'], ChekiSize.fiveInch): 0,
          ledgerLineKey(['b'], ChekiSize.threeInch): 0,
        },
      );
      final byKey = {for (final l in lines) l.lineKey: l};
      expect(byKey['a#threeInch']!.photoCount, 2);
      expect(byKey['a#threeInch']!.supplement, 0);
      expect(byKey['a#fiveInch']!.supplement, 1);
      expect(byKey['b#threeInch']!.supplement, 1);
      final multi = byKey['a+b#threeInch']!;
      expect(multi.isMulti, isTrue);
      expect(multi.supplement, 1);
    });

    test('partial existing count adds only the difference', () {
      final line = planLedger(
        cards: [
          for (var i = 0; i < 5; i++)
            (memberKeys: ['a'], size: ChekiSize.threeInch),
        ],
        existing: {
          ledgerLineKey(['a'], ChekiSize.threeInch): 3
        },
      ).single;
      expect(line.supplement, 2);
    });
  });

  group('sample cap', () {
    test('nothing evicted at or under the limit', () {
      expect(pickSampleToEvict([_vec(0), _vec(1)], limit: 2), -1);
    });

    test('evicts the most redundant sample', () {
      final samples = [
        _vec(0),
        _vec(1),
        _vec(2),
        _vec(0, similarity: 0.99, other: 3), // near-duplicate of #0
      ];
      final victim = pickSampleToEvict(samples, limit: 3);
      // #0 and #3 are each other's nearest; the earlier one goes.
      expect(victim, 0);
    });

    test('default limit is 30', () {
      expect(FaceMatchThresholds.maxSamplesPerMember, 30);
      final many = [for (var i = 0; i < 30; i++) _vec(i % 8)];
      expect(pickSampleToEvict(many), -1);
      expect(pickSampleToEvict([...many, _vec(0)]), isNonNegative);
    });
  });
}
