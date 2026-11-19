import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'album_models.dart';
import '../../models/album_preferences.dart';
import 'album_widgets.dart';

/// Geometry for the landing timeline, a quilted mosaic: the first print of an
/// activity day is enlarged, the rest sit in a compact grid.
///
/// The landing page is one scroll view, so the year jump cannot rely on the
/// timeline being the first sliver. Both the row builder and the offset math
/// read the same [AlbumMosaicLayout.planDay] result, which is what makes the
/// jump land on the chosen month and keeps the layout unit-testable.
class AlbumMosaicLayout {
  const AlbumMosaicLayout({
    required this.viewportWidth,
    this.preferredColumns = 0,
    this.collage = true,
  });

  final int preferredColumns;
  final bool collage;

  static const double horizontalPadding = 16;
  static const double gap = 10;
  static const double tileAspectRatio = 0.56; // width / height, with caption
  static const double monthHeaderHeight = 48;
  static const double dayHeaderHeight = 44;
  static const double dayBottomGap = 6;
  static const double monthBottomGap = 18;
  static const double timelineTopPadding = 4;
  static const double timelineBottomPadding = 108;

  final double viewportWidth;

  double get contentWidth {
    final width = viewportWidth - horizontalPadding * 2;
    return width < 0 ? 0 : width;
  }

  int get columns {
    if (preferredColumns != 0) return preferredColumns;
    if (contentWidth < 300) return 2;
    if (contentWidth < 560) return 3;
    return 4;
  }

  double get smallWidth => (contentWidth - gap * (columns - 1)) / columns;

  double get smallHeight => smallWidth / tileAspectRatio;

  AlbumMosaicDay planDay(int count) {
    if (count <= 0) return const AlbumMosaicDay(rows: []);
    if (!collage) {
      return AlbumMosaicDay(rows: [
        for (var start = 0; start < count; start += columns)
          AlbumMosaicRow(
            height: smallHeight,
            stackedRight: false,
            cells: [
              for (var i = start; i < math.min(start + columns, count); i++)
                AlbumMosaicCell(
                    photoIndex: i, width: smallWidth, height: smallHeight),
            ],
          ),
      ]);
    }
    if (count <= 2) {
      // A day with one or two prints is not a feature: keep the normal grid
      // tile size instead of turning a single cheki into a full-screen slab.
      return AlbumMosaicDay(
        rows: [
          AlbumMosaicRow(
            height: smallHeight,
            stackedRight: false,
            cells: [
              for (var i = 0; i < count; i++)
                AlbumMosaicCell(
                  photoIndex: i,
                  width: smallWidth,
                  height: smallHeight,
                ),
            ],
          ),
        ],
      );
    }

    final rightCount = math.min(2, count - 1);
    final double rightWidth;
    if (columns >= 3) {
      rightWidth = smallWidth;
    } else {
      rightWidth = contentWidth * 0.36;
    }
    final heroWidth = contentWidth - rightWidth - gap;
    final rightSmallHeight = rightWidth / tileAspectRatio;
    final heroHeight =
        rightCount >= 2 ? rightSmallHeight * 2 + gap : rightSmallHeight * 1.5;
    final rows = <AlbumMosaicRow>[
      AlbumMosaicRow(
        height: heroHeight,
        stackedRight: true,
        cells: [
          AlbumMosaicCell(
            photoIndex: 0,
            width: heroWidth,
            height: heroHeight,
          ),
          for (var i = 1; i <= rightCount; i++)
            AlbumMosaicCell(
              photoIndex: i,
              width: rightWidth,
              height: rightSmallHeight,
            ),
        ],
      ),
    ];

    var index = 1 + rightCount;
    while (index < count) {
      final take = math.min(columns, count - index);
      rows.add(
        AlbumMosaicRow(
          height: smallHeight,
          stackedRight: false,
          cells: [
            for (var i = 0; i < take; i++)
              AlbumMosaicCell(
                photoIndex: index + i,
                width: smallWidth,
                height: smallHeight,
              ),
          ],
        ),
      );
      index += take;
    }
    return AlbumMosaicDay(rows: rows);
  }

  double dayHeight(int photoCount) =>
      dayHeaderHeight + planDay(photoCount).height + dayBottomGap;

  double monthHeight(AlbumMonth month) {
    var height = monthHeaderHeight;
    for (final day in month.days) {
      height += dayHeight(day.count);
    }
    return height + monthBottomGap;
  }

  double undatedHeight(int photoCount) =>
      monthHeaderHeight + planDay(photoCount).height + monthBottomGap;

  /// Scroll offset of the first month of [year], measured from the start of
  /// the timeline (before the landing header).
  double offsetForYear(int year, List<AlbumMonth> months) {
    var offset = timelineTopPadding;
    for (final month in months) {
      if (month.month.year > year) {
        offset += monthHeight(month);
      } else {
        break;
      }
    }
    return offset;
  }

  double offsetForUndated(List<AlbumMonth> months) {
    var offset = timelineTopPadding;
    for (final month in months) {
      offset += monthHeight(month);
    }
    return offset;
  }
}

class AlbumMosaicCell {
  final int photoIndex;
  final double width;
  final double height;

  const AlbumMosaicCell({
    required this.photoIndex,
    required this.width,
    required this.height,
  });
}

class AlbumMosaicRow {
  final double height;
  final bool stackedRight;
  final List<AlbumMosaicCell> cells;

  const AlbumMosaicRow({
    required this.height,
    required this.stackedRight,
    required this.cells,
  });
}

class AlbumMosaicDay {
  final List<AlbumMosaicRow> rows;

  const AlbumMosaicDay({required this.rows});

  double get height {
    if (rows.isEmpty) return 0;
    return rows.fold<double>(0, (sum, row) => sum + row.height) +
        (rows.length - 1) * AlbumMosaicLayout.gap;
  }
}

/// The timeline slivers: sticky month headers, a day header, then the mosaic
/// rows. Rows are lazy; tiny prints decode at their own size.
List<Widget> buildAlbumMosaicSlivers({
  required AlbumData data,
  required AlbumMosaicLayout layout,
  BoxFit photoFit = BoxFit.cover,
  AlbumPrintStyle printStyle = AlbumPrintStyle.classic,
  required void Function(List<AlbumPhoto> photos, int index) onOpenPhoto,
}) {
  final indexByPhoto = <AlbumPhoto, int>{
    for (var i = 0; i < data.photos.length; i++) data.photos[i]: i,
  };
  final slivers = <Widget>[
    const SliverToBoxAdapter(
      child: SizedBox(height: AlbumMosaicLayout.timelineTopPadding),
    ),
  ];
  for (final month in data.months) {
    slivers.add(
      SliverPersistentHeader(
        pinned: true,
        delegate: _MonthHeaderDelegate(
          month: month,
          extent: AlbumMosaicLayout.monthHeaderHeight,
        ),
      ),
    );
    // A delegate per day forces Flutter to lay out its first photo row even
    // off screen (to estimate scroll extent). One delegate per month starts
    // with a cheap day header and creates photo tiles only near the viewport.
    final entries = <WidgetBuilder>[];
    final extents = <double>[];
    for (final day in month.days) {
      extents.add(AlbumMosaicLayout.dayHeaderHeight);
      entries.add((context) => SizedBox(
            height: AlbumMosaicLayout.dayHeaderHeight,
            child: AlbumDayHeader(day: day.day, count: day.count),
          ));
      final plan = layout.planDay(day.count);
      for (var index = 0; index < plan.rows.length; index++) {
        final row = plan.rows[index];
        final last = index == plan.rows.length - 1;
        extents.add(row.height + (last ? 0 : AlbumMosaicLayout.gap));
        entries.add((context) => Padding(
              padding: EdgeInsets.fromLTRB(
                AlbumMosaicLayout.horizontalPadding,
                0,
                AlbumMosaicLayout.horizontalPadding,
                last ? 0 : AlbumMosaicLayout.gap,
              ),
              child: _MosaicRowView(
                row: row,
                day: day,
                data: data,
                indexByPhoto: indexByPhoto,
                photoFit: photoFit,
                printStyle: printStyle,
                onOpenPhoto: onOpenPhoto,
              ),
            ));
      }
      extents.add(AlbumMosaicLayout.dayBottomGap);
      entries.add(
          (context) => const SizedBox(height: AlbumMosaicLayout.dayBottomGap));
    }
    slivers.add(SliverVariedExtentList(
        itemExtentBuilder: (index, _) =>
            index < extents.length ? extents[index] : null,
        delegate: _MonthRowsDelegate(
          (context, index) => entries[index](context),
          totalExtent: extents.fold(0, (total, extent) => total + extent),
          childCount: entries.length,
          addAutomaticKeepAlives: false,
        )));
    slivers.add(
      const SliverToBoxAdapter(
        child: SizedBox(height: AlbumMosaicLayout.monthBottomGap),
      ),
    );
  }
  final undated = data.undatedDay;
  if (undated != null) {
    slivers.add(
      SliverPersistentHeader(
        pinned: true,
        delegate: _undatedHeaderDelegate(undated.count),
      ),
    );
    slivers.add(
      _mosaicList(undated, layout, data, indexByPhoto, onOpenPhoto, photoFit,
          printStyle),
    );
    slivers.add(
      const SliverToBoxAdapter(
        child: SizedBox(height: AlbumMosaicLayout.monthBottomGap),
      ),
    );
  }
  return slivers;
}

/// The default delegate extrapolates from the first (44px) day header,
/// underestimating hidden months and clamping calendar jumps too early.
class _MonthRowsDelegate extends SliverChildBuilderDelegate {
  final double totalExtent;

  _MonthRowsDelegate(
    super.builder, {
    required this.totalExtent,
    required super.childCount,
    super.addAutomaticKeepAlives,
  });

  @override
  double estimateMaxScrollOffset(int firstIndex, int lastIndex,
          double leadingScrollOffset, double trailingScrollOffset) =>
      totalExtent;
}

Widget _mosaicList(
  AlbumDay day,
  AlbumMosaicLayout layout,
  AlbumData data,
  Map<AlbumPhoto, int> indexByPhoto,
  void Function(List<AlbumPhoto> photos, int index) onOpenPhoto,
  BoxFit photoFit,
  AlbumPrintStyle printStyle,
) {
  final plan = layout.planDay(day.count);
  if (plan.rows.isEmpty) {
    return const SliverToBoxAdapter(child: SizedBox.shrink());
  }
  return SliverPadding(
    padding: const EdgeInsets.symmetric(
        horizontal: AlbumMosaicLayout.horizontalPadding),
    sliver: SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final row = plan.rows[index];
          final last = index == plan.rows.length - 1;
          return Padding(
            padding: EdgeInsets.only(
              bottom: last ? 0 : AlbumMosaicLayout.gap,
            ),
            child: _MosaicRowView(
              row: row,
              day: day,
              data: data,
              indexByPhoto: indexByPhoto,
              onOpenPhoto: onOpenPhoto,
              photoFit: photoFit,
              printStyle: printStyle,
            ),
          );
        },
        childCount: plan.rows.length,
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: true,
      ),
    ),
  );
}

class _MosaicRowView extends StatelessWidget {
  final AlbumMosaicRow row;
  final BoxFit photoFit;
  final AlbumPrintStyle printStyle;
  final AlbumDay day;
  final AlbumData data;
  final Map<AlbumPhoto, int> indexByPhoto;
  final void Function(List<AlbumPhoto> photos, int index) onOpenPhoto;

  const _MosaicRowView({
    required this.row,
    required this.photoFit,
    required this.printStyle,
    required this.day,
    required this.data,
    required this.indexByPhoto,
    required this.onOpenPhoto,
  });

  @override
  Widget build(BuildContext context) {
    if (row.cells.isEmpty) return const SizedBox.shrink();
    if (row.stackedRight) {
      final hero = row.cells.first;
      final right = row.cells.skip(1).toList(growable: false);
      return SizedBox(
        height: row.height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: hero.width,
              height: hero.height,
              child: _tile(hero),
            ),
            if (right.isNotEmpty) ...[
              const SizedBox(width: AlbumMosaicLayout.gap),
              SizedBox(
                width: right.first.width,
                height: row.height,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    for (var i = 0; i < right.length; i++) ...[
                      if (i > 0) const SizedBox(height: AlbumMosaicLayout.gap),
                      SizedBox(
                        width: right[i].width,
                        height: right[i].height,
                        child: _tile(right[i]),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        height: row.height,
        child: Row(
          children: [
            for (var i = 0; i < row.cells.length; i++) ...[
              if (i > 0) const SizedBox(width: AlbumMosaicLayout.gap),
              SizedBox(
                width: row.cells[i].width,
                height: row.cells[i].height,
                child: _tile(row.cells[i]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tile(AlbumMosaicCell cell) {
    final photo = day.photos[cell.photoIndex];
    final decodeWidth = (cell.width * 1.8).round().clamp(120, 560).toInt();
    return AlbumPhotoTile(
      photo: photo,
      fit: photoFit,
      printStyle: printStyle,
      cacheWidth: decodeWidth,
      onTap: () => onOpenPhoto(data.photos, indexByPhoto[photo] ?? 0),
    );
  }
}

class _MonthHeaderDelegate extends SliverPersistentHeaderDelegate {
  final AlbumMonth month;
  final double extent;

  const _MonthHeaderDelegate({required this.month, required this.extent});

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return SizedBox(
      height: extent,
      child: AlbumMonthHeader(month: month),
    );
  }

  @override
  bool shouldRebuild(covariant _MonthHeaderDelegate oldDelegate) =>
      oldDelegate.month.month != month.month ||
      oldDelegate.month.count != month.count ||
      oldDelegate.extent != extent;
}

class _UndatedHeaderDelegate extends SliverPersistentHeaderDelegate {
  final int count;
  final double extent;

  const _UndatedHeaderDelegate({required this.count, required this.extent});

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return SizedBox(
      height: extent,
      child: AlbumUndatedHeader(count: count),
    );
  }

  @override
  bool shouldRebuild(covariant _UndatedHeaderDelegate oldDelegate) =>
      oldDelegate.count != count || oldDelegate.extent != extent;
}

SliverPersistentHeaderDelegate _undatedHeaderDelegate(int count) =>
    _UndatedHeaderDelegate(
      count: count,
      extent: AlbumMosaicLayout.monthHeaderHeight,
    );
