import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/database_service.dart';
import '../services/face/face_engine.dart';
import '../services/face/face_sample_service.dart';
import '../services/face/face_recognition_rules.dart';
import '../services/settings_service.dart';

/// 设置 → 人脸识别: switch, enrol "我", learn from archived photos, wipe.
class FaceRecognitionSettingsPage extends StatefulWidget {
  const FaceRecognitionSettingsPage({super.key});

  /// Shared consent explanation for settings and member enrolment.
  static Future<bool> ensureEnabled(BuildContext context) async {
    if (await SettingsService.getFaceRecognitionEnabled()) return true;
    if (!context.mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('开启人脸识别'),
        content: const Text(
          '批量拍切时会在照片里找人脸，自动建议是哪位成员。\n\n'
          '· 识别只在这台手机上进行，照片和人脸数据都不会上传。\n'
          '· 人脸数据不会进入「导出数据」的备份。\n'
          '· 可以随时在这里关闭，或清除全部人脸数据。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开启'),
          ),
        ],
      ),
    );
    if (ok != true) return false;
    await SettingsService.saveFaceRecognitionEnabled(true);
    FaceEngine.warmUp().catchError((_) {});
    return true;
  }

  @override
  State<FaceRecognitionSettingsPage> createState() =>
      _FaceRecognitionSettingsPageState();
}

class _FaceRecognitionSettingsPageState
    extends State<FaceRecognitionSettingsPage> {
  final ImagePicker _picker = ImagePicker();
  bool _enabled = false;
  bool _busy = false;
  String _busyLabel = '';
  ({int self, int members, int people})? _stats;
  List<({FaceMember member, int count})> _members = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await SettingsService.getFaceRecognitionEnabled();
    final stats = await FaceSampleService.getStats();
    final knownMembers = await FaceSampleService.getKnownMembers();
    final counters = await DatabaseService.getCounters();
    final members = knownMembers.map((item) {
      final groups = counters
          .where((counter) =>
              (item.member.counterId != null &&
                  counter.id == item.member.counterId) ||
              (item.member.personId != null &&
                  counter.personId == item.member.personId))
          .map((counter) => counter.groupName.trim())
          .where((group) => group.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      return (
        member: item.member.mergedWith(
            FaceMember(name: item.member.name, groupName: groups.join('、'))),
        count: item.count,
      );
    }).toList();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _stats = stats;
      _members = members;
    });
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(String label, Future<void> Function() task) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyLabel = label;
    });
    try {
      await task();
    } catch (error) {
      _toast('$label失败: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<void> _setEnabled(bool value) async {
    if (value) {
      if (!await FaceRecognitionSettingsPage.ensureEnabled(context)) return;
    }
    await SettingsService.saveFaceRecognitionEnabled(value);
    await _load();
  }

  Future<void> _enrollSelf() async {
    final source = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_front_outlined),
              title: const Text('用前置相机拍 3 张'),
              subtitle: const Text('每张换一点角度'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选几张自己的照片'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final photos = <Uint8List>[];
    if (source == 'camera') {
      for (var i = 0; i < 3; i++) {
        final shot = await _picker.pickImage(
          source: ImageSource.camera,
          preferredCameraDevice: CameraDevice.front,
          maxWidth: 1600,
          maxHeight: 1600,
        );
        if (shot == null) break;
        photos.add(await shot.readAsBytes());
      }
    } else {
      final picked = await _picker.pickMultiImage(maxWidth: 1600);
      for (final file in picked) {
        photos.add(await file.readAsBytes());
      }
    }
    if (photos.isEmpty) return;
    await _run('录入', () async {
      final count = await FaceSampleService.enrollSelf(photos);
      _toast(count == 0 ? '没找到人脸，换张清楚的正脸照片再试' : '已录入 $count 张「我」');
    });
  }

  Future<void> _learn() async {
    await _run('学习', () async {
      final result = await FaceSampleService.learnFromArchive(
        onProgress: (done, total) {
          if (mounted) {
            setState(() => _busyLabel = '学习中 $done/$total');
          }
        },
      );
      _toast('看了 ${result.scanned} 张，新学到 ${result.learned} 张；'
          '${result.notSingleFace} 张不是单人脸，'
          '${result.noOwner} 张不知道是谁');
    });
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除全部人脸数据'),
        content: const Text('会删除「我」和所有成员的人脸样本，照片和流水不受影响。'),
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
    if (ok != true) return;
    await _run('清除', () async {
      await FaceSampleService.clearAll();
      _toast('已清除');
    });
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    return Scaffold(
      appBar: AppBar(title: const Text('人脸识别')),
      body: ListView(
        children: [
          SwitchListTile(
            value: _enabled,
            onChanged: _busy ? null : _setEnabled,
            title: const Text('批量拍切时自动认人'),
            subtitle: const Text('只在手机本地识别，不上传，可随时清除'),
          ),
          if (_busy)
            ListTile(
              leading: const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text(_busyLabel),
            ),
          ListTile(
            leading: const Icon(Icons.face_outlined),
            title: const Text('录入我自己'),
            subtitle: Text(stats == null
                ? ''
                : stats.self == 0
                    ? '还没录入；录入后合照里的你会被自动排除'
                    : '已有 ${stats.self} 个样本'),
            onTap: _busy ? null : _enrollSelf,
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('从已归档照片学习'),
            subtitle: Text(stats == null
                ? ''
                : '已认识 ${stats.people} 位成员（${stats.members} 个样本）。'
                    '只用知道是谁、且只有一张非「我」人脸的照片'),
            onTap: _busy ? null : _learn,
          ),
          if (_members.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Text('已认识的成员及样本数'),
            ),
            for (final item in _members)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(item.member.identityName),
                subtitle: item.member.groupName.isEmpty
                    ? null
                    : Text(item.member.groupName),
                trailing: Text('${item.count} 个样本'),
              ),
          ],
          ListTile(
            leading: const Icon(Icons.delete_forever_outlined),
            title: const Text('清除全部人脸数据'),
            onTap: _busy ? null : _clear,
          ),
        ],
      ),
    );
  }
}
