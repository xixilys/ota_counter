import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ota_counter/models/album_preferences.dart';
import 'package:ota_counter/pages/album/album_preferences_sheet.dart';
import 'package:ota_counter/pages/album/album_timeline_mosaic.dart';
import 'package:ota_counter/services/settings_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults preserve Dream and settings survive a fresh preferences read',
      () async {
    final defaults = await SettingsService.getAlbumPreferences();
    expect(defaults.columns, 0);
    expect(defaults.printStyle, AlbumPrintStyle.classic);
    expect(defaults.collage && defaults.fillPhotos && defaults.showShelves,
        isTrue);
    await SettingsService.saveAlbumPreferences(const AlbumPreferences(
      printStyle: AlbumPrintStyle.supporter,
      columns: 2,
      collage: false,
      fillPhotos: false,
      showShelves: false,
    ));
    SharedPreferences.resetStatic();
    final restored = await SettingsService.getAlbumPreferences();
    expect(restored.columns, 2);
    expect(restored.printStyle, AlbumPrintStyle.supporter);
    expect(restored.collage || restored.fillPhotos || restored.showShelves,
        isFalse);
  });

  test(
      'invalid stored columns recover to adaptive; invalid writes are rejected',
      () async {
    SharedPreferences.setMockInitialValues({'cheki_album_columns': 99});
    expect((await SettingsService.getAlbumPreferences()).columns, 0);
    await expectLater(
        SettingsService.saveAlbumPreferences(
          const AlbumPreferences(columns: 1),
        ),
        throwsArgumentError);
  });

  test('configured grid retains every photo with matching section geometry',
      () {
    for (final columns in [2, 3, 4]) {
      final layout = AlbumMosaicLayout(
          viewportWidth: 393, preferredColumns: columns, collage: false);
      final plan = layout.planDay(11);
      expect(plan.rows.every((row) => !row.stackedRight), isTrue);
      expect(plan.rows.first.cells.length, columns);
      expect([
        for (final row in plan.rows)
          for (final cell in row.cells) cell.photoIndex
      ], List.generate(11, (i) => i));
      expect(layout.dayHeight(11), plan.height + 50);
    }
  });

  testWidgets(
      'sheet saves explicit choices and cancelling leaves stored values alone',
      (tester) async {
    AlbumPreferences? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () async {
                        result = await showModalBottomSheet<AlbumPreferences>(
                            context: context,
                            isScrollControlled: true,
                            builder: (_) => const AlbumPreferencesSheet(
                                initial: AlbumPreferences()));
                      },
                      child: const Text('open')),
                ))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应援印边'));
    await tester.ensureVisible(find.text('2 列'));
    await tester.tap(find.text('2 列'));
    await tester.ensureVisible(find.text('每天一张主打'));
    await tester.tap(find.text('每天一张主打'));
    await tester.ensureVisible(find.text('时间线照片铺满相框'));
    await tester.tap(find.text('时间线照片铺满相框'));
    await tester.ensureVisible(find.text('首页展示收藏架'));
    await tester.tap(find.text('首页展示收藏架'));
    await tester.ensureVisible(find.text('保存显示设置'));
    await tester.tap(find.text('保存显示设置'));
    await tester.pumpAndSettle();
    expect(result?.columns, 2);
    expect(result?.showShelves, false);
    final saved = await SettingsService.getAlbumPreferences();
    expect(saved.columns, 2);
    expect(saved.printStyle, AlbumPrintStyle.supporter);
    expect(saved.collage || saved.fillPhotos || saved.showShelves, false);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应援印边'));
    await tester.ensureVisible(find.text('4 列'));
    await tester.tap(find.text('4 列'));
    Navigator.of(tester.element(find.text('4 列'))).pop();
    await tester.pumpAndSettle();
    expect((await SettingsService.getAlbumPreferences()).columns, 2);
    expect((await SettingsService.getAlbumPreferences()).printStyle,
        AlbumPrintStyle.supporter);
    expect(tester.takeException(), isNull);
  });
}
