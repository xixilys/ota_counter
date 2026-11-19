import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ota_counter/pages/album/checked_cheki_import_page.dart';
import 'package:ota_counter/theme/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/activity_record_media_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/services/checked_cheki_import_service.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/idol_database_service.dart';
import 'package:ota_counter/models/idol_database_models.dart';
import 'support/isolated_test_databases.dart';

final _png = () {
  final image = img.Image(width: 120, height: 180);
  img.fill(image, color: img.ColorRgb8(255, 192, 210));
  img.drawCircle(image,
      x: 60, y: 64, radius: 37, color: img.ColorRgb8(65, 42, 48));
  img.fillRect(image,
      x1: 21, y1: 100, x2: 99, y2: 179, color: img.ColorRgb8(225, 77, 133));
  return Uint8List.fromList(img.encodePng(image));
}();
final _quad = {
  'tlx': 0,
  'tly': 0,
  'trx': 119,
  'try': 0,
  'blx': 0,
  'bly': 179,
  'brx': 119,
  'bry': 179
};

Map<String, Object?> _card(int id,
        {String subject = '小满', String group = 'Hermes'}) =>
    {
      'card_id': 'hermes-20261117-001',
      'record_id': id,
      'date': '2026-11-15',
      'subject': subject,
      'group': group,
      'image': 'cards/card-001.png',
      'source': 'sources/original-01.png',
      'source_sha1': sha1.convert(_png).toString(),
      'quad': {..._quad},
    };

Uint8List _zip(List<Map<String, Object?>> cards,
    {Map<String, List<int>>? files,
    Map<String, Object?>? manifest,
    ArchiveFile? extra}) {
  final archive = Archive()
    ..addFile(ArchiveFile.string(
        'manifest.json',
        jsonEncode(manifest ??
            {
              'format': 'ota-checked-cheki',
              'version': 1,
              'cards': cards,
            })));
  for (final entry in (files ??
          {'cards/card-001.png': _png, 'sources/original-01.png': _png})
      .entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  if (extra != null) archive.addFile(extra);
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Future<String> _ledger() async => jsonEncode([
      (await DatabaseService.getCounters()).map((v) => v.toMap()).toList(),
      (await DatabaseService.getActivityRecords())
          .map((v) => v.toMap())
          .toList(),
    ]);

class _LocalZipPicker extends FilePicker {
  final String path;
  _LocalZipPicker(this.path);
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    expect(type, FileType.custom);
    expect(allowedExtensions, ['zip']);
    return FilePickerResult(
        [PlatformFile(name: 'checked-cheki-demo.zip', size: 100, path: path)]);
  }
}

Future<void> _settleImport(WidgetTester tester) async {
  for (var i = 0; i < 500; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 16));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late int a, b;
  late Directory documents;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final dir = await useIsolatedTestDatabases();
    documents = Directory('${dir.path}/documents')..createSync();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => documents.path);
  });
  setUp(() async {
    await DatabaseService.clearAppData();
    Future<int> record(String name) async {
      final personId =
          await IdolDatabaseService.upsertPerson(IdolPerson(name: '$name真人'));
      final id = await DatabaseService.insertCounter(CounterModel(
        name: name,
        groupName: 'Hermes',
        color: '#D3245F',
        personId: personId,
        personName: '$name真人',
      ));
      final counter =
          (await DatabaseService.getCounters()).firstWhere((c) => c.id == id);
      return DatabaseService.insertActivityRecordWithCounterImpact(
          ActivityRecordModel.counterAdjustment(
              counter: counter,
              occurredAt: DateTime(2026, 11, 15),
              deltas: {CounterCountField.threeInch: 3}));
    }

    a = await record('小满');
    b = await record('小雪');
  });

  test('valid ZIP attaches only, preserves all ledger fields and old photos',
      () async {
    await DatabaseService.saveBatchImport(newRecords: [], media: [
      BatchMediaInput(recordId: a, bytes: _png, fileExtension: '.png'),
    ]);
    final old = (await DatabaseService.getActivityRecordMedia()).single;
    final before = await _ledger();
    final preview =
        await CheckedChekiImportService.previewBytes(_zip([_card(a)]));
    expect(preview.canImport, true);
    expect((await DatabaseService.getActivityRecordMedia()).length, 1);
    await CheckedChekiImportService.confirm(preview);
    final media = await DatabaseService.getActivityRecordMedia();
    expect(media.length, 2);
    final attached = media.firstWhere((m) => m.id != old.id);
    expect(attached.recordId, a);
    expect(attached.sourceHash, sha1.convert(_png).toString());
    expect(jsonDecode(attached.cropQuadJson)['_checked_card_id'],
        'hermes-20261117-001');
    expect(await File(old.path).readAsBytes(), _png);
    expect(await File(attached.path).readAsBytes(), _png);
    final optimizedDir =
        Directory('${File(attached.path).parent.path}/.album-optimized-v3');
    final savedDisplay = await optimizedDir
        .list(recursive: true)
        .where((e) => e is File)
        .cast<File>()
        .toList();
    expect(savedDisplay, hasLength(2));
    expect(await _ledger(), before);
  });

  test(
      'duplicate ZIP, stale preview, concurrent confirmations and renumbered card skip',
      () async {
    final before = await _ledger();
    final bytes = _zip([_card(a), _card(a)]);
    final first = await CheckedChekiImportService.previewBytes(bytes);
    expect(first.additions.length, 1);
    expect(first.duplicates, 1);
    final stale = await CheckedChekiImportService.previewBytes(bytes);
    final saving = CheckedChekiImportService.confirm(first);
    await expectLater(
        CheckedChekiImportService.confirm(stale), throwsStateError);
    await saving;
    final repeated = await CheckedChekiImportService.confirm(stale);
    expect(repeated.additions, isEmpty);
    expect(repeated.duplicates, 2);
    final renamed = _card(a)..['card_id'] = 'new-number';
    renamed['quad'] = {
      for (final entry in _quad.entries.toList().reversed)
        entry.key: entry.value.toDouble()
    };
    final checked =
        await CheckedChekiImportService.previewBytes(_zip([renamed]));
    expect(checked.additions, isEmpty);
    expect(checked.duplicates, 1);
    expect((await DatabaseService.getActivityRecordMedia()).length, 1);
    expect(await _ledger(), before);
  });

  test(
      'target date/name/group/id mismatch blocks the entire package with no counter impact',
      () async {
    final before = await _ledger();
    for (final mismatch in [
      {'date': '2026-11-16'},
      {'subject': '小满 '},
      {'group': 'hermes'},
      {'record_id': 99999},
    ]) {
      final bad = _card(a)..addAll(mismatch);
      final preview =
          await CheckedChekiImportService.previewBytes(_zip([_card(a), bad]));
      expect(preview.conflicts, isNotEmpty);
      await expectLater(
          CheckedChekiImportService.confirm(preview), throwsFormatException);
    }
    expect(await DatabaseService.getActivityRecordMedia(), isEmpty);
    expect(await _ledger(), before);
  });

  test(
      'same photo attached to another person conflicts rather than silently skips',
      () async {
    final before = await _ledger();
    await CheckedChekiImportService.confirm(
        await CheckedChekiImportService.previewBytes(_zip([_card(a)])));
    final preview = await CheckedChekiImportService.previewBytes(
        _zip([_card(b, subject: '小雪')]));
    expect(preview.conflicts, isNotEmpty);
    await expectLater(
        CheckedChekiImportService.confirm(preview), throwsFormatException);
    expect((await DatabaseService.getActivityRecordMedia()).single.recordId, a);
    expect(await _ledger(), before);
  });

  test('stable card ID cannot be reused for a different crop in another ZIP',
      () async {
    await CheckedChekiImportService.confirm(
        await CheckedChekiImportService.previewBytes(_zip([_card(a)])));
    final other = _card(a)..['quad'] = {..._quad, 'trx': 18, 'brx': 18};
    final preview = await CheckedChekiImportService.previewBytes(_zip([other]));
    expect(preview.conflicts, isNotEmpty);
    await expectLater(
        CheckedChekiImportService.confirm(preview), throwsFormatException);
    expect((await DatabaseService.getActivityRecordMedia()).length, 1);
  });

  test(
      'existing sourceHash and numeric quad encoding deduplicates legacy batch media',
      () async {
    await DatabaseService.saveBatchImport(newRecords: [], media: [
      BatchMediaInput(
        recordId: a,
        bytes: _png,
        fileExtension: '.png',
        sourceHash: sha1.convert(_png).toString(),
        cropQuadJson: jsonEncode({
          for (final e in _quad.entries.toList().reversed)
            e.key: e.value.toDouble()
        }),
      )
    ]);
    final preview =
        await CheckedChekiImportService.previewBytes(_zip([_card(a)]));
    expect(preview.duplicates, 1);
    expect(preview.canImport, false);
  });

  test(
      'owner identityName differs from ledger card name: matching IDs or exact identity deduplicate',
      () async {
    final db = await DatabaseService.database;
    final record = (await DatabaseService.getActivityRecords())
        .firstWhere((r) => r.id == a);
    final counter = (await DatabaseService.getCounters())
        .firstWhere((c) => c.id == record.counterId);
    expect(counter.personId, isNotNull);
    // Preserve the real linked ID; only give its group card a distinct main name.
    await db.update(DatabaseService.tableName, {'person_name': '真人主档'},
        where: 'id = ?', whereArgs: [counter.id]);
    await db.update(
        DatabaseService.activityRecordTableName, {'person_name': '真人主档'},
        where: 'id = ?', whereArgs: [a]);
    await DatabaseService.saveBatchImport(newRecords: [], media: [
      BatchMediaInput(
        recordId: a,
        bytes: _png,
        fileExtension: '.png',
        sourceHash: sha1.convert(_png).toString(),
        cropQuadJson: jsonEncode(_quad),
        owner: ActivityRecordMediaOwnerScope(
            personId: counter.personId,
            personName: '真人主档',
            groupName: 'Hermes'),
      )
    ]);
    final before = await _ledger();
    final media = (await DatabaseService.getActivityRecordMedia()).single;
    for (final withOwnerId in [true, false]) {
      await db.update(DatabaseService.activityRecordMediaTableName,
          {'owner_person_id': withOwnerId ? counter.personId : null},
          where: 'id = ?', whereArgs: [media.id]);
      final preview =
          await CheckedChekiImportService.previewBytes(_zip([_card(a)]));
      expect(preview.conflicts, isEmpty);
      expect(preview.duplicates, 1);
      await CheckedChekiImportService.confirm(preview);
      expect((await DatabaseService.getActivityRecordMedia()).length, 1);
    }
    // Old ledger rows can omit personId/name while the linked card retains it.
    await db.update(DatabaseService.activityRecordTableName,
        {'person_id': null, 'person_name': ''},
        where: 'id = ?', whereArgs: [a]);
    final legacyBefore = await _ledger();
    final legacy =
        await CheckedChekiImportService.previewBytes(_zip([_card(a)]));
    expect(legacy.conflicts, isEmpty);
    expect(legacy.duplicates, 1);
    await CheckedChekiImportService.confirm(legacy);
    expect(await _ledger(), legacyBefore);
    await db.update(DatabaseService.activityRecordTableName,
        {'person_id': record.personId, 'person_name': '真人主档'},
        where: 'id = ?', whereArgs: [a]);
    expect(await _ledger(), before);
  });

  test(
      'same record owner remains conflicting for a different group, ID or unlinked name',
      () async {
    final record = (await DatabaseService.getActivityRecords())
        .firstWhere((r) => r.id == a);
    final counter = (await DatabaseService.getCounters())
        .firstWhere((c) => c.id == record.counterId);
    await DatabaseService.saveBatchImport(newRecords: [], media: [
      BatchMediaInput(
        recordId: a,
        bytes: _png,
        fileExtension: '.png',
        sourceHash: sha1.convert(_png).toString(),
        cropQuadJson: jsonEncode(_quad),
      )
    ]);
    final db = await DatabaseService.database;
    final media = (await DatabaseService.getActivityRecordMedia()).single;
    final before = await _ledger();
    for (final owner in [
      {
        'owner_person_id': counter.personId,
        'owner_person_name': '小满',
        'owner_group_name': '其他团'
      },
      {
        'owner_person_id': counter.personId! + 10000,
        'owner_person_name': '小满',
        'owner_group_name': 'Hermes'
      },
      {
        'owner_person_id': null,
        'owner_person_name': '无关联真人',
        'owner_group_name': 'Hermes'
      },
    ]) {
      await db.update(DatabaseService.activityRecordMediaTableName, owner,
          where: 'id = ?', whereArgs: [media.id]);
      final preview =
          await CheckedChekiImportService.previewBytes(_zip([_card(a)]));
      expect(preview.conflicts, isNotEmpty);
      await expectLater(
          CheckedChekiImportService.confirm(preview), throwsFormatException);
      expect((await DatabaseService.getActivityRecordMedia()).length, 1);
      expect(await _ledger(), before);
    }
  });

  test('preview is revalidated when target ledger changes before confirmation',
      () async {
    final preview =
        await CheckedChekiImportService.previewBytes(_zip([_card(a)]));
    final db = await DatabaseService.database;
    await db.update(
        DatabaseService.activityRecordTableName, {'subject_name': '已更名'},
        where: 'id = ?', whereArgs: [a]);
    final before = await _ledger();
    await expectLater(
        CheckedChekiImportService.confirm(preview), throwsFormatException);
    expect(await _ledger(), before);
    expect(await DatabaseService.getActivityRecordMedia(), isEmpty);
  });

  test(
      'archive rejects traversal, links, unlisted files, invalid manifests and corrupt images',
      () async {
    final before = await _ledger();
    final link = ArchiveFile('cards/link.png', 1, [1])..mode = 0xa1ff;
    final cases = [
      _zip([_card(a)], extra: ArchiveFile('../escape.png', 1, [1])),
      _zip([_card(a)], extra: ArchiveFile('/absolute.png', 1, [1])),
      _zip([_card(a)], extra: link),
      _zip([_card(a)],
          extra: ArchiveFile('cards/unlisted.png', _png.length, _png)),
      _zip([], manifest: {'format': 'ota-full-backup', 'version': 1}),
      _zip([_card(a)..['date'] = '2026-02-30']),
      _zip([_card(a)..['source_sha1'] = '0' * 40]),
      _zip([
        _card(a)..['quad'] = {..._quad, 'tlx': -1}
      ]),
      _zip([
        _card(a)
      ], files: {
        'cards/card-001.png': [1, 2, 3],
        'sources/original-01.png': _png
      }),
      _zip(List.generate(129, (_) => _card(a))),
    ];
    for (final bytes in cases) {
      await expectLater(CheckedChekiImportService.previewBytes(bytes),
          throwsA(isA<Exception>()));
    }
    expect(await DatabaseService.getActivityRecordMedia(), isEmpty);
    expect(await _ledger(), before);
    expect(await File('${documents.parent.path}/escape.png').exists(), false);
  });

  test(
      'archive rejects oversized declarations, lying expanded sizes, duplicates and CRC corruption',
      () async {
    Uint8List patchSize(int declared) {
      final bytes = _zip([_card(a)]);
      final view = ByteData.sublistView(bytes);
      // Modify the first entry's local and central uncompressed-size fields.
      view.setUint32(22, declared, Endian.little);
      for (var i = 0; i < bytes.length - 46; i++) {
        if (view.getUint32(i, Endian.little) == 0x02014b50) {
          view.setUint32(i + 24, declared, Endian.little);
          break;
        }
      }
      return bytes;
    }

    await expectLater(
        CheckedChekiImportService.previewBytes(patchSize(1024 * 1024 + 1)),
        throwsFormatException);
    await expectLater(CheckedChekiImportService.previewBytes(patchSize(2)),
        throwsFormatException);
    final crc = _zip([_card(a)]);
    final view = ByteData.sublistView(crc);
    for (var i = 0; i < crc.length - 46; i++) {
      if (view.getUint32(i, Endian.little) == 0x02014b50) {
        view.setUint32(i + 16, 0, Endian.little);
        break;
      }
    }
    await expectLater(
        CheckedChekiImportService.previewBytes(crc), throwsFormatException);
    // Rename an unreferenced equal-length entry to an existing name in both headers.
    final raw = _zip([_card(a)],
        extra: ArchiveFile('cards/card-002.png', _png.length, _png));
    final from = ascii.encode('cards/card-002.png'),
        to = ascii.encode('cards/card-001.png');
    for (var i = 0; i <= raw.length - from.length; i++) {
      if (List.generate(from.length, (j) => raw[i + j]).join(',') ==
          from.join(',')) {
        raw.setRange(i, i + to.length, to);
      }
    }
    await expectLater(
        CheckedChekiImportService.previewBytes(raw), throwsFormatException);
    expect(await DatabaseService.getActivityRecordMedia(), isEmpty);
  });
  test(
      'archive enforces ZIP, image, total expanded limits and rejects encryption',
      () async {
    final before = await _ledger();
    final sparse = File('${documents.path}/oversized.zip');
    final handle = await sparse.open(mode: FileMode.write);
    await handle.truncate(CheckedChekiImportService.maxZipBytes + 1);
    await handle.close();
    await expectLater(CheckedChekiImportService.previewFile(sparse.path),
        throwsFormatException);
    await sparse.delete();
    final archive = Archive()
      ..addFile(ArchiveFile.string('manifest.json', '{}'));
    for (var i = 0; i < 9; i++) {
      archive.addFile(ArchiveFile('sources/source-$i.png', _png.length, _png));
    }
    Uint8List declaredSizes(int size) {
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
      final view = ByteData.sublistView(bytes);
      for (var i = 0; i < bytes.length - 46; i++) {
        if (view.getUint32(i, Endian.little) == 0x02014b50) {
          final nameLength = view.getUint16(i + 28, Endian.little);
          final name = utf8.decode(bytes.sublist(i + 46, i + 46 + nameLength));
          if (name != 'manifest.json') {
            view.setUint32(i + 24, size, Endian.little);
            final offset = view.getUint32(i + 42, Endian.little);
            view.setUint32(offset + 22, size, Endian.little);
          }
        }
      }
      return bytes;
    }

    await expectLater(
        CheckedChekiImportService.previewBytes(
            declaredSizes(32 * 1024 * 1024 + 1)),
        throwsFormatException);
    await expectLater(
        CheckedChekiImportService.previewBytes(declaredSizes(32 * 1024 * 1024)),
        throwsFormatException);
    final encrypted = _zip([_card(a)]);
    final view = ByteData.sublistView(encrypted);
    for (var i = 0; i < encrypted.length - 46; i++) {
      if (view.getUint32(i, Endian.little) == 0x02014b50) {
        view.setUint16(
            i + 8, view.getUint16(i + 8, Endian.little) | 1, Endian.little);
        final offset = view.getUint32(i + 42, Endian.little);
        view.setUint16(offset + 6,
            view.getUint16(offset + 6, Endian.little) | 1, Endian.little);
        break;
      }
    }
    await expectLater(CheckedChekiImportService.previewBytes(encrypted),
        throwsFormatException);
    expect(await _ledger(), before);
    expect(await DatabaseService.getActivityRecordMedia(), isEmpty);
  });

  testWidgets(
      'local picker previews groups and photos; explicit confirmation attaches only',
      (tester) async {
    const screenshot = String.fromEnvironment('CHECKED_CHEKI_PREVIEW_OUT');
    if (screenshot.isNotEmpty) {
      tester.view.physicalSize = const Size(786, 1704);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final font = await tester.runAsync(
          () => File('tool/ui_preview/PingFangSC-Preview.ttf').readAsBytes());
      final loader = FontLoader('PingFangPreview')
        ..addFont(Future.value(ByteData.sublistView(font!)));
      await loader.load();
      final icon = await rootBundle.load('fonts/MaterialIcons-Regular.otf');
      await (FontLoader('MaterialIcons')..addFont(Future.value(icon))).load();
    }
    final file = File('${documents.path}/checked-cheki-demo.zip');
    await tester.runAsync(() => file.writeAsBytes(_zip([_card(a)])));
    FilePicker.platform = _LocalZipPicker(file.path);
    final before = await tester.runAsync(_ledger);
    await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(
            fontFamily: screenshot.isEmpty ? null : 'PingFangPreview'),
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const CheckedChekiImportPage())),
                      child: const Text('open')),
                ))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择本地 ZIP'));
    await _settleImport(tester);
    expect(find.text('共 1 张 · 待附 1 张 · 重复跳过 0 张'), findsOneWidget);
    expect(find.text('小满 · Hermes'), findsOneWidget);
    expect(find.text('#$a · 2026-11-15'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    await tester.runAsync(() => precacheImage(
          tester.widget<Image>(find.byType(Image)).image,
          tester.element(find.byType(Image)),
        ));
    await tester.pumpAndSettle();
    if (screenshot.isNotEmpty) {
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile(screenshot));
    }
    final mediaBefore =
        await tester.runAsync(DatabaseService.getActivityRecordMedia);
    expect(mediaBefore, isEmpty);
    await tester.ensureVisible(find.text('确认仅附 1 张图片'));
    await tester.tap(find.text('确认仅附 1 张图片'));
    await _settleImport(tester);
    expect(find.text('open'), findsOneWidget);
    final media = await tester.runAsync(DatabaseService.getActivityRecordMedia);
    expect(media!.single.recordId, a);
    expect(await tester.runAsync(_ledger), before);
    expect(tester.takeException(), isNull);
  });
}
