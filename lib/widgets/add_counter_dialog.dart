import 'package:flutter/material.dart';
import '../models/counter_model.dart';
import 'color_picker_dialog.dart';

class AddCounterDialog extends StatefulWidget {
  final CounterModel? initialData;

  const AddCounterDialog({
    super.key,
    this.initialData,
  });

  @override
  State<AddCounterDialog> createState() => _AddCounterDialogState();
}

class _AddCounterDialogState extends State<AddCounterDialog> {
  final _nameController = TextEditingController();
  late final Map<String, TextEditingController> _countControllers;
  Color _selectedColor = const Color(0xFFFFE135);
  String? _nameError;
  final Map<String, String?> _countErrors = {};

  @override
  void initState() {
    super.initState();
    _countControllers = {
      for (final field in CounterCountField.values)
        field.key: TextEditingController(),
    };

    if (widget.initialData != null) {
      _nameController.text = widget.initialData!.name;
      _selectedColor = widget.initialData!.colorValue;
      for (final field in CounterCountField.values) {
        _countControllers[field.key]!.text =
            widget.initialData!.countForField(field).toString();
      }
    }
  }

  void _showColorPicker() {
    showDialog(
      context: context,
      builder: (context) => ColorPickerDialog(
        initialColor: _selectedColor,
        onColorChanged: (color) {
          setState(() {
            _selectedColor = color;
          });
        },
      ),
    );
  }

  String _colorToHex(Color color) {
    final hex =
        '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    return hex.toUpperCase();
  }

  @override
  void dispose() {
    _nameController.dispose();
    for (final controller in _countControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool _validate() {
    bool isValid = true;
    setState(() {
      _nameError = null;
      _countErrors.clear();

      final name = _nameController.text.trim();
      if (name.isEmpty) {
        _nameError = '请输入名称';
        isValid = false;
      }

      for (final field in CounterCountField.values) {
        final countText = _countControllers[field.key]!.text.trim();
        if (countText.isEmpty) {
          continue;
        }

        final count = int.tryParse(countText);
        if (count == null || count < 0) {
          _countErrors[field.key] = '请输入有效的数值';
          isValid = false;
        }
      }
    });
    return isValid;
  }

  int _parseCount(CounterCountField field) {
    return int.tryParse(_countControllers[field.key]!.text.trim()) ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.initialData != null;

    return AlertDialog(
      title: Text(isEditing ? '编辑计数器' : '添加新计数器'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: '名称',
                hintText: '请输入名称',
                errorText: _nameError,
              ),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '规格计数（留空默认 0）',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final fieldWidth = constraints.maxWidth > 360
                    ? (constraints.maxWidth - 12) / 2
                    : constraints.maxWidth;

                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: CounterCountField.values.map((field) {
                    return SizedBox(
                      width: fieldWidth,
                      child: TextField(
                        controller: _countControllers[field.key],
                        decoration: InputDecoration(
                          labelText: field.label,
                          hintText: '0',
                          errorText: _countErrors[field.key],
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    );
                  }).toList(),
                );
              },
            ),
            const SizedBox(height: 16),
            const Text('选择颜色:'),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _showColorPicker,
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: _selectedColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.grey),
                ),
                child: const Icon(Icons.color_lens, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            if (!_validate()) return;

            final name = _nameController.text.trim();

            Navigator.of(context).pop(
              CounterModel(
                id: widget.initialData?.id,
                name: name,
                color: _colorToHex(_selectedColor),
                threeInchCount: _parseCount(CounterCountField.threeInch),
                fiveInchCount: _parseCount(CounterCountField.fiveInch),
                groupCutCount: _parseCount(CounterCountField.groupCut),
                threeInchShukudaiCount: _parseCount(
                  CounterCountField.threeInchShukudai,
                ),
                fiveInchShukudaiCount: _parseCount(
                  CounterCountField.fiveInchShukudai,
                ),
              ),
            );
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}
