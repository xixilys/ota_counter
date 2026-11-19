import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/activity_record_media_model.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/pages/album/album_grouping.dart';
import 'package:ota_counter/pages/album/album_models.dart';
import 'package:ota_counter/pages/album/album_timeline_layout.dart';

CounterModel _counter({
  required int id,
  required String name,
  required String group,
  required int personId,
  required String color,
}) {
  return CounterModel(
    id: id,
    name: name,
    groupName: group,
    personId: personId,
    personName: name,
    color: color,
  );
}

final _manatsu = _counter(
  id: 1,
  name: '小满',
  group: 'Aurora',
  personId: 101,
  color: '#FF7A9E',
);
final _koyuki = _counter(
  id: 2,
  name: '小雪',
  group: 'Lumiere',
  personId: 202,
  color: '#4E8DF5',
);

ActivityRecordMediaModel _media({
  int id = 1,
  required int recordId,
  required String path,
  DateTime? createdAt,
  DateTime? capturedAt,
  bool scan = true,
  int? ownerPersonId,
  String ownerPersonName = '',
  String ownerGroupName = '',
}) {
  return ActivityRecordMediaModel(
    id: id,
    recordId: recordId,
    path: path,
    createdAt: createdAt ?? DateTime(2026, 10, 12, 12),
    mediaType:
        scan ? ActivityRecordMediaType.scan : ActivityRecordMediaType.memory,
    processingMode: scan
        ? ActivityRecordMediaProcessingMode.nativeScanner
        : ActivityRecordMediaProcessingMode.none,
    capturedAt: capturedAt,
    ownerPersonId: ownerPersonId,
    ownerPersonName: ownerPersonName,
    ownerGroupName: ownerGroupName,
  );
}

void main() {
  group('photo → member / date / 场次 mapping', () {
    final r1 = ActivityRecordModel.counterAdjustment(
      id: 1,
      counter: _manatsu,
      occurredAt: DateTime(2026, 10, 12, 19, 30),
      deltas: {CounterCountField.threeInch: 2},
      activityName: 'Aurora 定期公演',
      venueName: '涩谷 O-EAST',
      sessionLabel: '第一部',
    );
    final r2 = ActivityRecordModel.multiCut(
      id: 2,
      participants: const [
        ActivityParticipant(
          memberName: '小满',
          groupName: 'Aurora',
          personId: 101,
          personName: '小满',
        ),
        ActivityParticipant(
          memberName: '小雪',
          groupName: 'Lumiere',
          personId: 202,
          personName: '小雪',
        ),
      ],
      field: CounterCountField.groupCut,
      occurredAt: DateTime(2026, 10, 12, 20, 30),
      activityName: 'Aurora 定期公演',
      venueName: '涩谷 O-EAST',
      sessionLabel: '第二部',
      quantity: 1,
      totalPrice: 400,
    );
    final r3 = ActivityRecordModel.ticket(
      id: 3,
      eventName: 'Lumiere 免费场',
      occurredAt: DateTime(2026, 10, 13),
      venueName: '下北泽',
      sessionLabel: '第二部',
    );
    final r4 = ActivityRecordModel.counterAdjustment(
      id: 4,
      counter: _koyuki,
      occurredAt: DateTime(2026, 9, 30, 23, 30),
      deltas: {CounterCountField.fiveInch: 1},
      activityName: 'Starlight 秋巡',
      venueName: '南京太阳宫',
      sessionLabel: '第二部',
    );

    final media = [
      _media(
        id: 1,
        recordId: 1,
        path: 'ma.jpg',
        capturedAt: DateTime(2026, 10, 12, 1, 20),
        ownerPersonId: 101,
        ownerPersonName: '小满',
        ownerGroupName: 'Aurora',
      ),
      _media(
        id: 2,
        recordId: 1,
        path: 'mb.jpg',
        ownerPersonId: 202,
        ownerPersonName: '小雪',
        ownerGroupName: 'Lumiere',
      ),
      _media(
        id: 3,
        recordId: 2,
        path: 'mc.jpg',
        capturedAt: DateTime(2026, 10, 12, 20, 35),
      ),
      _media(
        id: 4,
        recordId: 4,
        path: 'md.jpg',
        capturedAt: DateTime(2026, 9, 30, 23, 50),
        ownerPersonId: 202,
        ownerPersonName: '小雪',
        ownerGroupName: 'Lumiere',
      ),
      _media(
        id: 5,
        recordId: 3,
        path: 'me.jpg',
        scan: false,
      ),
      _media(id: 6, recordId: 999, path: 'mf.jpg'),
    ];

    final data = buildAlbumData(
      counters: [_manatsu, _koyuki],
      records: [r1, r2, r3, r4],
      media: media,
      eventHints: [
        AlbumEventHint(
          day: DateTime(2026, 10, 12),
          eventName: 'Aurora 定期公演',
          venue: '新宿 BLAZE',
          city: '东京',
          startTime: '19:00',
        ),
      ],
    );

    test('only an unprocessed scan can get a corrected display preview', () {
      final raw = _media(id: 7, recordId: 1, path: 'raw.jpg')
          .copyWith(processingMode: ActivityRecordMediaProcessingMode.none);
      final photos = buildAlbumData(
        counters: [_manatsu, _koyuki],
        records: [r1],
        media: [raw, ...media],
      ).photos;
      expect(photos.where((p) => p.canAutoRectify).map((p) => p.mediaId), [7]);
    });

    test('counts and buckets', () {
      expect(data.photoCount, 6);
      expect(data.scanCount, 5);
      expect(data.memoryCount, 1);
      expect(data.months, hasLength(2));
      expect(data.months.first.month, DateTime(2026, 10));
      expect(data.months.first.count, 4);
      expect(data.months.last.month, DateTime(2026, 9));
      expect(data.undatedDay?.count, 1);
      expect(data.sessions, hasLength(5));
      expect(data.members, hasLength(2));
      expect(data.unattributedPhotos, hasLength(2));
    });

    test('capture day wins; activity day starts at 06:00', () {
      final photo = data.photos.firstWhere((photo) => photo.mediaId == 1);
      expect(photo.activityDay, DateTime(2026, 10, 11));
      expect(photo.dateFromPhoto, isTrue);

      final recordDate = data.photos.firstWhere((photo) => photo.mediaId == 2);
      expect(recordDate.activityDay, DateTime(2026, 10, 12));
      expect(recordDate.dateFromPhoto, isFalse);

      final ticketPhoto = data.photos.firstWhere((photo) => photo.mediaId == 5);
      expect(ticketPhoto.activityDay, DateTime(2026, 10, 13));

      final unknown = data.photos.firstWhere((photo) => photo.mediaId == 6);
      expect(unknown.activityDay, isNull);
    });

    test('member owner label overrides the record member', () {
      final photo = data.photos.firstWhere((photo) => photo.mediaId == 2);
      expect(photo.members.single.personId, 202);
      expect(photo.members.single.displayName, '小雪');
      expect(photo.isGroup, isFalse);
    });

    test('multi cut becomes a group photo for every participant', () {
      final photo = data.photos.firstWhere((photo) => photo.mediaId == 3);
      expect(photo.isGroup, isTrue);
      expect(photo.members.map((member) => member.displayName),
          containsAll(['小满', '小雪']));
      final manatsu =
          data.members.firstWhere((album) => album.member.personId == 101);
      expect(manatsu.soloCount, 1);
      expect(manatsu.groupCount, 1);
      expect(manatsu.cover?.mediaId, 1);
      final koyuki =
          data.members.firstWhere((album) => album.member.personId == 202);
      expect(koyuki.soloCount, 2);
      expect(koyuki.groupCount, 1);
    });

    test('spec label comes from the ledger', () {
      final scan = data.photos.firstWhere((photo) => photo.mediaId == 1);
      expect(scan.specLabel, contains('3寸'));
      final group = data.photos.firstWhere((photo) => photo.mediaId == 3);
      expect(group.specLabel, contains('团切'));
      final memory = data.photos.firstWhere((photo) => photo.mediaId == 5);
      expect(memory.specLabel, '纪念照');
      final orphan = data.photos.firstWhere((photo) => photo.mediaId == 6);
      expect(orphan.specLabel, '切图');
    });

    test('sessions merge ledger records with the same event identity', () {
      final auroraFirst = data.sessions.firstWhere(
        (session) =>
            session.title == 'Aurora 定期公演' && session.sessionLabel == '第一部',
      );
      expect(auroraFirst.count, 2); // ma + mb
      expect(auroraFirst.photos.map((photo) => photo.mediaId),
          containsAll([1, 2]));
      expect(auroraFirst.venueName, '涩谷 O-EAST');
      expect(auroraFirst.cityName, '东京'); // from the 演出名单 cache
      // A labelled 部 already says which slot it is; the event cache carries
      // one time per event, so pairing it with 第一部 could be wrong.
      expect(auroraFirst.eventTimeLabel, isEmpty);
      expect(
        auroraFirst.members.map((member) => member.displayName),
        containsAll(['小满', '小雪']),
      );

      final second = data.sessions.firstWhere(
        (session) =>
            session.sessionLabel == '第二部' &&
            session.day == DateTime(2026, 10, 12),
      );
      expect(second.count, 1);
      expect(second.photos.single.mediaId, 3);
      expect(second.members, hasLength(2));
    });

    test('ticket session without an owner has photos but no member chips', () {
      final ticketSession = data.sessions.firstWhere(
        (session) => session.title == 'Lumiere 免费场',
      );
      expect(ticketSession.count, 1);
      expect(ticketSession.members, isEmpty);
      expect(ticketSession.photos.single.mediaId, 5);
    });

    test('unknown record becomes an undated orphan session', () {
      final orphanSession = data.sessions.firstWhere(
        (session) => session.key == 'orphan',
      );
      expect(orphanSession.day, isNull);
      expect(orphanSession.count, 1);
      expect(orphanSession.members, isEmpty);
      expect(orphanSession.photos.single.mediaId, 6);
    });

    test('member-filtered data still includes 同框 photos', () {
      final filtered = data.filteredToMember(
        personId: 101,
        name: '小满',
        groupName: 'Aurora',
      );
      expect(filtered.photoCount, 2);
      expect(filtered.sessions, hasLength(2));
      expect(
        filtered.photos.map((photo) => photo.mediaId),
        containsAll([1, 3]),
      );
      expect(filtered.members, hasLength(2)); // both participants of 同框
    });
  });

  test('event cache fills venue/time only when the ledger has no slot', () {
    final counter = _counter(
      id: 1,
      name: '小满',
      group: 'Aurora',
      personId: 101,
      color: '#FF7A9E',
    );
    final record = ActivityRecordModel.counterAdjustment(
      id: 1,
      counter: counter,
      occurredAt: DateTime(2026, 10, 12, 19, 30),
      deltas: {CounterCountField.threeInch: 1},
      activityName: 'Aurora 定期公演',
    );
    final data = buildAlbumData(
      counters: [counter],
      records: [record],
      media: [
        _media(
          id: 1,
          recordId: 1,
          path: 'hint.jpg',
          capturedAt: DateTime(2026, 10, 12, 19, 40),
        ),
      ],
      eventHints: [
        AlbumEventHint(
          day: DateTime(2026, 10, 12),
          eventName: 'Aurora 定期公演',
          venue: '新宿 BLAZE',
          city: '东京',
          startTime: '19:00',
        ),
      ],
    );
    expect(data.sessions.single.venueName, '新宿 BLAZE');
    expect(data.sessions.single.cityName, '东京');
    expect(data.sessions.single.eventTimeLabel, '19:00');
  });

  test('date-only records keep their date, 05:59 belongs to yesterday', () {
    final counter = _counter(
      id: 1,
      name: '小满',
      group: 'Aurora',
      personId: 101,
      color: '#FF7A9E',
    );
    final record = ActivityRecordModel.counterAdjustment(
      id: 1,
      counter: counter,
      occurredAt: DateTime(2026, 10, 12),
      deltas: {CounterCountField.threeInch: 2},
      activityName: '日场',
    );
    final data = buildAlbumData(
      counters: [counter],
      records: [record],
      media: [
        _media(
          id: 1,
          recordId: 1,
          path: 'a.jpg',
          capturedAt: DateTime(2026, 10, 13, 5, 59),
        ),
        _media(
          id: 2,
          recordId: 1,
          path: 'b.jpg',
          capturedAt: DateTime(2026, 10, 13, 6),
        ),
        _media(id: 3, recordId: 1, path: 'c.jpg'),
      ],
    );
    expect(data.photos[0].mediaId, 2); // 06:00 on the 13th, newest first
    expect(data.photos[0].activityDay, DateTime(2026, 10, 13));
    expect(data.photos[1].activityDay, DateTime(2026, 10, 12));
    expect(data.photos[2].activityDay, DateTime(2026, 10, 12));
  });

  test('empty archive and ticket rows behave', () {
    final empty = buildAlbumData(
      counters: const [],
      records: const [],
      media: const [],
    );
    expect(empty.isEmpty, isTrue);
    expect(empty.months, isEmpty);
    expect(empty.sessions, isEmpty);
    expect(empty.undatedDay, isNull);

    final ticket = ActivityRecordModel.ticket(
      id: 1,
      eventName: '无主门票',
      occurredAt: DateTime(2026, 10, 12),
    );
    final data = buildAlbumData(
      counters: const [],
      records: [ticket],
      media: [
        _media(id: 1, recordId: 1, path: 'x.jpg', createdAt: DateTime(2026)),
      ],
    );
    expect(data.photoCount, 1);
    expect(data.members, isEmpty);
    expect(data.unattributedPhotos.single.mediaId, 1);
    expect(data.sessions.single.title, '无主门票');
  });

  test('timeline layout offsets line up with section heights', () {
    final photos = <AlbumPhoto>[];
    var mediaId = 1;
    for (final year in [2026, 2025]) {
      for (var month = year == 2026 ? 10 : 12;
          month >= (year == 2026 ? 8 : 11);
          month--) {
        for (var day = 1; day <= 2; day++) {
          for (var i = 0; i < day + month % 2; i++) {
            photos.add(
              _fakePhoto(
                mediaId: mediaId++,
                day: DateTime(year, month, day),
              ),
            );
          }
        }
      }
    }
    final data = AlbumData.assemble(photos);
    final layout = AlbumTimelineLayout(
      viewportWidth: 393,
      undatedPhotoCount: 2,
    );
    expect(layout.columns, 3);
    expect(layout.tileWidth, greaterThan(0));
    expect(layout.tileHeight, greaterThan(layout.tileWidth));

    var expected = AlbumTimelineLayout.timelineTopPadding;
    for (final month in data.months) {
      expected += layout.monthHeight(month);
    }
    expect(layout.offsetForUndated(data.months), expected);

    final newerYear = data.months.first.month.year;
    expect(
      layout.offsetForYear(newerYear, data.months),
      AlbumTimelineLayout.timelineTopPadding,
    );
    final olderYear = data.months.last.month.year;
    expect(
      layout.offsetForYear(olderYear, data.months),
      greaterThan(AlbumTimelineLayout.timelineTopPadding),
    );
    expect(
      layout.offsetForUndated(data.months),
      greaterThan(layout.offsetForYear(olderYear, data.months)),
    );
  });
}

AlbumPhoto _fakePhoto({required int mediaId, DateTime? day}) {
  return AlbumPhoto(
    mediaId: mediaId,
    path: 'photo-$mediaId.jpg',
    isScan: true,
    mediaLabel: '切图',
    specLabel: '3寸',
    activityDay: day,
    members: const [],
    sessionKey: day == null ? 'orphan' : 'day:${day.month}-${day.day}',
    sessionDay: day,
  );
}
