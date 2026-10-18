import 'package:sqflite/sqflite.dart';
import 'dart:io';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:math';

class ImageService {
  static const String tableName = 'images';
  static Database? _database;

  static Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'images.db');

    return await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $tableName(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            is_used INTEGER DEFAULT 0
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
              'ALTER TABLE $tableName ADD COLUMN is_used INTEGER DEFAULT 0');
        }
      },
    );
  }

  static Future<String> saveImage(File imageFile) async {
    // 复制图片到应用目录
    final directory = await getApplicationDocumentsDirectory();
    final fileName = '${DateTime.now().microsecondsSinceEpoch}.jpg';
    final savedPath = join(directory.path, fileName);
    await imageFile.copy(savedPath);

    // 保存记录到数据库
    final db = await database;
    await db.insert(tableName, {
      'path': savedPath,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'is_used': 0, // 确保新图片默认未使用
    });

    return savedPath;
  }

  static Future<List<String>> getAllImages() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableName,
      orderBy: 'created_at DESC',
    );

    return List.generate(maps.length, (i) => maps[i]['path'] as String);
  }

  static Future<void> deleteImage(String path) async {
    try {
      // 删除文件
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }

      // 删除数据库记录
      final db = await database;
      await db.delete(
        tableName,
        where: 'path = ?',
        whereArgs: [path],
      );
    } catch (e) {
      throw Exception('删除失败: $e');
    }
  }

  static Future<String?> getRandomImage() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(tableName);

    if (maps.isEmpty) return null;

    final random = Random();
    final randomIndex = random.nextInt(maps.length);
    return maps[randomIndex]['path'] as String;
  }

  // 获取未使用的图片
  static Future<List<String>> getUnusedImages() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableName,
      where: 'is_used = 0',
      orderBy: 'created_at DESC',
    );

    return List.generate(maps.length, (i) => maps[i]['path'] as String);
  }

  // 标记图片为已使用
  static Future<void> markAsUsed(String path, {bool used = true}) async {
    final db = await database;
    await db.update(
      tableName,
      {'is_used': used ? 1 : 0},
      where: 'path = ?',
      whereArgs: [path],
    );
  }

  // 获取所有图片的使用状态，避免列表逐项查询
  static Future<Map<String, bool>> getImageUsageByPath() async {
    final db = await database;
    final maps = await db.query(
      tableName,
      columns: ['path', 'is_used'],
    );
    return {
      for (final row in maps)
        (row['path'] ?? '') as String: (row['is_used'] ?? 0) == 1,
    };
  }

  // 获取图片使用状态
  static Future<bool> isImageUsed(String path) async {
    final db = await database;
    final List<Map<String, dynamic>> result = await db.query(
      tableName,
      columns: ['is_used'],
      where: 'path = ?',
      whereArgs: [path],
    );
    return result.isNotEmpty && result.first['is_used'] == 1;
  }
}
