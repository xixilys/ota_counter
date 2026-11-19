import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ota_counter/models/album_preferences.dart';
import 'package:ota_counter/pages/album/album_models.dart';
import 'package:ota_counter/pages/album/album_widgets.dart';
import 'package:ota_counter/theme/app_theme.dart';

void main() {
  test('supporter paper keeps caption ink readable in both themes', () {
    for (final brightness in Brightness.values) {
      for (final hex in [
        '#FF7A9E',
        '#7C6CF0',
        '#FFFF00',
        '#000000',
        '#FFFFFF',
        ''
      ]) {
        final paper =
            albumCaptionPaper(hex, brightness, AlbumPrintStyle.supporter);
        expect(
            albumContrastRatio(
                albumAccent(hex, brightness, paper: paper), paper),
            greaterThanOrEqualTo(4.5));
        expect(albumContrastRatio(albumPrintInk(brightness), paper),
            greaterThanOrEqualTo(4.5));
      }
    }
  });

  testWidgets(
      'print style changes paper only: photo and text geometry stay unchanged',
      (tester) async {
    final photo = AlbumPhoto(
        path: '/missing-generated-preview.png',
        isScan: true,
        mediaLabel: '切图',
        specLabel: '3寸',
        activityDay: DateTime(2026, 11, 17),
        sessionKey: 'sample',
        members: const [
          AlbumMemberRef(
              key: 'p', name: '林小满', groupName: 'Aurora', colorHex: '#FF7A9E')
        ]);
    for (final brightness in Brightness.values) {
      Rect? originalPhoto, originalCaption, originalName;
      for (final style in AlbumPrintStyle.values) {
        await tester.pumpWidget(MaterialApp(
            theme: brightness == Brightness.light
                ? AppTheme.light()
                : AppTheme.dark(),
            home: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
                child: Scaffold(
                    body: Center(
                        child: SizedBox(
                            width: 160,
                            height: 280,
                            child: AlbumPhotoTile(
                                photo: photo,
                                onTap: () {},
                                printStyle: style)))))));
        await tester.pumpAndSettle();
        final image = tester.getRect(find.byType(AlbumPhotoThumb));
        final caption = tester.getRect(find.byType(AlbumPrintCaption));
        final name = tester.getRect(find.text('林小满'));
        if (style == AlbumPrintStyle.classic) {
          originalPhoto = image;
          originalCaption = caption;
          originalName = name;
        } else {
          expect(image, originalPhoto);
          expect(caption, originalCaption);
          expect(name, originalName);
        }
        expect(tester.getRect(find.text('11.17')).bottom,
            lessThanOrEqualTo(caption.bottom - 2));
        expect(tester.takeException(), isNull);
      }
    }
  });
}
