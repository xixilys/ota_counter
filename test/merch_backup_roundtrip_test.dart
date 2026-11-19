import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/merch_purchase_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/export_import_service.dart';
import 'package:ota_counter/services/merch_service.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory documents;

  setUpAll(() async {
    final databases = await useIsolatedTestDatabases();
    documents = Directory(p.join(databases.path, 'documents'))
      ..createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => documents.path,
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService.clearAppData();
  });

  tearDown(() async {
    await DatabaseService.clearAppData();
  });

  List<int> buildBackupZip({
    required Map<String, Object?> manifest,
    Map<String, List<int>> documentFiles = const {},
  }) {
    final archive = Archive()
      ..addFile(ArchiveFile.string('manifest.json', jsonEncode(manifest)));
    for (final entry in documentFiles.entries) {
      archive.addFile(
        ArchiveFile(
          'documents/${entry.key}',
          entry.value.length,
          entry.value,
        ),
      );
    }
    return ZipEncoder().encode(archive);
  }

  Map<String, Object?> legacyManifest() {
    return {
      'type': FullBackupBundle.backupType,
      'format_version': FullBackupBundle.currentFormatVersion,
      'exported_at': '2026-11-07T23:23:02.000',
      'main_database': {
        DatabaseService.tableName: const [],
        DatabaseService.activityRecordTableName: const [],
        DatabaseService.activityRecordMediaTableName: const [],
      },
      'idol_database': {
        'idol_people': const [],
        'idol_groups': const [],
        'idol_members': const [],
        'idol_meta': const [],
      },
      'image_database': const {'images': []},
    };
  }

  test('merch purchases, custom kinds and photos round-trip through a backup',
      () async {
    final photoDirectory = Directory(p.join(documents.path, 'merch_photos'))
      ..createSync(recursive: true);
    final photo = File(p.join(photoDirectory.path, 'purchase.jpg'));
    await photo.writeAsBytes([9, 8, 7, 6]);

    await MerchService.addCustomKind('应援扇');
    final purchaseId = await MerchService.savePurchase(
      MerchPurchaseModel.purchase(
        kind: '生写真',
        memberName: '林小满',
        groupName: 'Aurora',
        eventName: '定期公演',
        venueName: '涩谷 O-EAST',
        quantity: 2,
        unitPrice: 30,
        note: '白色边框',
        photoPath: photo.path,
        occurredAt: DateTime(2026, 3, 5),
      ),
    );
    expect(purchaseId, greaterThan(0));

    final bundle = await ExportImportService.buildFullBackupBundle();
    final purchaseRows =
        bundle.mainDatabase[DatabaseService.merchPurchaseTableName]!;
    expect(purchaseRows, hasLength(1));
    expect(purchaseRows.single['kind'], '生写真');
    expect(
      purchaseRows.single['photo_path'],
      'merch_photos/purchase.jpg',
    );
    expect(
      bundle.mainDatabase[DatabaseService.merchKindTableName]!.map(
        (row) => row['name'],
      ),
      contains('应援扇'),
    );
    expect(
      bundle.documentPaths.keys,
      contains('merch_photos/purchase.jpg'),
    );

    final documentBytes = <String, List<int>>{
      for (final entry in bundle.documentPaths.entries)
        entry.key: await File(entry.value).readAsBytes(),
    };
    final payload = ExportImportService.parseImportPayload(
      fileName: 'backup.zip',
      rawBytes: buildBackupZip(
        manifest: bundle.toManifest(),
        documentFiles: documentBytes,
      ),
    );
    await ExportImportService.restoreFullBackup(payload.fullBackup!);

    final restored = (await MerchService.getPurchases()).single;
    expect(restored.kind, '生写真');
    expect(restored.memberName, '林小满');
    expect(restored.quantity, 2);
    expect(restored.resolvedTotalAmount, 60);
    expect(restored.note, '白色边框');
    expect(restored.photoPath,
        p.join(documents.path, 'merch_photos', 'purchase.jpg'));
    expect(await File(restored.photoPath).exists(), isTrue);
    expect(await File(restored.photoPath).readAsBytes(), [9, 8, 7, 6]);
    expect(
      (await MerchService.getKinds()).map((kind) => kind.name),
      contains('应援扇'),
    );
    final stats = await MerchService.getStats();
    expect(stats.itemCount, 2);
    expect(stats.amount, 60);
  });

  test('an older backup without merch tables restores cleanly', () async {
    final payload = ExportImportService.parseImportPayload(
      fileName: 'old-backup.zip',
      rawBytes: buildBackupZip(manifest: legacyManifest()),
    );
    await ExportImportService.restoreFullBackup(payload.fullBackup!);
    expect(await MerchService.getPurchases(), isEmpty);
    expect(
      (await MerchService.getKinds()).map((kind) => kind.name),
      containsAll(['生写真', '吧唧']),
    );
    final id = await MerchService.savePurchase(
      MerchPurchaseModel.purchase(
        kind: '海报',
        quantity: 1,
        unitPrice: 20,
        occurredAt: DateTime(2026, 3, 20),
      ),
    );
    expect(id, greaterThan(0));
  });

  test('merch photo paths are validated like other backup documents', () {
    final manifest = legacyManifest();
    manifest['main_database'] = {
      DatabaseService.merchPurchaseTableName: [
        {
          'id': 1,
          'kind': '生写真',
          'photo_path': '../outside.jpg',
        },
      ],
    };
    expect(
      () => ExportImportService.parseImportPayload(
        fileName: 'bad.zip',
        rawBytes: buildBackupZip(manifest: manifest),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('父级目录'),
        ),
      ),
    );
  });
}
