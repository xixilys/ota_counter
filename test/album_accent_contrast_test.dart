import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/pages/album/album_widgets.dart';
import 'package:ota_counter/theme/app_theme.dart';

void main() {
  const colors = <String>[
    '#FF7A9E',
    '#7C6CF0',
    '#21B6A8',
    '#F4A63A',
    '#4E8DF5',
    '#E45C8A',
    '#FFE135',
    '#8A8F9E',
    '#FF0000',
    '#FFFFFF',
  ];

  test('member accent text keeps WCAG AA on the polaroid frame', () {
    for (final hex in colors) {
      final light = albumContrastRatio(
        albumAccent(hex, Brightness.light),
        AppTheme.polaroid(Brightness.light),
      );
      final dark = albumContrastRatio(
        albumAccent(hex, Brightness.dark),
        AppTheme.polaroid(Brightness.dark),
      );
      expect(light, greaterThanOrEqualTo(4.5), reason: 'light $hex');
      expect(dark, greaterThanOrEqualTo(4.5), reason: 'dark $hex');
    }
  });

  test('member accent on card surfaces keeps WCAG AA', () {
    const surfaces = <String>[
      '#FF7A9E',
      '#7C6CF0',
      '#21B6A8',
      '#F4A63A',
      '#4E8DF5',
      '#E45C8A',
      '#FFE135',
      '#FFFFFF',
    ];
    for (final hex in surfaces) {
      for (final brightness in Brightness.values) {
        final background = AppTheme.light().colorScheme.surface;
        final accent = albumSurfaceAccent(hex, brightness);
        final target = brightness == Brightness.dark
            ? AppTheme.dark().colorScheme.surface
            : background;
        expect(
          albumContrastRatio(accent, target),
          greaterThanOrEqualTo(4.5),
          reason: '$brightness $hex',
        );
      }
    }
  });

  test('fallback colour is still a readable accent', () {
    final accent = albumAccent('', Brightness.light);
    expect(
      albumContrastRatio(accent, AppTheme.polaroid(Brightness.light)),
      greaterThanOrEqualTo(4.5),
    );
  });
}
