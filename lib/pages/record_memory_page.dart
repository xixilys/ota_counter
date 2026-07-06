import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:live_document_scanner/live_document_scanner.dart';
import 'package:flutter/services.dart';

import '../models/activity_record_media_model.dart';
import '../models/activity_record_model.dart';
import 'manual_scan_crop_page.dart';
import '../services/database_service.dart';
import '../services/record_scan_service.dart';

class RecordMemoryPage extends StatefulWidget {
  final List<ActivityRecordModel> records;
  final String? albumTitle;
  final DateTime? albumDate;

  RecordMemoryPage({
    super.key,
    required ActivityRecordModel record,
  })  : records = [record],
        albumTitle = null,
        albumDate = DateTime(
          record.occurredAt.year,
          record.occurredAt.month,
          record.occurredAt.day,
        );

  RecordMemoryPage.group({
    super.key,
    required List<ActivityRecordModel> records,
    this.albumTitle,
    this.albumDate,
  }) : records = List<ActivityRecordModel>.unmodifiable(records);

  @override
  State<RecordMemoryPage> createState() => _RecordMemoryPageState();
}

class _RecordMemoryPageState extends State<RecordMemoryPage> {
  final ImagePicker _picker = ImagePicker();
  final LiveDocumentScanner _nativeScanner = LiveDocumentScanner(
    options: DocumentScannerOptions(
      pageLimit: 1,
      type: DocumentScannerType.images,
      galleryImportAllowed: true,
    ),
  );
  List<ActivityRecordMediaModel> _media = [];
  bool _loading = true;
  bool _saving = false;

  List<ActivityRecordModel> get _records => widget.records;

  ActivityRecordModel? get _primaryRecord {
    for (final record in _records) {
      if (record.id != null) {
        return record;
      }
    }
    return _records.isEmpty ? null : _records.first;
  }

  List<int> get _recordIds {
    return _records.map((record) => record.id).whereType<int>().toList();
  }

  int? get _targetRecordId => _primaryRecord?.id;

  bool get _isGroupedAlbum => _records.length > 1;

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
        _media = [];
        _loading = false;
      });
      return;
    }

    final media = await DatabaseService.getActivityRecordMedia(
      recordIds: recordIds,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _media = media;
      _loading = false;
    });
  }

  String _formatDateTime(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    final date =
        '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)}';
    if (value.hour == 0 && value.minute == 0) {
      return date;
    }
    return '$date ${twoDigits(value.hour)}:${twoDigits(value.minute)}';
  }

  String get _pageTitle {
    if (_isGroupedAlbum) {
      final title = widget.albumTitle?.trim() ?? '';
      return title.isEmpty ? '当日存图' : '$title · 当日存图';
    }

    final record = _primaryRecord;
    if (record == null) {
      return '存图记录';
    }

    final activityName = record.resolvedActivityName;
    if (activityName.isNotEmpty) {
      return activityName;
    }
    if (record.isMulti) {
      return record.multiDisplayName;
    }
    return record.subjectName;
  }

  List<String> get _metaLines {
    final record = _primaryRecord;
    if (record == null) {
      return const <String>[];
    }

    if (_isGroupedAlbum) {
      final activities = _records
          .map((item) {
            final activityName = item.resolvedActivityName.trim();
            if (activityName.isNotEmpty) {
              return activityName;
            }
            return item.isMulti
                ? item.multiDisplayName
                : item.subjectName.trim();
          })
          .where((item) => item.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      final venues = _records
          .map((item) => item.resolvedVenueName.trim())
          .where((item) => item.isNotEmpty)
          .toSet()
          .toList()
        ..sort();

      return [
        _formatDateTime(widget.albumDate ?? record.occurredAt),
        '${_records.length} 条相关记录',
        if (activities.isNotEmpty)
          activities.length <= 2
              ? activities.join(' / ')
              : '${activities.take(2).join(' / ')} 等${activities.length}项',
        if (venues.isNotEmpty)
          venues.length <= 2
              ? venues.join(' / ')
              : '${venues.take(2).join(' / ')} 等${venues.length}处',
      ];
    }

    return [
      _formatDateTime(record.occurredAt),
      if (record.resolvedVenueName.isNotEmpty) record.resolvedVenueName,
      if (record.sessionLabel.trim().isNotEmpty) record.sessionLabel.trim(),
    ];
  }

  Future<void> _savePickedFiles(
    List<XFile> files, {
    ActivityRecordMediaType mediaType = ActivityRecordMediaType.memory,
    ActivityRecordMediaProcessingMode processingMode =
        ActivityRecordMediaProcessingMode.none,
    String successLabel = '图片',
  }) async {
    final recordId = _targetRecordId;
    if (recordId == null || files.isEmpty) {
      return;
    }

    setState(() {
      _saving = true;
    });

    try {
      for (final file in files) {
        await DatabaseService.saveActivityRecordMediaFile(
          recordId: recordId,
          imageFile: File(file.path),
          mediaType: mediaType,
          processingMode: processingMode,
        );
      }
      await _loadMedia();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存 ${files.length} 张$successLabel')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _pickFromGallery() async {
    final files = await _picker.pickMultiImage(
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    await _savePickedFiles(files, successLabel: '张纪念照');
  }

  Future<void> _takePhoto() async {
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (file == null) {
      return;
    }
    await _savePickedFiles([file], successLabel: '张纪念照');
  }

  Future<void> _saveScanOutput(RecordScanOutput output) async {
    final recordId = _targetRecordId;
    if (recordId == null) {
      return;
    }

    await DatabaseService.saveActivityRecordMediaBytes(
      recordId: recordId,
      bytes: output.bytes,
      fileExtension: output.fileExtension,
      mediaType: ActivityRecordMediaType.scan,
      processingMode: output.processingMode,
    );
  }

  Future<void> _startNativeScanner() async {
    final recordId = _targetRecordId;
    if (recordId == null || _saving) {
      return;
    }

    setState(() {
      _saving = true;
    });

    try {
      final results = await _nativeScanner.scanDocument();
      final imagePaths = results.images ?? const <String>[];
      if (imagePaths.isEmpty) {
        return;
      }

      for (final path in imagePaths) {
        final file = File(path);
        if (!await file.exists()) {
          continue;
        }
        await DatabaseService.saveActivityRecordMediaFile(
          recordId: recordId,
          imageFile: file,
          mediaType: ActivityRecordMediaType.scan,
          processingMode: ActivityRecordMediaProcessingMode.nativeScanner,
        );
      }

      await _loadMedia();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存原生扫描切图')),
      );
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      final code = error.code.toUpperCase();
      if (code.contains('CANCEL')) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('原生扫描失败: ${error.message ?? error.code}')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('原生扫描失败: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _startScan() async {
    if (_targetRecordId == null || _saving) {
      return;
    }

    final source = await _pickScanSource();
    if (!mounted || source == null) {
      return;
    }

    final sourceFile = await _pickSingleScanFile(source);
    if (!mounted || sourceFile == null) {
      return;
    }

    setState(() {
      _saving = true;
    });

    try {
      final output = await RecordScanService.createBasicScan(
        sourceFile: sourceFile,
      );
      await _saveScanOutput(output);
      await _loadMedia();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已生成简单防反光切图')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('扫描失败: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _startManualAssistScan() async {
    if (_targetRecordId == null || _saving) {
      return;
    }

    final source = await _pickManualScanSource();
    if (!mounted || source == null) {
      return;
    }

    final file = await _pickSingleScanFile(source);
    if (!mounted || file == null) {
      return;
    }

    RecordScanManualDraft draft;
    setState(() {
      _saving = true;
    });
    try {
      draft = await RecordScanService.prepareManualDraft(sourceFile: file);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('准备手动框选失败: $error')),
      );
      return;
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }

    if (!mounted) {
      return;
    }

    final quad = await Navigator.of(context).push<RecordScanQuad>(
      MaterialPageRoute(
        builder: (context) => ManualScanCropPage(draft: draft),
      ),
    );
    if (!mounted || quad == null) {
      return;
    }

    setState(() {
      _saving = true;
    });
    try {
      final output = await RecordScanService.createManualScan(
        sourceBytes: draft.sourceBytes,
        quad: quad,
      );
      await _saveScanOutput(output);
      await _loadMedia();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已生成手动框选切图')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('手动框选失败: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<_ScanSource?> _pickManualScanSource() async {
    return showModalBottomSheet<_ScanSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('手动框选辅助'),
              subtitle: Text('先拍一张或选一张图，再自己拖四个角把拍立得框出来。'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍一张后手动框选'),
              onTap: () => Navigator.of(context).pop(_ScanSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择后手动框选'),
              onTap: () => Navigator.of(context).pop(_ScanSource.gallery),
            ),
          ],
        ),
      ),
    );
  }

  Future<_ScanSource?> _pickScanSource() async {
    return showModalBottomSheet<_ScanSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('简单防反光'),
              subtitle: Text('本地快速处理一张图，适合懒得手动框选时先扫一版留档。'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍一张扫描'),
              subtitle: const Text('直接拍一张后本地快速处理'),
              onTap: () => Navigator.of(context).pop(_ScanSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择一张'),
              subtitle: const Text('使用现有图片做本地快速处理'),
              onTap: () => Navigator.of(context).pop(_ScanSource.gallery),
            ),
          ],
        ),
      ),
    );
  }

  Future<File?> _pickSingleScanFile(_ScanSource source) async {
    final file = source == _ScanSource.camera
        ? await _picker.pickImage(
            source: ImageSource.camera,
            maxWidth: 2400,
            maxHeight: 2400,
            imageQuality: 95,
          )
        : await _picker.pickImage(
            source: ImageSource.gallery,
            maxWidth: 2400,
            maxHeight: 2400,
            imageQuality: 95,
          );
    if (file == null) {
      return null;
    }
    return File(file.path);
  }

  Future<void> _showScanModes() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.document_scanner_outlined),
              title: const Text('调用外部扫描组件'),
              subtitle: const Text('交给系统扫描组件自动裁边和矫正，效果更稳时优先用它。'),
              onTap: () async {
                Navigator.of(context).pop();
                await _startNativeScanner();
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.crop_free_outlined),
              title: const Text('手动框选辅助'),
              subtitle: const Text('自动不准时自己拖四个角，更适合无谷歌框架或复杂背景。'),
              onTap: () async {
                Navigator.of(context).pop();
                await _startManualAssistScan();
              },
            ),
            ListTile(
              leading: const Icon(Icons.auto_fix_high_outlined),
              title: const Text('简单防反光'),
              subtitle: const Text('本地快速处理单张图片，适合不想手动框选时先留一版。'),
              onTap: () async {
                Navigator.of(context).pop();
                await _startScan();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddOptions() async {
    if (_targetRecordId == null || _saving) {
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.document_scanner_outlined),
              title: const Text('扫描切图'),
              subtitle: const Text('切图会排在纪念照前面展示'),
              onTap: () async {
                Navigator.of(context).pop();
                await _showScanModes();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍一张纪念照'),
              onTap: () async {
                Navigator.of(context).pop();
                await _takePhoto();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择纪念照'),
              onTap: () async {
                Navigator.of(context).pop();
                await _pickFromGallery();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteMedia(ActivityRecordMediaModel media) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除图片'),
        content: Text(
          media.isScan ? '确定删除这张扫描切图吗？' : '确定删除这张纪念照吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    await DatabaseService.deleteActivityRecordMedia(media.id!);
    await _loadMedia();
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
                  media.isScan
                      ? Icons.document_scanner_outlined
                      : Icons.photo_library_outlined,
                ),
                label: Text(_mediaBadgeLabel(media)),
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

  String _mediaBadgeLabel(ActivityRecordMediaModel media) {
    if (!media.isScan) {
      return media.mediaType.label;
    }
    if (!media.processingMode.isProcessed) {
      return media.mediaType.label;
    }
    return '${media.mediaType.label} · ${media.processingMode.label}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scanCount = _media.where((item) => item.isScan).length;
    final memoryCount = _media.length - scanCount;

    return Scaffold(
      appBar: AppBar(
        title: const Text('存图记录'),
        actions: [
          IconButton(
            onPressed:
                _targetRecordId == null || _saving ? null : _showAddOptions,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            tooltip: '添加图片',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _targetRecordId == null || _saving ? null : _showAddOptions,
        icon: _saving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add_a_photo_outlined),
        label: Text(_saving ? '处理中' : '新增存图'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _pageTitle,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (_metaLines.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        ..._metaLines.map(
                          (line) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              line,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _MemoryMetricChip(
                            icon: Icons.document_scanner_outlined,
                            label: '扫描切图',
                            value: '$scanCount',
                          ),
                          _MemoryMetricChip(
                            icon: Icons.photo_library_outlined,
                            label: '纪念照',
                            value: '$memoryCount',
                          ),
                        ],
                      ),
                      if (_isGroupedAlbum) ...[
                        const SizedBox(height: 12),
                        Text(
                          '当天记录',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ..._records.map((record) {
                          final title = record.resolvedActivityName.isNotEmpty
                              ? record.resolvedActivityName
                              : (record.isMulti
                                  ? record.multiDisplayName
                                  : record.subjectName);
                          final parts = <String>[
                            if (record.resolvedVenueName.isNotEmpty)
                              record.resolvedVenueName,
                            if (record.counterSpecSummaryLabel.isNotEmpty)
                              record.counterSpecSummaryLabel,
                            if (record.isMulti &&
                                record.multiFieldLabel.isNotEmpty)
                              record.multiFieldLabel,
                            if (record.note.trim().isNotEmpty)
                              record.note.trim(),
                          ];

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surface,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (parts.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      parts.join(' · '),
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        }),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (_media.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant,
                      ),
                    ),
                    child: const Text(
                      '这条见面记录还没有存图，可以直接拍纪念照，也可以用扫描模式保存切图。',
                    ),
                  )
                else
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _media.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 0.82,
                    ),
                    itemBuilder: (context, index) {
                      final media = _media[index];
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
                                      child: Icon(Icons.broken_image_outlined),
                                    );
                                  },
                                ),
                                Positioned(
                                  top: 8,
                                  left: 8,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: media.isScan
                                          ? theme.colorScheme.primaryContainer
                                          : Colors.black54,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 6,
                                      ),
                                      child: Text(
                                        _mediaBadgeLabel(media),
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(
                                          color: media.isScan
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
                                  top: 8,
                                  right: 8,
                                  child: IconButton.filledTonal(
                                    onPressed: () => _deleteMedia(media),
                                    icon: const Icon(Icons.delete_outline),
                                    tooltip: '删除',
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
    );
  }
}

enum _ScanSource {
  camera,
  gallery,
}

class _MemoryMetricChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _MemoryMetricChip({
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
