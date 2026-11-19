import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/counter_model.dart';
import '../models/face_sample_model.dart';
import '../services/batch_import_service.dart';
import '../services/database_service.dart';
import '../services/face/face_recognition_rules.dart';
import '../services/face/face_sample_service.dart';
import '../services/idol_database_service.dart';
import '../services/record_scan_service.dart';
import '../widgets/dream/dream_section_header.dart';
import 'add_idol_page.dart';
import 'manual_scan_crop_page.dart';

/// 批量拍切 step 2: check every cut polaroid, its member(s) and size, see
/// exactly what the ledger will get, then save everything at once.
class BatchReviewPage extends StatefulWidget {
  final List<BatchReviewCard> cards;

  /// Keep originals even when a photo produced no valid automatic crops.
  final List<BatchSourceResult> sources;
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
    this.sources = const [],
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
  late final List<BatchSourceResult> _sources = {
    for (final source in widget.sources) source.photo.path: source,
    for (final card in widget.cards) card.source.photo.path: card.source,
  }.values.where((source) => source.error == null).toList();

  /// Members added from the picker during this review (new counters).
  final List<FaceMember> _addedMembers = [];
  final List<CounterModel> _addedCounters = [];
  final Set<String> _disabledLines = {};
  bool _saving = false;
  bool _addingCrop = false;
  bool _pendingOnly = false;
  final Set<BatchReviewCard> _confirmedInPicker = {};
  bool _showLedger = false;
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

  // A suggested name can be shown on a card before its owner is confirmed.
  bool _canSave(BatchReviewCard card) =>
      card.hasRequiredDetails &&
      card.unresolvedAffiliationMembers.isEmpty &&
      card.status == FaceMatchStatus.auto;

  List<BatchReviewCard> get _ready => _cards.where(_canSave).toList();

  void _deleteCard(BatchReviewCard card) {
    final index = _cards.indexOf(card);
    if (index < 0) return;
    setState(() => _cards.removeAt(index));
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: const Text('已删除这张'),
      action: SnackBarAction(
        label: '撤销',
        onPressed: () {
          if (!mounted || _cards.contains(card)) return;
          setState(() => _cards.insert(index.clamp(0, _cards.length), card));
        },
      ),
    ));
  }

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
        ..._addedMembers,
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
        onAddMembers: _addMembers,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      final changed = result.length != card.members.length ||
          !result.every((m) => card.members.any((x) => x.sameAs(m)));
      final previousType = card.cutType;
      if (changed) card.rememberRemovedRecognitions(card.members, result);
      card.members = result;
      // The member picker merges affiliations. Only the group chooser can
      // resolve an ambiguous card, even after the right person was selected.
      _confirmedInPicker.add(card);
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
        // Choosing a group confirms its ledger line, not a tentative face.
        if (selected.isEmpty) card.status = FaceMatchStatus.auto;
        card.confirmedAffiliationKeys
            .addAll(selected.map((member) => member.key));
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
        // A new frame can contain a different card. Discard all matches from
        // the old pixels, including the embeddings used for sample learning.
        final bytes = output.bytes;
        _cards[_cards.indexOf(card)] = BatchReviewCard(
          source: card.source,
          card: card.card,
          members: [],
          status: FaceMatchStatus.unknown,
          suggestions: const [],
          size: card.size,
          sizeUncertain: true,
          faceMatches: const [],
        )
          ..bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes)
          ..fileExtension = output.fileExtension
          ..processingMode = output.processingMode
          ..quad = quad;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('修框失败: $error')));
      }
    }
  }

  Future<void> _addCrop() async {
    if (_addingCrop || _saving || _sources.isEmpty) return;
    setState(() => _addingCrop = true);
    try {
      final source = _sources.length == 1
          ? _sources.single
          : await showModalBottomSheet<BatchSourceResult>(
              context: context,
              showDragHandle: true,
              builder: (context) => SafeArea(
                child: SizedBox(
                  height: MediaQuery.sizeOf(context).height * 0.65,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('选择要补框的原图',
                            style: Theme.of(context).textTheme.titleMedium),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _sources.length,
                          itemBuilder: (context, i) {
                            final source = _sources[i];
                            return ListTile(
                              key: ValueKey('batch_crop_source_$i'),
                              leading: Image.file(
                                File(source.photo.path),
                                width: 64,
                                height: 64,
                                fit: BoxFit.cover,
                                cacheWidth: 160,
                                errorBuilder: (_, __, ___) =>
                                    const Icon(Icons.broken_image_outlined),
                              ),
                              title: Text('原图 ${i + 1}'),
                              subtitle: Text('自动检出 ${source.cards.length} 张'),
                              onTap: () => Navigator.pop(context, source),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
      if (source == null || !mounted) return;
      final sourceBytes = await File(source.photo.path).readAsBytes();
      if (!mounted) return;
      final w = source.sourceWidth.toDouble();
      final h = source.sourceHeight.toDouble();
      final quad = await Navigator.of(context).push<RecordScanQuad>(
        MaterialPageRoute(
          builder: (context) => ManualScanCropPage(
            draft: RecordScanManualDraft(
              sourceBytes: sourceBytes,
              imageWidth: source.sourceWidth,
              imageHeight: source.sourceHeight,
              suggestedQuad: RecordScanQuad(
                topLeftX: w * 0.1,
                topLeftY: h * 0.1,
                topRightX: w * 0.9,
                topRightY: h * 0.1,
                bottomLeftX: w * 0.1,
                bottomLeftY: h * 0.9,
                bottomRightX: w * 0.9,
                bottomRightY: h * 0.9,
              ),
              usedFallback: true,
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
      final card = BatchCard(
        bytes: Uint8List.fromList(output.bytes),
        fileExtension: output.fileExtension,
        processingMode: output.processingMode,
        quad: quad,
        sizeClass: RecordScanCardSize.uncertain,
        confidence: 0,
        splitFromMerged: false,
      );
      setState(() {
        // This is a new, unconfirmed card, never a copy of an old recognition.
        _cards.add(BatchReviewCard(
          source: source,
          card: card,
          members: [],
          status: FaceMatchStatus.unknown,
          suggestions: const [],
          size: ChekiSize.threeInch,
          sizeUncertain: true,
          faceMatches: const [],
        ));
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('补框失败，无法读取或裁切原图：$error')));
      }
    } finally {
      if (mounted) setState(() => _addingCrop = false);
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
        _deleteCard(card);
    }
  }

  Future<void> _chooseAffiliation(
    BatchReviewCard card,
    FaceMember member,
  ) async {
    final options = card.affiliationsFor(member);
    if (options.length <= 1) return;
    final selected = await showModalBottomSheet<FaceMember>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('${member.name} 这张算到哪个团？'),
              subtitle: const Text('同一位真人在不同团有各自的卡片和计数。'),
            ),
            const Divider(height: 1),
            for (final option in options)
              ListTile(
                leading: CircleAvatar(
                  radius: 18,
                  child: Text(option.groupName.trim().isEmpty
                      ? '?'
                      : option.groupName.trim().substring(0, 1)),
                ),
                title: Text(option.groupName.trim().isEmpty
                    ? '未分组'
                    : option.groupName.trim()),
                subtitle: Text(
                  option.name == member.name ? '当前卡片' : '卡名：${option.name}',
                ),
                trailing: option.groupName == member.groupName
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.of(context).pop(option),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      card.confirmAffiliation(selected);
      card.edited = true;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final plan = await BatchImportService.buildSavePlan(
        cards: _ready,
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

  Widget _summary(BuildContext context, List<BatchReviewCard> ready) {
    final theme = Theme.of(context);
    final pending = _cards.length - ready.length;
    final entries = _showLedger
        ? BatchImportService.planEntries(ready, widget.day,
            session: widget.session)
        : const <BatchLedgerEntry>[];
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
            DreamSectionHeader(
              title: '拍切复核',
              countLabel: '${ready.length}/${_cards.length}',
              eyebrow:
                  '$_dayLabel${widget.session == null ? '' : ' · ${widget.session!.title}'}',
            ),
            if (duplicates > 0)
              Text('$duplicates 张原图之前导入过',
                  style: TextStyle(color: theme.colorScheme.error)),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilterChip(
                  label: Text('待核对 $pending'),
                  selected: _pendingOnly,
                  onSelected: pending == 0 && !_pendingOnly
                      ? null
                      : (on) => setState(() => _pendingOnly = on),
                ),
                TextButton.icon(
                  onPressed: ready.isEmpty
                      ? null
                      : () => setState(() => _showLedger = !_showLedger),
                  icon:
                      Icon(_showLedger ? Icons.expand_less : Icons.expand_more),
                  label: const Text('将要保存'),
                ),
              ],
            ),
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

  /// Opens 添加偶像 from the picker, saves the new members right away (so
  /// the ledger can point at them) and returns them for selection.
  Future<List<FaceMember>> _addMembers(BuildContext pickerContext) async {
    final counters = await Navigator.of(pickerContext).push<List<CounterModel>>(
      MaterialPageRoute(
        builder: (context) => AddIdolPage(
          existingCounters: [...widget.day.counters, ..._addedCounters],
        ),
      ),
    );
    if (counters == null || counters.isEmpty) return const [];
    final added = <FaceMember>[];
    for (final counter in counters) {
      final id = await DatabaseService.insertCounter(counter);
      final saved = counter.copyWith(id: id);
      _addedCounters.add(saved);
      added.add(FaceSampleService.memberFromCounter(saved));
    }
    await DatabaseService.autoAssignCounterThemeColors();
    if (mounted) setState(() => _addedMembers.addAll(added));
    return added;
  }

  @override
  Widget build(BuildContext context) {
    final ready = _ready;
    final pending = _cards.length - ready.length;
    final visible = [
      for (final entry in _cards.indexed)
        if (!_pendingOnly || !_canSave(entry.$2)) entry,
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text('复核 ${_cards.length} 张'),
        actions: [
          TextButton.icon(
            key: const ValueKey('batch_add_crop'),
            onPressed:
                _saving || _addingCrop || _sources.isEmpty ? null : _addCrop,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(_addingCrop ? '处理中…' : '补框'),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _summary(context, ready)),
          if (_cards.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('没有自动找到拍立得，点右上角“补框”手动添加。')),
              ),
            )
          else if (visible.isEmpty && _pendingOnly)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('这批都核对好了')),
              ),
            ),
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
                (context, i) {
                  final (index, card) = visible[i];
                  return _CardTile(
                    key: ValueKey('batch_card_$index'),
                    card: card,
                    confirmed: _confirmedInPicker.contains(card),
                    onTap: () => _editMembers(card),
                    onMore: () => _showCardActions(card),
                    onDelete: () => _deleteCard(card),
                    onSize: () => _toggleSize(card),
                    onType: (type) => _chooseType(card, type),
                    onAffiliation: (member) => _chooseAffiliation(card, member),
                  );
                },
                childCount: visible.length,
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
            onPressed: _saving || _addingCrop || ready.isEmpty ? null : _save,
            child: Text(_saving
                ? '保存中…'
                : ready.isEmpty
                    ? '先确认至少一张拍立得'
                    : pending > 0
                        ? '保存 ${ready.length} 张，跳过 $pending 张待核对'
                        : '确认保存 ${_cards.length} 张'),
          ),
        ),
      ),
    );
  }
}

class _CardTile extends StatelessWidget {
  final BatchReviewCard card;
  final bool confirmed;
  final VoidCallback onTap;
  final VoidCallback onMore;
  final VoidCallback onDelete;
  final VoidCallback onSize;
  final ValueChanged<BatchCutType> onType;
  final ValueChanged<FaceMember> onAffiliation;

  const _CardTile({
    super.key,
    required this.card,
    required this.onTap,
    required this.confirmed,
    required this.onMore,
    required this.onDelete,
    required this.onSize,
    required this.onType,
    required this.onAffiliation,
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
    final awaitingGroup = card.unresolvedAffiliationMembers.isNotEmpty;
    final statusLabel = awaitingGroup
        ? '选团'
        : confirmed ||
                card.edited ||
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
                  Image.memory(card.bytes,
                      fit: BoxFit.contain, cacheWidth: 360),
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
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: const ValueKey('batch_card_delete'),
                          onPressed: onDelete,
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.white),
                          tooltip: '删除这张',
                        ),
                        IconButton(
                          onPressed: onMore,
                          icon:
                              const Icon(Icons.more_vert, color: Colors.white),
                          tooltip: '更多',
                        ),
                      ],
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
                          ? '${card.groupName} · ${card.members.isEmpty ? '可补成员' : card.members.map((m) => card.affiliationsFor(m).length > 1 && m.groupName.trim().isNotEmpty ? '${m.name}·${m.groupName}' : m.name).join(' + ')}'
                          : card.members.isEmpty
                              ? '点这里指定成员'
                              : card.members
                                  .map((m) =>
                                      card.affiliationsFor(m).length > 1 &&
                                              m.groupName.trim().isNotEmpty
                                          ? '${m.name}·${m.groupName}'
                                          : m.name)
                                  .join(' + '),
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
            if (awaitingGroup) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 4, 2),
                child: Wrap(
                  spacing: 4,
                  runSpacing: -6,
                  children: [
                    for (final member in card.unresolvedAffiliationMembers)
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        label: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 118),
                          child: Text(
                            '${member.name} → ${member.groupName.isEmpty ? '选团' : member.groupName} ▾',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                        onPressed: () => onAffiliation(member),
                      ),
                  ],
                ),
              ),
            ],
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
  final Future<List<FaceMember>> Function(BuildContext context)? onAddMembers;

  const _MemberPickerSheet({
    required this.card,
    required this.candidates,
    required this.allMembers,
    required this.avatars,
    this.onAddMembers,
  });

  @override
  State<_MemberPickerSheet> createState() => _MemberPickerSheetState();
}

class _MemberPickerSheetState extends State<_MemberPickerSheet> {
  late final List<FaceMember> _selected = [...widget.card.members];
  final List<FaceMember> _added = [];
  String _query = '';

  Future<void> _addNew() async {
    final added = await widget.onAddMembers?.call(context) ?? const [];
    if (added.isEmpty || !mounted) return;
    setState(() {
      _added.addAll(added);
      for (final m in added) {
        if (!_isSelected(m)) _selected.add(m);
      }
    });
  }

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
    // Suggestions may name members outside the day's list; keep them.
    final suggestions = card.suggestions
        .where((s) =>
            widget.candidates.any((c) => c.sameAs(s)) ||
            widget.allMembers.any((c) => c.sameAs(s)))
        .toList();
    final query = _query.trim().toLowerCase();
    bool matches(FaceMember m) =>
        query.isEmpty ||
        m.name.toLowerCase().contains(query) ||
        m.groupName.toLowerCase().contains(query) ||
        m.personName.toLowerCase().contains(query);
    final others = [...widget.allMembers, ..._added]
        .where((m) =>
            !widget.candidates.any((c) => c.sameAs(m)) &&
            (query.isNotEmpty || !suggestions.any((s) => s.sameAs(m))) &&
            matches(m))
        .toList();
    final candidates = widget.candidates
        .where((m) =>
            (query.isNotEmpty || !suggestions.any((s) => s.sameAs(m))) &&
            matches(m))
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
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(card.bytes,
                        width: 66,
                        height: 82,
                        fit: BoxFit.contain,
                        cacheWidth: 200),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      card.cutType == BatchCutType.group
                          ? '${card.groupName}的成员'
                          : '这张是谁？',
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
                  if (widget.onAddMembers != null)
                    ListTile(
                      key: const ValueKey('member_picker_add_new'),
                      leading: const Icon(Icons.person_add_alt_1_outlined),
                      title: const Text('名单里没有？添加新成员'),
                      subtitle: const Text('从偶像库搜，或手动输入名字'),
                      onTap: _addNew,
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
