import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/services/settings_service.dart';
import 'package:ota_counter/theme/app_theme.dart';
import 'package:ota_counter/widgets/counter_card.dart';

const _physicalSize = Size(1440, 3168);
const _devicePixelRatio = 3.5;
const _horizontalPagePadding = 16.0;
const _groupName = 'PokaPokaTime';
const _cardScales = [1.0, 1.15, 1.3];

class _CardFixture {
  final String name;
  final String color;
  final int threeInch;
  final int fiveInch;
  final int threeInchShukudai;
  final int fiveInchShukudai;

  const _CardFixture({
    required this.name,
    required this.color,
    this.threeInch = 0,
    this.fiveInch = 0,
    this.threeInchShukudai = 0,
    this.fiveInchShukudai = 0,
  });

  int get total =>
      threeInch + fiveInch + threeInchShukudai + fiveInchShukudai;

  List<CounterCountBadgeData> get breakdown => [
        CounterCountBadgeData(label: '3寸', value: threeInch),
        CounterCountBadgeData(label: '5寸', value: fiveInch),
        CounterCountBadgeData(label: '3寸宿', value: threeInchShukudai),
        CounterCountBadgeData(label: '5寸宿', value: fiveInchShukudai),
      ];
}

const _fixtures = <_CardFixture>[
  _CardFixture(
    name: '皮皮猪',
    color: '#FF5C8A',
    threeInch: 12,
    fiveInch: 7,
    threeInchShukudai: 3,
    fiveInchShukudai: 4,
  ),
  _CardFixture(
    name: '夏小米',
    color: '#8B6CF0',
    threeInch: 2,
  ),
  _CardFixture(
    name: '桃菓_momoka',
    color: '#FF9F43',
  ),
];
const _allSpecLabels = ['3寸', '5寸', '3寸宿', '5寸宿'];

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

Widget _cardFor(_CardFixture fixture, int columns) {
  return CounterCard(
    key: ValueKey<String>('counter-card-${fixture.name}'),
    counter: CounterModel(
      name: fixture.name,
      groupName: _groupName,
      color: fixture.color,
      threeInchCount: fixture.threeInch,
      fiveInchCount: fixture.fiveInch,
      threeInchShukudaiCount: fixture.threeInchShukudai,
      fiveInchShukudaiCount: fixture.fiveInchShukudai,
      isHidden: fixture.name == '桃菓_momoka',
    ),
    totalCount: fixture.total,
    breakdownEntries: fixture.breakdown,
    percentage: 0.42,
    onTap: () {},
    onDelete: () {},
    onEdit: () {},
    gridColumns: columns,
  );
}

Widget _gridApp({required int columns, required double cardHeight}) {
  final cards = [for (final fixture in _fixtures) _cardFor(fixture, columns)];

  if (columns <= 2) {
    // Mirrors the home page: 1/2 columns use intrinsically sized cards in
    // rows, so a card with no chips does not reserve empty space.
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(_horizontalPagePadding),
            child: SizedBox(
              width: _contentWidth(),
              child: Column(
                children: [
                  for (var i = 0; i < cards.length; i += columns)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: i < cards.length
                                ? cards[i]
                                : const SizedBox.shrink(),
                          ),
                          if (columns == 2) const SizedBox(width: 12),
                          if (columns == 2)
                            Expanded(
                              child: i + 1 < cards.length
                                  ? cards[i + 1]
                                  : const SizedBox.shrink(),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

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
              itemCount: cards.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: _crossAxisSpacing(columns),
                mainAxisSpacing: columns >= 3 ? 12 : 16,
                mainAxisExtent: cardHeight,
              ),
              itemBuilder: (context, index) => cards[index],
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

Finder _cardFinder(String name) =>
    find.byKey(ValueKey<String>('counter-card-$name'));

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

          SettingsService.fontScale.value = scale;
          final cardWidth = _cardWidth(columns);
          final cardHeight = counterCardHeight(
            gridColumns: columns,
            availableWidth: _contentWidth(),
            crossAxisSpacing: _crossAxisSpacing(columns),
            textScale: scale,
            breakdownEntryCount: 4,
          );

          await tester.pumpWidget(
            _gridApp(columns: columns, cardHeight: cardHeight),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);

          for (final fixture in _fixtures) {
            final finder = _cardFinder(fixture.name);
            expect(finder, findsOneWidget);
            final cardRect = tester.getRect(finder);
            expect(
              cardRect.width,
              closeTo(cardWidth, 0.1),
              reason: 'the grid should use the expected card width',
            );
            expect(cardRect.height, greaterThan(0));
          }

          for (final fixture in _fixtures.take(2)) {
            _expectNameOnOneLine(
              tester,
              fixture.name,
              columns: columns,
              cardWidth: cardWidth,
              scale: scale,
            );
          }

          final groupFinder = find.text(_groupName);
          expect(groupFinder, findsNWidgets(_fixtures.length));
          for (var i = 0; i < groupFinder.evaluate().length; i++) {
            final text = tester.widget<Text>(groupFinder.at(i));
            expect(text.maxLines, 1);
          }

          if (columns <= 2) {
            final fullCard = _cardFinder('皮皮猪');
            _expectChipsInsideCard(tester, fullCard, [
              for (final label in _allSpecLabels) (label, true)
            ]);

            final oneChipCard = _cardFinder('夏小米');
            _expectChipsInsideCard(tester, oneChipCard, [
              ('3寸', true),
              ('5寸', false),
              ('3寸宿', false),
              ('5寸宿', false),
            ]);

            final emptyCard = _cardFinder('桃菓_momoka');
            _expectChipsInsideCard(tester, emptyCard, [
              for (final label in _allSpecLabels) (label, false)
            ]);

            // The empty card really is shorter instead of leaving the old
            // four-row blank area at the bottom of a fixed grid extent.
            final fullRect = tester.getRect(fullCard);
            final emptyRect = tester.getRect(emptyCard);
            expect(
              emptyRect.height,
              lessThan(fullRect.height),
              reason: 'a card with no chips should shrink to its content',
            );
          } else {
            // 3-5 columns stay on the compact layout: no chip row at all.
            for (final label in _allSpecLabels) {
              expect(find.text(label), findsNothing);
            }
          }

          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('all-zero 2-column card draws no spec chips', (tester) async {
    tester.view.physicalSize = _physicalSize;
    tester.view.devicePixelRatio = _devicePixelRatio;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: _cardWidth(2),
              child: _cardFor(_fixtures.last, 2),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('3寸'), findsNothing);
    expect(find.text('5寸'), findsNothing);
    expect(find.text('3寸宿'), findsNothing);
    expect(find.text('5寸宿'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

void _expectChipsInsideCard(
  WidgetTester tester,
  Finder cardFinder,
  List<(String, bool)> expectations,
) {
  final cardRect = tester.getRect(cardFinder);
  for (final entry in expectations) {
    final label = entry.$1;
    final shouldShow = entry.$2;
    final chipFinder = find.descendant(
      of: cardFinder,
      matching: find.byKey(ValueKey<String>('count-chip-$label')),
    );
    expect(
      chipFinder,
      shouldShow ? findsOneWidget : findsNothing,
      reason: '$label chip visibility at 2 columns',
    );
    if (shouldShow) {
      final chipRect = tester.getRect(chipFinder);
      expect(chipRect.top, greaterThanOrEqualTo(cardRect.top - 0.1));
      expect(chipRect.bottom, lessThanOrEqualTo(cardRect.bottom + 0.1));
      expect(chipRect.left, greaterThanOrEqualTo(cardRect.left - 0.1));
      expect(chipRect.right, lessThanOrEqualTo(cardRect.right + 0.1));
    }
  }
}
