import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/activity_record_media_model.dart';
import '../../models/activity_record_model.dart';
import '../../models/album_preferences.dart';
import '../../models/counter_model.dart';
import '../../services/album_clarity_service.dart';
import '../../services/album_camera_recovery.dart';
import '../../services/database_service.dart';
import '../../services/idol_database_service.dart';
import '../../services/settings_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_page_background.dart';
import 'album_camera_access_banner.dart';
import 'album_grouping.dart';
import 'album_landing_widgets.dart';
import 'album_members_page.dart';
import 'album_models.dart';
import 'album_preferences_sheet.dart';
import 'album_session_page.dart';
import 'album_sessions_page.dart';
import 'album_timeline_mosaic.dart';
import 'album_viewer_page.dart';
import 'album_widgets.dart';
import 'checked_cheki_import_page.dart';

/// 切冊 — one continuous scrapbook landing page.
///
/// The page opens on a compact stats header, the newest 場次 as a loose pile of
/// prints, a shelf of member polaroids and a shelf of 場次 ticket stubs, then
/// the quilted timeline. The three lenses are no longer tabs: all of them are
/// visible by scrolling. 「全部」 still opens the full member / session views.
class AlbumPage extends StatefulWidget {
  /// Optional member filter, used by the member detail hook and by tapping a
  /// cover. The page then shows that member's timeline with a compact header.
  final int? memberPersonId;
  final String? memberName;
  final String? memberGroupName;
  final String? memberColorHex;

  const AlbumPage({
    super.key,
    this.memberPersonId,
    this.memberName,
    this.memberGroupName,
    this.memberColorHex,
  });

  /// The one-line hook for `member_detail_page.dart`.
  static Future<void> openForMember(
    BuildContext context, {
    required String memberName,
    String groupName = '',
    int? personId,
    String? colorHex,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => AlbumPage(
          memberPersonId: personId,
          memberName: memberName.trim(),
          memberGroupName: groupName.trim(),
          memberColorHex: colorHex,
        ),
      ),
    );
  }

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  final ScrollController _scrollController = ScrollController();

  AlbumPreferences _preferences = const AlbumPreferences();
  AlbumData? _data;
  AlbumMemberAlbum? _memberAlbum;
  bool _loading = true;
  String? _error;

  AlbumMosaicLayout? _mosaicLayout;
  double _timelineBaseOffset = 0;

  bool get _isMemberFiltered =>
      widget.memberPersonId != null ||
      (widget.memberName?.trim().isNotEmpty ?? false);

  String get _memberDisplayName {
    final member = _memberAlbum?.member.displayName;
    if (member != null && member.isNotEmpty) return member;
    final name = widget.memberName?.trim() ?? '';
    return name.isEmpty ? '成员' : name;
  }

  /// Used for headers on an empty member album, where no grouped member
  /// exists yet but the page still needs the requested name and 応援色.
  AlbumMemberAlbum? get _displayMemberAlbum {
    if (_memberAlbum != null) return _memberAlbum;
    if (!_isMemberFiltered) return null;
    return AlbumMemberAlbum(
      member: AlbumMemberRef(
        key: 'filter:${widget.memberPersonId ?? widget.memberName}',
        personId: widget.memberPersonId,
        name: widget.memberName ?? '',
        groupName: widget.memberGroupName ?? '',
        colorHex: widget.memberColorHex ?? '',
      ),
      soloPhotos: const [],
      groupPhotos: const [],
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _preferences = await SettingsService.getAlbumPreferences();
      final counters = await DatabaseService.getCounters();
      final records = await DatabaseService.getActivityRecords();
      final media = await DatabaseService.getActivityRecordMedia();
      final generation = ++_loadGeneration;
      _installAlbumData(
        buildAlbumData(counters: counters, records: records, media: media),
        loading: false,
        generation: generation,
      );
      // Mount the visible tiles first. Feed the rest of the archive one at
      // a time so a quick scroll or an opened photo can request its own work.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _loadGeneration) return;
        AlbumCameraRecovery.schedule(media, records);
        AlbumPhotoFiles.warmScans([
          for (final item in media)
            if (item.isScan) (item.path, !item.processingMode.isProcessed),
        ]);
      });
      // The 演出名单 cache only enriches venue/time labels. It must never
      // hold up the album: when the idol database is still seeding on a cold
      // start, waiting for it would leave the spinner up for seconds.
      unawaited(
        _enrichWithEventHints(
          counters: counters,
          records: records,
          media: media,
          generation: generation,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '照片和流水读取失败：$error';
      });
    }
  }

  int _loadGeneration = 0;

  void _installAlbumData(
    AlbumData full, {
    required bool loading,
    required int generation,
  }) {
    if (!mounted || generation != _loadGeneration) return;
    final filtered = _isMemberFiltered
        ? full.filteredToMember(
            personId: widget.memberPersonId,
            name: widget.memberName,
            groupName: widget.memberGroupName,
          )
        : full;
    final memberAlbum =
        _isMemberFiltered ? _findMemberAlbum(full, filtered) : null;
    setState(() {
      _data = filtered;
      _memberAlbum = memberAlbum;
      _loading = loading;
    });
  }

  Future<void> _enrichWithEventHints({
    required List<CounterModel> counters,
    required List<ActivityRecordModel> records,
    required List<ActivityRecordMediaModel> media,
    required int generation,
  }) async {
    try {
      final hints =
          await _loadEventHints(records).timeout(const Duration(seconds: 3));
      if (!mounted || generation != _loadGeneration || hints.isEmpty) {
        return;
      }
      final full = buildAlbumData(
        counters: counters,
        records: records,
        media: media,
        eventHints: hints,
      );
      _installAlbumData(full, loading: false, generation: generation);
    } catch (_) {
      // Optional enrichment only; keep the album already on screen.
    }
  }

  AlbumMemberAlbum? _findMemberAlbum(AlbumData full, AlbumData filtered) {
    for (final album in full.members) {
      final matchesPerson = widget.memberPersonId != null &&
          album.member.personId == widget.memberPersonId;
      final matchesName = album.member.matchesIdentity(
        personId: widget.memberPersonId,
        name: widget.memberName,
        groupName: widget.memberGroupName,
      );
      if (matchesPerson || matchesName) return album;
    }
    // Photos can be attributed to a name that no longer has a counter card;
    // use the filtered photos' own member ref so the header is still useful.
    for (final photo in filtered.photos) {
      for (final member in photo.members) {
        if (member.matchesIdentity(
          personId: widget.memberPersonId,
          name: widget.memberName,
          groupName: widget.memberGroupName,
        )) {
          return AlbumMemberAlbum(
            member: member,
            soloPhotos: filtered.photos
                .where((item) => !item.isGroup && item.members.contains(member))
                .toList(growable: false),
            groupPhotos: filtered.photos
                .where((item) => item.isGroup && item.members.contains(member))
                .toList(growable: false),
          );
        }
      }
    }
    return null;
  }

  Future<List<AlbumEventHint>> _loadEventHints(
    List<ActivityRecordModel> records,
  ) async {
    try {
      final dates = records
          .map((record) => record.occurredAt)
          .where((date) => date.year >= 1970 && date.year <= 3000)
          .toList(growable: false);
      if (dates.isEmpty) return const [];
      DateTime? earliest;
      DateTime? latest;
      for (final date in dates) {
        if (earliest == null || date.isBefore(earliest)) earliest = date;
        if (latest == null || date.isAfter(latest)) latest = date;
      }
      final events = await IdolDatabaseService.getActivityEvents(
        from: DateTime(earliest!.year, earliest.month, earliest.day),
        to: DateTime(latest!.year, latest.month, latest.day),
        limit: 2000,
      );
      return [
        for (final event in events)
          if (event.eventName.trim().isNotEmpty)
            AlbumEventHint(
              day: DateTime(
                event.eventDate.year,
                event.eventDate.month,
                event.eventDate.day,
              ),
              eventName: event.eventName,
              venue: event.venue,
              city: event.city,
              startTime: event.startTime.trim().isNotEmpty
                  ? event.startTime.trim()
                  : event.openTime.trim(),
            ),
      ];
    } catch (_) {
      // The album must open even when the optional 演出名单 cache is empty or
      // unavailable; venue/time enrichment is a bonus, not a requirement.
      return const [];
    }
  }

  /// The newest dated 場次. A sparse session still opens the feature with
  /// only its real prints (the collage grows the single print instead of
  /// inventing photos); the page never claims an older session is newest.
  AlbumSession? _recentSession(AlbumData data) {
    for (final session in data.sessions) {
      if (session.day != null && session.photos.isNotEmpty) return session;
    }
    return null;
  }

  void _openMember(AlbumMemberAlbum album) {
    AlbumPage.openForMember(
      context,
      memberName: album.member.displayName,
      groupName: album.member.groupName,
      personId: album.member.personId,
      colorHex: album.member.colorHex,
    );
  }

  void _openAllMembers() {
    final data = _data;
    if (data == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => AlbumMembersPage(
          data: data,
          onOpenMember: _openMember,
          onOpenSessions: _openAllSessions,
        ),
      ),
    );
  }

  void _openSession(AlbumSession session) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) =>
            AlbumSessionPage(session: session, onChanged: _load),
      ),
    );
  }

  void _openAllSessions() {
    final data = _data;
    if (data == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => AlbumSessionsPage(
          data: data,
          onOpenPhoto: _openPhoto,
        ),
      ),
    );
  }

  void _openPhoto(List<AlbumPhoto> photos, int index) {
    if (photos.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => AlbumViewerPage(
          photos: photos,
          initialIndex: index,
          onChanged: _load,
        ),
      ),
    );
  }

  Future<void> _importCheckedCheki() async {
    final imported = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const CheckedChekiImportPage()),
    );
    if (mounted && imported == true) await _load();
  }

  Future<void> _openPreferences() async {
    final value = await showModalBottomSheet<AlbumPreferences>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => AlbumPreferencesSheet(initial: _preferences),
    );
    if (value == null || !mounted) return;
    setState(() => _preferences = value);
    // Layout changes alter all year offsets; return to the collection header.
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  Future<void> _openYearJump() async {
    final data = _data;
    final layout = _mosaicLayout;
    if (data == null || layout == null) return;
    final target = await showModalBottomSheet<_YearJumpTarget>(
      context: context,
      showDragHandle: true,
      builder: (context) => _YearJumpSheet(data: data),
    );
    if (!mounted || target == null) return;
    if (!_scrollController.hasClients) return;
    final offset = _timelineBaseOffset +
        (target.year == null
            ? layout.offsetForUndated(data.months)
            : layout.offsetForYear(target.year!, data.months));
    await _scrollController.animateTo(
      offset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isMemberFiltered ? '$_memberDisplayName的切册' : '切册',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (!_isMemberFiltered)
            PopupMenuButton<String>(
              tooltip: '切册操作',
              onSelected: (_) => _importCheckedCheki(),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'checked-import',
                  child: Text('导入已核对切图'),
                )
              ],
            ),
          IconButton(
            onPressed: _openPreferences,
            tooltip: '切册显示设置',
            icon: const Icon(Icons.tune_rounded),
          ),
          if (!_loading && data != null && !data.isEmpty)
            IconButton(
              onPressed: _openYearJump,
              tooltip: '跳到年份',
              icon: const Icon(Icons.calendar_month_rounded),
            ),
        ],
      ),
      body: AppPageBackground(
        child: Column(children: [
          if (data != null && data.photos.any((p) => p.isScan))
            AlbumCameraAccessBanner(onGranted: _load),
          ValueListenableBuilder<String?>(
            valueListenable: AlbumCameraRecovery.progress,
            builder: (context, status, _) => status == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                    child: Text(status,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
          ),
          Expanded(child: _buildBody(data)),
        ]),
      ),
    );
  }

  Widget _buildBody(AlbumData? data) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(height: 14),
            Text(
              '正在整理切册…',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      );
    }
    if (_error != null) {
      return AlbumEmptyState(
        title: '切册暂时打不开',
        message: _error!,
        icon: Icons.error_outline_rounded,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    if (data == null) {
      return const SizedBox.shrink();
    }
    if (data.isEmpty) {
      return Column(
        children: [
          AlbumLandingHeader(
            data: data,
            memberAlbum: _displayMemberAlbum,
          ),
          Expanded(
            child: AlbumEmptyState(
              title:
                  _isMemberFiltered ? '还没有 $_memberDisplayName 的切图' : '还没有切图',
              message: _isMemberFiltered
                  ? '给这位成员的流水存图，或者拍一批切，照片会按时间收进这里。'
                  : '批量拍切，或者给流水的切图存一张照片，它们就会自动收进这里。',
              icon: Icons.photo_camera_outlined,
            ),
          ),
        ],
      );
    }

    final recent = _isMemberFiltered || !_preferences.showShelves
        ? null
        : _recentSession(data);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final scaler = MediaQuery.textScalerOf(context);
        final layout = AlbumMosaicLayout(
          viewportWidth: width,
          preferredColumns: _preferences.columns,
          collage: _preferences.collage,
        );
        _mosaicLayout = layout;
        _timelineBaseOffset = _landingExtent(
          data: data,
          recent: recent,
          viewportWidth: width,
          scaler: scaler,
        );

        return CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverToBoxAdapter(
              child: AlbumLandingHeader(
                data: data,
                memberAlbum: _displayMemberAlbum,
              ),
            ),
            if (recent != null)
              SliverToBoxAdapter(
                child: AlbumRecentSessionFeature(
                  session: recent,
                  onOpen: () => _openSession(recent),
                ),
              ),
            if (!_isMemberFiltered &&
                _preferences.showShelves &&
                data.members.isNotEmpty)
              SliverToBoxAdapter(
                child: AlbumMemberStrip(
                  members: data.members,
                  onOpenMember: _openMember,
                  onViewAll: _openAllMembers,
                ),
              ),
            if (!_isMemberFiltered &&
                _preferences.showShelves &&
                data.sessions.isNotEmpty)
              SliverToBoxAdapter(
                child: AlbumSessionStrip(
                  sessions: data.sessions,
                  onOpenSession: _openSession,
                  onViewAll: _openAllSessions,
                ),
              ),
            ...buildAlbumMosaicSlivers(
              data: data,
              layout: layout,
              photoFit: _preferences.fillPhotos ? BoxFit.cover : BoxFit.contain,
              printStyle: _preferences.printStyle,
              onOpenPhoto: _openPhoto,
            ),
            const SliverToBoxAdapter(
              child: SizedBox(height: AlbumMosaicLayout.timelineBottomPadding),
            ),
          ],
        );
      },
    );
  }

  double _landingExtent({
    required AlbumData data,
    required AlbumSession? recent,
    required double viewportWidth,
    required TextScaler scaler,
  }) {
    var extent = albumLandingHeaderExtent(scaler);
    if (recent != null) {
      extent += albumFeatureExtent(
        viewportWidth: viewportWidth,
        scaler: scaler,
        photoCount: recent.photos.length,
      );
    }
    if (!_isMemberFiltered &&
        _preferences.showShelves &&
        data.members.isNotEmpty) {
      extent += albumMemberStripExtent(scaler);
    }
    if (!_isMemberFiltered &&
        _preferences.showShelves &&
        data.sessions.isNotEmpty) {
      extent += albumSessionStripExtent(scaler);
    }
    return extent;
  }
}

class _YearJumpTarget {
  final int? year;

  const _YearJumpTarget(this.year);
}

class _YearJumpSheet extends StatelessWidget {
  final AlbumData data;

  const _YearJumpSheet({required this.data});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = AppTheme.readableAccent(scheme.secondary, theme.brightness);
    final years = data.years;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.calendar_month_rounded, size: 18, color: accent),
                const SizedBox(width: 8),
                Text(
                  '跳到年份',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                Text(
                  '共 ${data.photoCount} 张',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.58,
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final year in years)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      onTap: () =>
                          Navigator.of(context).pop(_YearJumpTarget(year)),
                      leading: Container(
                        width: 40,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        child: Text(
                          '$year',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontSize: 9,
                          ),
                        ),
                      ),
                      title: Text(
                        '$year年',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        '${data.photosInYear(year)} 张 · '
                        '${data.monthCountInYear(year)} 个月',
                      ),
                      trailing: Icon(
                        Icons.arrow_forward_rounded,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  if (data.undatedDay != null)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      onTap: () => Navigator.of(context).pop(
                        const _YearJumpTarget(null),
                      ),
                      leading: Container(
                        width: 40,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        child: Icon(
                          Icons.help_outline_rounded,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      title: Text(
                        '日期不明',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        '${data.undatedDay!.count} 张 · 没有拍到日期',
                      ),
                      trailing: Icon(
                        Icons.arrow_forward_rounded,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
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
