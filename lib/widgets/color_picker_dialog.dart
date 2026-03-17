import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'no_autofill_text_field.dart';

class ColorPickerDialog extends StatefulWidget {
  final Color initialColor;
  final ValueChanged<Color> onColorChanged;

  const ColorPickerDialog({
    super.key,
    required this.initialColor,
    required this.onColorChanged,
  });

  @override
  State<ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<ColorPickerDialog> {
  late Color _currentColor;
  final _redController = TextEditingController();
  final _greenController = TextEditingController();
  final _blueController = TextEditingController();

  // 基础预设颜色
  static const List<Color> _defaultColors = [
    Colors.red,
    Colors.yellow,
    Colors.blue,
    Colors.green,
    Colors.pink,
    Colors.purple,
    Colors.black,
    Colors.white,
  ];

  List<Color> _presetColors = [];

  int _colorStorageValue(Color color) => color.toARGB32();

  int _channelValue(double component) =>
      (component * 255.0).round().clamp(0, 255);

  @override
  void initState() {
    super.initState();
    _currentColor = widget.initialColor;
    _updateTextFields();
    _loadPresetColors();
  }

  // 加载保存的预设颜色
  Future<void> _loadPresetColors() async {
    final prefs = await SharedPreferences.getInstance();
    final savedColors = prefs.getStringList('preset_colors') ?? [];

    setState(() {
      _presetColors = [
        ..._defaultColors,
        ...savedColors.map((colorStr) {
          final colorValue = int.parse(colorStr);
          return Color(colorValue);
        }),
      ];
    });
  }

  // 保存预设颜色
  Future<void> _savePresetColor(Color color) async {
    if (_presetColors.contains(color)) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final savedColors = prefs.getStringList('preset_colors') ?? [];
    // 直接存储颜色的整数值
    savedColors.add(_colorStorageValue(color).toString());
    await prefs.setStringList('preset_colors', savedColors);

    setState(() {
      _presetColors.add(color);
    });
  }

  // 删除预设颜色
  Future<void> _removePresetColor(Color color) async {
    final prefs = await SharedPreferences.getInstance();
    final savedColors = prefs.getStringList('preset_colors') ?? [];
    // 使用颜色的整数值进行匹配
    savedColors.remove(_colorStorageValue(color).toString());
    await prefs.setStringList('preset_colors', savedColors);

    setState(() {
      _presetColors.remove(color);
    });
  }

  void _updateTextFields() {
    _redController.text = _channelValue(_currentColor.r).toString();
    _greenController.text = _channelValue(_currentColor.g).toString();
    _blueController.text = _channelValue(_currentColor.b).toString();
  }

  void _updateColorFromRGB() {
    final r = int.tryParse(_redController.text) ?? 0;
    final g = int.tryParse(_greenController.text) ?? 0;
    final b = int.tryParse(_blueController.text) ?? 0;

    setState(() {
      _currentColor = Color.fromRGBO(
        r.clamp(0, 255),
        g.clamp(0, 255),
        b.clamp(0, 255),
        1,
      );
    });
    widget.onColorChanged(_currentColor);
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final isPortrait = screenSize.height > screenSize.width;
    final dialogWidth =
        isPortrait ? screenSize.width * 0.9 : screenSize.width * 0.7;
    final dialogHeight =
        isPortrait ? screenSize.height * 0.7 : screenSize.height * 0.75; // 减小高度

    return Dialog(
      child: DefaultTabController(
        length: 2,
        child: Container(
          width: dialogWidth,
          height: dialogHeight,
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '选择颜色',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              const TabBar(
                tabs: [
                  Tab(text: '预设颜色'),
                  Tab(text: '自定义颜色'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    // 预设颜色页面
                    Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            '长按可删除自定义颜色',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Colors.grey[600],
                                    ),
                          ),
                        ),
                        // 默认颜色部分
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 5,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            childAspectRatio: 1,
                          ),
                          itemCount: _defaultColors.length,
                          itemBuilder: (context, index) {
                            return _buildColorItem(
                                _defaultColors[index], false);
                          },
                        ),
                        // 分割线
                        if (_presetColors.length > _defaultColors.length) ...[
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Divider(thickness: 2),
                          ),
                          // 自定义颜色部分
                          Expanded(
                            child: GridView.builder(
                              padding: const EdgeInsets.only(bottom: 8),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 5,
                                mainAxisSpacing: 8,
                                crossAxisSpacing: 8,
                                childAspectRatio: 1,
                              ),
                              itemCount:
                                  _presetColors.length - _defaultColors.length,
                              itemBuilder: (context, index) {
                                return _buildColorItem(
                                  _presetColors[index + _defaultColors.length],
                                  true,
                                );
                              },
                            ),
                          ),
                        ],
                      ],
                    ),
                    // 自定义颜色页面
                    Stack(
                      children: [
                        Column(
                          children: [
                            // RGB 输入
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: SizedBox(
                                height: 80.0,
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: NoAutofillTextField(
                                        controller: _redController,
                                        keyboardType: TextInputType.number,
                                        decoration: const InputDecoration(
                                          labelText: 'R',
                                          helperText: '0-255',
                                          isDense: true,
                                        ),
                                        onChanged: (_) => _updateColorFromRGB(),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: NoAutofillTextField(
                                        controller: _greenController,
                                        keyboardType: TextInputType.number,
                                        decoration: const InputDecoration(
                                          labelText: 'G',
                                          helperText: '0-255',
                                          isDense: true,
                                        ),
                                        onChanged: (_) => _updateColorFromRGB(),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: NoAutofillTextField(
                                        controller: _blueController,
                                        keyboardType: TextInputType.number,
                                        decoration: const InputDecoration(
                                          labelText: 'B',
                                          helperText: '0-255',
                                          isDense: true,
                                        ),
                                        onChanged: (_) => _updateColorFromRGB(),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // 颜色选择器
                            Expanded(
                              child: NotificationListener<
                                  OverscrollIndicatorNotification>(
                                onNotification: (notification) {
                                  notification.disallowIndicator();
                                  return true;
                                },
                                child: SingleChildScrollView(
                                  physics: const ClampingScrollPhysics(),
                                  child: ColorPicker(
                                    pickerColor: _currentColor,
                                    onColorChanged: (color) {
                                      setState(() {
                                        _currentColor = color;
                                        _updateTextFields();
                                      });
                                      widget.onColorChanged(color);
                                    },
                                    enableAlpha: false,
                                    displayThumbColor: true,
                                    portraitOnly: true,
                                    hexInputBar: false,
                                    pickerAreaHeightPercent: 0.7,
                                    labelTypes: const [],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween, // 改为两端对齐
                children: [
                  TextButton.icon(
                    // 左侧放保存按钮
                    onPressed: () => _savePresetColor(_currentColor),
                    icon: const Icon(Icons.save_alt),
                    label: const Text('保存为预设'),
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  TextButton(
                    // 右侧放确定按钮
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildColorItem(Color color, bool canDelete) {
    return InkWell(
      onTap: () {
        setState(() {
          _currentColor = color;
          _updateTextFields();
        });
        widget.onColorChanged(color);
      },
      onLongPress: canDelete ? () => _removePresetColor(color) : null,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: color == _currentColor ? Colors.white : Colors.grey,
            width: color == _currentColor ? 3 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _redController.dispose();
    _greenController.dispose();
    _blueController.dispose();
    super.dispose();
  }
}
