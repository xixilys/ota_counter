enum AlbumPrintStyle { classic, supporter }

/// Display choices for the cheki landing page, independent of counter cards.
class AlbumPreferences {
  final int columns; // 0 = adaptive
  final bool collage;
  final bool fillPhotos;
  final bool showShelves;
  final AlbumPrintStyle printStyle;

  const AlbumPreferences({
    this.columns = 0,
    this.collage = true,
    this.fillPhotos = true,
    this.showShelves = true,
    this.printStyle = AlbumPrintStyle.classic,
  });

  AlbumPreferences copyWith({
    int? columns,
    bool? collage,
    bool? fillPhotos,
    bool? showShelves,
    AlbumPrintStyle? printStyle,
  }) =>
      AlbumPreferences(
        columns: columns ?? this.columns,
        collage: collage ?? this.collage,
        fillPhotos: fillPhotos ?? this.fillPhotos,
        showShelves: showShelves ?? this.showShelves,
        printStyle: printStyle ?? this.printStyle,
      );
}
