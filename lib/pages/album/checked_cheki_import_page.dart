import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/checked_cheki_import_service.dart';

/// Reachable only from the unfiltered collection, never a member album.
class CheckedChekiImportPage extends StatefulWidget {
  const CheckedChekiImportPage({super.key});
  @override
  State<CheckedChekiImportPage> createState() => _CheckedChekiImportPageState();
}

class _CheckedChekiImportPageState extends State<CheckedChekiImportPage> {
  CheckedChekiPreview? _preview;
  bool _busy = false;
  String? _error;

  Future<void> _pick() async {
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
    });
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (selection == null) return;
      final path = selection.files.single.path;
      if (path == null) throw const FormatException('无法读取此本地文件');
      final preview = await CheckedChekiImportService.previewFile(path);
      if (mounted) setState(() => _preview = preview);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await CheckedChekiImportService.confirm(_preview!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
        '已附 ${result.additions.length} 张，跳过 ${result.duplicates} 张重复照片；计数未变',
      )));
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final groups = <int, List<CheckedChekiCard>>{};
    for (final card in preview?.cards ?? <CheckedChekiCard>[]) {
      groups.putIfAbsent(card.recordId, () => []).add(card);
    }
    final additions = preview?.additions.toSet() ?? <CheckedChekiCard>{};
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('导入已核对切图')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          Text('把切图挂回已有流水', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('只接受本地已核对 ZIP。先核对日期、成员、团体和流水编号，再附图片；不新增流水、不改变计数、不覆盖旧图。'),
          const SizedBox(height: 16),
          OutlinedButton.icon(
              onPressed: _busy ? null : _pick,
              icon: const Icon(Icons.folder_zip_outlined),
              label: Text(preview == null ? '选择本地 ZIP' : '重新选择 ZIP')),
          if (_busy)
            const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator())),
          if (_error != null)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          if (preview != null) ...[
            const SizedBox(height: 16),
            Text(
                '共 ${preview.cards.length} 张 · 待附 ${preview.additions.length} 张 · 重复跳过 ${preview.duplicates} 张',
                style: Theme.of(context).textTheme.titleMedium),
            if (preview.conflicts.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('发现冲突，整包未导入。请修正后重新选择：',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              for (final conflict in preview.conflicts) Text('• $conflict'),
            ],
            for (final entry in groups.entries) ...[
              const Divider(height: 32),
              Text('#${entry.key} · ${entry.value.first.date}',
                  style: Theme.of(context).textTheme.titleSmall),
              Text('${entry.value.first.subject} · ${entry.value.first.group}',
                  style: Theme.of(context).textTheme.titleMedium),
              Text(
                  '包内 ${entry.value.length} 张 · 待附 ${entry.value.where(additions.contains).length} 张'),
              const SizedBox(height: 10),
              SizedBox(
                  height: 148,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: entry.value.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final card = entry.value[index];
                      return SizedBox(
                          width: 96,
                          child: Column(children: [
                            Expanded(
                                child: Image.memory(card.bytes,
                                    cacheWidth: 192, fit: BoxFit.contain)),
                            Text(card.cardId,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall),
                          ]));
                    },
                  )),
            ],
            const SizedBox(height: 24),
            FilledButton(
                onPressed: !_busy && preview.canImport ? _confirm : null,
                child: Text('确认仅附 ${preview.additions.length} 张图片')),
          ],
        ]),
      ),
    );
  }
}
