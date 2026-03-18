import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/widgets/counter_card.dart';
import 'package:ota_counter/widgets/counter_count_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('counter card breakdown keeps group cut visible', (
    WidgetTester tester,
  ) async {
    final counter = CounterModel(
      name: '成员A',
      groupName: '团体A',
      color: '#FFE135',
      threeInchCount: 2,
      groupCutCount: 3,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 220,
              height: 260,
              child: CounterCard(
                counter: counter,
                percentage: 0.5,
                onTap: () {},
                onDelete: () {},
                onEdit: () {},
                gridColumns: 2,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('团切'), findsOneWidget);
  });

  testWidgets('counter sheet shows group cut as read only', (
    WidgetTester tester,
  ) async {
    final counter = CounterModel(
      name: '成员A',
      groupName: '团体A',
      color: '#FFE135',
      groupCutCount: 4,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CounterCountSheet(
            counter: counter,
            allCounters: [counter],
            onCounterChanged: (updatedCounter, occurredAt) async =>
                updatedCounter,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('团切'), findsOneWidget);
    expect(find.text('只读'), findsOneWidget);
    expect(find.text('团切请通过多人切记录处理，这里仅展示当前累计数量。'), findsOneWidget);
  });

  testWidgets('counter sheet quick count keeps edit and additive buttons', (
    WidgetTester tester,
  ) async {
    final counter = CounterModel(
      name: '成员A',
      groupName: '团体A',
      color: '#FFE135',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CounterCountSheet(
            counter: counter,
            allCounters: [counter],
            onCounterChanged: (updatedCounter, occurredAt) async =>
                updatedCounter,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.remove), findsNothing);
    expect(find.text('+1'), findsWidgets);
    expect(find.text('+5'), findsWidgets);
    expect(find.text('+10'), findsWidgets);
    expect(find.text('+50'), findsWidgets);
    expect(find.text('+100'), findsNothing);

    await tester.tap(find.text('+10').first);
    await tester.pumpAndSettle();

    expect(find.text('总计 10'), findsOneWidget);

    await tester.tap(find.text('10').first);
    await tester.pumpAndSettle();

    expect(find.text('修改3寸'), findsOneWidget);
  });
}
