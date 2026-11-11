// Renders the home member-card grid at 2 and 4 columns for 标准 / 特大 card
// font sizes. Output is written to /private/tmp/card_font_preview/.
//
//   python3 tool/ui_preview/prepare_font.py
//   flutter test tool/ui_preview/card_font_preview_test.dart
//
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/services/settings_service.dart';
import 'package:ota_counter/theme/app_theme.dart';
import 'package:ota_counter/widgets/counter_card.dart';

const _fontPath = 'tool/ui_preview/PingFangSC-Preview.ttf';
const _outputDir = '/private/tmp/card_font_preview';
const _physicalSize = Size(1440, 3168);
const _devicePixelRatio = 3.5;
const _pagePadding = 16.0;

const _members = <(String, String, String)>[
  ('皮皮猪', 'PokaPokaTime', '#FF5C8A'),
  ('夏小米', 'PokaPokaTime', '#8B6CF0'),
  ('桃菓_momoka', 'PokaPokaTime', '#FF9F43'),
  ('阿岚', 'Lumiere', '#1FB5A8'),
  ('星野遥', 'Lumiere', '#F5B700'),
  ('白鸟纱', 'Lumiere', '#4E8DF5'),
  ('陈知夏', '星屑电台', '#E8485F'),
  ('宫本栞', '星屑电台', '#F06BC8'),
];

const _breakdown = <CounterCountBadgeData>[
  CounterCountBadgeData(label: '3寸', value: 21),
  CounterCountBadgeData(label: '5寸', value: 8),
  CounterCountBadgeData(label: '3寸宿', value: 4),
  CounterCountBadgeData(label: '5寸宿', value: 2),
];

Future<void> _loadPreviewFont() async {
  final file = File(_fontPath);
  if (!file.existsSync()) {
    fail('Missing $_fontPath. Run: python3 tool/ui_preview/prepare_font.py');
  }
  final bytes = await file.readAsBytes();
  final loader = FontLoader('PingFangPreview')
    ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
  await loader.load();

  final iconBytes = await rootBundle.load('fonts/MaterialIcons-Regular.otf');
  final iconLoader = FontLoader('MaterialIcons')
    ..addFont(Future<ByteData>.value(iconBytes));
  await iconLoader.load();
}

Widget _previewGrid(int columns, double scale) {
  final contentWidth =
      _physicalSize.width / _devicePixelRatio - _pagePadding * 2;
  final spacing = columns >= 4 ? 10.0 : 12.0;
  final cardHeight = counterCardHeight(
    gridColumns: columns,
    availableWidth: contentWidth,
    crossAxisSpacing: spacing,
    textScale: scale,
    breakdownEntryCount: _breakdown.length,
  );

  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(fontFamily: 'PingFangPreview'),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(_pagePadding),
        child: SizedBox(
          width: contentWidth,
          child: GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _members.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: spacing,
              mainAxisSpacing: columns >= 3 ? 12 : 16,
              mainAxisExtent: cardHeight,
            ),
            itemBuilder: (context, index) {
              final member = _members[index];
              return CounterCard(
                counter: CounterModel(
                  name: member.$1,
                  groupName: member.$2,
                  color: member.$3,
                  threeInchCount: 21,
                  fiveInchCount: 8,
                  threeInchShukudaiCount: 4,
                  fiveInchShukudaiCount: 2,
                  isHidden: index == 2,
                ),
                totalCount: 35,
                breakdownEntries: _breakdown,
                percentage: 0.37,
                onTap: () {},
                onDelete: () {},
                onEdit: () {},
                gridColumns: columns,
                textScale: scale,
              );
            },
          ),
        ),
      ),
    ),
  );
}

Future<void> _writePng(WidgetTester tester, String fileName) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey<String>('preview-boundary')),
  );
  final path = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: _devicePixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      throw StateError('Could not encode $fileName');
    }
    final file = File('$_outputDir/$fileName');
    await file.writeAsBytes(bytes.buffer.asUint8List());
    return file.path;
  });
  print('wrote $path');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(_loadPreviewFont);

  setUp(() {
    SettingsService.fontScale.value = 1.0;
  });

  tearDown(() {
    SettingsService.fontScale.value = 1.0;
  });

  for (final columns in [2, 4]) {
    for (final scale in [1.0, 1.3]) {
      final scaleLabel = scale == 1.0 ? '100' : '130';
      testWidgets('render home cards $columns-col scale $scaleLabel', (
        tester,
      ) async {
        tester.view.physicalSize = _physicalSize;
        tester.view.devicePixelRatio = _devicePixelRatio;
        addTearDown(tester.view.reset);
        SettingsService.fontScale.value = scale;

        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey<String>('preview-boundary'),
            child: _previewGrid(columns, scale),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        await _writePng(
          tester,
          'home-cards-${columns}col-scale$scaleLabel.png',
        );
      });
    }
  }
}
