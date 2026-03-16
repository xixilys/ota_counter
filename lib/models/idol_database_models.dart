import 'package:lpinyin/lpinyin.dart';

class IdolGroup {
  final int? id;
  final String name;
  final int memberCount;
  final bool isBuiltIn;
  final String source;

  const IdolGroup({
    this.id,
    required this.name,
    this.memberCount = 0,
    this.isBuiltIn = false,
    this.source = 'manual',
  });

  IdolGroup copyWith({
    int? id,
    String? name,
    int? memberCount,
    bool? isBuiltIn,
    String? source,
  }) {
    return IdolGroup(
      id: id ?? this.id,
      name: name ?? this.name,
      memberCount: memberCount ?? this.memberCount,
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
      source: source ?? this.source,
    );
  }

  factory IdolGroup.fromMap(Map<String, Object?> map) {
    return IdolGroup(
      id: map['id'] as int?,
      name: (map['name'] ?? '') as String,
      memberCount: ((map['member_count'] ?? map['memberCount']) as num?)?.toInt() ?? 0,
      isBuiltIn: ((map['is_builtin'] ?? map['isBuiltIn']) as num?)?.toInt() == 1,
      source: (map['source'] ?? 'manual') as String,
    );
  }
}

class IdolMember {
  final int? id;
  final int groupId;
  final String groupName;
  final String name;
  final String status;
  final bool isBuiltIn;
  final String source;
  final String namePinyin;
  final String groupPinyin;

  IdolMember({
    this.id,
    required this.groupId,
    required this.groupName,
    required this.name,
    this.status = '',
    this.isBuiltIn = false,
    this.source = 'manual',
  })  : namePinyin = PinyinHelper.getPinyinE(
          name,
          defPinyin: '#',
          format: PinyinFormat.WITHOUT_TONE,
        ),
        groupPinyin = PinyinHelper.getPinyinE(
          groupName,
          defPinyin: '#',
          format: PinyinFormat.WITHOUT_TONE,
        );

  IdolMember copyWith({
    int? id,
    int? groupId,
    String? groupName,
    String? name,
    String? status,
    bool? isBuiltIn,
    String? source,
  }) {
    return IdolMember(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      groupName: groupName ?? this.groupName,
      name: name ?? this.name,
      status: status ?? this.status,
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
      source: source ?? this.source,
    );
  }

  factory IdolMember.fromMap(Map<String, Object?> map) {
    return IdolMember(
      id: map['id'] as int?,
      groupId: ((map['group_id'] ?? 0) as num).toInt(),
      groupName: (map['group_name'] ?? map['groupName'] ?? '') as String,
      name: (map['name'] ?? '') as String,
      status: (map['status'] ?? '') as String,
      isBuiltIn: ((map['is_builtin'] ?? map['isBuiltIn']) as num?)?.toInt() == 1,
      source: (map['source'] ?? 'manual') as String,
    );
  }

  bool matchesQuery(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return true;
    }

    return name.toLowerCase().contains(normalized) ||
        groupName.toLowerCase().contains(normalized) ||
        status.toLowerCase().contains(normalized) ||
        namePinyin.toLowerCase().contains(normalized) ||
        groupPinyin.toLowerCase().contains(normalized);
  }
}

class IdolSeedBundle {
  final String sourceUrl;
  final String sourceLabel;
  final String generatedAt;
  final List<IdolSeedGroup> groups;

  const IdolSeedBundle({
    required this.sourceUrl,
    required this.sourceLabel,
    required this.generatedAt,
    required this.groups,
  });

  factory IdolSeedBundle.fromJson(Map<String, Object?> json) {
    final rawGroups = (json['groups'] as List<dynamic>? ?? [])
        .cast<Map<String, Object?>>();

    return IdolSeedBundle(
      sourceUrl: (json['sourceUrl'] ?? '') as String,
      sourceLabel: (json['sourceLabel'] ?? '') as String,
      generatedAt: (json['generatedAt'] ?? '') as String,
      groups: rawGroups.map(IdolSeedGroup.fromJson).toList(),
    );
  }
}

class IdolSeedGroup {
  final String name;
  final List<IdolSeedMember> members;

  const IdolSeedGroup({
    required this.name,
    required this.members,
  });

  factory IdolSeedGroup.fromJson(Map<String, Object?> json) {
    final rawMembers = (json['members'] as List<dynamic>? ?? [])
        .cast<Map<String, Object?>>();

    return IdolSeedGroup(
      name: (json['name'] ?? '') as String,
      members: rawMembers.map(IdolSeedMember.fromJson).toList(),
    );
  }
}

class IdolSeedMember {
  final String name;
  final String status;

  const IdolSeedMember({
    required this.name,
    required this.status,
  });

  factory IdolSeedMember.fromJson(Map<String, Object?> json) {
    return IdolSeedMember(
      name: (json['name'] ?? '') as String,
      status: (json['status'] ?? '') as String,
    );
  }
}
