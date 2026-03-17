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
      memberCount:
          ((map['member_count'] ?? map['memberCount']) as num?)?.toInt() ?? 0,
      isBuiltIn:
          ((map['is_builtin'] ?? map['isBuiltIn']) as num?)?.toInt() == 1,
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

  String get displayName => _sanitizeIdolDisplayName(name);

  String? get themeColorHex =>
      _extractInlineHex('$name $status') ??
      _extractIdolThemeColorHex('$name $status');

  String? get themeColorLabel => _extractIdolThemeColorLabel('$name $status');

  factory IdolMember.fromMap(Map<String, Object?> map) {
    return IdolMember(
      id: map['id'] as int?,
      groupId: ((map['group_id'] ?? 0) as num).toInt(),
      groupName: (map['group_name'] ?? map['groupName'] ?? '') as String,
      name: (map['name'] ?? '') as String,
      status: (map['status'] ?? '') as String,
      isBuiltIn:
          ((map['is_builtin'] ?? map['isBuiltIn']) as num?)?.toInt() == 1,
      source: (map['source'] ?? 'manual') as String,
    );
  }

  bool matchesQuery(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return true;
    }

    return name.toLowerCase().contains(normalized) ||
        displayName.toLowerCase().contains(normalized) ||
        groupName.toLowerCase().contains(normalized) ||
        status.toLowerCase().contains(normalized) ||
        (themeColorLabel?.toLowerCase().contains(normalized) ?? false) ||
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
    final rawGroups =
        (json['groups'] as List<dynamic>? ?? []).cast<Map<String, Object?>>();

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
    final rawMembers =
        (json['members'] as List<dynamic>? ?? []).cast<Map<String, Object?>>();

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

class _IdolThemeColor {
  final String label;
  final String hex;
  final List<String> aliases;

  const _IdolThemeColor({
    required this.label,
    required this.hex,
    required this.aliases,
  });
}

const List<_IdolThemeColor> _idolThemeColors = [
  _IdolThemeColor(
    label: '玫红色担当',
    hex: '#EC4899',
    aliases: ['玫红色', '玫红'],
  ),
  _IdolThemeColor(
    label: '浅粉色担当',
    hex: '#F9A8D4',
    aliases: ['樱花粉色', '樱花粉', '浅粉色', '浅粉'],
  ),
  _IdolThemeColor(
    label: '粉色担当',
    hex: '#F472B6',
    aliases: ['粉红色', '粉红', '粉色', '粉'],
  ),
  _IdolThemeColor(
    label: '桃色担当',
    hex: '#FB7185',
    aliases: ['桃色', '桃'],
  ),
  _IdolThemeColor(
    label: '红色担当',
    hex: '#EF4444',
    aliases: ['大红色', '大红', '红色', '红'],
  ),
  _IdolThemeColor(
    label: '橙色担当',
    hex: '#FB923C',
    aliases: ['橙色', '橙'],
  ),
  _IdolThemeColor(
    label: '黄色担当',
    hex: '#FACC15',
    aliases: ['亮黄色', '黄色', '黄'],
  ),
  _IdolThemeColor(
    label: '金色担当',
    hex: '#D4AF37',
    aliases: ['金黄色', '金黄', '金色', '金'],
  ),
  _IdolThemeColor(
    label: '绿色担当',
    hex: '#22C55E',
    aliases: ['亮绿色', '绿色', '绿'],
  ),
  _IdolThemeColor(
    label: '薄荷色担当',
    hex: '#6EE7B7',
    aliases: ['薄荷色', '薄荷'],
  ),
  _IdolThemeColor(
    label: '水色担当',
    hex: '#67E8F9',
    aliases: ['水蓝色', '水蓝', '水色'],
  ),
  _IdolThemeColor(
    label: '青蓝色担当',
    hex: '#22D3EE',
    aliases: ['青蓝色', '青蓝'],
  ),
  _IdolThemeColor(
    label: '湖蓝色担当',
    hex: '#06B6D4',
    aliases: ['湖蓝色', '湖蓝'],
  ),
  _IdolThemeColor(
    label: '天蓝色担当',
    hex: '#38BDF8',
    aliases: ['天蓝色', '天蓝'],
  ),
  _IdolThemeColor(
    label: '浅蓝色担当',
    hex: '#60A5FA',
    aliases: ['浅蓝色', '浅蓝'],
  ),
  _IdolThemeColor(
    label: '深蓝色担当',
    hex: '#2563EB',
    aliases: ['深蓝色', '深蓝'],
  ),
  _IdolThemeColor(
    label: '蓝色担当',
    hex: '#3B82F6',
    aliases: ['宝蓝色', '宝蓝', '蓝色', '蓝'],
  ),
  _IdolThemeColor(
    label: '青色担当',
    hex: '#14B8A6',
    aliases: ['青色', '青'],
  ),
  _IdolThemeColor(
    label: '紫色担当',
    hex: '#A855F7',
    aliases: ['紫罗兰色', '紫罗兰', '紫色', '紫'],
  ),
  _IdolThemeColor(
    label: '白色担当',
    hex: '#F3F4F6',
    aliases: ['纯白色', '纯白', '白色', '白'],
  ),
  _IdolThemeColor(
    label: '黑色担当',
    hex: '#1F2937',
    aliases: ['纯黑色', '纯黑', '黑色', '黑'],
  ),
  _IdolThemeColor(
    label: '银色担当',
    hex: '#CBD5E1',
    aliases: ['银白色', '银白', '银色', '银'],
  ),
  _IdolThemeColor(
    label: '灰色担当',
    hex: '#9CA3AF',
    aliases: ['灰色', '灰'],
  ),
  _IdolThemeColor(
    label: '棕色担当',
    hex: '#A16207',
    aliases: ['棕色', '棕', '咖色', '咖啡色'],
  ),
];

final String _idolThemeAliasPattern = _buildIdolThemeAliasPattern();

final RegExp _leadingThemeRolePattern = RegExp(
  '^(?:前|现|現)?(?:$_idolThemeAliasPattern)(?:担当色|担当|擔當)[_\\s:：\\-—－|/]*',
);

final RegExp _trailingThemeRolePattern = RegExp(
  '[，,、\\s]*(?:前|现|現)?(?:$_idolThemeAliasPattern)(?:担当色|担当|擔當).*' r'$',
);

final RegExp _dashSeparatorPattern = RegExp(r'\s*[—－-]{1,2}\s*');

final RegExp _memberDescriptorPattern = RegExp(
  r'(?:担当|擔當|成员|成員|研修生|练习生|練習生|候补|候補|加入于|末次|毕业|畢業|初始|正式|前成员|现成员|現成员|飞行成员)',
);

String _buildIdolThemeAliasPattern() {
  final aliases = <String>{};
  for (final color in _idolThemeColors) {
    aliases.addAll(color.aliases);
  }

  final ordered = aliases.toList()
    ..sort((left, right) => right.length.compareTo(left.length));
  return ordered.map(RegExp.escape).join('|');
}

String _normalizeThemeSource(String text) {
  return text
      .replaceAll('擔當', '担当')
      .replaceAll('　', '')
      .replaceAll(
        RegExp(r'[\s_，,、:：;；()（）\[\]【】<>《》|/\\\-—－]+'),
        '',
      )
      .trim();
}

_IdolThemeColor? _matchIdolThemeColor(String text) {
  final normalized = _normalizeThemeSource(text);
  if (normalized.isEmpty || !normalized.contains('担当')) {
    return null;
  }

  for (final color in _idolThemeColors) {
    for (final alias in color.aliases) {
      if (normalized.contains('$alias担当') ||
          normalized.contains('$alias担当色') ||
          normalized.contains('担当色$alias') ||
          normalized.contains('担当$alias')) {
        return color;
      }
    }
  }

  return null;
}

String? _extractIdolThemeColorHex(String text) {
  return _matchIdolThemeColor(text)?.hex;
}

String? _extractIdolThemeColorLabel(String text) {
  return _matchIdolThemeColor(text)?.label;
}

String? _extractInlineHex(String text) {
  final match = RegExp(r'#[0-9a-fA-F]{6}').firstMatch(text);
  return match?.group(0)?.toUpperCase();
}

String _sanitizeIdolDisplayName(String raw) {
  var text = raw.trim();
  if (text.isEmpty) {
    return text;
  }

  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  text = text.replaceFirst(_leadingThemeRolePattern, '').trim();

  for (final separator in const ['_', '，', ',', '、', '|', '/', '／']) {
    final parts = text
        .split(separator)
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length > 1 &&
        parts.skip(1).any((part) => _memberDescriptorPattern.hasMatch(part))) {
      text = parts.first;
      break;
    }
  }

  final dashParts = text
      .split(_dashSeparatorPattern)
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
  if (dashParts.length > 1 &&
      dashParts
          .skip(1)
          .any((part) => _memberDescriptorPattern.hasMatch(part))) {
    text = dashParts.first;
  }

  text = text.replaceAll(_trailingThemeRolePattern, '').trim();
  text = text.replaceAll(RegExp(r'[_\s，,、:：\-—－|/]+$'), '').trim();

  return text.isEmpty ? raw.trim() : text;
}
