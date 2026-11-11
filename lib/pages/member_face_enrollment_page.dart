import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../models/face_sample_model.dart';
import '../services/face/face_engine.dart';
import '../services/face/face_models.dart';
import '../services/face/face_recognition_rules.dart';
import '../services/face/face_sample_service.dart';

/// A member's local face samples. Imported photos are never archived here.
class MemberFaceEnrollmentPage extends StatefulWidget {
  final FaceMember member;

  const MemberFaceEnrollmentPage({super.key, required this.member});

  @override
  State<MemberFaceEnrollmentPage> createState() =>
      _MemberFaceEnrollmentPageState();
}

class _MemberFaceEnrollmentPageState extends State<MemberFaceEnrollmentPage> {
  final _picker = ImagePicker();
  int? _sampleCount;
  bool _busy = false;
  String _progress = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final samples = await FaceSampleService.getMemberSamples(widget.member);
    if (mounted) setState(() => _sampleCount = samples.length);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pick(ImageSource source) async {
    setState(() {
      _busy = true;
      _progress = '选择照片';
    });
    var kept = 0;
    var noFace = 0;
    var failed = 0;
    try {
      final List<XFile> photos;
      if (source == ImageSource.gallery) {
        photos = await _picker.pickMultiImage(maxWidth: 1600, maxHeight: 1600);
      } else {
        final photo = await _picker.pickImage(
          source: source,
          maxWidth: 1600,
          maxHeight: 1600,
        );
        photos = [if (photo != null) photo];
      }
      final selfSamples = [
        for (final sample in await FaceSampleService.getSamples(isSelf: true))
          sample.embedding,
      ];
      for (var i = 0; i < photos.length; i++) {
        if (!mounted) return;
        setState(() => _progress = '识别人脸 ${i + 1}/${photos.length}');
        List<FaceAnalysis> faces;
        List<Uint8List> thumbnails;
        try {
          final bytes = await photos[i].readAsBytes();
          faces = FaceSampleService.memberFaces(
            await FaceSampleService.analyzer(bytes),
            selfSamples,
          );
          if (faces.isEmpty) {
            noFace++;
            continue;
          }
          // Use the same EXIF-aware decoder and coordinates as the detector.
          final image = await FaceEngine.decodeImageBytes(bytes);
          thumbnails =
              await compute(_faceThumbnails, (image: image, faces: faces));
        } catch (_) {
          failed++;
          continue;
        }
        if (!mounted) return;
        final selected = await _chooseFace(
          thumbnails,
          i + 1,
          photos.length,
          hasSelfSamples: selfSamples.isNotEmpty,
        );
        if (selected == null || !mounted) continue;
        kept += await FaceSampleService.addSamples([
          FaceSampleService.sampleFromAnalysis(
            faces[selected],
            source: FaceSampleSource.manual,
            owner: widget.member,
          ),
        ]);
        await _load();
      }
      if (photos.isNotEmpty) {
        _toast('保留 $kept 个新样本'
            '${noFace == 0 ? '' : '，$noFace 张未找到非「我」人脸'}'
            '${failed == 0 ? '' : '，$failed 张读取或识别失败'}');
      }
    } catch (error) {
      _toast('登记失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<int?> _chooseFace(
    List<Uint8List> thumbnails,
    int photoIndex,
    int photoCount, {
    required bool hasSelfSamples,
  }) async {
    int? selected = thumbnails.length == 1 ? 0 : null;
    return showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: SingleChildScrollView(
              child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '哪张脸是${widget.member.name}？',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text('照片 $photoIndex/$photoCount · '
                    '${hasSelfSamples ? '已排除「我」' : '未录入「我」，别选到自己'}'
                    '${thumbnails.length > 1 ? '，请点选人脸' : ''}'),
                const SizedBox(height: 16),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                  ),
                  child: GridView.builder(
                    shrinkWrap: true,
                    itemCount: thumbnails.length,
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 180,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    itemBuilder: (context, index) => Semantics(
                      label: '人脸 ${index + 1}',
                      selected: selected == index,
                      button: true,
                      child: InkWell(
                        onTap: () => setSheetState(() => selected = index),
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.memory(thumbnails[index],
                                  fit: BoxFit.cover),
                            ),
                            if (thumbnails.length > 1 && index == 0)
                              Positioned(
                                left: 8,
                                top: 8,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color:
                                        Theme.of(context).colorScheme.surface,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Text('最大'),
                                ),
                              ),
                            if (selected == index)
                              Positioned(
                                right: 8,
                                bottom: 8,
                                child: CircleAvatar(
                                  radius: 16,
                                  backgroundColor:
                                      Theme.of(context).colorScheme.primary,
                                  child: Icon(Icons.check,
                                      size: 20,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onPrimary),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                OverflowBar(
                  alignment: MainAxisAlignment.spaceBetween,
                  overflowAlignment: OverflowBarAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('跳过这张照片'),
                    ),
                    FilledButton(
                      onPressed: selected == null
                          ? null
                          : () => Navigator.pop(context, selected),
                      child: const Text('登记这张脸'),
                    ),
                  ],
                ),
              ],
            ),
          )),
        ),
      ),
    );
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('清除${widget.member.name}的人脸样本？'),
        content: const Text('只清除这位成员的样本，照片、流水和其他成员不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _progress = '清除样本中';
    });
    try {
      await FaceSampleService.clearMember(widget.member);
      await _load();
    } catch (error) {
      _toast('清除失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('登记人脸')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(widget.member.displayLabel,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(_sampleCount == null ? '读取样本中' : '已有 $_sampleCount 个样本'),
            const SizedBox(height: 8),
            const Text('只有一张脸时默认选中；有多张脸时，最大脸排在前面，请点选成员的人脸。录入过的「我」会自动排除。'
                '仅保留本机人脸样本，不保存原照片，每人最多 30 个。'),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : () => _pick(ImageSource.gallery),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('从相册选择照片（可多选）'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _pick(ImageSource.camera),
              icon: const Icon(Icons.camera_alt_outlined),
              label: const Text('拍照登记'),
            ),
            if (_busy) ...[
              const SizedBox(height: 24),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(_progress),
            ],
            const SizedBox(height: 24),
            TextButton.icon(
              onPressed: _busy || (_sampleCount ?? 0) == 0 ? null : _clear,
              icon: const Icon(Icons.delete_outline),
              label: const Text('清除这位成员的样本'),
            ),
          ],
        ),
      );
}

List<Uint8List> _faceThumbnails(
  ({BgrImage image, List<FaceAnalysis> faces}) input,
) {
  final (:image, :faces) = input;
  final decoded = img.Image.fromBytes(
    width: image.width,
    height: image.height,
    bytes: image.data.buffer,
    order: img.ChannelOrder.bgr,
  );
  return [
    for (final analysis in faces)
      (() {
        final face = analysis.face;
        final x =
            (face.x - face.width * 0.15).floor().clamp(0, image.width - 1);
        final y =
            (face.y - face.height * 0.15).floor().clamp(0, image.height - 1);
        final width = (face.width * 1.3).ceil().clamp(1, image.width - x);
        final height = (face.height * 1.3).ceil().clamp(1, image.height - y);
        return Uint8List.fromList(img.encodeJpg(img.copyResize(
          img.copyCrop(decoded, x: x, y: y, width: width, height: height),
          width: 240,
        )));
      })(),
  ];
}
