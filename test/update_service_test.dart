import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/services/update_service.dart';

void main() {
  test('selects platform-specific update links when available', () {
    final info = AppUpdateInfo.fromJson(
      {
        'versionName': '1.4.0',
        'versionCode': 12,
        'versionLabel': 'v1.4.0',
        'title': 'OTA Counter v1.4.0',
        'notes': ['Android legacy field stays available'],
        'primaryUrl':
            'https://ota-counter.huangxuanqi.top/ota-counter/OTA-Counter-v1.4.0.apk',
        'downloadPageUrl':
            'https://ota-counter.huangxuanqi.top/ota-counter/',
        'platforms': {
          'ios': {
            'primaryUrl':
                'https://ota-counter.huangxuanqi.top/ota-counter/OTA-Counter-v1.4.0.ipa',
            'downloadPageUrl':
                'https://ota-counter.huangxuanqi.top/ota-counter/#ios',
          },
        },
      },
      platform: 'ios',
    );

    expect(info.primaryUrl, endsWith('.ipa'));
    expect(info.preferredOpenUrl, endsWith('/#ios'));
    expect(info.versionCode, 12);
  });

  test('keeps legacy top-level update links without platform override', () {
    final info = AppUpdateInfo.fromJson(
      {
        'versionName': '1.4.0',
        'versionCode': 12,
        'primaryUrl':
            'https://ota-counter.huangxuanqi.top/ota-counter/OTA-Counter-v1.4.0.apk',
        'downloadPageUrl':
            'https://ota-counter.huangxuanqi.top/ota-counter/',
        'platforms': const {},
      },
      platform: 'ios',
    );

    expect(info.primaryUrl, endsWith('.apk'));
    expect(info.preferredOpenUrl, endsWith('/ota-counter/'));
  });
}
