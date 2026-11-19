import 'album_models.dart';

/// Geometry shared by the timeline widgets and the year-jump offset math.
///
/// The timeline is a `CustomScrollView` whose slivers are all declared up front
/// (month headers, day headers, one lazy `SliverGrid` per day), so its total
/// extent and section offsets are deterministic from the grouped data. Keeping
/// the constants in one place means the jump lands where the user expects and
/// the widget tests can assert the same numbers.
class AlbumTimelineLayout {
  const AlbumTimelineLayout({
    required this.viewportWidth,
    this.undatedPhotoCount = 0,
  });

  static const double horizontalPadding = 16;
  static const double gridSpacing = 10;
  static const double tileAspectRatio = 0.56;
  static const double monthHeaderHeight = 48;
  static const double dayHeaderHeight = 44;
  static const double dayBottomGap = 6;
  static const double monthBottomGap = 18;
  static const double timelineTopPadding = 4;
  static const double timelineBottomPadding = 108;

  final double viewportWidth;
  final int undatedPhotoCount;

  double get contentWidth {
    final width = viewportWidth - horizontalPadding * 2;
    return width < 0 ? 0 : width;
  }

  int get columns {
    if (contentWidth < 300) return 2;
    if (contentWidth < 560) return 3;
    return 4;
  }

  double get tileWidth {
    final columns = this.columns;
    return (contentWidth - gridSpacing * (columns - 1)) / columns;
  }

  double get tileHeight => tileWidth / tileAspectRatio;

  double gridHeight(int photoCount) {
    if (photoCount <= 0) return 0;
    final rows = (photoCount + columns - 1) ~/ columns;
    return rows * tileHeight + (rows - 1) * gridSpacing;
  }

  double dayHeight(int photoCount) =>
      dayHeaderHeight + gridHeight(photoCount) + dayBottomGap;

  double monthHeight(AlbumMonth month) {
    var height = monthHeaderHeight;
    for (final day in month.days) {
      height += dayHeight(day.count);
    }
    return height + monthBottomGap;
  }

  double get undatedHeight =>
      monthHeaderHeight + gridHeight(undatedPhotoCount) + monthBottomGap;

  /// Scroll offset that puts the first month of [year] under the sticky
  /// header. Months are sorted newest first.
  double offsetForYear(int year, List<AlbumMonth> months) {
    var offset = timelineTopPadding;
    for (final month in months) {
      if (month.month.year > year) {
        offset += monthHeight(month);
      } else if (month.month.year == year) {
        // Months are newest first: reaching the first month of [year] is the
        // target itself, so do not add that year's months.
        break;
      } else {
        break;
      }
    }
    return offset;
  }

  /// Offset of the "日期不明" section after all months.
  double offsetForUndated(List<AlbumMonth> months) {
    var offset = timelineTopPadding;
    for (final month in months) {
      offset += monthHeight(month);
    }
    return offset;
  }
}
