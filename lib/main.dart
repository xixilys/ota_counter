import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'models/activity_record_model.dart';
import 'models/counter_model.dart';
import 'pages/chart_page.dart';
import 'pages/idol_database_page.dart';
import 'pages/image_page.dart';
import 'services/database_service.dart';
import 'services/export_import_service.dart';
import 'services/idol_database_service.dart';
import 'services/ota_admin_import_service.dart';
import 'services/settings_service.dart';
import 'widgets/add_counter_dialog.dart';
import 'widgets/counter_card.dart';
import 'widgets/counter_count_sheet.dart';

void main() async {
  // 确保 Flutter 绑定初始化
  WidgetsFlutterBinding.ensureInitialized();

  // 仅在非 Android 平台初始化 FFI
  if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '计数器',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  static const double _overviewCardHorizontalPadding = 10;
  static const double _overviewCardVerticalPadding = 10;
  static const double _overviewCardHeaderHeight = 44;
  static const double _overviewCardBorderExtent = 2;
  static const double _overviewCardSectionGap = 8;
  static const double _overviewChipSpacing = 6;
  static const double _overviewChipHeight = 40;
  static const double _topHeaderGap = 10;

  final List<CounterModel> _counters = [];
  double _gridSize = 2;
  bool _sortAscending = true;
  String _sortType = SettingsService.sortByCount; // 添加排序类型
  bool _isLocked = false;
  bool _showHiddenCounters = false;

  @override
  void initState() {
    super.initState();
    _loadCounters();
    _loadSettings();
    _initializeIdolDatabase();
  }

  Future<void> _initializeIdolDatabase() async {
    await IdolDatabaseService.initializeBuiltInDataIfNeeded();
  }

  Future<void> _loadSettings() async {
    final size = await SettingsService.getGridSize();
    final sortDirection = await SettingsService.getSortDirection();
    final sortType = await SettingsService.getSortType();
    final isLocked = await SettingsService.getLockState(); // 加载锁定状态
    final showHiddenCounters = await SettingsService.getShowHiddenCounters();
    setState(() {
      _gridSize = size;
      _sortAscending = sortDirection;
      _sortType = sortType;
      _isLocked = isLocked; // 设置锁定状态
      _showHiddenCounters = showHiddenCounters;
    });
  }

  Future<void> _loadCounters() async {
    try {
      await DatabaseService.syncActivityRecordsToCounters('ota_site');
      await DatabaseService.autoAssignCounterThemeColors();
      final counters = await DatabaseService.getCounters();
      setState(() {
        _counters.clear();
        _counters.addAll(counters);
        _applySort(_counters);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败: ${e.toString()}')),
        );
      }
    }
  }

  List<CounterModel> get _homeCounters => _showHiddenCounters
      ? List.unmodifiable(_counters)
      : List.unmodifiable(_counters.where((counter) => !counter.isHidden));

  int get _total =>
      _homeCounters.fold<int>(0, (sum, counter) => sum + counter.count);

  Map<CounterCountField, int> get _typeTotals {
    return {
      for (final field in CounterCountField.values)
        field: _homeCounters.fold<int>(
          0,
          (sum, counter) => sum + counter.countForField(field),
        ),
    };
  }

  double _getPercentage(int count) {
    return _total == 0 ? 0 : count / _total;
  }

  void _toggleLock() {
    setState(() {
      _isLocked = !_isLocked;
      SettingsService.saveLockState(_isLocked); // 保存锁定状态
    });
  }

  Map<CounterCountField, int> _buildCounterDeltas(
    CounterModel before,
    CounterModel after,
  ) {
    return {
      for (final field in CounterCountField.values)
        field: after.countForField(field) - before.countForField(field),
    };
  }

  Future<void> _recordCounterChange({
    required CounterModel counter,
    required Map<CounterCountField, int> deltas,
    required DateTime occurredAt,
    required String note,
  }) async {
    if (deltas.values.every((value) => value == 0)) {
      return;
    }

    final pricing = await DatabaseService.getGroupPricingByName(
      counter.groupName,
    );

    await DatabaseService.insertActivityRecord(
      ActivityRecordModel.counterAdjustment(
        counter: counter,
        occurredAt: occurredAt,
        deltas: deltas,
        pricing: pricing,
        note: note,
      ),
    );
  }

  Future<void> _saveCounter(
    CounterModel updatedCounter, {
    required DateTime occurredAt,
    String note = '快捷计数',
  }) async {
    final index =
        _counters.indexWhere((counter) => counter.id == updatedCounter.id);
    if (index == -1) {
      return;
    }

    final previousCounter = _counters[index];
    final deltas = _buildCounterDeltas(previousCounter, updatedCounter);

    setState(() {
      _counters[index] = updatedCounter;
      _applySort(_counters);
    });

    if (updatedCounter.id != null) {
      await DatabaseService.updateCounter(updatedCounter.id!, updatedCounter);
      await _recordCounterChange(
        counter: updatedCounter,
        deltas: deltas,
        occurredAt: occurredAt,
        note: note,
      );
    }
  }

  void _openCounterSheet(CounterModel counter) {
    if (_isLocked) return;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => CounterCountSheet(
        counter: counter,
        onCounterChanged: (updatedCounter, occurredAt) async {
          await _saveCounter(
            updatedCounter,
            occurredAt: occurredAt,
          );
        },
      ),
    );
  }

  Future<void> _addCounter() async {
    try {
      final result = await showDialog<CounterDialogResult>(
        context: context,
        builder: (context) => const AddCounterDialog(),
      );

      if (result != null) {
        final counterId = await DatabaseService.insertCounter(result.counter);
        final insertedCounter = result.counter.copyWith(id: counterId);
        final deltas = {
          for (final field in CounterCountField.values)
            field: insertedCounter.countForField(field),
        };
        await _recordCounterChange(
          counter: insertedCounter,
          deltas: deltas,
          occurredAt: result.occurredAt,
          note: '初始化录入',
        );
        await _loadCounters();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('添加失败: ${e.toString()}')),
        );
      }
    }
  }

  Future<void> _editCounter(CounterModel counter) async {
    final result = await showDialog<CounterDialogResult>(
      context: context,
      builder: (context) => AddCounterDialog(initialData: counter),
    );

    if (result != null && counter.id != null) {
      final deltas = _buildCounterDeltas(counter, result.counter);
      await DatabaseService.updateCounter(counter.id!, result.counter);
      await _recordCounterChange(
        counter: result.counter,
        deltas: deltas,
        occurredAt: result.occurredAt,
        note: '编辑调整',
      );
      await _loadCounters();
    }
  }

  void _deleteCounter(CounterModel counter) {
    showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('确定要删除这个计数器吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    ).then((confirmed) async {
      if (confirmed ?? false) {
        if (counter.id != null) {
          await DatabaseService.deleteCounter(counter.id!);
          await _loadCounters();
        }
      }
    });
  }

  Future<void> _toggleCounterHidden(CounterModel counter) async {
    if (counter.id == null) {
      return;
    }

    final updatedCounter = counter.copyWith(isHidden: !counter.isHidden);
    await DatabaseService.updateCounter(counter.id!, updatedCounter);

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(updatedCounter.isHidden
            ? '已隐藏 ${counter.name}'
            : '已恢复 ${counter.name}'),
        duration: const Duration(seconds: 2),
      ),
    );
    await _loadCounters();
  }

  Future<void> _showCounterActions(CounterModel counter) async {
    if (_isLocked || !mounted) {
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
              leading: Icon(
                counter.isHidden
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_rounded,
              ),
              title: Text(counter.isHidden ? '取消隐藏卡片' : '隐藏这张卡片'),
              subtitle: Text(counter.name),
              onTap: () async {
                Navigator.of(context).pop();
                await _toggleCounterHidden(counter);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showGridSizeDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      useSafeArea: true,
      useRootNavigator: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => TweenAnimationBuilder(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          tween: Tween<double>(begin: 0.8, end: 1.0),
          builder: (context, value, child) => Transform.scale(
            scale: value,
            child: child,
          ),
          child: AlertDialog(
            title: const Text('调整网格大小'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Slider(
                  value: _gridSize,
                  min: 1, // 从 2 改为 1
                  max: 5, // 从 10 改为 5
                  divisions: 4, // 从 8 改为 4
                  label: _gridSize.round().toString(),
                  onChanged: (value) {
                    setDialogState(() {
                      setState(() {
                        _gridSize = value.roundToDouble();
                        SettingsService.saveGridSize(_gridSize);
                      });
                    });
                  },
                ),
                Text('每行显示 ${_gridSize.round()} 个'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                },
                child: const Text('确定'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleShowHiddenCounters() {
    setState(() {
      _showHiddenCounters = !_showHiddenCounters;
    });
    SettingsService.saveShowHiddenCounters(_showHiddenCounters);
  }

  void _applySort(List<CounterModel> counters) {
    switch (_sortType) {
      case SettingsService.sortByCount:
        counters.sort((a, b) => _sortAscending
            ? a.count.compareTo(b.count)
            : b.count.compareTo(a.count));
      case SettingsService.sortByName:
        counters.sort((a, b) => _sortAscending
            ? a.namePinyin.compareTo(b.namePinyin)
            : b.namePinyin.compareTo(a.namePinyin));
      case SettingsService.sortByColor:
        counters.sort((a, b) {
          final aHsv = a.hsvColor;
          final bHsv = b.hsvColor;
          final hueCompare = aHsv.hue.compareTo(bHsv.hue);
          if (hueCompare != 0) return _sortAscending ? hueCompare : -hueCompare;

          final satCompare = aHsv.saturation.compareTo(bHsv.saturation);
          if (satCompare != 0) return _sortAscending ? satCompare : -satCompare;

          return _sortAscending
              ? aHsv.value.compareTo(bHsv.value)
              : bHsv.value.compareTo(aHsv.value);
        });
      default:
        counters.sort((a, b) => _sortAscending
            ? a.count.compareTo(b.count)
            : b.count.compareTo(a.count));
    }
  }

  void _sortCounters() {
    setState(() {
      _applySort(_counters);
    });
  }

  void _toggleSortDirection() {
    setState(() {
      _sortAscending = !_sortAscending;
      SettingsService.saveSortDirection(_sortAscending);
      _sortCounters();
    });
  }

  void _changeSortType(String type) {
    setState(() {
      _sortType = type;
      SettingsService.saveSortType(type);
      _sortCounters();
    });
  }

  Future<void> _showPieChart() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const ChartPage(),
      ),
    );
    await _loadCounters();
  }

  Future<void> _openAddRecordEntry() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const ChartPage(openComposerOnStart: true),
      ),
    );
    await _loadCounters();
  }

  Future<void> _exportData() async {
    try {
      await ExportImportService.exportData(_counters);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: ${e.toString()}')),
        );
      }
    }
  }

  Future<void> _importData() async {
    try {
      final payload = await ExportImportService.pickImportPayload();
      if (payload == null || !mounted) {
        return;
      }

      if (payload.isLegacyCounters) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('导入旧版备份'),
            content: Text(
              '检测到 ${payload.fileName} 是旧版计数器备份。\n'
              '继续后会清空当前计数器、价格和流水数据，再导入备份内容。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('继续导入'),
              ),
            ],
          ),
        );

        if (confirmed != true || !mounted) {
          return;
        }

        await DatabaseService.clearAppData();
        for (final counter in payload.counters) {
          await DatabaseService.insertCounter(counter);
        }

        await _loadCounters();
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已导入旧版计数器备份，共 ${payload.counters.length} 项'),
          ),
        );
        return;
      }

      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在导入 OTA 历史文件...'),
                ],
              ),
            ),
          ),
        ),
      );

      try {
        final result = await OtaAdminImportService.importBundleJson(
          payload.rawJson,
        );
        if (!mounted) {
          return;
        }
        Navigator.of(context, rootNavigator: true).pop();
        await _loadCounters();
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${payload.fileName} 导入完成，'
              '新增 ${result.importedCount} 条历史记录，'
              '跳过 ${result.skippedCount} 条重复记录，'
              '同步 ${result.pricingCount} 个团体价格，'
              '补充 ${result.syncedMemberCount} 名成员',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      } catch (error) {
        if (!mounted) {
          return;
        }
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('导入失败: $error'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: ${e.toString()}')),
        );
      }
    }
  }

  double _calculateCardHeight({
    required int gridColumns,
    required double availableWidth,
    required double crossAxisSpacing,
  }) {
    final itemWidth = math.max(
      0.0,
      (availableWidth - ((gridColumns - 1) * crossAxisSpacing)) / gridColumns,
    );

    return switch (gridColumns) {
      1 => math.max(248.0, itemWidth * 0.72),
      2 => math.max(228.0, itemWidth * 1.08),
      3 => math.max(140.0, itemWidth + 14.0),
      4 => math.max(108.0, itemWidth + 18.0),
      5 => math.max(94.0, itemWidth + 24.0),
      _ => math.max(228.0, itemWidth * 1.08),
    };
  }

  double _calculateOverviewCardHeight(double width) {
    final rows = width >= 560 ? 1 : 2;
    return (_overviewCardVerticalPadding * 2) +
        _overviewCardBorderExtent +
        _overviewCardHeaderHeight +
        _overviewCardSectionGap +
        (rows * _overviewChipHeight) +
        ((rows - 1) * _overviewChipSpacing);
  }

  Widget _buildOverviewChipRow({
    required List<CounterCountField> fields,
    required Map<CounterCountField, int> totals,
  }) {
    return Row(
      children: [
        for (var index = 0; index < fields.length; index++) ...[
          if (index > 0) const SizedBox(width: _overviewChipSpacing),
          Expanded(
            child: _OverviewChip(
              label: fields[index].shortLabel,
              value: totals[fields[index]] ?? 0,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildOverviewCard(BuildContext context) {
    final typeTotals = _typeTotals;
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final useWideSingleRow = width >= 560;

        return Container(
          padding: const EdgeInsets.fromLTRB(
            _overviewCardHorizontalPadding,
            _overviewCardVerticalPadding,
            _overviewCardHorizontalPadding,
            _overviewCardVerticalPadding,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                theme.colorScheme.primary.withAlpha(28),
                theme.colorScheme.secondary.withAlpha(20),
              ],
            ),
            border: Border.all(
              color: theme.colorScheme.primary.withAlpha(20),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: _overviewCardHeaderHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '切奇总览',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            '${_counters.length} 个成员 / 项目',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 10,
                              color:
                                  theme.textTheme.bodyMedium?.color?.withValues(
                                alpha: 0.72,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          color: theme.colorScheme.surface.withAlpha(180),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '$_total',
                              textAlign: TextAlign.right,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                                height: 1,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              '总数',
                              textAlign: TextAlign.right,
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: _overviewCardSectionGap),
              if (useWideSingleRow)
                _buildOverviewChipRow(
                  fields: CounterCountField.values,
                  totals: typeTotals,
                )
              else
                Column(
                  children: [
                    _buildOverviewChipRow(
                      fields: const [
                        CounterCountField.threeInch,
                        CounterCountField.fiveInch,
                      ],
                      totals: typeTotals,
                    ),
                    const SizedBox(height: _overviewChipSpacing),
                    _buildOverviewChipRow(
                      fields: const [
                        CounterCountField.threeInchShukudai,
                        CounterCountField.fiveInchShukudai,
                        CounterCountField.groupCut,
                      ],
                      totals: typeTotals,
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTopHeaderRow(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final actionWidth = width >= 390
            ? 86.0
            : width >= 340
                ? 76.0
                : 70.0;
        final minimumOverviewWidth = width >= 360 ? 200.0 : 186.0;
        final useSideAction =
            width >= (actionWidth + _topHeaderGap + minimumOverviewWidth);

        if (!useSideAction) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildOverviewCard(context),
              const SizedBox(height: _topHeaderGap),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _openAddRecordEntry,
                  icon: const Icon(Icons.edit_note_rounded),
                  label: const Text('新增记录'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        final overviewWidth =
            math.max(0.0, width - actionWidth - _topHeaderGap);
        final headerHeight = _calculateOverviewCardHeight(overviewWidth);

        return SizedBox(
          height: headerHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _buildOverviewCard(context),
              ),
              const SizedBox(width: _topHeaderGap),
              SizedBox(
                width: actionWidth,
                child: FilledButton(
                  onPressed: _openAddRecordEntry,
                  style: FilledButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.edit_note_rounded, size: 24),
                      const SizedBox(height: 6),
                      Text(
                        '新增\n记录',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor:
            Theme.of(context).colorScheme.inversePrimary.withAlpha(204),
        title: Text('总计 $_total'),
        actions: [
          IconButton(
            onPressed: _showPieChart,
            tooltip: '统计与流水',
            icon: const Icon(Icons.insights_outlined),
          ),
          IconButton(
            icon: Icon(
                _sortAscending ? Icons.arrow_upward : Icons.arrow_downward),
            onPressed: _toggleSortDirection,
            tooltip: _sortAscending ? '升序' : '降序',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort),
            tooltip: '排序方式',
            onSelected: _changeSortType,
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: SettingsService.sortByCount,
                child: Row(
                  children: [
                    Icon(Icons.format_list_numbered),
                    SizedBox(width: 8),
                    Text('按数量排序'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: SettingsService.sortByName,
                child: Row(
                  children: [
                    Icon(Icons.sort_by_alpha),
                    SizedBox(width: 8),
                    Text('按名称排序'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: SettingsService.sortByColor,
                child: Row(
                  children: [
                    Icon(Icons.palette),
                    SizedBox(width: 8),
                    Text('按颜色排序'),
                  ],
                ),
              ),
            ],
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'export':
                  _exportData();
                  break;
                case 'import':
                  _importData();
                  break;
                case 'grid':
                  _showGridSizeDialog();
                  break;
                case 'toggleHidden':
                  _toggleShowHiddenCounters();
                  break;
                case 'image':
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const ImagePage()),
                  );
                  break;
                case 'idolDb':
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const IdolDatabasePage(),
                    ),
                  );
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'export',
                child: Row(
                  children: [
                    Icon(Icons.upload),
                    SizedBox(width: 8),
                    Text('导出数据'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'import',
                child: Row(
                  children: [
                    Icon(Icons.download),
                    SizedBox(width: 8),
                    Text('导入数据'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'grid',
                child: Row(
                  children: [
                    Icon(Icons.grid_4x4),
                    SizedBox(width: 8),
                    Text('网格大小'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'toggleHidden',
                child: Row(
                  children: [
                    Icon(
                      _showHiddenCounters
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                    ),
                    const SizedBox(width: 8),
                    Text(_showHiddenCounters ? '隐藏已隐藏项' : '显示已隐藏项'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'image',
                child: Row(
                  children: [
                    Icon(Icons.image),
                    SizedBox(width: 8),
                    Text('抽取图片'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'idolDb',
                child: Row(
                  children: [
                    Icon(Icons.groups_2),
                    SizedBox(width: 8),
                    Text('偶像数据库'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.blue.withAlpha(26),
              Colors.purple.withAlpha(26),
            ],
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final homeCounters = _homeCounters;
            final gridColumns = _gridSize.toInt();
            final crossAxisSpacing = gridColumns >= 4 ? 10.0 : 12.0;
            final mainAxisSpacing = gridColumns >= 3 ? 12.0 : 16.0;
            final cardHeight = _calculateCardHeight(
              gridColumns: gridColumns,
              availableWidth: math.max(0.0, constraints.maxWidth - 32.0),
              crossAxisSpacing: crossAxisSpacing,
            );

            return CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: _buildTopHeaderRow(context),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  sliver: SliverGrid(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final counter = homeCounters[index];
                        return RepaintBoundary(
                          child: CounterCard(
                            key: ValueKey(counter.id),
                            counter: counter,
                            percentage: _getPercentage(counter.count),
                            onTap: () => _openCounterSheet(counter),
                            onLongPress: () => _showCounterActions(counter),
                            onEdit: () => _editCounter(counter),
                            onDelete: () => _deleteCounter(counter),
                            isLocked: _isLocked,
                            gridColumns: gridColumns,
                          ),
                        );
                      },
                      childCount: homeCounters.length,
                    ),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: gridColumns,
                      mainAxisExtent: cardHeight,
                      crossAxisSpacing: crossAxisSpacing,
                      mainAxisSpacing: mainAxisSpacing,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            onPressed: _toggleLock,
            heroTag: 'lock',
            child: Icon(_isLocked ? Icons.lock : Icons.lock_open),
          ),
          const SizedBox(height: 16),
          FloatingActionButton(
            onPressed: _addCounter,
            heroTag: 'add',
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

class _OverviewChip extends StatelessWidget {
  final String label;
  final int value;

  const _OverviewChip({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withAlpha(192),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontSize: 11,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$value',
            textAlign: TextAlign.right,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}
