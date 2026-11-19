import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/counter_model.dart';
import '../../models/merch_purchase_model.dart';
import '../../services/database_service.dart';
import '../../services/merch_service.dart';
import '../../theme/app_theme.dart';
import '../no_autofill_text_field.dart';

Future<MerchPurchaseModel?> showMerchPurchaseDialog(
  BuildContext context, {
  MerchPurchaseModel? initial,
}) {
  return showDialog<MerchPurchaseModel>(
    context: context,
    builder: (_) => MerchPurchaseDialog(initial: initial),
  );
}

class MerchPurchaseDialog extends StatefulWidget {
  final MerchPurchaseModel? initial;

  const MerchPurchaseDialog({super.key, this.initial});

  @override
  State<MerchPurchaseDialog> createState() => _MerchPurchaseDialogState();
}

class _MerchPurchaseDialogState extends State<MerchPurchaseDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _memberController = TextEditingController();
  final TextEditingController _groupController = TextEditingController();
  final TextEditingController _eventController = TextEditingController();
  final TextEditingController _venueController = TextEditingController();
  final TextEditingController _sessionController = TextEditingController();
  final TextEditingController _unitPriceController = TextEditingController();
  final TextEditingController _totalController = TextEditingController();
  final TextEditingController _noteController = TextEditingController();
  final TextEditingController _dateController = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  List<MerchKindModel> _kinds = const [];
  List<CounterModel> _counters = const [];
  String _kind = '';
  DateTime _occurredAt = DateTime.now();
  int _quantity = 1;
  String _photoPath = '';
  final Set<String> _newPhotoPaths = <String>{};
  bool _syncingAmounts = false;
  bool _saving = false;
  bool _kindsLoading = true;

  bool get _isEditing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _kind = initial.kind;
      _occurredAt = initial.occurredAt;
      _quantity = initial.quantity > 0 ? initial.quantity : 1;
      _photoPath = initial.photoPath;
      _memberController.text = initial.memberName;
      _groupController.text = initial.groupName;
      _eventController.text = initial.eventName;
      _venueController.text = initial.venueName;
      _sessionController.text = initial.sessionLabel;
      _noteController.text = initial.note;
      _unitPriceController.text = _formatEditableNumber(initial.unitPrice);
      _totalController.text =
          _formatEditableNumber(initial.resolvedTotalAmount);
      _dateController.text = _formatDate(initial.occurredAt);
    } else {
      _unitPriceController.text = '0';
      _totalController.text = '0';
      _dateController.text = _formatDate(_occurredAt);
    }
    _loadKinds();
    _loadCounters();
  }

  @override
  void dispose() {
    _memberController.dispose();
    _groupController.dispose();
    _eventController.dispose();
    _venueController.dispose();
    _sessionController.dispose();
    _unitPriceController.dispose();
    _totalController.dispose();
    _noteController.dispose();
    _dateController.dispose();
    super.dispose();
  }

  Future<void> _loadKinds() async {
    final kinds = await MerchService.getKinds();
    if (!mounted) return;
    final existing = _kind.trim();
    final available = List<MerchKindModel>.from(kinds);
    if (existing.isNotEmpty &&
        !available.any((kind) => kind.name == existing)) {
      available.add(
        MerchKindModel(
          name: existing,
          updatedAt: DateTime.now(),
        ),
      );
    }
    setState(() {
      _kinds = available;
      _kindsLoading = false;
      if (_kind.trim().isEmpty && _kinds.isNotEmpty) {
        _kind = _kinds.first.name;
        final defaultPrice = _kinds.first.defaultPrice;
        if (!_isEditing && defaultPrice > 0) {
          _unitPriceController.text = _formatEditableNumber(defaultPrice);
          _syncTotalFromUnitPrice();
        }
      }
    });
  }

  Future<void> _loadCounters() async {
    try {
      final counters = await DatabaseService.getCounters();
      if (!mounted) return;
      setState(() => _counters = counters);
    } catch (_) {
      // Member association is optional; the ledger still saves without it.
    }
  }

  void _selectKind(String name) {
    setState(() {
      _kind = name;
      if (!_isEditing) {
        final kind = _kinds.where((item) => item.name == name).firstOrNull;
        final defaultPrice = kind?.defaultPrice ?? 0;
        if (defaultPrice > 0 &&
            (double.tryParse(_unitPriceController.text.trim()) ?? 0) <= 0) {
          _unitPriceController.text = _formatEditableNumber(defaultPrice);
          _syncTotalFromUnitPrice();
        }
      }
    });
  }

  Future<void> _addCustomKind() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('添加周边种类'),
        content: NoAutofillTextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '种类名称',
            hintText: '例如 拍立得收纳册 / 应援扇',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty || !mounted) return;
    try {
      final id = await MerchService.addCustomKind(value);
      if (!mounted) return;
      final kind = MerchKindModel(
        id: id,
        name: value,
        updatedAt: DateTime.now(),
      );
      setState(() {
        _kinds = [..._kinds, kind];
        _kind = kind.name;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('添加种类失败：$error')),
      );
    }
  }

  void _syncTotalFromUnitPrice() {
    if (_syncingAmounts) return;
    _syncingAmounts = true;
    final unitPrice = double.tryParse(_unitPriceController.text.trim()) ?? 0;
    _totalController.text = _formatEditableNumber(unitPrice * _quantity);
    _syncingAmounts = false;
  }

  void _syncUnitPriceFromTotal() {
    if (_syncingAmounts) return;
    _syncingAmounts = true;
    final total = double.tryParse(_totalController.text.trim()) ?? 0;
    _unitPriceController.text =
        _formatEditableNumber(_quantity > 0 ? total / _quantity : total);
    _syncingAmounts = false;
  }

  void _changeQuantity(int delta) {
    final next = _quantity + delta;
    if (next <= 0 || next > 999) return;
    setState(() => _quantity = next);
    _syncTotalFromUnitPrice();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _occurredAt,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: '选择购买日期',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _occurredAt = picked;
      _dateController.text = _formatDate(picked);
    });
  }

  Future<void> _pickMember() async {
    if (_counters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有成员卡片，可以手动填写成员名')),
      );
      return;
    }
    final picked = await showModalBottomSheet<CounterModel>(
      context: context,
      showDragHandle: true,
      builder: (_) => _MemberPickerSheet(counters: _counters),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _memberController.text = picked.name;
      if (picked.groupName.trim().isNotEmpty &&
          _groupController.text.trim().isEmpty) {
        _groupController.text = picked.groupName;
      }
    });
  }

  Future<void> _pickPhoto() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
      maxWidth: 1800,
    );
    if (picked == null || !mounted) return;
    try {
      final savedPath = await MerchService.savePhoto(File(picked.path));
      if (!mounted) return;
      setState(() {
        _newPhotoPaths.add(savedPath);
        _photoPath = savedPath;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存照片失败：$error')),
      );
    }
  }

  void _removePhoto() {
    setState(() => _photoPath = '');
  }

  Future<void> _cleanupNewPhotos({String? keepPath}) async {
    for (final path in _newPhotoPaths) {
      if (path == keepPath) continue;
      await MerchService.deletePhoto(path);
    }
  }

  Future<void> _cancel() async {
    await _cleanupNewPhotos();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final kind = _kind.trim();
    if (kind.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先选一个周边种类')),
      );
      return;
    }
    setState(() => _saving = true);
    final initial = widget.initial;
    final unitPrice = double.tryParse(_unitPriceController.text.trim()) ?? 0;
    final total = double.tryParse(_totalController.text.trim()) ?? 0;
    final purchase = MerchPurchaseModel.purchase(
      id: initial?.id,
      kind: kind,
      occurredAt: _occurredAt,
      memberName: _memberController.text,
      groupName: _groupController.text,
      eventName: _eventController.text,
      venueName: _venueController.text,
      sessionLabel: _sessionController.text,
      note: _noteController.text,
      quantity: _quantity,
      unitPrice: unitPrice,
      totalAmount: total,
      photoPath: _photoPath,
    );
    // The page deletes the old photo only after the database write succeeds.
    // A failed save must never leave a record pointing at a deleted file.
    if (!mounted) return;
    Navigator.of(context).pop(purchase.copyWith(createdAt: initial?.createdAt));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      title: Text(_isEditing ? '编辑周边' : '记一笔周边'),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '种类',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                if (_kindsLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(minHeight: 2),
                  )
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final kind in _kinds)
                        FilterChip(
                          label: Text(kind.name),
                          labelStyle: theme.textTheme.bodySmall,
                          selected: _kind == kind.name,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => _selectKind(kind.name),
                        ),
                      ActionChip(
                        avatar: const Icon(Icons.add_rounded, size: 16),
                        label: const Text('自定义'),
                        labelStyle: theme.textTheme.bodySmall,
                        visualDensity: VisualDensity.compact,
                        onPressed: _addCustomKind,
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: _dateController,
                  readOnly: true,
                  onTap: _pickDate,
                  decoration: const InputDecoration(
                    labelText: '日期',
                    prefixIcon: Icon(Icons.event_outlined, size: 18),
                  ),
                ),
                const SizedBox(height: 10),
                NoAutofillTextField(
                  controller: _sessionController,
                  decoration: const InputDecoration(
                    labelText: '场次（可选）',
                    hintText: '第一部 / 特典会',
                  ),
                ),
                const SizedBox(height: 10),
                NoAutofillTextField(
                  controller: _memberController,
                  decoration: InputDecoration(
                    labelText: '成员（可选）',
                    hintText: '手动填写，或从卡片里选',
                    suffixIcon: IconButton(
                      tooltip: '选择成员',
                      onPressed: _pickMember,
                      icon: const Icon(Icons.person_search_outlined),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                NoAutofillTextField(
                  controller: _groupController,
                  decoration: const InputDecoration(
                    labelText: '团体（可选）',
                    hintText: '团体名',
                  ),
                ),
                const SizedBox(height: 10),
                NoAutofillTextField(
                  controller: _eventController,
                  decoration: const InputDecoration(
                    labelText: '场次 / 演出（可选）',
                    hintText: '哪一场买的',
                  ),
                ),
                const SizedBox(height: 10),
                NoAutofillTextField(
                  controller: _venueController,
                  decoration: const InputDecoration(
                    labelText: '场馆（可选）',
                    hintText: '地点',
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      '数量',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '减少',
                      onPressed: () => _changeQuantity(-1),
                      icon: const Icon(Icons.remove_circle_outline),
                      visualDensity: VisualDensity.compact,
                    ),
                    Text(
                      '$_quantity',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    IconButton(
                      tooltip: '增加',
                      onPressed: () => _changeQuantity(1),
                      icon: const Icon(Icons.add_circle_outline),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: NoAutofillTextField(
                        controller: _unitPriceController,
                        decoration: const InputDecoration(
                          labelText: '单价',
                          prefixText: '¥',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (_) => _syncTotalFromUnitPrice(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: NoAutofillTextField(
                        controller: _totalController,
                        decoration: const InputDecoration(
                          labelText: '总价',
                          prefixText: '¥',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (_) => _syncUnitPriceFromTotal(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                NoAutofillTextField(
                  controller: _noteController,
                  decoration: const InputDecoration(
                    labelText: '备注（可选）',
                    hintText: '颜色、尺寸、排队情况…',
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _PhotoPreview(
                      path: _photoPath,
                      onRemove: _removePhoto,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _pickPhoto,
                            icon: const Icon(Icons.add_photo_alternate_outlined,
                                size: 18),
                            label: Text(
                              _photoPath.isEmpty ? '加一张照片（可选）' : '换一张照片',
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '照片只存在本机，完整备份会一起带走。',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : _cancel,
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('保存'),
        ),
      ],
    );
  }

  static String _formatDate(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }

  static String _formatEditableNumber(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(2);
  }
}

class _PhotoPreview extends StatelessWidget {
  final String path;
  final VoidCallback onRemove;

  const _PhotoPreview({required this.path, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (path.trim().isEmpty) {
      return Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          Icons.photo_outlined,
          color: scheme.onSurfaceVariant,
          size: 26,
        ),
      );
    }
    final file = File(path);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: file.existsSync()
              ? Image.file(
                  file,
                  width: 84,
                  height: 84,
                  fit: BoxFit.cover,
                )
              : Container(
                  width: 84,
                  height: 84,
                  color: scheme.surfaceContainerHighest,
                  alignment: Alignment.center,
                  child: const Icon(Icons.broken_image_outlined),
                ),
        ),
        Positioned(
          top: -8,
          right: -8,
          child: IconButton(
            tooltip: '移除照片',
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
            icon: CircleAvatar(
              radius: 11,
              backgroundColor: scheme.surface,
              child: Icon(
                Icons.close_rounded,
                size: 14,
                color: scheme.onSurface,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MemberPickerSheet extends StatefulWidget {
  final List<CounterModel> counters;

  const _MemberPickerSheet({required this.counters});

  @override
  State<_MemberPickerSheet> createState() => _MemberPickerSheetState();
}

class _MemberPickerSheetState extends State<_MemberPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final filtered = widget.counters.where((counter) {
      final query = _query.trim().toLowerCase();
      if (query.isEmpty) return true;
      return counter.name.toLowerCase().contains(query) ||
          counter.groupName.toLowerCase().contains(query);
    }).toList(growable: false);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _searchController,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '搜成员或团体',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: filtered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        '没有匹配的成员',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final counter = filtered[index];
                        return ListTile(
                          leading: CircleAvatar(
                            radius: 14,
                            backgroundColor: _parseColor(counter.color),
                          ),
                          title: Text(counter.name),
                          subtitle: counter.groupName.isEmpty
                              ? null
                              : Text(counter.groupName),
                          onTap: () => Navigator.of(context).pop(counter),
                        );
                      },
                    ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('不关联成员'),
            ),
          ],
        ),
      ),
    );
  }

  static Color _parseColor(String value) {
    final hex = value.replaceFirst('#', '');
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed == null) return AppTheme.sakura;
    return Color(0xFF000000 | parsed);
  }
}
