import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/pages/album/album_models.dart';
import 'package:ota_counter/pages/album/album_timeline_mosaic.dart';

AlbumPhoto _photo({required int id, DateTime? day}) {
  return AlbumPhoto(
    mediaId: id,
    path: 'photo-$id.jpg',
    isScan: true,
    mediaLabel: '切图',
    specLabel: '3寸',
    activityDay: day,
    sessionKey: day == null ? 'orphan' : 'day:${day.month}-${day.day}',
    sessionDay: day,
  );
}

void main() {
  group('mosaic day plan', () {
    test('a single photo stays a normal grid tile', () {
      const layout = AlbumMosaicLayout(viewportWidth: 393);
      final plan = layout.planDay(1);
      expect(plan.rows, hasLength(1));
      expect(plan.rows.single.cells, hasLength(1));
      expect(plan.rows.single.cells.single.width, layout.smallWidth);
      expect(plan.rows.single.cells.single.height, layout.smallHeight);
      expect(plan.rows.single.stackedRight, isFalse);
      expect(layout.dayHeight(1), lessThan(400));
    });

    test('two photos stay two normal grid tiles, not a lead pair', () {
      const layout = AlbumMosaicLayout(viewportWidth: 393);
      final plan = layout.planDay(2);
      expect(plan.rows, hasLength(1));
      final row = plan.rows.single;
      expect(row.stackedRight, isFalse);
      expect(row.cells, hasLength(2));
      expect(row.cells.first.width, layout.smallWidth);
      expect(row.cells.last.width, layout.smallWidth);
    });

    test('three photos fill the right column with two stacked prints', () {
      const layout = AlbumMosaicLayout(viewportWidth: 393);
      final plan = layout.planDay(3);
      expect(plan.rows, hasLength(1));
      final row = plan.rows.single;
      expect(row.stackedRight, isTrue);
      expect(row.cells, hasLength(3));
      expect(
        row.cells.first.height,
        closeTo(row.cells[1].height * 2 + AlbumMosaicLayout.gap, 0.001),
      );
    });

    test('five photos make a lead row plus one ordinary row', () {
      const layout = AlbumMosaicLayout(viewportWidth: 393);
      final plan = layout.planDay(5);
      expect(plan.rows, hasLength(2));
      expect(plan.rows.first.cells, hasLength(3));
      expect(plan.rows.last.cells, hasLength(2));
      expect(plan.rows.last.stackedRight, isFalse);
      expect(layout.columns, 3);
      expect(
        plan.rows.first.cells.first.width,
        greaterThan(layout.smallWidth),
      );
    });

    test('seven photos wrap into a full second row', () {
      const layout = AlbumMosaicLayout(viewportWidth: 393);
      final plan = layout.planDay(7);
      expect(plan.rows, hasLength(3));
      expect(plan.rows[1].cells, hasLength(3));
      expect(plan.rows[2].cells, hasLength(1));
    });

    test('every plan cell carries the photo index in reading order', () {
      const layout = AlbumMosaicLayout(viewportWidth: 393);
      for (final count in [2, 3, 4, 5, 8, 11]) {
        final plan = layout.planDay(count);
        final indexes = [
          for (final row in plan.rows)
            for (final cell in row.cells) cell.photoIndex,
        ];
        expect(indexes, List.generate(count, (index) => index));
      }
    });

    test('no photo means no rows, so the day section has no mosaic height', () {
      const layout = AlbumMosaicLayout(viewportWidth: 393);
      expect(layout.planDay(0).rows, isEmpty);
      expect(layout.dayHeight(0),
          AlbumMosaicLayout.dayHeaderHeight + AlbumMosaicLayout.dayBottomGap);
    });

    test('narrow and wide screens pick sensible column counts', () {
      expect(
        const AlbumMosaicLayout(viewportWidth: 280).columns,
        2,
      );
      expect(
        const AlbumMosaicLayout(viewportWidth: 393).columns,
        3,
      );
      expect(
        const AlbumMosaicLayout(viewportWidth: 900).columns,
        4,
      );
    });
  });

  group('mosaic offsets', () {
    test('year and undated offsets match the section heights', () {
      final photos = <AlbumPhoto>[];
      var id = 1;
      for (final year in [2026, 2025]) {
        for (var month = year == 2026 ? 10 : 12;
            month >= (year == 2026 ? 8 : 11);
            month--) {
          for (var day = 1; day <= 2; day++) {
            final count = 1 + (day + month) % 4;
            for (var i = 0; i < count; i++) {
              photos.add(_photo(id: id++, day: DateTime(year, month, day)));
            }
          }
        }
      }
      final data = AlbumData.assemble(photos);
      const layout = AlbumMosaicLayout(viewportWidth: 393);

      var expected = AlbumMosaicLayout.timelineTopPadding;
      for (final month in data.months) {
        expected += layout.monthHeight(month);
      }
      expect(layout.offsetForUndated(data.months), expected);

      expect(
        layout.offsetForYear(data.months.first.month.year, data.months),
        AlbumMosaicLayout.timelineTopPadding,
      );
      expect(
        layout.offsetForYear(data.months.last.month.year, data.months),
        greaterThan(AlbumMosaicLayout.timelineTopPadding),
      );
      expect(
        layout.offsetForUndated(data.months),
        greaterThan(
            layout.offsetForYear(data.months.last.month.year, data.months)),
      );
    });
  });

  group('session title fallback order', () {
    const member = AlbumMemberRef(
      key: 'p:1',
      personId: 1,
      name: '小树',
      groupName: 'PokaPokaTime',
      colorHex: '#21B6A8',
    );

    test('recorded activity name wins', () {
      expect(
        albumSessionTitle(
          activityName: 'Aurora 定期公演 Vol.12',
          venueName: '涩谷 O-EAST',
          members: const [member],
        ),
        'Aurora 定期公演 Vol.12',
      );
    });

    test('group name comes before the venue', () {
      expect(
        albumSessionTitle(
          activityName: '',
          venueName: '涩谷 O-EAST',
          members: const [member],
        ),
        'PokaPokaTime 场',
      );
    });

    test('multiple groups are joined', () {
      const second = AlbumMemberRef(
        key: 'p:2',
        personId: 2,
        name: '小雪',
        groupName: '風時計Kazetoke',
      );
      expect(
        albumSessionTitle(
          activityName: '',
          venueName: '',
          members: const [member, second],
        ),
        'PokaPokaTime / 風時計Kazetoke 场',
      );
    });

    test('venue comes before member names', () {
      expect(
        albumSessionTitle(
          activityName: '',
          venueName: '新宿 BLAZE',
          members: const [
            AlbumMemberRef(key: 'p:3', personId: 3, name: '阿岚'),
          ],
        ),
        '新宿 BLAZE',
      );
    });

    test('member names are used when there is no group or venue', () {
      expect(
        albumSessionTitle(
          activityName: '',
          venueName: '',
          members: const [
            AlbumMemberRef(key: 'p:3', personId: 3, name: '阿岚'),
            AlbumMemberRef(key: 'p:4', personId: 4, name: '星野遥'),
          ],
        ),
        '阿岚 / 星野遥 场',
      );
    });

    test('未记公演 is the very last fallback', () {
      expect(
        albumSessionTitle(
          activityName: '  ',
          venueName: ' ',
          members: const [],
        ),
        '未记公演',
      );
    });
  });

  group('member badge text', () {
    test('short badge keeps the whole short name, not one character', () {
      const members = [
        AlbumMemberRef(key: 'a', name: '林小满'),
        AlbumMemberRef(key: 'b', name: '小雪'),
        AlbumMemberRef(key: 'c', name: 'Anna'),
        AlbumMemberRef(key: 'd', name: ''),
      ];
      expect(members[0].shortBadge, '林小满');
      expect(members[1].shortBadge, '小雪');
      expect(members[2].shortBadge, 'Ann');
      expect(members[3].shortBadge, '?');
    });
  });
}
