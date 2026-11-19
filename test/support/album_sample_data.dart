import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:ota_counter/models/activity_record_media_model.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/idol_activity_event_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/idol_database_service.dart';

/// Demo data for the album tests and the rendered previews.
///
/// All images are generated stylised idol portraits (pastel gradient + simple
/// face silhouette), never the user's private photos. Photos are saved through
/// the normal `DatabaseService` path so the album reads exactly the rows it
/// reads in the app.
class AlbumSampleMember {
  final String name;
  final String group;
  final String color;
  final int personId;
  final int imageSeed;

  const AlbumSampleMember({
    required this.name,
    required this.group,
    required this.color,
    required this.personId,
    required this.imageSeed,
  });
}

const albumSampleMembers = <AlbumSampleMember>[
  AlbumSampleMember(
    name: '林小满',
    group: 'Aurora',
    color: '#FF7A9E',
    personId: 101,
    imageSeed: 1,
  ),
  AlbumSampleMember(
    name: '苏晚晴',
    group: 'Aurora',
    color: '#7C6CF0',
    personId: 102,
    imageSeed: 2,
  ),
  AlbumSampleMember(
    name: '阿岚',
    group: 'Lumiere',
    color: '#21B6A8',
    personId: 201,
    imageSeed: 3,
  ),
  AlbumSampleMember(
    name: '星野遥',
    group: 'Lumiere',
    color: '#F4A63A',
    personId: 202,
    imageSeed: 4,
  ),
  AlbumSampleMember(
    name: '陈知夏',
    group: 'Starlight',
    color: '#4E8DF5',
    personId: 301,
    imageSeed: 5,
  ),
  AlbumSampleMember(
    name: '顾星野',
    group: 'Starlight',
    color: '#E45C8A',
    personId: 302,
    imageSeed: 6,
  ),
];

class AlbumSampleSeed {
  final List<CounterModel> counters;
  final List<String> mediaPaths;
  final int sessionCount;

  const AlbumSampleSeed({
    required this.counters,
    required this.mediaPaths,
    required this.sessionCount,
  });

  int get photoCount => mediaPaths.length;
}

class _SessionPlan {
  final DateTime day;
  final String activity;
  final String venue;
  final String city;
  final String sessionLabel;
  final String startTime;
  final List<({int member, int count, bool fiveInch})> solo;
  final List<int> groupMembers;
  final int groupPhotos;
  final int memoryPhotos;

  const _SessionPlan({
    required this.day,
    required this.activity,
    required this.venue,
    required this.city,
    required this.sessionLabel,
    required this.startTime,
    required this.solo,
    this.groupMembers = const [],
    this.groupPhotos = 0,
    this.memoryPhotos = 0,
  });
}

final _sessionPlans = <_SessionPlan>[
  _SessionPlan(
    day: DateTime(2026, 10, 12),
    activity: 'Aurora 定期公演 Vol.12',
    venue: '涩谷 O-EAST',
    city: '东京',
    sessionLabel: '第一部',
    startTime: '19:00',
    solo: [
      (member: 0, count: 2, fiveInch: false),
      (member: 1, count: 1, fiveInch: true),
    ],
    groupMembers: [0, 1],
    groupPhotos: 1,
    memoryPhotos: 1,
  ),
  _SessionPlan(
    day: DateTime(2026, 10, 12),
    activity: 'Aurora 定期公演 Vol.12',
    venue: '涩谷 O-EAST',
    city: '东京',
    sessionLabel: '第二部',
    startTime: '21:00',
    solo: [
      (member: 0, count: 1, fiveInch: false),
      (member: 1, count: 1, fiveInch: false),
    ],
    groupMembers: [0, 1],
    groupPhotos: 1,
  ),
  _SessionPlan(
    day: DateTime(2026, 9, 27),
    activity: 'Lumiere × Starlight 联合公演',
    venue: '新宿 BLAZE',
    city: '东京',
    sessionLabel: '第一部',
    startTime: '18:30',
    solo: [
      (member: 2, count: 2, fiveInch: false),
      (member: 3, count: 1, fiveInch: true),
      (member: 4, count: 1, fiveInch: false),
    ],
    groupMembers: [2, 3, 4],
    groupPhotos: 1,
    memoryPhotos: 1,
  ),
  _SessionPlan(
    day: DateTime(2026, 8, 15),
    activity: 'Starlight 夏日特别场',
    venue: '下北泽 SHELTER',
    city: '东京',
    sessionLabel: '第一部',
    startTime: '19:30',
    solo: [
      (member: 4, count: 2, fiveInch: true),
      (member: 5, count: 1, fiveInch: false),
    ],
    groupMembers: [4, 5],
    groupPhotos: 1,
  ),
  _SessionPlan(
    day: DateTime(2026, 7, 20),
    activity: 'Aurora 夏日祭',
    venue: '万代南梦宫上海文化中心',
    city: '上海',
    sessionLabel: '第二部',
    startTime: '20:00',
    solo: [
      (member: 0, count: 2, fiveInch: false),
      (member: 1, count: 2, fiveInch: true),
    ],
    groupMembers: [0, 1],
    groupPhotos: 1,
    memoryPhotos: 1,
  ),
  _SessionPlan(
    day: DateTime(2025, 12, 31),
    activity: 'Lumiere 跨年公演',
    venue: '杭州酒球会',
    city: '杭州',
    sessionLabel: '第一部',
    startTime: '21:00',
    solo: [
      (member: 2, count: 2, fiveInch: false),
      (member: 3, count: 2, fiveInch: true),
    ],
    groupMembers: [2, 3],
    groupPhotos: 2,
  ),
  _SessionPlan(
    day: DateTime(2025, 11, 9),
    activity: 'Starlight 秋巡',
    venue: '南京太阳宫',
    city: '南京',
    sessionLabel: '第二部',
    startTime: '19:00',
    solo: [
      (member: 4, count: 2, fiveInch: true),
      (member: 5, count: 2, fiveInch: false),
    ],
    groupMembers: [4, 5],
    groupPhotos: 1,
  ),
];

Future<AlbumSampleSeed> seedAlbumSample(
  Directory documents, {
  bool includeIdolEvents = true,
}) async {
  final generated = <int, Uint8List>{};
  for (final member in albumSampleMembers) {
    for (var variant = 0; variant < 2; variant++) {
      generated[member.imageSeed * 10 + variant] = img.encodePng(
        _drawPortrait(member, variant),
      );
    }
  }

  final counters = <CounterModel>[];
  for (final member in albumSampleMembers) {
    final id = await DatabaseService.insertCounter(
      CounterModel(
        name: member.name,
        groupName: member.group,
        personId: member.personId,
        personName: member.name,
        color: member.color,
      ),
    );
    counters.add(
      CounterModel(
        id: id,
        name: member.name,
        groupName: member.group,
        personId: member.personId,
        personName: member.name,
        color: member.color,
      ),
    );
  }

  final mediaPaths = <String>[];
  var variantTick = 0;

  Uint8List bytesFor(int memberIndex) {
    final seedKey =
        albumSampleMembers[memberIndex].imageSeed * 10 + (variantTick++ % 2);
    return generated[seedKey]!;
  }

  Future<int> saveMedia({
    required int recordId,
    required int memberIndex,
    required DateTime capturedAt,
    required bool memory,
    bool owned = true,
  }) async {
    final member = albumSampleMembers[memberIndex];
    final saved = await DatabaseService.saveActivityRecordMediaBytes(
      recordId: recordId,
      bytes: bytesFor(memberIndex),
      fileExtension: '.png',
      mediaType: memory
          ? ActivityRecordMediaType.memory
          : ActivityRecordMediaType.scan,
      processingMode: memory
          ? ActivityRecordMediaProcessingMode.none
          : ActivityRecordMediaProcessingMode.nativeScanner,
      owner: owned
          ? ActivityRecordMediaOwnerScope(
              personId: member.personId,
              personName: member.name,
              groupName: member.group,
            )
          : null,
    );
    mediaPaths.add(saved.path);
    return saved.id!;
  }

  for (var sessionIndex = 0;
      sessionIndex < _sessionPlans.length;
      sessionIndex++) {
    final plan = _sessionPlans[sessionIndex];
    final occurredAt = DateTime(
      plan.day.year,
      plan.day.month,
      plan.day.day,
      18,
      30 + sessionIndex * 35,
    );
    final participants = [
      for (final memberIndex in plan.groupMembers)
        ActivityParticipant(
          memberName: albumSampleMembers[memberIndex].name,
          groupName: albumSampleMembers[memberIndex].group,
          personId: albumSampleMembers[memberIndex].personId,
          personName: albumSampleMembers[memberIndex].name,
        ),
    ];

    // Ticket row doubles as the session/venue anchor for memory photos.
    final ticketId = await DatabaseService.insertActivityRecord(
      ActivityRecordModel.ticket(
        eventName: plan.activity,
        occurredAt: occurredAt,
        venueName: plan.venue,
        sessionLabel: plan.sessionLabel,
        quantity: 1,
        unitPrice: sessionIndex.isEven ? 80 : 100,
        ticketType: sessionIndex.isEven ? '预售票' : '现场票',
      ),
    );

    for (final line in plan.solo) {
      final counter = counters[line.member];
      final field = line.fiveInch
          ? CounterCountField.fiveInch
          : CounterCountField.threeInch;
      final recordId = await DatabaseService.insertActivityRecord(
        ActivityRecordModel.counterAdjustment(
          counter: counter,
          occurredAt: occurredAt,
          deltas: {field: line.count},
          activityName: plan.activity,
          venueName: plan.venue,
          sessionLabel: plan.sessionLabel,
          note: '相册预览数据',
        ),
      );
      for (var i = 0; i < line.count; i++) {
        await saveMedia(
          recordId: recordId,
          memberIndex: line.member,
          capturedAt: occurredAt.add(Duration(minutes: 8 + i * 3)),
          memory: false,
        );
      }
    }

    if (plan.groupPhotos > 0 && participants.length > 1) {
      final groupRecordId = await DatabaseService.insertActivityRecord(
        ActivityRecordModel.multiCut(
          participants: participants,
          field: CounterCountField.groupCut,
          occurredAt: occurredAt,
          activityName: plan.activity,
          venueName: plan.venue,
          sessionLabel: plan.sessionLabel,
          quantity: plan.groupPhotos,
          totalPrice: 400,
          note: '相册预览数据',
        ),
      );
      for (var i = 0; i < plan.groupPhotos; i++) {
        await saveMedia(
          recordId: groupRecordId,
          memberIndex: plan.groupMembers.first,
          capturedAt: occurredAt.add(Duration(minutes: 20 + i * 4)),
          memory: false,
          owned: false,
        );
      }
    }

    for (var i = 0; i < plan.memoryPhotos; i++) {
      await saveMedia(
        recordId: ticketId,
        memberIndex: plan.solo.first.member,
        capturedAt: occurredAt.add(Duration(minutes: 60)),
        memory: true,
        owned: false,
      );
    }
  }

  // One photo without any usable date: exercises the "日期不明" section and
  // the year-jump sheet. The ledger row falls back to DateTime(0), exactly how
  // old/broken imports look.
  final undatedRecordId = await DatabaseService.insertActivityRecord(
    ActivityRecordModel.counterAdjustment(
      counter: counters[0],
      occurredAt: DateTime.fromMillisecondsSinceEpoch(0),
      deltas: {CounterCountField.threeInch: 1},
      note: '日期不明的旧照片',
    ),
  );
  await DatabaseService.saveActivityRecordMediaBytes(
    recordId: undatedRecordId,
    bytes: bytesFor(0),
    fileExtension: '.png',
    owner: ActivityRecordMediaOwnerScope(
      personId: albumSampleMembers[0].personId,
      personName: albumSampleMembers[0].name,
      groupName: albumSampleMembers[0].group,
    ),
  );
  mediaPaths.add(
    (await DatabaseService.getActivityRecordMedia(recordId: undatedRecordId))
        .single
        .path,
  );

  if (includeIdolEvents) {
    final db = await IdolDatabaseService.database;
    await db.delete('idol_activity_events');
    for (var i = 0; i < _sessionPlans.length; i++) {
      final plan = _sessionPlans[i];
      final groups = <String>{
        for (final member in plan.groupMembers)
          albumSampleMembers[member].group,
      }.toList();
      await db.insert(
        'idol_activity_events',
        IdolActivityEvent(
          sourceEventId: 'album-seed-$i',
          eventDate: plan.day,
          city: plan.city,
          venue: plan.venue,
          eventName: plan.activity,
          startTime: plan.startTime,
          groups: [
            for (final group in groups)
              IdolActivityGroup(name: group, uid: group.toLowerCase()),
          ],
          ticketTiers: const [IdolTicketTier(name: '预售票', price: 80)],
          syncedAt: DateTime(2026, 10, 1),
        ).toDbMap(),
      );
    }
  }

  // Keep the parameter meaningful for callers that want a clean documents
  // directory; files are written by the service below `activity_record_media`.
  if (!documents.existsSync()) {
    documents.createSync(recursive: true);
  }

  return AlbumSampleSeed(
    counters: counters,
    mediaPaths: mediaPaths,
    sessionCount: _sessionPlans.length,
  );
}

img.Image _drawPortrait(AlbumSampleMember member, int variant) {
  const width = 300;
  const height = 400;
  final image = img.Image(width: width, height: height);
  final memberRgb = _hexRgb(member.color);
  final top = _mix(memberRgb, const [255, 251, 247], 0.58);
  final bottom = _mix(memberRgb, const [255, 242, 230], 0.22);
  for (var y = 0; y < height; y++) {
    final t = y / (height - 1);
    final color = _mix(top, bottom, t);
    img.fillRect(
      image,
      x1: 0,
      y1: y,
      x2: width - 1,
      y2: y,
      color: img.ColorRgb8(color[0], color[1], color[2]),
    );
  }

  // A soft "stage light" disc behind the head.
  img.fillCircle(
    image,
    x: 236,
    y: 74,
    radius: 62,
    color: img.ColorRgba8(255, 255, 255, 62),
  );
  img.fillCircle(
    image,
    x: 48,
    y: 330,
    radius: 34,
    color: img.ColorRgba8(255, 255, 255, 40),
  );

  // Hair silhouette, face, fringe, body.
  final hair =
      variant.isEven ? img.ColorRgb8(61, 42, 48) : img.ColorRgb8(74, 47, 44);
  final skin = variant.isEven
      ? img.ColorRgb8(244, 208, 186)
      : img.ColorRgb8(238, 198, 174);
  img.fillCircle(image, x: 150, y: 208, radius: 108, color: hair);
  img.fillRect(
    image,
    x1: 72,
    y1: 315,
    x2: 228,
    y2: 430,
    radius: 58,
    color: img.ColorRgb8(memberRgb[0], memberRgb[1], memberRgb[2]),
  );
  img.fillRect(
    image,
    x1: 128,
    y1: 286,
    x2: 172,
    y2: 338,
    color: skin,
  );
  img.fillCircle(image, x: 150, y: 212, radius: 88, color: skin);
  img.fillCircle(image, x: 102, y: 154, radius: 49, color: hair);
  img.fillCircle(image, x: 198, y: 154, radius: 49, color: hair);
  img.fillCircle(image, x: 150, y: 142, radius: 62, color: hair);
  img.fillRect(
    image,
    x1: 144,
    y1: 136,
    x2: 156,
    y2: 165,
    radius: 5,
    color: skin,
  );

  // Face: eyes, catchlights, blush, smile.
  img.fillCircle(image, x: 121, y: 214, radius: 7, color: hair);
  img.fillCircle(image, x: 179, y: 214, radius: 7, color: hair);
  img.fillCircle(
    image,
    x: 123,
    y: 212,
    radius: 2,
    color: img.ColorRgba8(255, 255, 255, 220),
  );
  img.fillCircle(
    image,
    x: 181,
    y: 212,
    radius: 2,
    color: img.ColorRgba8(255, 255, 255, 220),
  );
  img.fillCircle(
    image,
    x: 102,
    y: 238,
    radius: 13,
    color: img.ColorRgba8(242, 150, 162, 95),
  );
  img.fillCircle(
    image,
    x: 198,
    y: 238,
    radius: 13,
    color: img.ColorRgba8(242, 150, 162, 95),
  );
  img.drawLine(
    image,
    x1: 143,
    y1: 250,
    x2: 157,
    y2: 250,
    thickness: 3,
    color: img.ColorRgb8(190, 97, 106),
  );

  // Member-coloured ribbon / flower in the hair.
  img.fillCircle(
    image,
    x: variant.isEven ? 214 : 86,
    y: 142,
    radius: 16,
    color: img.ColorRgba8(255, 251, 247, 235),
  );
  img.fillCircle(
    image,
    x: variant.isEven ? 214 : 86,
    y: 142,
    radius: 10,
    color: img.ColorRgb8(memberRgb[0], memberRgb[1], memberRgb[2]),
  );
  img.fillCircle(
    image,
    x: variant.isEven ? 210 : 90,
    y: 138,
    radius: 4,
    color: img.ColorRgba8(255, 255, 255, 205),
  );

  // A few doodled sparkles.
  for (final spot in [
    (250, 120, 4),
    (60, 96, 3),
    (270, 300, 2),
    (36, 250, 2),
    (260, 210, 3),
  ]) {
    img.fillCircle(
      image,
      x: spot.$1,
      y: spot.$2,
      radius: spot.$3,
      color: img.ColorRgba8(255, 255, 255, 180),
    );
  }

  return image;
}

List<int> _hexRgb(String hex) {
  final normalized = hex.replaceAll('#', '');
  final value = int.parse(normalized, radix: 16);
  return [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF];
}

List<int> _mix(List<int> a, List<int> b, double t) {
  return [
    (a[0] * (1 - t) + b[0] * t).round(),
    (a[1] * (1 - t) + b[1] * t).round(),
    (a[2] * (1 - t) + b[2] * t).round(),
  ];
}
