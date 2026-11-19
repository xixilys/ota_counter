import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/pages/album/album_page.dart';
import 'package:ota_counter/theme/app_theme.dart';

import 'support/isolated_test_databases.dart';

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(860, 1864);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _app({required Widget home}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    locale: const Locale('zh', 'CN'),
    home: home,
  );
}

Future<void> _settle(WidgetTester tester) async {
  // SQLite initialization runs on real I/O time; do not enter the fake-clock
  // pumpAndSettle while its loading spinner is still waiting on the database.
  for (var i = 0; i < 500; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // AlbumPage only reads on an empty archive; no image files are needed.
    final dir = await useIsolatedTestDatabases();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '${dir.path}/documents',
    );
  });

  testWidgets('empty album shows the empty print and no year jump', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(home: const AlbumPage()));
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('还没有切图'), findsOneWidget);
    expect(find.byIcon(Icons.calendar_month_rounded), findsNothing);
  });

  testWidgets('empty member filter still names the member', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        home: const AlbumPage(
          memberPersonId: 999,
          memberName: '小春',
          memberGroupName: 'Unknown',
        ),
      ),
    );
    await _settle(tester);

    expect(find.text('小春的切册'), findsOneWidget);
    expect(find.text('还没有 小春 的切图'), findsOneWidget);
  });
}
