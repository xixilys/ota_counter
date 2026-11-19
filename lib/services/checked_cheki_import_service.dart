import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' hide ZLibDecoder;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../models/activity_record_media_model.dart';
import '../models/activity_record_model.dart';
import '../models/counter_model.dart';
import 'database_service.dart';

class CheckedChekiCard {
  final String cardId;
  final int recordId;
  final String date, subject, group, imagePath, sourceHash, quadJson;
  final Uint8List bytes;
  const CheckedChekiCard._(this.cardId, this.recordId, this.date, this.subject,
      this.group, this.imagePath, this.sourceHash, this.quadJson, this.bytes);
  String get identity => '$sourceHash|${_canonicalQuad(jsonDecode(quadJson))}';
}

class CheckedChekiPreview {
  final List<CheckedChekiCard> cards;
  final List<CheckedChekiCard> additions;
  final int duplicates;
  final List<String> conflicts;
  const CheckedChekiPreview._(
      this.cards, this.additions, this.duplicates, this.conflicts);
  bool get canImport => conflicts.isEmpty && additions.isNotEmpty;
}

/// Local attach-only ZIP import. No backup / ledger / counter mutation path.
class CheckedChekiImportService {
  static const maxZipBytes = 128 * 1024 * 1024;
  static const maxExpandedBytes = 256 * 1024 * 1024;
  static const maxFileBytes = 32 * 1024 * 1024;
  static const maxCards = 128;
  static bool _saving = false;

  static Future<CheckedChekiPreview> previewFile(String path) async {
    final file = File(path);
    if (!path.toLowerCase().endsWith('.zip') ||
        await file.length() > maxZipBytes) {
      throw const FormatException('请选择不超过 128 MiB 的本地 ZIP');
    }
    return previewBytes(await file.readAsBytes());
  }

  static Future<CheckedChekiPreview> previewBytes(Uint8List bytes) async {
    final cards = await compute(_parsePackage, bytes);
    return _checkTargets(cards);
  }

  static Future<CheckedChekiPreview> _checkTargets(
      List<CheckedChekiCard> cards) async {
    final records = {
      for (final r in await DatabaseService.getActivityRecords()) r.id: r
    };
    final counters = await DatabaseService.getCounters();
    final existing = await DatabaseService.getActivityRecordMedia();
    final identities = <String, List<ActivityRecordMediaModel>>{};
    final ids = <String, List<ActivityRecordMediaModel>>{};
    final ambiguousSources = <String>{};
    for (final media in existing) {
      if (media.sourceHash.isEmpty) continue;
      try {
        final q = jsonDecode(media.cropQuadJson);
        identities
            .putIfAbsent('${media.sourceHash}|${_canonicalQuad(q)}', () => [])
            .add(media);
        if (q is Map && q['_checked_card_id'] is String) {
          ids.putIfAbsent(q['_checked_card_id'], () => []).add(media);
        }
      } catch (_) {
        ambiguousSources.add(media.sourceHash);
      }
    }
    final additions = <CheckedChekiCard>[];
    final conflicts = <String>[];
    final seenIdentities = <String, CheckedChekiCard>{};
    final seenIds = <String, CheckedChekiCard>{};
    var duplicates = 0;
    for (final card in cards) {
      final record = records[card.recordId];
      if (record == null ||
          record.type == ActivityRecordType.ticket ||
          _date(record.occurredAt) != card.date ||
          record.subjectName != card.subject ||
          record.groupName != card.group) {
        conflicts.add('${card.cardId}：流水 #${card.recordId} 不存在或日期/名字/团体不符');
        continue;
      }
      final previousPhoto = seenIdentities[card.identity];
      final previousId = seenIds[card.cardId];
      seenIdentities[card.identity] = card;
      seenIds[card.cardId] = card;
      if (previousPhoto != null && previousPhoto.recordId != card.recordId ||
          previousId != null &&
              (previousId.identity != card.identity ||
                  previousId.recordId != card.recordId)) {
        conflicts.add('${card.cardId}：包内卡号或照片归属冲突');
        continue;
      }
      final matches = {...?identities[card.identity], ...?ids[card.cardId]};
      if (matches.any((media) =>
          media.sourceHash != card.sourceHash ||
          _canonicalQuad(jsonDecode(media.cropQuadJson)) !=
              _canonicalQuad(jsonDecode(card.quadJson)))) {
        conflicts.add('${card.cardId}：此卡号已用于另一张照片');
      } else if (matches.any((media) =>
          media.recordId != card.recordId ||
          !_ownerMatchesRecord(media, record, counters))) {
        conflicts.add('${card.cardId}：照片已挂到其他流水或成员');
      } else if (matches.isNotEmpty ||
          previousPhoto != null ||
          previousId != null) {
        duplicates++;
      } else if (ambiguousSources.contains(card.sourceHash)) {
        conflicts.add('${card.cardId}：原图已有缺少有效框选坐标的照片，无法核对重复');
      } else {
        additions.add(card);
      }
    }
    return CheckedChekiPreview._(cards, additions, duplicates, conflicts);
  }

  /// Revalidate immediately before saving; repeated/stale confirmations skip
  /// photos already attached since preview. Concurrent confirmations are denied.
  static Future<CheckedChekiPreview> confirm(
      CheckedChekiPreview preview) async {
    if (_saving) throw StateError('正在附图，请勿重复确认');
    _saving = true;
    try {
      final checked = await _checkTargets(preview.cards);
      if (checked.conflicts.isNotEmpty) {
        throw FormatException(checked.conflicts.join('\n'));
      }
      if (checked.additions.isNotEmpty) {
        await DatabaseService.saveBatchImport(newRecords: [], media: [
          for (final card in checked.additions)
            BatchMediaInput(
              bytes: card.bytes,
              fileExtension:
                  card.imagePath.substring(card.imagePath.lastIndexOf('.')),
              processingMode: ActivityRecordMediaProcessingMode.none,
              recordId: card.recordId,
              sourceHash: card.sourceHash,
              cropQuadJson: card.quadJson,
            ),
        ]);
      }
      return checked;
    } finally {
      _saving = false;
    }
  }
}

// Manifest subject is a ledger card name; media owner names are identityName
// (personName, falling back to card name). Do not equate these two fields.
bool _ownerMatchesRecord(ActivityRecordMediaModel media,
    ActivityRecordModel record, List<CounterModel> counters) {
  if (!media.hasOwnerScope) return true;
  final counter = resolveCounterForActivityRecord(
    counters,
    record,
    allowUniquePersonFallback: false,
  );
  final candidates = record.isMulti && record.effectiveParticipants.isNotEmpty
      ? record.effectiveParticipants
      : [
          ActivityParticipant(
            memberName: record.subjectName,
            personName: record.personName,
            personId: record.personId ?? counter?.personId,
            groupName: record.groupName,
          )
        ];
  return candidates.any((candidate) {
    if (media.ownerGroupName.trim().isNotEmpty &&
        media.ownerGroupName.trim() != candidate.groupName.trim()) {
      return false;
    }
    final ownerId = media.ownerPersonId;
    final targetId = candidate.personId;
    if (ownerId != null && targetId != null) return ownerId == targetId;
    final name = media.ownerPersonName.trim();
    if (name.isEmpty) return ownerId == null;
    final names = {candidate.memberName.trim(), candidate.personName.trim()};
    if (!record.isMulti &&
        counter != null &&
        (record.personId == null || counter.personId == record.personId)) {
      names.addAll([counter.name.trim(), counter.personName.trim()]);
    }
    names.remove('');
    return names.contains(name);
  });
}

String _date(DateTime date) => '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

const _quadKeys = ['tlx', 'tly', 'trx', 'try', 'blx', 'bly', 'brx', 'bry'];

// Fixed key order and 1/10000-pixel rounding normalize JSON number spellings.
String _canonicalQuad(dynamic value) {
  if (value is! Map) throw const FormatException('quad 必须是坐标对象');
  return _quadKeys.map((key) {
    final number = value[key];
    if (number is! num || !number.isFinite || number < 0 || number > 100000) {
      throw const FormatException('quad 坐标无效');
    }
    return (number * 10000).round();
  }).join(',');
}

List<CheckedChekiCard> _parsePackage(Uint8List bytes) {
  if (bytes.length > CheckedChekiImportService.maxZipBytes) {
    throw const FormatException('ZIP 超过 128 MiB');
  }
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  if (directory.fileHeaders.isEmpty ||
      directory.fileHeaders.length > 259 ||
      directory.numberOfThisDisk != 0 ||
      directory.diskWithTheStartOfTheCentralDirectory != 0) {
    throw const FormatException('ZIP 为空、文件过多或为分卷压缩包');
  }
  final files = <String, ZipFileHeader>{};
  var total = 0;
  for (final header in directory.fileHeaders) {
    final name = header.filename;
    final type = (header.externalFileAttributes >> 16) & 0xf000;
    if (type != 0 && type != 0x8000 && type != 0x4000 ||
        header.generalPurposeBitFlag & 1 != 0 ||
        !const [0, 8].contains(header.compressionMethod)) {
      throw const FormatException('ZIP 不允许链接、特殊文件、加密或非标准压缩');
    }
    if (name == 'cards/' || name == 'sources/') continue;
    if (name != 'manifest.json' &&
        !RegExp(r'^(cards|sources)/[A-Za-z0-9][A-Za-z0-9_.-]*\.(jpg|jpeg|png)$')
            .hasMatch(name)) {
      throw FormatException('不允许的 ZIP 路径：$name');
    }
    if (files.containsKey(name) ||
        header.file == null ||
        header.file!.filename != name ||
        header.uncompressedSize != header.file!.uncompressedSize ||
        header.file!.flags & 1 != 0) {
      throw const FormatException('ZIP 含重名文件或不一致的文件头');
    }
    final limit = name == 'manifest.json'
        ? 1024 * 1024
        : CheckedChekiImportService.maxFileBytes;
    total += header.uncompressedSize;
    if (header.uncompressedSize <= 0 ||
        header.uncompressedSize > limit ||
        total > CheckedChekiImportService.maxExpandedBytes) {
      throw const FormatException('ZIP 展开超过限制：单图 32 MiB、总计 256 MiB、清单 1 MiB');
    }
    files[name] = header;
  }
  Uint8List read(String path) {
    final header = files[path];
    if (header == null) throw FormatException('ZIP 缺少 $path');
    final output = _LimitedBytes(header.uncompressedSize);
    final sink = header.compressionMethod == 8
        ? ZLibDecoder(raw: true).startChunkedConversion(output)
        : output;
    final raw = header.file!.getRawContent();
    for (var offset = 0; offset < raw.length; offset += 16384) {
      sink.add(Uint8List.sublistView(
          raw, offset, (offset + 16384).clamp(0, raw.length)));
    }
    sink.close();
    final data = output.builder.takeBytes();
    if (data.length != header.uncompressedSize ||
        getCrc32(data) != header.crc32) {
      throw FormatException('$path 长度或 CRC 校验失败');
    }
    return data;
  }

  final manifest = jsonDecode(utf8.decode(read('manifest.json')));
  if (manifest is! Map ||
      manifest['format'] != 'ota-checked-cheki' ||
      manifest['version'] != 1 ||
      manifest['cards'] is! List ||
      (manifest['cards'] as List).isEmpty ||
      (manifest['cards'] as List).length > CheckedChekiImportService.maxCards) {
    throw const FormatException('仅支持 ota-checked-cheki v1，1–128 张；不支持备份');
  }
  final dimensions = <String, (int, int)>{};
  final sourceHashes = <String, String>{};
  final usedPaths = <String>{'manifest.json'};
  final cards = <CheckedChekiCard>[];
  for (final row in manifest['cards']) {
    if (row is! Map) throw const FormatException('卡片条目格式错误');
    String field(String key, {bool empty = false}) {
      final value = row[key];
      if (value is! String || (!empty && value.isEmpty) || value.length > 500) {
        throw FormatException('卡片缺少有效 $key');
      }
      return value;
    }

    final id = field('card_id');
    final record = row['record_id'];
    final date = field('date');
    final day = DateTime.tryParse(date);
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,95}$').hasMatch(id) ||
        record is! int ||
        record <= 0 ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
        day == null ||
        _date(day) != date) {
      throw FormatException('$id：卡号、record_id 或日期格式错误');
    }
    final imagePath = field('image'), source = field('source');
    final hash = field('source_sha1');
    if (!imagePath.startsWith('cards/') ||
        !source.startsWith('sources/') ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(hash)) {
      throw FormatException('$id：图片路径或原图 SHA1 格式错误');
    }
    usedPaths.addAll([imagePath, source]);
    if (!dimensions.containsKey(source)) {
      final original = read(source);
      sourceHashes[source] = sha1.convert(original).toString();
      dimensions[source] = _imageDimensions(original, source);
    }
    if (sourceHashes[source] != hash) throw FormatException('$id：原图 SHA1 不符');
    final quad = row['quad'];
    _canonicalQuad(quad);
    final q = {for (final key in _quadKeys) key: (quad[key] as num).toDouble()};
    final (width, height) = dimensions[source]!;
    final points = [
      (q['tlx']!, q['tly']!),
      (q['trx']!, q['try']!),
      (q['brx']!, q['bry']!),
      (q['blx']!, q['bly']!)
    ];
    for (var i = 0; i < 4; i++) {
      final a = points[i], b = points[(i + 1) % 4], c = points[(i + 2) % 4];
      if (a.$1 > width - 1 ||
          a.$2 > height - 1 ||
          (b.$1 - a.$1) * (c.$2 - b.$2) - (b.$2 - a.$2) * (c.$1 - b.$1) <= 0) {
        throw FormatException('$id：quad 越界、交叉或退化');
      }
    }
    final imageBytes = read(imagePath);
    _imageDimensions(imageBytes, imagePath);
    cards.add(CheckedChekiCard._(
        id,
        record,
        date,
        field('subject'),
        field('group', empty: true),
        imagePath,
        hash,
        jsonEncode({...q, '_checked_card_id': id}),
        imageBytes));
  }
  if (usedPaths.length != files.length || !usedPaths.containsAll(files.keys)) {
    throw const FormatException('ZIP 含未在清单声明的文件');
  }
  return List.unmodifiable(cards);
}

(int, int) _imageDimensions(Uint8List bytes, String path) {
  final decoder = path.endsWith('.png') ? img.PngDecoder() : img.JpegDecoder();
  final info = decoder.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > 24000000 ||
      info.numFrames != 1) {
    throw FormatException('$path：不是有效的单帧 JPEG/PNG 或超过 2400 万像素');
  }
  final image = decoder.decodeFrame(0);
  if (image == null) throw FormatException('$path：图片损坏');
  final orientation = image.exif.imageIfd.orientation ?? 1;
  return orientation >= 5 && orientation <= 8
      ? (image.height, image.width)
      : (image.width, image.height);
}

class _LimitedBytes implements Sink<List<int>> {
  final int limit;
  final builder = BytesBuilder(copy: false);
  _LimitedBytes(this.limit);
  @override
  void add(List<int> bytes) {
    if (builder.length + bytes.length > limit) {
      throw const FormatException('ZIP 实际展开超出声明大小');
    }
    builder.add(bytes);
  }

  @override
  void close() {}
}
