import 'package:flutter/material.dart';

import '../../models/album_preferences.dart';
import '../../services/settings_service.dart';
import 'album_widgets.dart';

class AlbumPreferencesSheet extends StatefulWidget {
  final AlbumPreferences initial;
  const AlbumPreferencesSheet({super.key, required this.initial});

  @override
  State<AlbumPreferencesSheet> createState() => _AlbumPreferencesSheetState();
}

class _AlbumPreferencesSheetState extends State<AlbumPreferencesSheet> {
  late AlbumPreferences _value = widget.initial;
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await SettingsService.saveAlbumPreferences(_value);
      if (mounted) {
        Navigator.pop(context, _value);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '设置未能保存，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('按喜欢的方式翻切册', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 20),
              Text('时间线印边', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 10),
              Row(children: [
                for (final style in [
                  AlbumPrintStyle.supporter,
                  AlbumPrintStyle.classic
                ]) ...[
                  if (style == AlbumPrintStyle.classic)
                    const SizedBox(width: 12),
                  Expanded(
                      child: Column(children: [
                    AlbumPrintCaption(
                        style: style,
                        colorHexes: const ['#FF7A9E', '#7C6CF0'],
                        child: Center(
                            child: Text('应援色 · 同框',
                                style: TextStyle(
                                    color: albumPrintInk(
                                        Theme.of(context).brightness),
                                    fontSize: 12)))),
                    ChoiceChip(
                        label: Text(style == AlbumPrintStyle.supporter
                            ? '应援印边'
                            : '经典白边'),
                        selected: _value.printStyle == style,
                        onSelected: _saving
                            ? null
                            : (_) => setState(() =>
                                _value = _value.copyWith(printStyle: style))),
                  ])),
                ],
              ]),
              const SizedBox(height: 16),
              Text('时间线每行照片', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final columns in [0, 2, 3, 4])
                  ChoiceChip(
                    label: Text(columns == 0 ? '自动' : '$columns 列'),
                    selected: _value.columns == columns,
                    onSelected: _saving
                        ? null
                        : (_) => setState(() {
                              _value = _value.copyWith(columns: columns);
                            }),
                  ),
              ]),
              const SizedBox(height: 12),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('每天一张主打'),
                subtitle: const Text('当天至少 3 张时，放大第一张；关闭则整齐排列'),
                value: _value.collage,
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                          _value = _value.copyWith(collage: value);
                        }),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('时间线照片铺满相框'),
                subtitle: const Text('关闭可看完整照片，保留签名与边角'),
                value: _value.fillPhotos,
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                          _value = _value.copyWith(fillPhotos: value);
                        }),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('首页展示收藏架'),
                subtitle: const Text('最近一场、成员与场次；关闭后直接翻时间线'),
                value: _value.showShelves,
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                          _value = _value.copyWith(showShelves: value);
                        }),
              ),
              if (_error != null)
                Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 12),
              SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? '保存中…' : '保存显示设置'),
                  )),
            ],
          ),
        ),
      );
}
