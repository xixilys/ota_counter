import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/face_sample_model.dart';
import '../services/batch_import_service.dart';
import '../services/face/face_engine.dart';
import '../services/face/face_recognition_rules.dart';
import '../services/face/face_sample_service.dart';
import '../services/settings_service.dart';
import 'batch_review_page.dart';

enum _PhotoState { queued, processing, done, failed }

class _QueuedPhoto {
  final BatchSourcePhoto photo;
  _PhotoState state = _PhotoState.queued;
  BatchSourceResult? result;

  _QueuedPhoto(this.photo);
}

/// 批量拍切 step 1: shoot (or pick) photos of laid-out polaroids. Every photo
/// is cut and its faces analysed in a serial background queue while the
/// user keeps shooting.
class BatchCapturePage extends StatefulWidget {
  /// Day to suggest when the photos carry no capture time (e.g. opened from
  /// a day's album).
  final DateTime? preferredDay;

  const BatchCapturePage({super.key, this.preferredDay});

  /// Integration tests on an emulator turn the live camera off (its
  /// permission dialog would cover the page); the gallery path is the same.
  @visibleForTesting
  static bool cameraEnabled = true;

  @override
  State<BatchCapturePage> createState() => _BatchCapturePageState();
}

class _BatchCapturePageState extends State<BatchCapturePage>
    with WidgetsBindingObserver {
  final ImagePicker _picker = ImagePicker();
  final List<_QueuedPhoto> _photos = [];
  Future<void> _queue = Future.value();
  CameraController? _camera;
  String? _cameraError;
  bool _recognition = false;
  bool _shooting = false;
  bool _continuing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    final enabled = await SettingsService.getFaceRecognitionEnabled();
    if (!mounted) return;
    setState(() => _recognition = enabled);
    if (enabled) {
      // Load both models while the user lines up the first shot.
      unawaited(FaceEngine.warmUp().catchError((_) {}));
    }
    if (BatchCapturePage.cameraEnabled) await _startCamera();
  }

  Future<void> _startCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _cameraError = '没有可用的相机，可以从相册选择');
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.veryHigh,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _camera = controller;
        _cameraError = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _cameraError = '相机打不开（$error），可以从相册选择');
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final camera = _camera;
    if (!BatchCapturePage.cameraEnabled) return;
    if (state == AppLifecycleState.inactive) {
      _camera = null;
      camera?.dispose();
    } else if (state == AppLifecycleState.resumed && camera == null) {
      _startCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _camera?.dispose();
    super.dispose();
  }

  void _enqueue(BatchSourcePhoto photo) {
    final item = _QueuedPhoto(photo);
    setState(() => _photos.add(item));
    _queue = _queue.then((_) => _process(item));
  }

  Future<void> _process(_QueuedPhoto item) async {
    if (!mounted) return;
    setState(() => item.state = _PhotoState.processing);
    final result = await BatchImportService.processPhoto(
      item.photo,
      analyzer: _recognition ? FaceSampleService.analyzer : null,
    );
    if (!mounted) return;
    setState(() {
      item.result = result;
      item.state = result.error == null ? _PhotoState.done : _PhotoState.failed;
    });
  }

  Future<void> _shoot() async {
    final camera = _camera;
    if (camera == null || _shooting || !camera.value.isInitialized) return;
    final pressedAt = DateTime.now();
    setState(() => _shooting = true);
    try {
      final shot = await camera.takePicture();
      final dir = Directory(
          p.join((await getTemporaryDirectory()).path, 'batch_capture'));
      await dir.create(recursive: true);
      final path =
          p.join(dir.path, 'shot_${pressedAt.microsecondsSinceEpoch}.jpg');
      await File(shot.path).copy(path);
      _enqueue(BatchSourcePhoto(
        path: path,
        capturedAt: pressedAt,
        fromCamera: true,
      ));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('拍照失败: $error')));
      }
    } finally {
      if (mounted) setState(() => _shooting = false);
    }
  }

  Future<void> _pickFromGallery() async {
    // No resizing: re-encoding would drop EXIF (capture time).
    final files = await _picker.pickMultiImage();
    for (final file in files) {
      final takenAt =
          await BatchImportService.readExifCaptureTimeFromFile(file.path);
      _enqueue(BatchSourcePhoto(
        path: file.path,
        capturedAt: takenAt,
        fromCamera: false,
      ));
    }
  }

  int get _cardCount =>
      _photos.fold(0, (sum, item) => sum + (item.result?.cards.length ?? 0));

  bool get _busy => _photos.any((item) =>
      item.state == _PhotoState.queued || item.state == _PhotoState.processing);

  Future<void> _continue() async {
    if (_continuing) return;
    setState(() => _continuing = true);
    try {
      await _queue;
      if (!mounted) return;
      final sources = [
        for (final item in _photos)
          if (item.result != null && item.result!.cards.isNotEmpty)
            item.result!,
      ];
      if (sources.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('还没有切出拍立得')),
        );
        return;
      }
      final duplicates = sources.where((s) => s.alreadyImported > 0).length;
      if (duplicates > 0) {
        final go = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('有照片导入过'),
            content: Text('$duplicates 张原图之前已经导入过，继续会再存一份。'
                '复核页里可以删掉重复的拍立得。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('继续'),
              ),
            ],
          ),
        );
        if (go != true || !mounted) return;
      }

      final times = [for (final s in sources) s.photo.capturedAt];
      var suggested = await BatchImportService.suggestDay(times);
      if (times.every((t) => t == null) && widget.preferredDay != null) {
        suggested = dateOnly(widget.preferredDay!);
      }
      if (!mounted) return;
      final choice = await showBatchDayPicker(context, suggested);
      if (choice == null || !mounted) return;

      final context0 = choice.context;
      final sessionMembers = choice.session == null
          ? const <FaceMember>[]
          : await BatchImportService.membersOfGroups(
              choice.session!.groupNames, context0.counters);
      final all = BatchImportService.allMembers(context0.counters);
      // Keep each affiliation for group coverage even though face assignment
      // merges the same person across their different groups.
      final groupCandidates = [...context0.dayMembers, ...sessionMembers];
      if (groupCandidates.isEmpty) groupCandidates.addAll(all);
      final candidates = buildCandidateMembers(
        dayMembers: context0.dayMembers,
        sessionGroupMembers: sessionMembers,
        allMembers: all,
      );
      final samples = _recognition
          ? await FaceSampleService.getSamples()
          : const <FaceSampleModel>[];
      final cards = BatchImportService.recognize(
        sources: sources,
        candidates: candidates,
        groupCandidates: groupCandidates,
        samples: samples,
        day: context0,
      );
      if (!mounted) return;
      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (context) => BatchReviewPage(
            cards: cards,
            day: context0,
            session: choice.session,
            candidates: candidates,
            groupCandidates: groupCandidates,
            allMembers: buildCandidateMembers(
              dayMembers: [...candidates, ...all],
              sessionGroupMembers: const [],
              allMembers: const [],
            ),
            samples: samples,
            learnFaces: _recognition,
          ),
        ),
      );
      if (saved == true && mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _continuing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final camera = _camera;
    return Scaffold(
      appBar: AppBar(
        title: const Text('批量拍切'),
        actions: [
          IconButton(
            tooltip: '从相册多选',
            onPressed: _pickFromGallery,
            icon: const Icon(Icons.photo_library_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: camera != null && camera.value.isInitialized
                  ? CameraPreview(camera)
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _cameraError ??
                                (BatchCapturePage.cameraEnabled
                                    ? '正在打开相机…'
                                    : '相机已关闭，可以从相册选择'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70),
                          ),
                          const SizedBox(height: 12),
                          FilledButton.tonalIcon(
                            onPressed: _pickFromGallery,
                            icon: const Icon(Icons.photo_library_outlined),
                            label: const Text('从相册多选'),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
          Container(
            color: scheme.surfaceContainerLow,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '把拍立得平铺在深色桌面上，每张之间留空隙；'
                    '${_recognition ? '会自动认人' : '人脸识别未开启（设置在「更多 → 人脸识别」）'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 72,
                    child: _photos.isEmpty
                        ? Center(
                            child: Text('拍一张或从相册选，这里会出现缩略图',
                                style: Theme.of(context).textTheme.bodySmall),
                          )
                        : ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: _photos.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 8),
                            itemBuilder: (context, i) =>
                                _Thumb(item: _photos[i]),
                          ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${_photos.length} 张照片 · 已切出 $_cardCount 张'
                          '${_busy ? ' · 处理中…' : ''}',
                        ),
                      ),
                      IconButton.filled(
                        key: const ValueKey('batch_shutter'),
                        iconSize: 32,
                        onPressed: camera == null || _shooting ? null : _shoot,
                        icon: const Icon(Icons.camera_alt_rounded),
                        tooltip: '拍照',
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        key: const ValueKey('batch_next'),
                        onPressed:
                            _photos.isEmpty || _continuing ? null : _continue,
                        child: Text(_continuing ? '处理中…' : '下一步'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  final _QueuedPhoto item;

  const _Thumb({required this.item});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final result = item.result;
    final badge = switch (item.state) {
      _PhotoState.queued => const Icon(Icons.schedule, size: 16),
      _PhotoState.processing => const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      _PhotoState.done => Text('${result?.cards.length ?? 0}张',
          style: const TextStyle(fontSize: 11)),
      _PhotoState.failed =>
        Icon(Icons.error_outline, size: 16, color: scheme.error),
    };
    final warning = result?.warnings.isNotEmpty == true ||
        (item.state == _PhotoState.done && (result?.cards.isEmpty ?? true));
    return Tooltip(
      message: result?.error ??
          result?.warnings.map((w) => w.message).join('\n') ??
          '',
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(item.photo.path),
              width: 64,
              height: 72,
              fit: BoxFit.cover,
              cacheWidth: 160,
            ),
          ),
          Positioned(
            right: 2,
            bottom: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: warning
                    ? scheme.errorContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: badge,
            ),
          ),
        ],
      ),
    );
  }
}

/// Answer of 「这批是哪天的切？」.
class BatchDayChoice {
  final BatchDayContext context;
  final BatchSession? session;

  const BatchDayChoice(this.context, this.session);
}

/// Asks which activity day the batch belongs to (default [suggested]) and
/// which session, listing that day's tickets and events.
Future<BatchDayChoice?> showBatchDayPicker(
  BuildContext context,
  DateTime suggested,
) {
  return showModalBottomSheet<BatchDayChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _DayPickerSheet(initialDay: suggested),
  );
}

class _DayPickerSheet extends StatefulWidget {
  final DateTime initialDay;

  const _DayPickerSheet({required this.initialDay});

  @override
  State<_DayPickerSheet> createState() => _DayPickerSheetState();
}

class _DayPickerSheetState extends State<_DayPickerSheet> {
  late DateTime _day = dateOnly(widget.initialDay);
  BatchDayContext? _context;
  int _session = -1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _context = null);
    final loaded = await BatchImportService.loadDayContext(_day);
    if (!mounted || loaded.day != _day) return;
    setState(() {
      _context = loaded;
      _session = loaded.sessions.length == 1 ? 0 : -1;
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2015),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null) return;
    _day = dateOnly(picked);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final loaded = _context;
    final textTheme = Theme.of(context).textTheme;
    final date =
        '${_day.year}-${_day.month.toString().padLeft(2, '0')}-${_day.day.toString().padLeft(2, '0')}';
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('这批是哪天的切？', style: textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('凌晨 6 点前拍的算前一天', style: textTheme.bodySmall),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const ValueKey('batch_day_button'),
                onPressed: _pickDate,
                icon: const Icon(Icons.event_outlined),
                label: Text(date),
              ),
              const SizedBox(height: 8),
              if (loaded == null)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                Text(
                  loaded.records.isEmpty
                      ? '这天还没有任何流水'
                      : '这天有 ${loaded.records.length} 条流水、'
                          '${loaded.dayMembers.length} 位成员',
                  style: textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text('场次', style: textTheme.titleSmall),
                Flexible(
                  child: RadioGroup<int>(
                    groupValue: _session,
                    onChanged: (v) => setState(() => _session = v ?? -1),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        const RadioListTile<int>(
                          value: -1,
                          title: Text('不选场次'),
                        ),
                        for (var i = 0; i < loaded.sessions.length; i++)
                          RadioListTile<int>(
                            value: i,
                            title: Text(loaded.sessions[i].title),
                            subtitle: loaded.sessions[i].subtitle.isEmpty
                                ? null
                                : Text(loaded.sessions[i].subtitle,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('batch_day_confirm'),
                onPressed: loaded == null
                    ? null
                    : () => Navigator.of(context).pop(BatchDayChoice(
                          loaded,
                          _session >= 0 ? loaded.sessions[_session] : null,
                        )),
                child: const Text('开始复核'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
