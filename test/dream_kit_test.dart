import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/theme/app_theme.dart';
import 'package:ota_counter/widgets/dream/dream_kit.dart';

Widget _app(Brightness brightness) {
  final theme = brightness == Brightness.dark
      ? AppTheme.dark()
      : AppTheme.light();
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    home: Scaffold(
      body: DreamPaperBackground(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DreamSectionHeader(
                key: const ValueKey('section'),
                title: '八月手帐',
                countLabel: '12 位',
                eyebrow: 'MEMORY',
                trailingText: '长按可管理',
              ),
              const SizedBox(height: 16),
              PolaroidFrame(
                key: const ValueKey('polaroid'),
                tapeColor: const Color(0xFFF3C6D3),
                tapeLabel: '推し',
                photo: Container(
                  height: 120,
                  color: const Color(0xFFF7C9D9),
                  child: const Center(child: Text('切奇')),
                ),
                caption: const Text('2026.08.14 · 涩谷'),
              ),
              const SizedBox(height: 20),
              StickerBadge(
                key: const ValueKey('sticker'),
                value: '247',
                label: '张',
                color: const Color(0xFFD3245F),
                valueFontSize: 28,
                labelFontSize: 10,
              ),
              const SizedBox(height: 12),
              StickerBadge(
                key: const ValueKey('burst'),
                value: '18',
                label: '次',
                shape: StickerShape.burst,
                size: 84,
              ),
              const SizedBox(height: 20),
              TicketNotchEdge(
                key: const ValueKey('ticket'),
                color: const Color(0xFFFFF3C4),
                notchSide: TicketNotchSide.both,
                child: const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('现场门票 · 26 张'),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  for (final variant in SparkleVariant.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: SparkleMark(
                        key: ValueKey('sparkle-$variant'),
                        size: 22,
                        variant: variant,
                        dot: true,
                      ),
                    ),
                  const WashiTape(
                    key: ValueKey('tape'),
                    color: Color(0xFFB8D8EA),
                    width: 72,
                    height: 18,
                    label: '手帐',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final brightness in Brightness.values) {
    final label = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('dream kit renders every decoration in $label', (tester) async {
      tester.view.physicalSize = const Size(600, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_app(brightness));
      await tester.pump();

      expect(find.byKey(const ValueKey('section')), findsOneWidget);
      expect(find.text('八月手帐'), findsOneWidget);
      expect(find.byKey(const ValueKey('polaroid')), findsOneWidget);
      expect(find.text('切奇'), findsOneWidget);
      expect(find.text('2026.08.14 · 涩谷'), findsOneWidget);
      expect(find.byKey(const ValueKey('sticker')), findsOneWidget);
      expect(find.text('247'), findsOneWidget);
      expect(find.byKey(const ValueKey('burst')), findsOneWidget);
      expect(find.byKey(const ValueKey('ticket')), findsOneWidget);
      expect(find.text('现场门票 · 26 张'), findsOneWidget);
      for (final variant in SparkleVariant.values) {
        expect(
          find.byKey(ValueKey('sparkle-$variant')),
          findsOneWidget,
        );
      }
      expect(find.byKey(const ValueKey('tape')), findsOneWidget);
      expect(find.text('手帐'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test('die-cut sticker ink keeps at least 4.5:1 contrast', () {
    const memberColors = [
      Color(0xFF22C55E),
      Color(0xFFFFE135),
      Color(0xFF67E8F9),
      Color(0xFFEF4444),
      Color(0xFFF472B6),
      Color(0xFF3B82F6),
      Color(0xFFFB923C),
      Color(0xFF808080),
      Colors.white,
      Colors.black,
    ];
    for (final fill in memberColors) {
      final ink = DreamPalette.onColor(fill);
      final l1 = fill.computeLuminance();
      final l2 = ink.computeLuminance();
      final lighter = l1 > l2 ? l1 : l2;
      final darker = l1 > l2 ? l2 : l1;
      final ratio = (lighter + 0.05) / (darker + 0.05);
      expect(ratio, greaterThanOrEqualTo(4.5), reason: '$fill -> $ink');
    }
  });

  test('ticket notch cuts the edge and keeps the middle solid', () {
    const size = Size(220, 90);
    final path = ticketStubPath(size);
    final notchY = size.height / 2;
    expect(path.contains(Offset(0, notchY)), isFalse);
    expect(path.contains(Offset(size.width, notchY)), isFalse);
    expect(path.contains(Offset(20, notchY)), isTrue);
    expect(path.contains(Offset(size.width / 2, 10)), isTrue);
  });

  testWidgets('dream kit survives a 2x system text scale', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DreamSectionHeader(title: '成员', countLabel: '18 位'),
                const SizedBox(height: 12),
                const StickerBadge(
                  value: '247',
                  label: '张',
                  color: Color(0xFFD3245F),
                ),
                const SizedBox(height: 12),
                const WashiTape(
                  color: Color(0xFFB8D8EA),
                  width: 72,
                  height: 18,
                  label: '手帐',
                ),
                const SizedBox(height: 12),
                const PolaroidFrame(
                  photo: SizedBox(height: 60),
                  caption: Text('日期未知 · 29 张'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
