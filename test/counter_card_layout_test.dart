import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/services/settings_service.dart';
import 'package:ota_counter/theme/app_theme.dart';
import 'package:ota_counter/widgets/counter_card.dart';

const _physicalSize = Size(1440, 3168);
const _devicePixelRatio = 3.5;
const _horizontalPagePadding = 16.0;
const _breakdown = <CounterCountBadgeData>[
  CounterCountBadgeData(label: '3寸', value: 12),
  CounterCountBadgeData(label: '5寸', value: 7),
  CounterCountBadgeData(label: '3寸宿', value: 3),
  CounterCountBadgeData(label: '5寸宿', value: 4),
];
const _memberNames = ['皮皮猪', '夏小米', '桃菓_momoka'];
const _groupName = 'PokaPokaTime';
const _cardScales = [1.0, 1.15, 1.3];

double _logicalWidth() => _physicalSize.width / _devicePixelRatio;

double _contentWidth() => _logicalWidth() - _horizontalPagePadding * 2;

double _crossAxisSpacing(int columns) => columns >= 4 ? 10.0 : 12.0;

double _cardWidth(int columns) {
  final spacing = _crossAxisSpacing(columns);
  return (_contentWidth() - (columns - 1) * spacing) / columns;
}

double _nameFontSize(int columns, double cardWidth) {
  if (columns <= 2) {
    return cardWidth < 190 ? 15.0 : 17.0;
  }
  if (columns >= 5) {
    return 9.5;
  }
  return columns >= 4 ? 10.5 : 11.5;
}

double _nameLineHeight(int columns, double cardWidth, double scale) {
  final factor = columns <= 2 ? 1.18 : 1.12;
  return _nameFontSize(columns, cardWidth) * factor * scale;
}

Widget _gridApp({
  required int columns,
  required double cardHeight,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    home: Scaffold(
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(_horizontalPagePadding),
          child: SizedBox(
            width: _contentWidth(),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _memberNames.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: _crossAxisSpacing(columns),
                mainAxisSpacing: columns >= 3 ? 12 : 16,
                mainAxisExtent: cardHeight,
              ),
              itemBuilder: (context, index) {
                final name = _memberNames[index];
                final counter = CounterModel(
                  name: name,
                  groupName: _groupName,
                  color: const ['#FF5C8A', '#8B6CF0', '#FF9F43'][index],
                  threeInchCount: 12,
                  fiveInchCount: 7,
                  threeInchShukudaiCount: 3,
                  fiveInchShukudaiCount: 4,
                  isHidden: name == '桃菓_momoka',
                );
                return CounterCard(
                  key: ValueKey('counter-card-$name'),
                  counter: counter,
                  totalCount: 26,
                  breakdownEntries: _breakdown,
                  percentage: 0.42,
                  onTap: () {},
                  onDelete: () {},
                  onEdit: () {},
                  gridColumns: columns,
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}

void _expectNameOnOneLine(
  WidgetTester tester,
  String name, {
  required int columns,
  required double cardWidth,
  required double scale,
}) {
  final finder = find.text(name);
  expect(finder, findsOneWidget, reason: '$name should render once');
  final box = tester.renderObject<RenderBox>(finder);
  final oneLine = _nameLineHeight(columns, cardWidth, scale);
  expect(
    box.size.height,
    lessThanOrEqualTo(oneLine + 1.5),
    reason: '$name at $columns columns / scale $scale should fit one line '
        '(height ${box.size.height}, one line $oneLine)',
  );
}

void _expectBreakdownInsideCard(
  WidgetTester tester,
  Finder cardFinder,
) {
  final cardRect = tester.getRect(cardFinder);
  for (final entry in _breakdown) {
    final labelFinder = find.descendant(
      of: cardFinder,
      matching: find.text(entry.label),
    );
    expect(
      labelFinder,
      findsOneWidget,
      reason: '${entry.label} should be painted in the card',
    );
    final badgeFinder = find.descendant(
      of: cardFinder,
      matching: find.byKey(ValueKey<String>('count-badge-${entry.label}')),
    );
    expect(
      badgeFinder,
      findsOneWidget,
      reason: '${entry.label} badge should be painted in the card',
    );
    final labelRect = tester.getRect(labelFinder);
    final badgeRect = tester.getRect(badgeFinder);
    for (final rect in [labelRect, badgeRect]) {
      expect(rect.top, greaterThanOrEqualTo(cardRect.top - 0.1));
      expect(rect.bottom, lessThanOrEqualTo(cardRect.bottom + 0.1));
      expect(rect.left, greaterThanOrEqualTo(cardRect.left - 0.1));
      expect(rect.right, lessThanOrEqualTo(cardRect.right + 0.1));
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SettingsService.fontScale.value = 1.0;
  });

  tearDown(() {
    SettingsService.fontScale.value = 1.0;
  });

  for (final columns in [1, 2, 3, 4, 5]) {
    for (final scale in _cardScales) {
      testWidgets(
        'member cards: $columns columns × $scale scale',
        (tester) async {
          tester.view.physicalSize = _physicalSize;
          tester.view.devicePixelRatio = _devicePixelRatio;
          addTearDown(tester.view.reset);

          // Exercise the real 卡片字号 setting path, not just a constructor arg.
          SettingsService.fontScale.value = scale;
          final cardWidth = _cardWidth(columns);
          final cardHeight = counterCardHeight(
            gridColumns: columns,
            availableWidth: _contentWidth(),
            crossAxisSpacing: _crossAxisSpacing(columns),
            textScale: scale,
            breakdownEntryCount: _breakdown.length,
          );

          await tester.pumpWidget(
            _gridApp(columns: columns, cardHeight: cardHeight),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);

          for (final name in _memberNames) {
            final cardFinder =
                find.byKey(ValueKey<String>('counter-card-$name'));
            expect(cardFinder, findsOneWidget);
            final cardRect = tester.getRect(cardFinder);
            expect(
              cardRect.width,
              closeTo(cardWidth, 0.1),
              reason: 'the grid should use the expected card width',
            );
          }

          for (final name in ['皮皮猪', '夏小米']) {
            _expectNameOnOneLine(
              tester,
              name,
              columns: columns,
              cardWidth: cardWidth,
              scale: scale,
            );
          }

          final groupFinder = find.text(_groupName);
          expect(groupFinder, findsNWidgets(_memberNames.length));
          for (var i = 0; i < groupFinder.evaluate().length; i++) {
            final text = tester.widget<Text>(groupFinder.at(i));
            expect(text.maxLines, 1);
          }

          if (columns <= 2) {
            for (final name in _memberNames) {
              _expectBreakdownInsideCard(
                tester,
                find.byKey(ValueKey<String>('counter-card-$name')),
              );
            }
          }
        },
      );
    }
  }
}
