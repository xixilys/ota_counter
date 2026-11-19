import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/pages/album/album_landing_widgets.dart';
import 'package:ota_counter/pages/album/album_models.dart';
import 'package:ota_counter/theme/app_theme.dart';

AlbumPhoto _photo(int id) => AlbumPhoto(
      mediaId: id,
      path: '/nonexistent/album-preview-$id.jpg',
      isScan: true,
      mediaLabel: '切图',
      specLabel: '3寸',
      activityDay: DateTime(2026, 4, 6),
      sessionKey: 'day:4-6|',
      sessionDay: DateTime(2026, 4, 6),
    );

AlbumSession _session({required int photoCount}) {
  const member = AlbumMemberRef(
    key: 'p:1',
    personId: 1,
    name: '浙璃Kiko',
    groupName: 'DOKISTAR',
    colorHex: '#4E8DF5',
  );
  return AlbumSession(
    key: 'day:4-6|',
    day: DateTime(2026, 4, 6),
    title: 'DOKISTAR 场',
    venueName: '',
    cityName: '',
    sessionLabel: '',
    eventTimeLabel: '',
    photos: [for (var i = 0; i < photoCount; i++) _photo(i)],
    members: const [member],
  );
}

Widget _app(Widget child) => MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('sparse latest session uses the compact photo-left layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(860, 1864);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(
        AlbumRecentSessionFeature(
            session: _session(photoCount: 1), onOpen: () {}),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('最近一场'), findsOneWidget);
    expect(find.text('DOKISTAR 场'), findsOneWidget);
    expect(find.text('浙璃Kiko'), findsOneWidget);
    expect(
      tester.getSize(find.byType(AlbumRecentSessionFeature)).height,
      lessThan(260),
      reason: 'the member shelf should stay above the fold',
    );
  });

  testWidgets('compact feature also fits 1.3x text', (tester) async {
    tester.view.physicalSize = const Size(860, 1864);
    tester.view.devicePixelRatio = 2;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      _app(
        AlbumRecentSessionFeature(
            session: _session(photoCount: 2), onOpen: () {}),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('最近一场'), findsOneWidget);
  });
}
