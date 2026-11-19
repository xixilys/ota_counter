import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/pages/chart_page.dart';
import 'package:ota_counter/services/database_service.dart';

import 'support/isolated_test_databases.dart';

Finder _byType(String type) =>
    find.byWidgetPredicate((widget) => widget.runtimeType.toString() == type);

Future<void> _openChart(
  WidgetTester tester, {
  required double textScale,
}) async {
  tester.view.physicalSize = const Size(1200, 7200);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const ChartPage(),
      ),
    );
    for (var i = 0;
        i < 200 && _byType('_CalendarDayDetailCard').evaluate().isEmpty;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  });
  await tester.pumpAndSettle();
  expect(_byType('_CalendarDayDetailCard'), findsOneWidget);
}

void main() {
  setUpAll(() async => useIsolatedTestDatabases());

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService.clearAppData();
  });

  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('period switch keeps 5 labels on one row at $scale×',
        (tester) async {
      await _openChart(tester, textScale: scale);

      final labels = ['日统计', '周统计', '月统计', '年统计', '全部'];
      final tops = <double>{};
      var left = double.infinity;
      var right = -double.infinity;
      for (final label in labels) {
        final finder = find.text(label);
        expect(finder, findsOneWidget, reason: '$label should render once');
        final rect = tester.getRect(finder);
        // FittedBox scales the *glyph*, which can nudge a single label's
        // baseline by a hair; compare the ink bands instead of 1px exactness.
        tops.add((rect.top / 4).roundToDouble());
        left = rect.left < left ? rect.left : left;
        right = rect.right > right ? rect.right : right;
        expect(rect.width, greaterThan(0));
      }
      expect(
        tops,
        hasLength(1),
        reason: 'all five period labels must share one line, got tops $tops',
      );
      final screenWidth = tester.view.physicalSize.width /
          tester.view.devicePixelRatio;
      expect(left, greaterThanOrEqualTo(0));
      expect(right, lessThanOrEqualTo(screenWidth));
      expect(tester.takeException(), isNull);
    });
  }
}
