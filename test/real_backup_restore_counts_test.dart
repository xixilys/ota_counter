// Restores a real user full backup through the production restore entry and
// checks the home overview against the numbers the release app showed.
//
// The backup is private user data and is never committed. Point the test at
// it explicitly:
//
//   OTA_REAL_BACKUP=/path/to/ota_counter_backup_xxx.zip \
//     flutter test test/real_backup_restore_counts_test.dart
//
// Without OTA_REAL_BACKUP every test here is skipped.
//
// Expected numbers are derived from the backup's own `counters` rows (the card
// totals the release app stored), not hard coded, so no personal figures live
// in the repository.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/main.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/export_import_service.dart';

import 'support/isolated_test_databases.dart';

const _countFields = [
  'count',
  'three_inch_count',
  'five_inch_count',
  'three_inch_shukudai_count',
  'five_inch_shukudai_count',
  'group_cut_count',
];

int _int(Object? value) => value is num ? value.toInt() : 0;

/// Same grouping key the home page uses for one member entry
/// (`_homeEntryKey` in lib/main.dart): person id, then person name, then
/// group + card name.
String _homeEntryKey(Map<String, Object?> row) {
  final personId = row['person_id'];
  if (personId is num) {
    return 'person-id:${personId.toInt()}';
  }
  final personName = '${row['person_name'] ?? ''}'.trim();
  if (personName.isNotEmpty) {
    return 'person-name:${personName.toLowerCase()}';
  }
  final group = '${row['group_name'] ?? ''}'.trim().toLowerCase();
  final name = '${row['name'] ?? ''}'.trim().toLowerCase();
  return 'counter:$group|$name';
}

class _ExpectedOverview {
  _ExpectedOverview(Iterable<Map<String, Object?>> rows)
      : totals = {
          for (final field in _countFields)
            field: rows.fold<int>(0, (sum, row) => sum + _int(row[field])),
        },
        members = rows.map(_homeEntryKey).toSet().length;

  final Map<String, int> totals;
  final int members;

  @override
  String toString() => '$totals members=$members';
}

void main() {
  final backupPath = Platform.environment['OTA_REAL_BACKUP'];
  final skip = backupPath == null || backupPath.isEmpty
      ? 'OTA_REAL_BACKUP is not set'
      : null;

  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory documentsDirectory;

  setUpAll(() async {
    final databases = await useIsolatedTestDatabases();
    documentsDirectory = Directory('${databases.path}/documents')
      ..createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => documentsDirectory.path,
    );
  });

  setUp(() {
    // A zero build disables the automatic network update check and the
    // startup maintenance (run explicitly below instead).
    PackageInfo.setMockInitialValues(
      appName: 'OTA Counter',
      packageName: 'test.ota',
      version: 'test',
      buildNumber: '0',
      buildSignature: '',
    );
  });

  tearDown(() async => DatabaseService.clearAppData());

  Future<List<Map<String, Object?>>> restoreRealBackup() async {
    final payload = await ExportImportService.parseImportPayloadFile(
      fileName: backupPath!.split(Platform.pathSeparator).last,
      path: backupPath,
    );
    final backup = payload.fullBackup!;
    final rows = (backup.mainDatabase['counters'] ?? const [])
        .map((row) => Map<String, Object?>.from(row))
        .toList();
    await ExportImportService.restoreFullBackup(backup);
    return rows;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> openHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => tester.pumpWidget(const MyApp()));
    await settle(tester);
    expect(find.text('我的切奇'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }

  int metric(WidgetTester tester, String label) {
    final column = find
        .ancestor(of: find.text(label), matching: find.byType(Column))
        .first;
    final numbers = tester
        .widgetList<Text>(
            find.descendant(of: column, matching: find.byType(Text)))
        .map((text) => int.tryParse(text.data ?? ''))
        .whereType<int>()
        .toList();
    expect(numbers, hasLength(1), reason: 'metric $label');
    return numbers.single;
  }

  Map<String, int> homeOverview(WidgetTester tester) {
    final header = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? '')
        .firstWhere((text) => text.contains('位成员'));
    return {
      'count': metric(tester, '累计切奇'),
      'three_inch_count': metric(tester, '3寸'),
      'five_inch_count': metric(tester, '5寸'),
      'three_inch_shukudai_count': metric(tester, '3寸宿'),
      'five_inch_shukudai_count': metric(tester, '5寸宿'),
      'group_cut_count': metric(tester, '团切'),
      'members': int.parse(header.split(' ').first),
    };
  }

  Future<void> expectHomeMatches(
    WidgetTester tester,
    _ExpectedOverview expected,
  ) async {
    final actual = homeOverview(tester);
    // ignore: avoid_print
    print('home overview: $actual, expected: $expected');
    expect(actual, {...expected.totals, 'members': expected.members});
  }

  // The reported bug: a fresh install (e.g. the side-by-side debug build) has
  // "显示已隐藏项" off, so the same backup showed only the visible members.
  testWidgets(
    'restoring a real backup on a fresh install shows the release home totals',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final rows = (await tester.runAsync(restoreRealBackup))!;
      await openHome(tester);
      await expectHomeMatches(tester, _ExpectedOverview(rows));
    },
    skip: skip != null,
  );

  testWidgets(
    'hiding members after a real restore drops only them and says how many',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final rows = (await tester.runAsync(restoreRealBackup))!;
      await openHome(tester);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('隐藏已隐藏项'));
      await tester.pumpAndSettle();

      final visible = rows.where((row) => _int(row['is_hidden']) == 0);
      await expectHomeMatches(tester, _ExpectedOverview(visible));
      final visibleKeys = visible.map(_homeEntryKey).toSet();
      final hiddenMembers = rows
          .where((row) => _int(row['is_hidden']) != 0)
          .map(_homeEntryKey)
          .where((key) => !visibleKeys.contains(key))
          .toSet()
          .length;
      expect(hiddenMembers, greaterThan(0));
      expect(find.textContaining('另有 $hiddenMembers 位已隐藏'), findsOneWidget);
    },
    skip: skip != null,
  );

  testWidgets(
    'restore and the next launch maintenance never change any card count',
    (tester) async {
      SharedPreferences.setMockInitialValues({'show_hidden_counters': true});
      await tester.runAsync(() async {
        final rows = await restoreRealBackup();
        Future<void> expectCardsUnchanged(String stage) async {
          final restored = {
            for (final counter in await DatabaseService.getCounters())
              counter.id: <String, Object?>{
                'count': counter.count,
                'three_inch_count': counter.threeInchCount,
                'five_inch_count': counter.fiveInchCount,
                'three_inch_shukudai_count': counter.threeInchShukudaiCount,
                'five_inch_shukudai_count': counter.fiveInchShukudaiCount,
                'group_cut_count': counter.groupCutCount,
                'is_hidden': counter.isHidden ? 1 : 0,
              },
          };
          expect(restored.keys.toSet(), rows.map((row) => row['id']).toSet(),
              reason: stage);
          for (final row in rows) {
            final card = restored[row['id']]!;
            for (final field in _countFields) {
              expect(_int(card[field]), _int(row[field]),
                  reason: '$stage: counter ${row['id']} $field');
            }
            expect(_int(card['is_hidden']), _int(row['is_hidden']),
                reason: '$stage: counter ${row['id']} is_hidden');
          }
        }

        await expectCardsUnchanged('after restore');
        // What the first app launch after a restore runs
        // (_runStartupMaintenance in lib/main.dart).
        await DatabaseService.syncActivityRecordsToCounters('ota_site');
        await DatabaseService.autoAssignCounterThemeColors();
        await DatabaseService.reconcileCounterIdentities();
        await expectCardsUnchanged('after startup maintenance');
      });
    },
    skip: skip != null,
  );
}
