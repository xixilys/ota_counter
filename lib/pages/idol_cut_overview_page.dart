import 'dart:io';

import 'package:flutter/material.dart';

import '../models/activity_record_media_model.dart';
import '../models/activity_record_model.dart';
import '../services/database_service.dart';

class IdolCutOverviewPage extends StatefulWidget {
  final String idolName;
  final List<ActivityRecordModel> records;

  const IdolCutOverviewPage({
    super.key,
    required this.idolName,
    required this.records,
  });

  @override
  State<IdolCutOverviewPage> createState() => _IdolCutOverviewPageState();
}

class _IdolCutOverviewPageState extends State<IdolCutOverviewPage> {
  List<ActivityRecordMediaModel> _scanMedia = [];
  Set<int> _updatingMediaIds = const <int>{};
  bool _loading = true;
  _CutFilter _filter = _CutFilter.all;

  List<int> get _recordIds =>
      widget.records.map((record) => record.id).whereType<int>().toList();

  @override
  void initState() {
    super.initState();
    _loadMedia();
  }

  Future<void> _loadMedia() async {
    final recordIds = _recordIds;
    if (recordIds.isEmpty) {
      if (!mounted) {
        return;
      }
      setState(() {
        _scanMedia = [];
        _loading = false;
      });
      return;
    }

    try {
      final media = await DatabaseService.getActivityRecordMedia(
        recordIds: recordIds,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _scanMedia = media.where((item) => item.isScan).toList();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载切总览失败: $error')),
      );
    }
  }

  Future<void> _toggleReversed(ActivityRecordMediaModel media) async {
    final mediaId = media.id;
    if (mediaId == null || _updatingMediaIds.contains(mediaId)) {
      return;
    }
    final target = !media.isReversed;
    setState(() {
      _updatingMediaIds = {..._updatingMediaIds, mediaId};
    });

    try {
      await DatabaseService.updateActivityRecordMediaReversed(
        mediaId,
        isReversed: target,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _scanMedia = _scanMedia
            .map(
              (item) =>
                  item.id == mediaId ? item.copyWith(isReversed: target) : item,
            )
            .toList(growable: false);
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('更新反切状态失败: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _updatingMediaIds =
              _updatingMediaIds.where((id) => id != mediaId).toSet();
        });
      }
    }
  }

  Future<void> _previewMedia(ActivityRecordMediaModel media) async {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: Stack(
          children: [
            Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: InteractiveViewer(
                child: Image.file(File(media.path)),
              ),
            ),
            Positioned(
              top: 16,
              left: 16,
              child: FilledButton.tonalIcon(
                onPressed: null,
                icon: Icon(
                  media.isReversed
                      ? Icons.check_circle_outline
                      : Icons.radio_button_unchecked,
                ),
                label: Text(media.isReversed ? '已反' : '未反'),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton.filledTonal(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reversedCount = _scanMedia.where((item) => item.isReversed).length;
    final pendingCount = _scanMedia.length - reversedCount;
    final visibleMedia = switch (_filter) {
      _CutFilter.all => _scanMedia,
      _CutFilter.pending =>
        _scanMedia.where((item) => !item.isReversed).toList(growable: false),
      _CutFilter.reversed =>
        _scanMedia.where((item) => item.isReversed).toList(growable: false),
    };

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.idolName} · 切总览'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadMedia,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _SummaryChip(
                          icon: Icons.photo_library_outlined,
                          label: '切数量',
                          value: '${_scanMedia.length}',
                        ),
                        _SummaryChip(
                          icon: Icons.check_circle_outline,
                          label: '已反',
                          value: '$reversedCount',
                        ),
                        _SummaryChip(
                          icon: Icons.schedule_outlined,
                          label: '未反',
                          value: '$pendingCount',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('全部'),
                        selected: _filter == _CutFilter.all,
                        onSelected: (_) {
                          setState(() {
                            _filter = _CutFilter.all;
                          });
                        },
                      ),
                      ChoiceChip(
                        label: const Text('未反'),
                        selected: _filter == _CutFilter.pending,
                        onSelected: (_) {
                          setState(() {
                            _filter = _CutFilter.pending;
                          });
                        },
                      ),
                      ChoiceChip(
                        label: const Text('已反'),
                        selected: _filter == _CutFilter.reversed,
                        onSelected: (_) {
                          setState(() {
                            _filter = _CutFilter.reversed;
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_scanMedia.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      child: const Text('还没有切图，先去存图记录里添加扫描切图吧。'),
                    )
                  else if (visibleMedia.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      child: Text(
                        _filter == _CutFilter.pending
                            ? '当前没有未反切图。'
                            : '当前没有已反切图。',
                      ),
                    )
                  else
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: visibleMedia.length,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        childAspectRatio: 0.82,
                      ),
                      itemBuilder: (context, index) {
                        final media = visibleMedia[index];
                        final updating = media.id != null &&
                            _updatingMediaIds.contains(media.id);
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Material(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: InkWell(
                              onTap: () => _previewMedia(media),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Image.file(
                                    File(media.path),
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) {
                                      return const Center(
                                        child:
                                            Icon(Icons.broken_image_outlined),
                                      );
                                    },
                                  ),
                                  Positioned(
                                    left: 8,
                                    top: 8,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: media.isReversed
                                            ? theme.colorScheme.primaryContainer
                                            : Colors.black54,
                                        borderRadius:
                                            BorderRadius.circular(999),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        child: Text(
                                          media.isReversed ? '已反' : '未反',
                                          style: theme.textTheme.labelMedium
                                              ?.copyWith(
                                            color: media.isReversed
                                                ? theme.colorScheme
                                                    .onPrimaryContainer
                                                : Colors.white,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    right: 8,
                                    bottom: 8,
                                    child: FilledButton.tonalIcon(
                                      onPressed: updating
                                          ? null
                                          : () => _toggleReversed(media),
                                      icon: updating
                                          ? const SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : Icon(
                                              media.isReversed
                                                  ? Icons.undo
                                                  : Icons.check,
                                            ),
                                      label: Text(
                                          media.isReversed ? '改未反' : '标已反'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
    );
  }
}

enum _CutFilter {
  all,
  pending,
  reversed,
}

class _SummaryChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _SummaryChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 6),
          Text(label),
          const SizedBox(width: 6),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
