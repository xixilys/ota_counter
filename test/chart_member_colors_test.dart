import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/pages/chart_page.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/face/face_recognition_rules.dart';
import 'package:ota_counter/theme/app_theme.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => useIsolatedTestDatabases());
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService.clearAppData();
  });

  testWidgets('calendar marks and pie slices use the members 応援色',
      (tester) async {
    const palette = [
      (name: '樱', color: '#FF5C8A'),
      (name: '海', color: '#1FB5A8'),
      (name: '光', color: '#F5B700'),
    ];
    final day = activityDayOf(DateTime.now());
    await tester.runAsync(() async {
      for (final item in palette) {
        final counter = CounterModel(
          name: item.name,
          groupName: 'G',
          color: item.color,
        );
        final id = await DatabaseService.insertCounter(counter);
        await DatabaseService.insertActivityRecord(
          ActivityRecordModel.counterAdjustment(
            counter: counter.copyWith(id: id),
            occurredAt: day,
            deltas: const {CounterCountField.threeInch: 1},
          ),
        );
      }
    });

    await tester.binding.setSurfaceSize(const Size(1400, 14000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: const ChartPage(),
      ));
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();

    final expected = [
      for (final item in palette)
        AppTheme.readableAccent(_parse(item.color), Brightness.light),
    ];

    final slices = tester
        .widgetList<PieChart>(find.byType(PieChart))
        .expand((chart) => chart.data.sections)
        .toList();
    for (final color in expected) {
      expect(
        slices.where((slice) => slice.color == color),
        isNotEmpty,
        reason: 'member pie should use $color',
      );
    }

    final bars = tester
        .widgetList<Container>(find.descendant(
          of: find.byType(GridView),
          matching: find.byType(Container),
        ))
        .where((container) {
      final decoration = container.decoration;
      if (decoration is! BoxDecoration || decoration.color == null) {
        return false;
      }
      return expected.contains(decoration.color);
    }).toList();
    expect(bars, isNotEmpty,
        reason: 'calendar with records should draw member colour marks');

    expect(tester.takeException(), isNull);
  });
}

Color _parse(String hex) {
  return Color(int.parse('FF${hex.substring(1)}', radix: 16));
}
