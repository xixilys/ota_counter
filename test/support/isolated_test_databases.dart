import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Points every sqlite database opened by this test file at a fresh,
/// per-file temporary directory.
///
/// `flutter test` runs each test file in its own process and, by default,
/// several files in parallel. All services build their database path from
/// `getDatabasesPath()` + a fixed file name, so without this every file would
/// share `.dart_tool/sqflite_common_ffi/databases/counter_app.db` (and the idol
/// / image databases) and lock or pollute each other. Setting the factory's
/// databases path once per file isolates `DatabaseService`,
/// `IdolDatabaseService` and `ImageService` together.
///
/// Call from `setUpAll`; the directory is removed after the file's tests.
Future<Directory> useIsolatedTestDatabases() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final directory =
      await Directory.systemTemp.createTemp('ota_counter_test_db_');
  await databaseFactory.setDatabasesPath(directory.path);
  addTearDown(() async {
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // A widget test may still hold a handle; the OS temp dir is cleaned
      // eventually and the path is unique, so it cannot leak into other runs.
    }
  });
  return directory;
}
