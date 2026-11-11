import 'dart:async';

import 'package:flutter/material.dart';

import '../models/counter_model.dart';
import '../models/idol_database_models.dart';
import '../services/idol_database_service.dart';
import '../widgets/app_page_background.dart';
import '../widgets/no_autofill_text_field.dart';

/// Full-screen "添加偶像" flow.
///
/// The page searches the whole idol library at once and returns the counters
/// to insert. It deliberately has no count fields: a new member starts at
/// zero and counting happens from the quick-count sheet.
class AddIdolPage extends StatefulWidget {
  final List<CounterModel> existingCounters;

  /// Tests opt out of the network refresh; the app keeps it on.
  final bool autoSync;

  /// Tests opt out of the auto-focused search field, whose blinking cursor
  /// keeps pumpAndSettle busy. The real page keeps it on.
  final bool autoFocusSearch;

  const AddIdolPage({
    super.key,
    required this.existingCounters,
    this.autoSync = true,
    this.autoFocusSearch = true,
  });

  @override
  State<AddIdolPage> createState() => _AddIdolPageState();
}

class _IdolCandidate {
  final String key;
  final String name;
  final String groupName;
  final int? libraryPersonId;
  final String libraryPersonName;
  final String matchName;
  final String? colorHex;
  final IdolMember? member;

  const _IdolCandidate({
    required this.key,
    required this.name,
    required this.groupName,
    this.libraryPersonId,
    this.libraryPersonName = '',
    required this.matchName,
    this.colorHex,
    this.member,
  });

  bool get isManual => member == null;
}

class _ExistingPersonMatch {
  final int? personId;
  final String personName;
  final String groupName;
  final String counterName;

  const _ExistingPersonMatch({
    required this.personId,
    required this.personName,
    required this.groupName,
    required this.counterName,
  });

  String get displayName =>
      personName.trim().isNotEmpty ? personName.trim() : counterName.trim();
}

class _ManualIdolInput {
  final String name;
  final String groupName;

  const _ManualIdolInput({required this.name, required this.groupName});
}

class _AddIdolPageState extends State<AddIdolPage> {
  static const String _defaultColor = '#FFE135';
  static const int _resultLimit = 200;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final Map<String, _IdolCandidate> _selected = <String, _IdolCandidate>{};
  final Map<String, bool> _samePersonChoices = <String, bool>{};

  List<IdolGroup> _groups = const [];
  List<IdolMember> _members = const [];
  List<String> _allGroupNames = const [];
  late List<CounterModel> _existingCounters;
  bool _loading = true;
  bool _syncing = false;
  Object? _loadError;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _existingCounters = widget.existingCounters;
    unawaited(_loadLibrary());
    if (widget.autoSync) {
      unawaited(_syncLibraryInBackground());
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _loadLibrary() async {
    try {
      await IdolDatabaseService.initializeBuiltInDataIfNeeded();
      final results = await Future.wait([
        IdolDatabaseService.getGroups(),
        IdolDatabaseService.getMembers(),
      ]);
      final groups = results[0] as List<IdolGroup>;
      final members = results[1] as List<IdolMember>;
      final existingGroupNames = _existingCounters
          .map((counter) => counter.groupName.trim())
          .where((name) => name.isNotEmpty)
          .toList();
      final allGroupNames = <String>{
        for (final group in groups) group.name,
        ...existingGroupNames,
      }.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

      if (!mounted) {
        return;
      }
      setState(() {
        _groups = groups;
        _members = members;
        _allGroupNames = allGroupNames;
        _loading = false;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _loadError = error;
      });
    }
  }

  Future<void> _syncLibraryInBackground() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _syncing = true;
    });
    try {
      await IdolDatabaseService.syncFromRemoteIfStale();
      await _loadLibrary();
    } catch (_) {
      // The cached library stays usable when the upstream is unreachable.
    } finally {
      if (mounted) {
        setState(() {
          _syncing = false;
        });
      }
    }
  }

  String _normalize(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
  }

  String _normalizeLoose(String value) {
    final lowered = value.trim().toLowerCase();
    return lowered.replaceAll(
      RegExp(r'[\s·•・_\-~/\\\(\)\[\]\{\}]+'),
      '',
    );
  }

  bool _groupMatchesExactly(IdolGroup group, String query) {
    final normalized = _normalize(query);
    if (normalized.isEmpty) {
      return false;
    }
    final compactPinyin = _normalize(group.namePinyin);
    final initials = _normalize(group.nameInitials);
    return _normalize(group.name) == normalized ||
        _normalize(group.name).startsWith(normalized) && normalized.length >= 2 ||
        compactPinyin == normalized ||
        initials == normalized ||
        compactPinyin.startsWith(normalized) && normalized.length >= 3 ||
        initials.startsWith(normalized) && normalized.length >= 2;
  }

  _IdolCandidate _candidateForMember(IdolMember member) {
    return _IdolCandidate(
      key: 'member:${member.id ?? '${member.groupId}:${member.name}'}',
      name: member.displayName,
      groupName: member.groupName.trim(),
      libraryPersonId: member.personId,
      libraryPersonName: member.personName.trim(),
      matchName: member.resolvedPersonName,
      colorHex: member.themeColorHex,
      member: member,
    );
  }

  bool _isAlreadyAdded(_IdolCandidate candidate) {
    final groupKey = _normalize(candidate.groupName);
    final nameKey = _normalize(candidate.name);
    final matchNameKey = _normalize(candidate.matchName);

    for (final counter in _existingCounters) {
      if (_normalize(counter.groupName) != groupKey) {
        continue;
      }
      if (candidate.libraryPersonId != null &&
          counter.personId == candidate.libraryPersonId) {
        return true;
      }
      if (_normalize(counter.name) == nameKey) {
        return true;
      }
      final counterPersonName = _normalize(counter.personName);
      if (counterPersonName.isNotEmpty && counterPersonName == matchNameKey) {
        return true;
      }
    }
    return false;
  }

  _ExistingPersonMatch? _personMatchFor(_IdolCandidate candidate) {
    if (_isAlreadyAdded(candidate)) {
      return null;
    }

    _ExistingPersonMatch? fallback;
    for (final counter in _existingCounters) {
      final counterPersonName = counter.personName.trim().isNotEmpty
          ? counter.personName.trim()
          : counter.name.trim();
      final explicitMatch = candidate.libraryPersonId != null &&
          counter.personId == candidate.libraryPersonId;
      final nameMatch = _normalizeLoose(counterPersonName) ==
          _normalizeLoose(candidate.matchName);
      if (!explicitMatch && !nameMatch) {
        continue;
      }

      final match = _ExistingPersonMatch(
        personId: counter.personId,
        personName: counterPersonName,
        groupName: counter.groupName.trim(),
        counterName: counter.name.trim(),
      );
      if (explicitMatch) {
        return match;
      }
      fallback ??= match;
    }
    return fallback;
  }

  List<IdolGroup> get _followedGroups {
    final followedKeys = <String>{};
    for (final counter in _existingCounters) {
      final key = _normalize(counter.groupName);
      if (key.isNotEmpty) {
        followedKeys.add(key);
      }
    }
    final groups = _groups
        .where((group) => followedKeys.contains(_normalize(group.name)))
        .toList();
    return groups;
  }

  List<IdolMember> _notAddedMembersForGroup(IdolGroup group) {
    return _members
        .where((member) => member.groupId == group.id)
        .where((member) => !_isAlreadyAdded(_candidateForMember(member)))
        .toList(growable: false);
  }

  List<IdolMember> _searchResults() {
    final normalized = _query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return const [];
    }
    final compact = normalized.replaceAll(RegExp(r'\s+'), '');
    final ranks = <int, int>{};
    final results = <IdolMember>[];

    void addMember(IdolMember member, int rank) {
      final id = member.id;
      if (id != null && ranks.containsKey(id)) {
        if (rank < ranks[id]!) {
          ranks[id] = rank;
        }
        return;
      }
      if (results.length >= _resultLimit * 2) {
        return;
      }
      results.add(member);
      if (id != null) {
        ranks[id] = rank;
      }
    }

    final exactGroups = _groups
        .where((group) => _groupMatchesExactly(group, _query))
        .toList(growable: false);
    final partialGroups = _groups
        .where(
          (group) =>
              !exactGroups.contains(group) && group.matchesQuery(_query),
        )
        .take(exactGroups.isEmpty ? 5 : 0)
        .toList(growable: false);

    for (final group in exactGroups) {
      for (final member in _members.where((member) => member.groupId == group.id)) {
        addMember(member, 0);
      }
    }
    for (final group in partialGroups) {
      for (final member in _members.where((member) => member.groupId == group.id)) {
        addMember(member, 3);
      }
    }
    for (final member in _members) {
      if (!member.matchesQuery(_query)) {
        continue;
      }
      final name = member.displayName.toLowerCase();
      final rank = name.startsWith(normalized)
          ? 1
          : member.namePinyin.replaceAll(' ', '').startsWith(compact) ||
                  member.nameInitials.startsWith(normalized)
              ? 2
              : 4;
      addMember(member, rank);
    }

    final sorted = results.toList()
      ..sort((a, b) {
        final rankCompare =
            (ranks[a.id] ?? 99).compareTo(ranks[b.id] ?? 99);
        if (rankCompare != 0) {
          return rankCompare;
        }
        if (a.isActiveAffiliation != b.isActiveAffiliation) {
          return a.isActiveAffiliation ? -1 : 1;
        }
        final groupCompare =
            a.groupName.toLowerCase().compareTo(b.groupName.toLowerCase());
        if (groupCompare != 0) {
          return groupCompare;
        }
        return a.displayName
            .toLowerCase()
            .compareTo(b.displayName.toLowerCase());
      });
    return sorted.take(_resultLimit).toList(growable: false);
  }

  void _toggleCandidate(_IdolCandidate candidate) {
    if (_isAlreadyAdded(candidate)) {
      return;
    }
    setState(() {
      if (_selected.containsKey(candidate.key)) {
        _selected.remove(candidate.key);
        _samePersonChoices.remove(candidate.key);
      } else {
        _selected[candidate.key] = candidate;
        _samePersonChoices[candidate.key] = false;
      }
    });
    // Selecting a result reveals the bottom action bar; do not leave it
    // behind the keyboard.
    FocusScope.of(context).unfocus();
  }

  void _removeCandidate(_IdolCandidate candidate) {
    setState(() {
      _selected.remove(candidate.key);
      _samePersonChoices.remove(candidate.key);
    });
  }

  void _clearQuery() {
    _searchController.clear();
    setState(() {
      _query = '';
    });
    _searchFocus.requestFocus();
  }

  void _showManualAdd() {
    final exactGroup = _groups
        .where((group) => _groupMatchesExactly(group, _query))
        .firstOrNull;
    Navigator.of(context)
        .push<_ManualIdolInput>(
      MaterialPageRoute<_ManualIdolInput>(
        fullscreenDialog: true,
        builder: (context) => _ManualIdolPage(
          groupSuggestions: _allGroupNames,
          initialName:
              exactGroup == null ? _query.trim() : '',
          initialGroup: exactGroup?.name ?? '',
        ),
      ),
    )
        .then((result) {
      if (!mounted || result == null) {
        return;
      }
      final candidate = _IdolCandidate(
        key: 'manual:${_normalize(result.groupName)}|'
            '${_normalizeLoose(result.name)}',
        name: result.name.trim(),
        groupName: result.groupName.trim(),
        matchName: result.name.trim(),
      );
      if (_isAlreadyAdded(candidate)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('这个成员已经在首页了')),
        );
        return;
      }
      setState(() {
        _selected[candidate.key] = candidate;
        _samePersonChoices[candidate.key] = false;
      });
      _searchController.clear();
      _query = '';
      FocusScope.of(context).unfocus();
    });
  }

  Future<int?> _resolveMatchedPerson(_ExistingPersonMatch match) async {
    if (match.personId != null) {
      return match.personId;
    }
    return IdolDatabaseService.upsertPerson(
      IdolPerson(name: match.displayName),
    );
  }

  Future<void> _submit() async {
    if (_selected.isEmpty) {
      return;
    }

    final counters = <CounterModel>[];
    for (final candidate in _selected.values) {
      final match = _personMatchFor(candidate);
      final useMatch = match != null && (_samePersonChoices[candidate.key] ?? false);

      int? personId;
      String personName = '';
      if (useMatch) {
        personId = await _resolveMatchedPerson(match);
        personName = match.displayName;
      } else if (match == null) {
        personId = candidate.libraryPersonId;
        personName = candidate.libraryPersonName;
      }

      counters.add(
        CounterModel(
          name: candidate.name,
          groupName: candidate.groupName,
          personId: personId,
          personName: personName,
          color: candidate.colorHex ?? _defaultColor,
        ),
      );
    }

    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(counters);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final results = _searchResults();
    final exactGroup = _groups
        .where((group) => _groupMatchesExactly(group, _query))
        .firstOrNull;
    final selectedCandidates = _selected.values.toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('添加偶像'),
      ),
      body: AppPageBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: NoAutofillTextField(
                  controller: _searchController,
                  focusNode: _searchFocus,
                  autofocus: widget.autoFocusSearch,
                  decoration: InputDecoration(
                    hintText: '搜成员、团体、拼音或首字母',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除搜索',
                            onPressed: _clearQuery,
                            icon: const Icon(Icons.close),
                          ),
                  ),
                  textInputAction: TextInputAction.search,
                  onChanged: (value) {
                    setState(() {
                      _query = value;
                    });
                  },
                ),
              ),
              if (_syncing) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _buildContent(
                        context,
                        results: results,
                        exactGroup: exactGroup,
                        selectedCandidates: selectedCandidates,
                      ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: selectedCandidates.isEmpty
          ? null
          : SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  border: Border(
                    top: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '已选 ${selectedCandidates.length} 位',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _submit,
                      icon: const Icon(Icons.person_add_alt_1_rounded, size: 19),
                      label: Text('添加 ${selectedCandidates.length} 位'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildContent(
    BuildContext context, {
    required List<IdolMember> results,
    required IdolGroup? exactGroup,
    required List<_IdolCandidate> selectedCandidates,
  }) {
    if (_loadError != null) {
      return _CenteredMessage(
        icon: Icons.cloud_off_outlined,
        title: '偶像库读取失败',
        detail: '$_loadError',
        actionLabel: '重试',
        onAction: () {
          setState(() {
            _loading = true;
          });
          unawaited(_loadLibrary());
        },
      );
    }

    final children = <Widget>[];
    if (selectedCandidates.isNotEmpty) {
      children.add(
        _SelectedIdolsPanel(
          candidates: selectedCandidates,
          personMatchFor: _personMatchFor,
          samePersonChoices: _samePersonChoices,
          onChoiceChanged: (candidate, value) {
            setState(() {
              _samePersonChoices[candidate.key] = value;
            });
          },
          onRemove: _removeCandidate,
        ),
      );
      children.add(const SizedBox(height: 16));
    }

    if (_query.trim().isEmpty) {
      children.addAll(_buildShortcuts(context));
    } else {
      if (exactGroup != null) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '团体「${exactGroup.name}」 · ${exactGroup.memberCount} 位成员',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        );
      }
      if (results.isEmpty) {
        children.add(
          _CenteredMessage(
            icon: Icons.search_off_rounded,
            title: '没有找到「${_query.trim()}」',
            detail: '可以换个名字、团体或拼音试试',
            actionLabel: '库里没有？手动添加',
            onAction: _showManualAdd,
          ),
        );
      } else {
        children.addAll(
          results.map(
            (member) {
              final candidate = _candidateForMember(member);
              return _IdolResultTile(
                key: ValueKey<String>('add-idol-result-${candidate.key}'),
                candidate: candidate,
                added: _isAlreadyAdded(candidate),
                selected: _selected.containsKey(candidate.key),
                onTap: () => _toggleCandidate(candidate),
              );
            },
          ),
        );
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              onPressed: _showManualAdd,
              icon: const Icon(Icons.edit_outlined),
              label: const Text('找的人不在库里？手动添加'),
            ),
          ),
        );
      }
    }

    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: children,
    );
  }

  List<Widget> _buildShortcuts(BuildContext context) {
    final followed = _followedGroups;
    if (followed.isEmpty) {
      return [
        _CenteredMessage(
          icon: Icons.person_search_outlined,
          title: '搜索一位成员或团体',
          detail: '支持成员名、团体名、拼音和首字母。添加过的团体也会出现在这里。',
          actionLabel: '手动添加',
          onAction: _showManualAdd,
        ),
      ];
    }

    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          '继续添加',
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
    ];
    for (final group in followed) {
      final members = _notAddedMembersForGroup(group);
      if (members.isEmpty) {
        continue;
      }
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      group.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    '${members.length} 位未添加',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final member in members)
                    ActionChip(
                      key: ValueKey<String>(
                        'add-idol-shortcut-${member.id ?? member.name}',
                      ),
                      avatar: CircleAvatar(
                        child: Text(
                          member.displayName.isEmpty
                              ? '?'
                              : member.displayName.substring(0, 1),
                        ),
                      ),
                      label: Text(member.displayName),
                      onPressed: () => _toggleCandidate(
                        _candidateForMember(member),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    if (children.length == 1) {
      return [
        _CenteredMessage(
          icon: Icons.person_search_outlined,
          title: '搜索一位成员或团体',
          detail: '支持成员名、团体名、拼音和首字母。',
          actionLabel: '手动添加',
          onAction: _showManualAdd,
        ),
      ];
    }
    return children;
  }
}

class _SelectedIdolsPanel extends StatelessWidget {
  final List<_IdolCandidate> candidates;
  final _ExistingPersonMatch? Function(_IdolCandidate candidate)
      personMatchFor;
  final Map<String, bool> samePersonChoices;
  final void Function(_IdolCandidate candidate, bool value) onChoiceChanged;
  final void Function(_IdolCandidate candidate) onRemove;

  const _SelectedIdolsPanel({
    required this.candidates,
    required this.personMatchFor,
    required this.samePersonChoices,
    required this.onChoiceChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('已选成员', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          for (final candidate in candidates) ...[
            _SelectedIdolRow(
              candidate: candidate,
              match: personMatchFor(candidate),
              samePerson: samePersonChoices[candidate.key] ?? false,
              onChoiceChanged: (value) => onChoiceChanged(candidate, value),
              onRemove: () => onRemove(candidate),
            ),
            if (candidate != candidates.last) const Divider(height: 8),
          ],
        ],
      ),
    );
  }
}

class _SelectedIdolRow extends StatelessWidget {
  final _IdolCandidate candidate;
  final _ExistingPersonMatch? match;
  final bool samePerson;
  final ValueChanged<bool> onChoiceChanged;
  final VoidCallback onRemove;

  const _SelectedIdolRow({
    required this.candidate,
    required this.match,
    required this.samePerson,
    required this.onChoiceChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                candidate.groupName.isEmpty
                    ? candidate.name
                    : '${candidate.name} · ${candidate.groupName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: '移除',
              visualDensity: VisualDensity.compact,
              onPressed: onRemove,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
        if (match != null)
          CheckboxListTile(
            value: samePerson,
            onChanged: (value) => onChoiceChanged(value ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            dense: true,
            title: Text(
              '和已有的「${match!.displayName}（${match!.groupName}）」算同一个人',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _IdolResultTile extends StatelessWidget {
  final _IdolCandidate candidate;
  final bool added;
  final bool selected;
  final VoidCallback onTap;

  const _IdolResultTile({
    super.key,
    required this.candidate,
    required this.added,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final member = candidate.member;
    final status = member?.status.trim() ?? '';
    return ListTile(
      enabled: !added,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      dense: true,
      leading: CircleAvatar(
        radius: 17,
        backgroundColor: added
            ? scheme.surfaceContainerHighest
            : scheme.primaryContainer,
        child: added
            ? Icon(Icons.check, size: 17, color: scheme.onSurfaceVariant)
            : Text(
                candidate.name.isEmpty ? '?' : candidate.name.substring(0, 1),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onPrimaryContainer,
                ),
              ),
      ),
      title: Text(
        candidate.groupName.isEmpty
            ? candidate.name
            : '${candidate.name} · ${candidate.groupName}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: added ? scheme.onSurfaceVariant : scheme.onSurface,
        ),
      ),
      subtitle: status.isEmpty
          ? null
          : Text(
              status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
      trailing: added
          ? Text(
              '已添加',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            )
          : selected
              ? Icon(Icons.check_circle, color: scheme.primary)
              : Icon(Icons.add_circle_outline, color: scheme.onSurfaceVariant),
      onTap: added ? null : onTap,
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final String actionLabel;
  final VoidCallback onAction;

  const _CenteredMessage({
    required this.icon,
    required this.title,
    required this.detail,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 48, 8, 16),
      child: Column(
        children: [
          Icon(icon, size: 36, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: onAction,
            icon: const Icon(Icons.add, size: 19),
            label: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}

class _ManualIdolPage extends StatefulWidget {
  final List<String> groupSuggestions;
  final String initialName;
  final String initialGroup;

  const _ManualIdolPage({
    required this.groupSuggestions,
    required this.initialName,
    required this.initialGroup,
  });

  @override
  State<_ManualIdolPage> createState() => _ManualIdolPageState();
}

class _ManualIdolPageState extends State<_ManualIdolPage> {
  late final TextEditingController _nameController;
  final TextEditingController _groupController = TextEditingController();
  final FocusNode _groupFocusNode = FocusNode();
  String? _nameError;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
    _groupController.text = widget.initialGroup;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _groupController.dispose();
    _groupFocusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() {
        _nameError = '请输入名字';
      });
      return;
    }
    setState(() {
      _nameError = null;
    });
    Navigator.of(context).pop(
      _ManualIdolInput(
        name: name,
        groupName: _groupController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Scaffold(
      appBar: AppBar(
        title: const Text('手动添加'),
        actions: [
          TextButton(
            onPressed: _submit,
            child: const Text('添加'),
          ),
        ],
      ),
      body: AppPageBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 24 + bottomInset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '库里没有这位成员？',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  '先建一张零计数的成员卡，之后随时可以修改。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                NoAutofillTextField(
                  controller: _nameController,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: '名字',
                    hintText: '必填',
                    errorText: _nameError,
                  ),
                ),
                const SizedBox(height: 16),
                RawAutocomplete<String>(
                  textEditingController: _groupController,
                  focusNode: _groupFocusNode,
                  optionsBuilder: (TextEditingValue value) {
                    final query = value.text.trim().toLowerCase();
                    if (query.isEmpty) {
                      return const Iterable<String>.empty();
                    }
                    return widget.groupSuggestions
                        .where(
                          (group) => group.toLowerCase().contains(query),
                        )
                        .take(20);
                  },
                  fieldViewBuilder: (
                    context,
                    textController,
                    focusNode,
                    onFieldSubmitted,
                  ) {
                    return TextField(
                      controller: textController,
                      focusNode: focusNode,
                      decoration: const InputDecoration(
                        labelText: '团体',
                        hintText: '可以和偶像库里的团体名一致',
                        prefixIcon: Icon(Icons.groups_2_outlined),
                      ),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                    );
                  },
                  optionsViewBuilder: (context, onSelected, options) {
                    return Align(
                      alignment: Alignment.topLeft,
                      child: Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(12),
                        color: scheme.surface,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 240),
                          child: ListView(
                            padding: EdgeInsets.zero,
                            shrinkWrap: true,
                            children: [
                              for (final option in options)
                                ListTile(
                                  dense: true,
                                  title: Text(option),
                                  onTap: () => onSelected(option),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  '不确定团体可以先留空；首页会把它当成单独一张卡。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _submit,
                    child: const Text('添加到已选'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    for (final value in this) {
      return value;
    }
    return null;
  }
}
