import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ota_counter/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('app boots to home page', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('切奇总览'), findsOneWidget);
    expect(find.textContaining('新增'), findsOneWidget);
  });

  testWidgets('recent records page can be opened from overflow menu', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    expect(find.text('最近提交记录'), findsOneWidget);

    await tester.tap(find.text('最近提交记录').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('最近提交记录'), findsAtLeastNWidgets(1));
  });
}
