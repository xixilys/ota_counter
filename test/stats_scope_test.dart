import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/pages/chart_page.dart';

void main() {
  test('month navigation does not skip February from a month-end anchor', () {
    final shifted = StatsScope.month.shift(DateTime(2026, 1, 31), 1);

    expect(shifted.year, 2026);
    expect(shifted.month, 2);
  });

  test('year navigation clamps leap day to the target year', () {
    final shifted = StatsScope.year.shift(DateTime(2024, 2, 29), 1);

    expect(shifted, DateTime(2025, 2, 28));
  });
}
