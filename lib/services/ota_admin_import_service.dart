import 'dart:convert';

import '../models/activity_record_model.dart';
import '../models/group_pricing_model.dart';
import '../models/idol_database_models.dart';
import 'database_service.dart';
import 'idol_database_service.dart';

class OtaAdminImportResult {
  final int pricingCount;
  final int syncedMemberCount;
  final int importedCount;
  final int skippedCount;

  const OtaAdminImportResult({
    required this.pricingCount,
    required this.syncedMemberCount,
    required this.importedCount,
    required this.skippedCount,
  });
}

class OtaHistoryBundle {
  final List<Map<String, dynamic>> groups;
  final List<Map<String, dynamic>> idols;
  final List<Map<String, dynamic>> records;

  const OtaHistoryBundle({
    required this.groups,
    required this.idols,
    required this.records,
  });

  factory OtaHistoryBundle.fromJsonString(String rawJson) {
    final sanitized = rawJson.replaceFirst('\ufeff', '').trim();
    if (sanitized.isEmpty) {
      throw const FormatException('导入文件为空');
    }

    final decoded = jsonDecode(sanitized);
    if (decoded is List) {
      return OtaHistoryBundle(
        groups: const [],
        idols: const [],
        records: _readListOfMaps(decoded),
      );
    }

    if (decoded is Map<String, dynamic>) {
      if (decoded['ok'] == false) {
        throw Exception(decoded['message']?.toString() ?? '导入文件内容无效');
      }

      final records = _readListOfMaps(decoded['records']);
      final groups = _readListOfMaps(decoded['groups']);
      final idols = _readListOfMaps(decoded['idols']);

      if (records.isEmpty && groups.isEmpty && idols.isEmpty) {
        throw const FormatException('未找到可导入的数据');
      }

      return OtaHistoryBundle(
        groups: groups,
        idols: idols,
        records: records,
      );
    }

    throw const FormatException('导入文件格式不正确');
  }

  static List<Map<String, dynamic>> _readListOfMaps(Object? value) {
    if (value is! List) {
      return const [];
    }

    return value.whereType<Map>().map((item) {
      return item.map(
        (key, entryValue) => MapEntry(key.toString(), entryValue),
      );
    }).toList();
  }
}

class OtaAdminImportService {
  static const String _source = 'ota_site';
  static const String _idolSource = 'ota_export_bundle';

  static Future<OtaAdminImportResult> importBundleJson(String rawJson) async {
    final bundle = OtaHistoryBundle.fromJsonString(rawJson);
    return importBundle(bundle);
  }

  static Future<OtaAdminImportResult> importBundle(
    OtaHistoryBundle bundle,
  ) async {
    final groups = bundle.groups;
    final records = bundle.records;
    await IdolDatabaseService.initializeBuiltInDataIfNeeded();
    final syncedMemberCount = await _mergeBundleIdols(bundle.idols);
    final idolGroups = await IdolDatabaseService.getGroups();
    final idolMembers = await IdolDatabaseService.getMembers();
    final counters = await DatabaseService.getCounters();
    final importContext = _ImportContext(
      groupNames: [
        ...groups.map((group) => (group['name'] ?? '').toString()),
        ...bundle.idols.map((idol) => (idol['group'] ?? '').toString()),
        ...idolGroups.map((group) => group.name),
        ...counters.map((counter) => counter.groupName),
      ],
      rawMembers: bundle.idols
          .map(
            (idol) => _ImportMember(
              groupName: (idol['group'] ?? '').toString(),
              name: (idol['name'] ?? '').toString(),
            ),
          )
          .followedBy(
            idolMembers.map(
              (member) => _ImportMember(
                groupName: member.groupName,
                name: member.name,
              ),
            ),
          )
          .followedBy(
            counters
                .where((counter) => counter.groupName.trim().isNotEmpty)
                .map(
                  (counter) => _ImportMember(
                    groupName: counter.groupName,
                    name: counter.name,
                  ),
                ),
          )
          .toList(),
    );

    var pricingCount = 0;
    for (final group in groups) {
      final groupName = (group['name'] ?? '').toString();
      if (groupName.trim().isEmpty) {
        continue;
      }
      final resolvedGroupName = importContext.resolveGroupName(groupName);

      final prices = (group['prices'] as Map?)?.cast<String, dynamic>() ?? {};
      await DatabaseService.upsertGroupPricing(
        GroupPricingModel(
          groupName: resolvedGroupName,
          label: 'OTA 旧站默认价',
          threeInchPrice: _readDouble(prices['xiaoqie']),
          fiveInchPrice: _readDouble(prices['daqie']),
          groupCutPrice: _readDouble(prices['tuanqie']),
          updatedAt: DateTime.now(),
        ),
      );
      pricingCount += 1;
    }

    final existingIds =
        await DatabaseService.getActivityRecordSourceIds(_source);
    var importedCount = 0;
    var skippedCount = 0;

    for (final record in records) {
      final sourceRecordId = (record['id'] ?? '').toString().trim();
      if (sourceRecordId.isEmpty) {
        skippedCount += 1;
        continue;
      }
      if (existingIds.contains(sourceRecordId)) {
        skippedCount += 1;
        continue;
      }

      final mappedRecord = _mapRemoteRecord(record, importContext);
      await DatabaseService.insertActivityRecord(
        mappedRecord.copyWith(
          source: _source,
          sourceRecordId: sourceRecordId,
        ),
      );
      existingIds.add(sourceRecordId);
      importedCount += 1;
    }

    await DatabaseService.syncActivityRecordsToCounters(_source);

    return OtaAdminImportResult(
      pricingCount: pricingCount,
      syncedMemberCount: syncedMemberCount,
      importedCount: importedCount,
      skippedCount: skippedCount,
    );
  }

  static Future<int> _mergeBundleIdols(List<Map<String, dynamic>> idols) async {
    if (idols.isEmpty) {
      return 0;
    }

    final existingGroups = await IdolDatabaseService.getGroups();
    final existingMembers = await IdolDatabaseService.getMembers();
    final groupsByNormalized = <String, IdolGroup>{};
    final membersByKey = <String, IdolMember>{};

    for (final group in existingGroups) {
      final normalizedGroup = _ImportContext._normalizeName(group.name);
      if (normalizedGroup.isEmpty) {
        continue;
      }
      groupsByNormalized.putIfAbsent(normalizedGroup, () => group);
    }

    for (final member in existingMembers) {
      final normalizedGroup = _ImportContext._normalizeName(member.groupName);
      final normalizedMember = _ImportContext._normalizeName(member.name);
      if (normalizedGroup.isEmpty || normalizedMember.isEmpty) {
        continue;
      }
      membersByKey.putIfAbsent(
        '$normalizedGroup|$normalizedMember',
        () => member,
      );
    }

    var insertedCount = 0;
    for (final idol in idols) {
      final groupName = (idol['group'] ?? '').toString().trim();
      final memberName = (idol['name'] ?? '').toString().trim();
      final status = (idol['status'] ?? '').toString().trim();
      final normalizedGroup = _ImportContext._normalizeName(groupName);
      final normalizedMember = _ImportContext._normalizeName(memberName);

      if (normalizedGroup.isEmpty || normalizedMember.isEmpty) {
        continue;
      }

      var group = groupsByNormalized[normalizedGroup];
      if (group == null) {
        final groupId = await IdolDatabaseService.upsertGroup(
          IdolGroup(
            name: groupName,
            source: _idolSource,
          ),
        );
        group = IdolGroup(
          id: groupId,
          name: groupName,
          source: _idolSource,
        );
        groupsByNormalized[normalizedGroup] = group;
      }

      final memberKey = '$normalizedGroup|$normalizedMember';
      if (membersByKey.containsKey(memberKey) || group.id == null) {
        continue;
      }

      final member = IdolMember(
        groupId: group.id!,
        groupName: group.name,
        name: memberName,
        status: status,
        source: _idolSource,
      );
      final memberId = await IdolDatabaseService.upsertMember(member);
      membersByKey[memberKey] = member.copyWith(id: memberId);
      insertedCount += 1;
    }

    return insertedCount;
  }

  static ActivityRecordModel _mapRemoteRecord(
    Map<String, dynamic> record,
    _ImportContext context,
  ) {
    final cutType = (record['cutType'] ?? '').toString();
    final qty = _readInt(record['qty']);
    final price = _readDouble(record['price']);
    final note = (record['note'] ?? '').toString();
    final occurredAt = DateTime.tryParse((record['ts'] ?? '').toString()) ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final rawGroupName = (record['group'] ?? '').toString();
    final rawSubjectName = (record['idol'] ?? '').toString();
    final resolvedGroupName = cutType == 'ticket'
        ? rawGroupName.trim()
        : context.resolveGroupName(rawGroupName);
    final resolvedSubjectName = cutType == 'ticket'
        ? rawSubjectName.trim()
        : context.resolveMemberName(
            rawMemberName: rawSubjectName,
            rawGroupName: rawGroupName,
            resolvedGroupName: resolvedGroupName,
          );

    if (cutType == 'ticket') {
      return ActivityRecordModel.ticket(
        eventName: resolvedGroupName,
        occurredAt: occurredAt,
        sessionLabel: resolvedSubjectName,
        note: note,
        quantity: qty,
        unitPrice: price,
      ).copyWith(pricingLabel: 'OTA 历史导入');
    }

    final isShukudai = note.contains('宿题') || note.contains('宿題');
    var threeInchCount = 0;
    var fiveInchCount = 0;
    var groupCutCount = 0;
    var threeInchShukudaiCount = 0;
    var fiveInchShukudaiCount = 0;
    var threeInchPrice = 0.0;
    var fiveInchPrice = 0.0;
    var groupCutPrice = 0.0;
    var threeInchShukudaiPrice = 0.0;
    var fiveInchShukudaiPrice = 0.0;

    switch (cutType) {
      case 'daqie':
        if (isShukudai) {
          fiveInchShukudaiCount = qty;
          fiveInchShukudaiPrice = price;
        } else {
          fiveInchCount = qty;
          fiveInchPrice = price;
        }
        break;
      case 'xiaoqie':
        if (isShukudai) {
          threeInchShukudaiCount = qty;
          threeInchShukudaiPrice = price;
        } else {
          threeInchCount = qty;
          threeInchPrice = price;
        }
        break;
      case 'tuanqie':
        groupCutCount = qty;
        groupCutPrice = price;
        break;
      default:
        break;
    }

    return ActivityRecordModel(
      type: ActivityRecordType.counter,
      subjectName: resolvedSubjectName,
      groupName: resolvedGroupName,
      note: note,
      occurredAt: occurredAt,
      pricingLabel: 'OTA 历史导入',
      threeInchCount: threeInchCount,
      fiveInchCount: fiveInchCount,
      groupCutCount: groupCutCount,
      threeInchShukudaiCount: threeInchShukudaiCount,
      fiveInchShukudaiCount: fiveInchShukudaiCount,
      threeInchPrice: threeInchPrice,
      fiveInchPrice: fiveInchPrice,
      groupCutPrice: groupCutPrice,
      threeInchShukudaiPrice: threeInchShukudaiPrice,
      fiveInchShukudaiPrice: fiveInchShukudaiPrice,
      totalAmount: _readDouble(record['finalAmount']),
    );
  }

  static int _readInt(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value) ?? 0;
    }
    return 0;
  }

  static double _readDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value) ?? 0;
    }
    return 0;
  }
}

class _ImportMember {
  final String groupName;
  final String name;

  const _ImportMember({
    required this.groupName,
    required this.name,
  });
}

class _ImportContext {
  final Map<String, String> _groupByNormalized = {};
  final Map<String, Map<String, String>> _membersByGroupNormalized = {};
  final Map<String, String> _membersGlobal = {};

  _ImportContext({
    required List<String> groupNames,
    required List<_ImportMember> rawMembers,
  }) {
    for (final groupName in groupNames) {
      final normalized = _normalizeName(groupName);
      if (normalized.isEmpty) {
        continue;
      }
      _groupByNormalized.putIfAbsent(normalized, () => groupName.trim());
    }

    for (final member in rawMembers) {
      final resolvedGroupName = resolveGroupName(member.groupName);
      final normalizedGroup = _normalizeName(resolvedGroupName);
      final normalizedMember = _normalizeName(member.name);
      if (normalizedGroup.isNotEmpty && normalizedMember.isNotEmpty) {
        final groupMembers = _membersByGroupNormalized.putIfAbsent(
          normalizedGroup,
          () => <String, String>{},
        );
        groupMembers.putIfAbsent(normalizedMember, () => member.name.trim());
      }
      if (normalizedMember.isNotEmpty) {
        _membersGlobal.putIfAbsent(normalizedMember, () => member.name.trim());
      }
    }
  }

  String resolveGroupName(String rawGroupName) {
    final normalized = _normalizeName(rawGroupName);
    if (normalized.isEmpty) {
      return rawGroupName.trim();
    }
    final exact = _groupByNormalized[normalized];
    if (exact != null) {
      return exact;
    }

    final fuzzy = _findBestFuzzyMatch(normalized, _groupByNormalized);
    return fuzzy ?? rawGroupName.trim();
  }

  String resolveMemberName({
    required String rawMemberName,
    required String rawGroupName,
    required String resolvedGroupName,
  }) {
    final normalizedMember = _normalizeName(rawMemberName);
    if (normalizedMember.isEmpty) {
      return rawMemberName.trim();
    }

    final groupCandidates = <String>[
      resolvedGroupName,
      rawGroupName,
    ];

    for (final groupName in groupCandidates) {
      final normalizedGroup = _normalizeName(groupName);
      if (normalizedGroup.isEmpty) {
        continue;
      }
      final byGroup = _membersByGroupNormalized[normalizedGroup];
      if (byGroup == null) {
        continue;
      }
      final exact = byGroup[normalizedMember];
      if (exact != null) {
        return exact;
      }
      final fuzzy = _findBestFuzzyMatch(normalizedMember, byGroup);
      if (fuzzy != null) {
        return fuzzy;
      }
    }

    final exact = _membersGlobal[normalizedMember];
    if (exact != null) {
      return exact;
    }

    return _findBestFuzzyMatch(normalizedMember, _membersGlobal) ??
        rawMemberName.trim();
  }

  static String _normalizeName(String value) {
    final trimmed = value.trim().toLowerCase();
    if (trimmed.isEmpty) {
      return '';
    }
    return trimmed.replaceAll(
      RegExp(r'[\s·•・_\-~/\\\(\)\[\]\{\}]+'),
      '',
    );
  }

  static String? _findBestFuzzyMatch(
    String normalizedTarget,
    Map<String, String> candidates,
  ) {
    String? bestMatch;
    var bestScore = 1 << 30;

    for (final entry in candidates.entries) {
      final normalizedCandidate = entry.key;
      if (!normalizedCandidate.contains(normalizedTarget) &&
          !normalizedTarget.contains(normalizedCandidate)) {
        continue;
      }

      final score =
          (normalizedCandidate.length - normalizedTarget.length).abs();
      if (score < bestScore) {
        bestScore = score;
        bestMatch = entry.value;
      }
    }

    return bestMatch;
  }
}
