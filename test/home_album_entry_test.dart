import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/main.dart';
import 'package:ota_counter/pages/album/album_page.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/idol_database_service.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await useIsolatedTestDatabases();
    await DatabaseService.database;
    await IdolDatabaseService.initializeBuiltInDataIfNeeded();
  });

  testWidgets('切册 opens directly from the upper half of the home screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(720, 1520);
    tester.view.devicePixelRatio = 2;
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.runAsync(() => tester.pumpWidget(const MyApp()));
    final entry = find.widgetWithText(FilledButton, '切册');
    expect(entry.hitTestable(), findsOneWidget);
    expect(tester.getRect(entry).bottom, lessThan(380));

    await tester.runAsync(() async {
      await tester.tap(entry);
      await tester.pump();
    });
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(AlbumPage), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(AlbumPage), findsNothing);
    expect(entry.hitTestable(), findsOneWidget);
    expect(find.textContaining('新增').hitTestable(), findsOneWidget);
    expect(find.text('查看统计').hitTestable(), findsOneWidget);
  });
}
