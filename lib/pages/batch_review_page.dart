import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/face_sample_model.dart';
import '../services/batch_import_service.dart';
import '../services/database_service.dart';
import '../services/face/face_recognition_rules.dart';
import '../services/idol_database_service.dart';
import '../services/record_scan_service.dart';
import 'manual_scan_crop_page.dart';

/// 批量拍切 step 2: check every cut polaroid, its member(s) and size, see
/// exactly what the ledger will get, then save everything at once.
class BatchReviewPage extends StatefulWidget {
  final List<BatchReviewCard> cards;
  final BatchDayContext day;
  final BatchSession? session;
  final List<FaceMember> candidates;
  final List<FaceMember> groupCandidates;
  final List<FaceMember> allMembers;
  final List<FaceSampleModel> samples;
  final bool learnFaces;

  const BatchReviewPage({
    super.key,
    required this.cards,
    required this.day,
    required this.session,
    required this.candidates,
    required this.allMembers,
    this.groupCandidates = const [],
    this.samples = const [],
    this.learnFaces = true,
  });

  @override
  State<BatchReviewPage> createState() => _BatchReviewPageState();
}

class _BatchReviewPageState extends State<BatchReviewPage> {
  late final List<BatchReviewCard> _cards = [...widget.cards];
  final Set<String> _disabledLines = {};
  bool _saving = false;
  Map<String, String> _avatars = {};

  @override
  void initState() {
    super.initState();
    _loadAvatars();
  }

  /// A photo per member (from a stored sample's media) for the picker.
  Future<void> _loadAvatars() async {
    final mediaIds = {
      for (final s in widget.samples)
        if (!s.isSelf && s.mediaId != null) s.mediaId!,
    };
    if (mediaIds.isEmpty) return;
    final media = await DatabaseService.getActivityRecordMedia();
    final pathById = {
      for (final m in media)
        if (m.id != null && mediaIds.contains(m.id)) m.id!: m.path,
    };
    final avatars = <String, String>{};
    for (final member in widget.allMembers) {
      for (final s in widget.samples.reversed) {
        if (s.isSelf || s.mediaId == null) continue;
        final path = pathById[s.mediaId];
        if (path != null &&
            member.isSamePerson(
              counterId: s.counterId,
              personId: s.personId,
              name: s.personName,
            )) {
          avatars[member.key] = path;
          break;
        }
      }
    }
    if (mounted) setState(() => _avatars = avatars);
  }

  List<BatchLedgerEntry> get _entries =>
      BatchImportService.planEntries(_cards, widget.day);

  int get _unassigned => _cards.where((c) => !c.hasRequiredDetails).length;

  String get _dayLabel {
    final d = widget.day.day;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Future<void> _editMembers(BatchReviewCard card) async {
    bool inGroup(FaceMember member) =>
        card.cutType != BatchCutType.group ||
        groupLedgerLineKey(member.groupName) ==
            groupLedgerLineKey(card.groupName);
    final groupMembers = card.cutType == BatchCutType.group
        ? await BatchImportService.membersOfGroups(
            [card.groupName], widget.day.counters)
        : const <FaceMember>[];
    if (!mounted) return;
    final allMembers = buildCandidateMembers(
      dayMembers: [
        ...widget.groupCandidates,
        ...widget.allMembers,
        ...groupMembers,
      ].where(inGroup),
      sessionGroupMembers: const [],
      allMembers: const [],
    );
    final result = await showModalBottomSheet<List<FaceMember>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _MemberPickerSheet(
        card: card,
        candidates: widget.candidates.where(inGroup).toList(),
        allMembers: allMembers,
        avatars: _avatars,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      final changed = result.length != card.members.length ||
          !result.every((m) => card.members.any((x) => x.sameAs(m)));
      final previousType = card.cutType;
      if (changed) card.rememberRemovedRecognitions(card.members, result);
      card.members = result;
      if (previousType == BatchCutType.single && result.length > 1) {
        card.cutType = BatchCutType.multi;
      } else if (previousType == BatchCutType.multi) {
        card.cutType = BatchCutType.multi;
      }
      if (changed) card.edited = true;
      card.status = FaceMatchStatus.auto; // confirmed by the user
    });
  }

  Future<void> _chooseType(BatchReviewCard card, BatchCutType type) async {
    String? group;
    var groupMembers = const <FaceMember>[];
    if (type == BatchCutType.group) {
      var idolGroups = <String>[];
      try {
        idolGroups = [
          for (final group in await IdolDatabaseService.getGroups()) group.name,
        ];
      } catch (_) {
        // The user can still select a known group or enter its name.
      }
      if (!mounted) return;
      final groups = <String>{
        for (final group in idolGroups)
          if (group.trim().isNotEmpty) group.trim(),
        for (final m in [
          ...widget.groupCandidates,
          ...widget.candidates,
          ...widget.allMembers,
        ])
          if (m.groupName.trim().isNotEmpty) m.groupName.trim(),
        for (final r in widget.day.records)
          if (r.groupName.trim().isNotEmpty && r.groupName != '跨团')
            r.groupName.trim(),
        ...?widget.session?.groupNames,
      }.toList()
        ..sort();
      group = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => _GroupPickerSheet(
          groups: groups,
          suggested: card.groupName.isNotEmpty
              ? card.groupName
              : card.suggestedGroupName,
        ),
      );
      if (group == null || !mounted) return;
      groupMembers = await BatchImportService.membersOfGroups(
          [group], widget.day.counters);
      if (!mounted) return;
    }
    setState(() {
      card.groupSuggestionDismissed = true;
      card.cutType = type;
      if (type == BatchCutType.group) {
        card.groupName = group!.trim();
        final recognized = [
          for (final match in card.faceMatches)
            if (match.member != null &&
                !card.removedRecognizedMembers
                    .any((m) => m.sameAs(match.member!)))
              match.member!,
        ];
        final selected = <FaceMember>[];
        final affiliations = [
          ...widget.groupCandidates,
          ...groupMembers,
          ...widget.candidates,
          ...widget.allMembers,
        ].where((member) =>
            groupLedgerLineKey(member.groupName) ==
            groupLedgerLineKey(card.groupName));
        for (final member in [...card.members, ...recognized]) {
          final matchingAffiliation = groupLedgerLineKey(member.groupName) ==
                  groupLedgerLineKey(card.groupName)
              ? member
              : affiliations.where((m) => m.sameAs(member)).firstOrNull;
          if (matchingAffiliation != null &&
              !selected.any((m) => m.sameAs(matchingAffiliation))) {
            selected.add(matchingAffiliation);
          }
        }
        card.members = selected;
      } else if (type == BatchCutType.single && card.members.length > 1) {
        card.rememberRemovedRecognitions(card.members, [card.members.first]);
        card.members = [card.members.first];
        card.edited = true;
      }
    });
  }

  Future<void> _fixCrop(BatchReviewCard card) async {
    try {
      final sourceBytes = await File(card.source.photo.path).readAsBytes();
      if (!mounted) return;
      final quad = await Navigator.of(context).push<RecordScanQuad>(
        MaterialPageRoute(
          builder: (context) => ManualScanCropPage(
            draft: RecordScanManualDraft(
              sourceBytes: sourceBytes,
              imageWidth: card.source.sourceWidth,
              imageHeight: card.source.sourceHeight,
              suggestedQuad: card.quad,
              usedFallback: false,
            ),
          ),
        ),
      );
      if (quad == null || !mounted) return;
      final output = await RecordScanService.createManualScan(
        sourceBytes: sourceBytes,
        quad: quad,
      );
      if (!mounted) return;
      setState(() {
        final bytes = output.bytes;
        card.bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
        card.fileExtension = output.fileExtension;
        card.processingMode = output.processingMode;
        card.quad = quad;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('修框失败: $error')));
      }
    }
  }

  void _toggleSize(BatchReviewCard card) {
    setState(() {
      card.size = card.size == ChekiSize.threeInch
          ? ChekiSize.fiveInch
          : ChekiSize.threeInch;
      card.sizeUncertain = false;
    });
  }

  Future<void> _showCardActions(BatchReviewCard card) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_search_outlined),
              title: const Text('改成员'),
              onTap: () => Navigator.pop(context, 'members'),
            ),
            ListTile(
              leading: const Icon(Icons.straighten),
              title:
                  Text('改成${card.size == ChekiSize.threeInch ? '五寸' : '三寸'}'),
              onTap: () => Navigator.pop(context, 'size'),
            ),
            ListTile(
              leading: const Icon(Icons.crop_free),
              title: const Text('手动修框'),
              onTap: () => Navigator.pop(context, 'crop'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除这张'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'members':
        await _editMembers(card);
      case 'size':
        _toggleSize(card);
      case 'crop':
        await _fixCrop(card);
      case 'delete':
        setState(() => _cards.remove(card));
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final plan = await BatchImportService.buildSavePlan(
        cards: _cards,
        day: widget.day,
        session: widget.session,
        disabledLines: _disabledLines,
      );
      final summary =
          await BatchImportService.save(plan, learnFaces: widget.learnFaces);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已保存 ${summary.photos} 张拍立得'
            '${summary.newRecords > 0 ? '，补记 ${summary.newRecords} 条流水' : ''}'),
      ));
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败: $error')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _summary(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _entries;
    final duplicates = {
      for (final c in _cards)
        if (c.source.alreadyImported > 0) c.source.sourceHash,
    }.length;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('将要保存', style: theme.textTheme.titleMedium),
            Text(
              '$_dayLabel${widget.session == null ? '' : ' · ${widget.session!.title}'}'
              ' · ${_cards.length} 张',
              style: theme.textTheme.bodySmall,
            ),
            if (duplicates > 0)
              Text('$duplicates 张原图之前导入过',
                  style: TextStyle(color: theme.colorScheme.error)),
            if (_unassigned > 0)
              Text('还有 $_unassigned 张没有指定成员或团体',
                  style: TextStyle(color: theme.colorScheme.error)),
            for (final entry in entries)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${entry.label} · ${entry.line.isGroup ? '团切' : entry.line.size.label} '
                      '${entry.line.photoCount} 张',
                    ),
                  ),
                  if (entry.line.supplement == 0)
                    Text('只挂照片', style: theme.textTheme.bodySmall)
                  else ...[
                    Text(
                      _disabledLines.contains(entry.line.lineKey)
                          ? (entry.line.isGroup ? '团切不补记' : '不补记')
                          : '${entry.line.isGroup ? '团切 ' : ''}+${entry.line.supplement} 张',
                      style: TextStyle(
                        color: _disabledLines.contains(entry.line.lineKey)
                            ? theme.colorScheme.outline
                            : theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Switch(
                      value: !_disabledLines.contains(entry.line.lineKey),
                      onChanged: (on) => setState(() {
                        if (on) {
                          _disabledLines.remove(entry.line.lineKey);
                        } else {
                          _disabledLines.add(entry.line.lineKey);
                        }
                      }),
                    ),
                  ],
                ],
              ),
            if (entries.any((e) => e.line.supplement > 0))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '当天已有流水且张数够的只挂照片；不够的差额补记一条本地流水，可逐个关闭。',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('复核 ${_cards.length} 张'),
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _summary(context)),
          SliverPadding(
            padding: const EdgeInsets.all(12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.62,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => _CardTile(
                  key: ValueKey('batch_card_$i'),
                  card: _cards[i],
                  onTap: () => _editMembers(_cards[i]),
                  onMore: () => _showCardActions(_cards[i]),
                  onSize: () => _toggleSize(_cards[i]),
                  onType: (type) => _chooseType(_cards[i], type),
                ),
                childCount: _cards.length,
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: FilledButton(
            key: const ValueKey('batch_save'),
            onPressed:
                _saving || _cards.isEmpty || _unassigned > 0 ? null : _save,
            child: Text(_saving
                ? '保存中…'
                : _unassigned > 0
                    ? '还有 $_unassigned 张没指定成员或团体'
                    : '确认保存 ${_cards.length} 张'),
          ),
        ),
      ),
    );
  }
}

class _CardTile extends StatelessWidget {
  final BatchReviewCard card;
  final VoidCallback onTap;
  final VoidCallback onMore;
  final VoidCallback onSize;
  final ValueChanged<BatchCutType> onType;

  const _CardTile({
    super.key,
    required this.card,
    required this.onTap,
    required this.onMore,
    required this.onSize,
    required this.onType,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (bg, fg) = switch (card.status) {
      FaceMatchStatus.auto when !card.edited => (
          scheme.tertiaryContainer,
          scheme.onTertiaryContainer
        ),
      FaceMatchStatus.auto => (
          scheme.primaryContainer,
          scheme.onPrimaryContainer
        ),
      FaceMatchStatus.review => (
          scheme.secondaryContainer,
          scheme.onSecondaryContainer
        ),
      FaceMatchStatus.unknown => (
          scheme.errorContainer,
          scheme.onErrorContainer
        ),
    };
    final statusLabel = card.edited ||
            card.status == FaceMatchStatus.auto &&
                card.members.isNotEmpty &&
                card.faceMatches.isEmpty
        ? '已指定'
        : card.status.label;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        onLongPress: onMore,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(card.bytes, fit: BoxFit.cover, cacheWidth: 360),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: bg,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(statusLabel,
                          style: TextStyle(color: fg, fontSize: 12)),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    child: IconButton(
                      onPressed: onMore,
                      icon: const Icon(Icons.more_vert, color: Colors.white),
                      tooltip: '更多',
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      card.cutType == BatchCutType.group
                          ? '${card.groupName} · ${card.members.isEmpty ? '可补成员' : card.members.map((m) => m.name).join(' + ')}'
                          : card.members.isEmpty
                              ? '点这里指定成员'
                              : card.members.map((m) => m.name).join(' + '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: !card.hasRequiredDetails ? scheme.error : null,
                      ),
                    ),
                  ),
                  if (card.cutType != BatchCutType.group)
                    ActionChip(
                      label: Text(
                          '${card.size.label}${card.sizeUncertain ? '?' : ''}'),
                      onPressed: onSize,
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: Row(
                children: [
                  PopupMenuButton<BatchCutType>(
                    tooltip: '选择拍切类型',
                    onSelected: onType,
                    itemBuilder: (context) => [
                      for (final type in BatchCutType.values)
                        PopupMenuItem(value: type, child: Text(type.label)),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('${card.cutType.label} ▾',
                          style: theme.textTheme.labelLarge),
                    ),
                  ),
                  if (card.groupSuggested &&
                      !card.groupSuggestionDismissed &&
                      card.cutType != BatchCutType.group) ...[
                    const Spacer(),
                    InkWell(
                      onTap: () => onType(BatchCutType.group),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text('建议团切',
                            style: theme.textTheme.labelMedium
                                ?.copyWith(color: scheme.primary)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupPickerSheet extends StatefulWidget {
  final List<String> groups;
  final String? suggested;

  const _GroupPickerSheet({required this.groups, this.suggested});

  @override
  State<_GroupPickerSheet> createState() => _GroupPickerSheetState();
}

class _GroupPickerSheetState extends State<_GroupPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim();
    final groups = widget.groups
        .where((group) => group.toLowerCase().contains(query.toLowerCase()))
        .toList();
    if (widget.suggested != null && groups.remove(widget.suggested)) {
      groups.insert(0, widget.suggested!);
    }
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('选择团切的团体',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '搜索或输入团体名',
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final group in groups)
                    ListTile(
                      title: Text(group),
                      subtitle:
                          group == widget.suggested ? const Text('识别建议') : null,
                      onTap: () => Navigator.pop(context, group),
                    ),
                  if (query.isNotEmpty &&
                      !widget.groups.any((g) =>
                          groupLedgerLineKey(g) == groupLedgerLineKey(query)))
                    ListTile(
                      leading: const Icon(Icons.add),
                      title: Text('使用“$query”'),
                      onTap: () => Navigator.pop(context, query),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemberPickerSheet extends StatefulWidget {
  final BatchReviewCard card;
  final List<FaceMember> candidates;
  final List<FaceMember> allMembers;
  final Map<String, String> avatars;

  const _MemberPickerSheet({
    required this.card,
    required this.candidates,
    required this.allMembers,
    required this.avatars,
  });

  @override
  State<_MemberPickerSheet> createState() => _MemberPickerSheetState();
}

class _MemberPickerSheetState extends State<_MemberPickerSheet> {
  late final List<FaceMember> _selected = [...widget.card.members];
  String _query = '';

  bool _isSelected(FaceMember m) => _selected.any((x) => x.sameAs(m));

  void _toggle(FaceMember m) {
    setState(() {
      if (_isSelected(m)) {
        _selected.removeWhere((x) => x.sameAs(m));
      } else {
        _selected.add(m);
      }
    });
  }

  Widget _avatar(FaceMember m) {
    final path = widget.avatars[m.key];
    final initial =
        m.name.trim().isEmpty ? '?' : m.name.trim().characters.first;
    return CircleAvatar(
      backgroundImage:
          path == null ? null : ResizeImage(FileImage(File(path)), width: 96),
      child: path == null ? Text(initial) : null,
    );
  }

  Widget _tile(FaceMember m, {String? trailing}) => CheckboxListTile(
        key: ValueKey('member_${m.key}'),
        value: _isSelected(m),
        onChanged: (_) => _toggle(m),
        secondary: _avatar(m),
        title: Text(m.name),
        subtitle: Text([
          if (m.groupName.trim().isNotEmpty) m.groupName.trim(),
          if (trailing != null) trailing,
        ].join(' · ')),
      );

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final suggestions = card.suggestions
        .where((s) => widget.candidates.any((c) => c.sameAs(s)))
        .toList();
    final query = _query.trim().toLowerCase();
    bool matches(FaceMember m) =>
        query.isEmpty ||
        m.name.toLowerCase().contains(query) ||
        m.groupName.toLowerCase().contains(query) ||
        m.personName.toLowerCase().contains(query);
    final others = widget.allMembers
        .where((m) => !widget.candidates.any((c) => c.sameAs(m)) && matches(m))
        .toList();
    final candidates = widget.candidates
        .where((m) => !suggestions.any((s) => s.sameAs(m)) && matches(m))
        .toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      card.cutType == BatchCutType.group
                          ? '${card.groupName}的成员（可不选全）'
                          : '这张是谁？（多人切可多选）',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  FilledButton(
                    key: const ValueKey('member_picker_done'),
                    onPressed: () => Navigator.pop(context, _selected),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '搜成员 / 团体',
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  if (suggestions.isNotEmpty && query.isEmpty) ...[
                    const ListTile(dense: true, title: Text('最像的')),
                    for (final m in suggestions) _tile(m, trailing: '建议'),
                  ],
                  if (candidates.isNotEmpty) ...[
                    const ListTile(dense: true, title: Text('这天的成员')),
                    for (final m in candidates) _tile(m),
                  ],
                  if (others.isNotEmpty) ...[
                    const ListTile(dense: true, title: Text('其他成员')),
                    for (final m in others) _tile(m),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
