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
  final _countController = TextEditingController();
  Color _selectedColor = const Color(0xFFFFE135);
  String? _nameError;
  String? _countError;

  @override
  void initState() {
    super.initState();
    if (widget.initialData != null) {
      _nameController.text = widget.initialData!.name;
      _countController.text = widget.initialData!.count.toString();
      _selectedColor = widget.initialData!.colorValue;
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
    _countController.dispose();
    super.dispose();
  }

  bool _validate() {
    bool isValid = true;
    setState(() {
      _nameError = null;
      _countError = null;

      final name = _nameController.text.trim();
      if (name.isEmpty) {
        _nameError = '请输入名称';
        isValid = false;
      }

      final countText = _countController.text.trim();
      if (countText.isEmpty) {
        _countError = '请输入数值';
        isValid = false;
      } else {
        final count = int.tryParse(countText);
        if (count == null || count < 0) {
          _countError = '请输入有效的数值';
          isValid = false;
        }
      }
    });
    return isValid;
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
            TextField(
              controller: _countController,
              decoration: InputDecoration(
                labelText: '数值',
                hintText: '请输入数字',
                errorText: _countError,
              ),
              keyboardType: TextInputType.number,
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
            final count = int.parse(_countController.text.trim());

            Navigator.of(context).pop(
              CounterModel(
                name: name,
                count: count,
                color: _colorToHex(_selectedColor),
              ),
            );
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}
