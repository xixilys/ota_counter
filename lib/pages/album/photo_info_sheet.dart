import 'package:flutter/material.dart';

import '../../models/activity_record_media_model.dart';
import '../../models/activity_record_model.dart';
import '../../models/counter_model.dart';
import '../../services/cheki_photo_move_service.dart';
import '../../services/database_service.dart';
import '../../services/face/face_recognition_rules.dart';

/// Opens the 「调整信息」 sheet of one 切册 photo. Returns a short summary of
/// what changed, or null when nothing was saved.
Future<String?> showPhotoInfoSheet(BuildContext context,
    {required int mediaId}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => PhotoInfoSheet(mediaId: mediaId),
  );
}

/// Change a photo's member, day, activity and venue.
///
/// A new member or day moves the photo onto that member's record of the day
/// (created when there is none) through [ChekiPhotoMoveService], the same
/// path as the chat action `move_cheki_photo`; counts follow automatically.
/// With the same member and day, activity / venue / 场次 edit the photo's
/// record, like editing it in 流水.
class PhotoInfoSheet extends StatefulWidget {
  final int mediaId;
  const PhotoInfoSheet({super.key, required this.mediaId});

  @override
  State<PhotoInfoSheet> createState() => _PhotoInfoSheetState();
}

class _PhotoInfoSheetState extends State<PhotoInfoSheet> {
  final _activity = TextEditingController();
  final _venue = TextEditingController();
  final _session = TextEditingController();

  String? _loadError;
  ActivityRecordModel? _source;
  List<CounterModel> _counters = const [];
  List<ActivityRecordModel> _records = const [];
  int _photosOnRecord = 0;
  int? _originalCounterId;
  late DateTime _originalDay;

  int? _counterId;
  late DateTime _day;
  PhotoMovePlan? _plan;
  String? _planError;
  int _planGeneration = 0;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _activity.dispose();
    _venue.dispose();
    _session.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final media = (await DatabaseService.getActivityRecordMedia())
          .where((m) => m.id == widget.mediaId)
          .firstOrNull;
      final records = await DatabaseService.getActivityRecords();
      final source = records.where((r) => r.id == media?.recordId).firstOrNull;
      if (media == null || source == null) {
        setState(() => _loadError = '这张照片已不在切册里');
        return;
      }
      final counters = await DatabaseService.getCounters();
      final onRecord =
          await DatabaseService.getActivityRecordMedia(recordId: source.id);
      final owner = _ownerCounter(media, source, counters);
      if (!mounted) return;
      setState(() {
        _source = source;
        _records = records;
        _counters = [...counters]..sort((a, b) =>
            a.namePinyin.isEmpty || b.namePinyin.isEmpty
                ? a.name.compareTo(b.name)
                : a.namePinyin.compareTo(b.namePinyin));
        _photosOnRecord = onRecord.length;
        _originalCounterId = owner?.id;
        _counterId = owner?.id;
        _originalDay = recordActivityDay(source.occurredAt);
        _day = _originalDay;
        _activity.text = source.activityName;
        _venue.text = source.venueName;
        _session.text = source.sessionLabel;
      });
    } catch (error) {
      if (mounted) setState(() => _loadError = '读取照片信息失败：$error');
    }
  }

  CounterModel? _ownerCounter(ActivityRecordMediaModel media,
      ActivityRecordModel record, List<CounterModel> counters) {
    if (media.hasOwnerScope) {
      final name = media.ownerPersonName.trim();
      return counters
          .where((c) =>
              (media.ownerPersonId != null &&
                  c.personId == media.ownerPersonId) ||
              (name.isNotEmpty && (c.personName == name || c.name == name)))
          .firstOrNull;
    }
    if (!record.isCounter) return null;
    return resolveCounterForActivityRecord(counters, record);
  }

  bool get _moving =>
      _counterId != null &&
      (_counterId != _originalCounterId || _day != _originalDay);

  bool get _textChanged {
    final source = _source;
    if (source == null) return false;
    return _activity.text.trim() != source.activityName.trim() ||
        _venue.text.trim() != source.venueName.trim() ||
        _session.text.trim() != source.sessionLabel.trim();
  }

  Future<void> _replan() async {
    final generation = ++_planGeneration;
    if (!_moving) {
      setState(() {
        _plan = null;
        _planError = null;
      });
      return;
    }
    try {
      final plan = await ChekiPhotoMoveService.plan(
        PhotoMoveRequest(
          mediaId: widget.mediaId,
          counterId: _counterId!,
          day: _day,
          activityName: _activity.text,
          venueName: _venue.text,
          sessionLabel: _session.text,
        ),
        counters: _counters,
        records: _records,
      );
      if (!mounted || generation != _planGeneration) return;
      setState(() {
        _plan = plan;
        _planError = null;
      });
    } on MediaMoveException catch (error) {
      if (!mounted || generation != _planGeneration) return;
      setState(() {
        _plan = null;
        _planError = error.message;
      });
    }
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2015),
      lastDate: DateTime.now().add(const Duration(days: 366)),
      helpText: '选择这张切的日期',
    );
    if (picked == null || !mounted) return;
    setState(() => _day = dateOnly(picked));
    await _replan();
  }

  Future<void> _save() async {
    final source = _source!;
    setState(() => _saving = true);
    try {
      String summary;
      if (_moving) {
        // Re-plan with the latest fields so the preview and the write agree.
        await _replan();
        final plan = _plan;
        if (plan == null) throw MediaMoveException(_planError ?? '无法挪动这张照片');
        final result = await ChekiPhotoMoveService.apply(plan);
        final target = result.outcome.target;
        summary = '已挪到${target.subjectName} ${_dayLabel(_day)}'
            '${result.countMoved ? '，${result.countField!.label}跟着挪了一张' : ''}';
      } else if (_textChanged) {
        await DatabaseService.updateActivityRecordWithCounterImpact(
          source.id!,
          source.copyWith(
            activityName: _activity.text.trim(),
            venueName: _venue.text.trim(),
            sessionLabel: _session.text.trim(),
          ),
        );
        summary = '已更新这条流水的活动信息';
      } else {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      if (mounted) Navigator.of(context).pop(summary);
    } on MediaMoveException catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        child: Text(_loadError!, style: theme.textTheme.bodyLarge),
      );
    }
    if (_source == null) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final plan = _plan;
    final textEditable = !_moving || (plan?.createsTarget ?? false);
    final canSave = !_saving &&
        (_moving ? plan != null : _textChanged) &&
        _counterId != null;
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('调整照片信息',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            DropdownMenu<int>(
              key: const ValueKey('photo-info-member'),
              initialSelection: _counterId,
              label: const Text('成员'),
              expandedInsets: EdgeInsets.zero,
              enableFilter: true,
              requestFocusOnTap: true,
              menuHeight: 320,
              dropdownMenuEntries: [
                for (final counter in _counters)
                  if (counter.id != null &&
                      (!counter.isHidden || counter.id == _counterId))
                    DropdownMenuEntry(
                      value: counter.id!,
                      label: counter.groupName.trim().isEmpty
                          ? counter.name
                          : '${counter.name}（${counter.groupName}）',
                    ),
              ],
              onSelected: (value) {
                if (value == null) return;
                setState(() => _counterId = value);
                _replan();
              },
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('photo-info-day'),
              onPressed: _pickDay,
              icon: const Icon(Icons.event_outlined),
              label: Align(
                alignment: Alignment.centerLeft,
                child: Text('日期　${_dayLabel(_day)}'),
              ),
              style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14)),
            ),
            const SizedBox(height: 12),
            _field(_activity, '活动', textEditable),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _field(_venue, '场地', textEditable)),
              const SizedBox(width: 10),
              Expanded(child: _field(_session, '场次', textEditable)),
            ]),
            const SizedBox(height: 14),
            _Preview(lines: _previewLines()),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('photo-info-save'),
              onPressed: canSave ? _save : null,
              child: Text(_saving ? '保存中…' : (_moving ? '挪过去' : '保存')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController controller, String label, bool enabled) {
    return TextField(
      controller: controller,
      enabled: enabled,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (_) {
        setState(() {});
        if (_moving) _replan();
      },
    );
  }

  List<String> _previewLines() {
    if (_counterId == null) return ['这张照片在多人切流水上，先选它属于哪位成员'];
    if (_planError != null) return [_planError!];
    final plan = _plan;
    if (!_moving) {
      if (!_textChanged) return ['改成员或日期会把这张照片挪过去；张数自动跟着走'];
      return [
        '活动信息改的是整条流水'
            '${_photosOnRecord > 1 ? '（这条流水共 $_photosOnRecord 张照片都会跟着变）' : ''}',
      ];
    }
    if (plan == null) return ['计算中…'];
    final name = plan.counter.name;
    final target = plan.existingTarget;
    final field = plan.countField;
    final lines = <String>[
      target == null
          ? '${_dayLabel(_day)}还没有$name的流水，会新建一条'
          : '挪到$name ${_dayLabel(recordActivityDay(target.occurredAt))}'
              '${target.activityName.trim().isEmpty ? '' : ' · ${target.activityName.trim()}'}'
              '（沿用这条流水的活动信息）',
    ];
    if (field != null) {
      final from = plan.source.countForField(field);
      final to = target?.countForField(field) ?? 0;
      lines.add('张数跟着走：原流水${field.label}从 $from 张变 ${from - 1} 张，'
          '${target == null ? '新流水' : '目标流水'}${field.label}从 $to 张变 ${to + 1} 张');
    } else {
      lines.add('只挪照片，张数不动：${plan.countSkipReason}');
    }
    if (plan.removesEmptySource) lines.add('原流水挪完就空了，会一并删掉');
    if (plan.memberChanged) lines.add('这张图学到的人脸样本会撤掉，按$name重新学习');
    if (plan.clearsCapturedAt) lines.add('照片的拍摄时间不在这一天，切册改按流水日期归档');
    return lines;
  }
}

String _dayLabel(DateTime day) => '${day.year}年${day.month}月${day.day}日';

class _Preview extends StatelessWidget {
  final List<String> lines;
  const _Preview({required this.lines});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('photo-info-preview'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(line, style: theme.textTheme.bodyMedium),
            ),
        ],
      ),
    );
  }
}
