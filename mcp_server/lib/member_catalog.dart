import 'dart:convert';
import 'dart:io';

/// One member from the repository roster (assets/data/china_idols_seed.json).
class CatalogMember {
  const CatalogMember({
    required this.name,
    required this.group,
    required this.status,
  });

  final String name;
  final String group;
  final String status;

  bool get former =>
      status.contains('前成员') ||
      status.contains('毕业') ||
      status.contains('離團') ||
      status.contains('离团');

  Map<String, Object?> toJson({String match = '', int score = 0}) => {
        'name': name,
        'group': group,
        'status': status,
        'former': former,
        'match': match,
        'score': score,
      };
}

/// Name lookup shared by search_member: app snapshot + the repo's idol seed.
///
/// The seed is 694 groups (825+ in newer copies); it is deployed next to the
/// binary at /opt/ota-counter-sync/china_idols_seed.json and read once.
class MemberCatalog {
  const MemberCatalog(this.roster, {this.aliases = const {}});

  final List<CatalogMember> roster;

  /// normalized alias -> canonical member name.
  final Map<String, String> aliases;

  static const MemberCatalog empty = MemberCatalog([]);

  static const List<String> defaultSeedPaths = [
    '/opt/ota-counter-sync/china_idols_seed.json',
    'assets/data/china_idols_seed.json',
  ];

  static const Map<String, String> builtInAliases = {
    '猪猪包': '皮皮猪',
    'yuina': '優晴Yu1na',
  };

  static Future<MemberCatalog> load({
    String? seedPath,
    String? aliasPath,
    bool verbose = false,
  }) async {
    final candidates = <String>[
      if (seedPath != null && seedPath.trim().isNotEmpty) seedPath.trim(),
      ...defaultSeedPaths,
      if (seedPath != null && seedPath.trim().isNotEmpty)
        '${seedPath.trim()}/../china_idols_seed.json',
    ];
    List<CatalogMember> roster = const [];
    String? used;
    for (final path in candidates) {
      final file = File(path);
      if (!await file.exists()) continue;
      try {
        final decoded = jsonDecode(await file.readAsString());
        final groups = decoded is Map ? decoded['groups'] : null;
        if (groups is! List) continue;
        final members = <CatalogMember>[];
        for (final group in groups) {
          if (group is! Map) continue;
          final groupName = (group['name'] ?? '').toString().trim();
          final list = group['members'];
          if (list is! List) continue;
          for (final item in list) {
            if (item is! Map) continue;
            final name = (item['name'] ?? '').toString().trim();
            if (name.isEmpty) continue;
            members.add(CatalogMember(
              name: name,
              group: groupName,
              status: (item['status'] ?? '').toString().trim(),
            ));
          }
        }
        roster = members;
        used = path;
        break;
      } catch (_) {
        continue;
      }
    }

    final aliasMap = <String, String>{...builtInAliases};
    final aliasFiles = <String>[
      if (aliasPath != null && aliasPath.trim().isNotEmpty) aliasPath.trim(),
      '/opt/ota-counter-sync/member_aliases.json',
      'mcp_server/data/member_aliases.json',
    ];
    for (final path in aliasFiles) {
      final file = File(path);
      if (!await file.exists()) continue;
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map) continue;
        for (final entry in decoded.entries) {
          final key = normalizeName(entry.key.toString());
          if (key.isEmpty) continue;
          final value = entry.value;
          if (value is String) {
            final canonical = normalizeName(value);
            if (canonical.isNotEmpty) aliasMap[key] = value.toString();
          } else if (value is List) {
            for (final alias in value) {
              final aliasKey = normalizeName(alias.toString());
              if (aliasKey.isNotEmpty && aliasKey != key) {
                aliasMap[aliasKey] = entry.key.toString();
              }
            }
          }
        }
      } catch (_) {
        continue;
      }
    }

    if (verbose) {
      stderr.writeln(
          'Member roster: ${roster.length} names from ${used ?? 'none'}');
    }
    return MemberCatalog(roster, aliases: aliasMap);
  }

  /// Loose comparison used by search; 1↔i mirrors 優晴Yu1na / Yuina.
  static String normalizeName(String value) {
    var text = value.trim().toLowerCase();
    text = text.replaceAll(RegExp(r'[\s·•・_\-~/\\()\[\]{}（）【】「」『』“”]+'), '');
    text = text.replaceAll('1', 'i').replaceAll('0', 'o').replaceAll('5', 's');
    return text;
  }

  static int _similarity(String query, String candidate) {
    if (query.isEmpty || candidate.isEmpty) return 0;
    if (query == candidate) return 100;
    if (candidate.startsWith(query)) {
      return query.length >= 2 ? 90 : 70;
    }
    if (candidate.contains(query)) {
      return query.length >= 2 ? 80 : 60;
    }
    // Ordered subsequence (e.g. "優晴yuina" query "yuina" is caught above;
    // this helps with mixed Chinese/Latin spellings).
    var index = 0;
    for (var i = 0; i < candidate.length && index < query.length; i++) {
      if (candidate[i] == query[index]) index += 1;
    }
    if (index == query.length) {
      return 50 * query.length ~/ candidate.length + 20;
    }
    return 0;
  }

  static ({String match, int score}) bestMatch(String query, String name) {
    final q = normalizeName(query);
    final n = normalizeName(name);
    final direct = _similarity(q, n);
    final alias = builtInAliases[q] ?? builtInAliases[query.trim()];
    if (alias != null && normalizeName(alias) == n) {
      return (match: name, score: 95);
    }
    return (match: name, score: direct);
  }

  List<({CatalogMember member, int score})> search(
    String query, {
    int limit = 10,
  }) {
    final q = normalizeName(query);
    if (q.isEmpty) return const [];
    final aliasTarget = aliases[q];
    final scored = <({CatalogMember member, int score})>[];
    for (final member in roster) {
      var score = _similarity(q, normalizeName(member.name));
      if (aliasTarget != null &&
          normalizeName(member.name) == normalizeName(aliasTarget)) {
        score = 96;
      }
      // Also let an alias match a roster name directly.
      for (final entry in aliases.entries) {
        if (normalizeName(member.name) == normalizeName(entry.value) &&
            entry.key == q) {
          score = score < 96 ? 96 : score;
        }
      }
      if (score > 0) {
        scored.add((member: member, score: score));
      }
    }
    scored.sort((a, b) {
      final s = b.score.compareTo(a.score);
      if (s != 0) return s;
      if (a.member.former != b.member.former) {
        return a.member.former ? 1 : -1;
      }
      return a.member.name.compareTo(b.member.name);
    });
    return scored.take(limit).toList(growable: false);
  }
}
