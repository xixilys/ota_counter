// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ota_counter/main.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/sync_service.dart';
import 'package:ota_counter/widgets/counter_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('probe startup query and home aggregation cost', (tester) async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'OTA Counter',
      packageName: 'top.huangxuanqi.otacounter',
      version: '1.5.4',
      buildNumber: '20',
      buildSignature: '',
    );
    await tester.runAsync(DatabaseService.clearAppData);
    await tester.runAsync(() async {
      for (var i = 0; i < 60; i++) {
        await DatabaseService.insertCounter(
          CounterModel(
            name: '成员$i',
            groupName: '团体${i % 8}',
            color:
                '#${(0x336699 + i * 1234567).toRadixString(16).padLeft(6, '0').substring(0, 6)}',
            threeInchCount: 10 + i,
            fiveInchCount: 4 + (i % 7),
            threeInchShukudaiCount: i % 5,
          ),
        );
      }
      final now = DateTime(2026, 10, 31);
      for (var i = 0; i < 3000; i++) {
        await DatabaseService.insertActivityRecord(
          ActivityRecordModel.ticket(
            eventName: '公演 ${i % 20}',
            occurredAt: now.subtract(Duration(days: i % 180)),
            quantity: 1,
            unitPrice: 80,
            note: 'perf',
          ),
        );
      }
    });

    final countersWatch = Stopwatch()..start();
    await tester.runAsync(DatabaseService.getCounters);
    countersWatch.stop();

    final recordsWatch = Stopwatch()..start();
    await tester.runAsync(DatabaseService.getActivityRecords);
    recordsWatch.stop();

    final homeRecordsWatch = Stopwatch()..start();
    final homeRecords = await tester.runAsync(
      DatabaseService.getHomeActivityRecords,
    );
    homeRecordsWatch.stop();
    final countWatch = Stopwatch()..start();
    final recordCount = await tester.runAsync(
      DatabaseService.getActivityRecordCount,
    );
    countWatch.stop();

    final snapshotWatch = Stopwatch()..start();
    final snapshot = await tester.runAsync(
      () => SyncService.buildSnapshot(
        const SyncSettings(
          baseUrl: 'http://127.0.0.1:1',
          token: 'x',
          deviceId: 'perf',
          autoSync: false,
          lastSyncAt: '',
        ),
      ),
    );
    snapshotWatch.stop();

    final rebuildWatch = Stopwatch()..start();
    await tester.runAsync(() async {
      await tester.pumpWidget(const MyApp());
    });
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    rebuildWatch.stop();
    final cards = find.byType(CounterCard).evaluate().length;

    // ignore: avoid_print
    print('PERF counters=${countersWatch.elapsedMilliseconds}ms '
        'records=${recordsWatch.elapsedMilliseconds}ms '
        'home_records=${homeRecordsWatch.elapsedMilliseconds}ms '
        'home_record_rows=${homeRecords?.length} '
        'record_count=${countWatch.elapsedMilliseconds}ms/$recordCount '
        'snapshot=${snapshotWatch.elapsedMilliseconds}ms '
        'json=${snapshot == null ? 0 : snapshot.toString().length} '
        'home_first_frames=${rebuildWatch.elapsedMilliseconds}ms '
        'visible_cards=$cards');
  });
}
