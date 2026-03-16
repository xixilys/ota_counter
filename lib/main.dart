import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'models/counter_model.dart';
import 'widgets/counter_card.dart';
import 'widgets/add_counter_dialog.dart';
import 'widgets/counter_count_sheet.dart';
import 'services/database_service.dart';
import 'services/settings_service.dart';
import 'services/export_import_service.dart';
import 'pages/image_page.dart';
import 'package:flutter/foundation.dart';
import 'pages/chart_page.dart';

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
  final List<CounterModel> _counters = [];
  double _gridSize = 2;
  bool _sortAscending = true;
  String _sortType = SettingsService.sortByCount;  // 添加排序类型
  bool _isLocked = false;

  @override
  void initState() {
    super.initState();
    _loadCounters();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final size = await SettingsService.getGridSize();
    final sortDirection = await SettingsService.getSortDirection();
    final sortType = await SettingsService.getSortType();
    final isLocked = await SettingsService.getLockState();  // 加载锁定状态
    setState(() {
      _gridSize = size;
      _sortAscending = sortDirection;
      _sortType = sortType;
      _isLocked = isLocked;  // 设置锁定状态
    });
  }

  Future<void> _loadCounters() async {
    try {
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

  int get _total => _counters.fold<int>(0, (sum, counter) => sum + counter.count);

  Map<CounterCountField, int> get _typeTotals {
    return {
      for (final field in CounterCountField.values)
        field: _counters.fold<int>(
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
      SettingsService.saveLockState(_isLocked);  // 保存锁定状态
    });
  }

  Future<void> _saveCounterAt(int index, CounterModel updatedCounter) async {
    setState(() {
      _counters[index] = updatedCounter;
      _applySort(_counters);
    });

    if (updatedCounter.id != null) {
      await DatabaseService.updateCounter(updatedCounter.id!, updatedCounter);
    }
  }

  void _openCounterSheet(int index) {
    if (_isLocked) return;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => CounterCountSheet(
        counter: _counters[index],
        onCounterChanged: (updatedCounter) async {
          await _saveCounterAt(index, updatedCounter);
        },
      ),
    );
  }

  Future<void> _addCounter() async {
    try {
      final result = await showDialog<CounterModel>(
        context: context,
        builder: (context) => const AddCounterDialog(),
      );
      
      if (result != null) {
        await DatabaseService.insertCounter(result);
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

  Future<void> _editCounter(int index) async {
    final counter = _counters[index];
    final result = await showDialog<CounterModel>(
      context: context,
      builder: (context) => AddCounterDialog(initialData: counter),
    );
    
    if (result != null && counter.id != null) {
      await DatabaseService.updateCounter(counter.id!, result);
      await _loadCounters();
    }
  }

  void _deleteCounter(int index) {
    final counter = _counters[index];
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
                  min: 1,     // 从 2 改为 1
                  max: 5,     // 从 10 改为 5
                  divisions: 4,  // 从 8 改为 4
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

  void _showPieChart() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChartPage(
          counters: _counters,
          total: _total,
        ),
      ),
    );
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
      final result = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认导入'),
          content: const Text('导入将清空当前所有数据，确定继续吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确定'),
            ),
          ],
        ),
      );

      if (result != true) return;

      final counters = await ExportImportService.importData();
      if (counters.isEmpty) return;

      // 清空当前数据
      final db = await DatabaseService.database;
      await db.delete(DatabaseService.tableName);

      // 导入新数据
      for (final counter in counters) {
        await DatabaseService.insertCounter(counter);
      }

      await _loadCounters();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('数据导入成功')),
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

  // 修改宽高比计算方法
  double _calculateAspectRatio(double gridSize) {
    final ratio = switch (gridSize.toInt()) {
      1 => 0.92,
      2 => 0.72,
      3 => 0.64,
      4 => 0.58,
      5 => 0.54,
      _ => 0.72,
    };
    
    return ratio;
  }

  Widget _buildOverviewCard(BuildContext context) {
    final typeTotals = _typeTotals;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Theme.of(context).colorScheme.primary.withAlpha(36),
            Theme.of(context).colorScheme.secondary.withAlpha(26),
          ],
        ),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withAlpha(26),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '切奇总览',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '已配置 ${_counters.length} 个成员 / 项目',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.color
                                ?.withValues(alpha: 0.7),
                          ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '$_total',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  Text(
                    '总张数',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: CounterCountField.values.map((field) {
              return _OverviewChip(
                label: field.label,
                value: typeTotals[field] ?? 0,
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary.withAlpha(204),
        title: Text('总计 $_total'),
        actions: [
          IconButton(
            icon: Icon(_sortAscending ? Icons.arrow_upward : Icons.arrow_downward),
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
                case 'chart':
                  _showPieChart();
                  break;
                case 'image':
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const ImagePage()),
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
              const PopupMenuItem(
                value: 'chart',
                child: Row(
                  children: [
                    Icon(Icons.pie_chart),
                    SizedBox(width: 8),
                    Text('饼图统计'),
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
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              sliver: SliverToBoxAdapter(
                child: _buildOverviewCard(context),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverGrid(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final counter = _counters[index];
                    return RepaintBoundary(
                      child: CounterCard(
                        key: ValueKey(counter.id),
                        counter: counter,
                        percentage: _getPercentage(counter.count),
                        onTap: () => _openCounterSheet(index),
                        onEdit: () => _editCounter(index),
                        onDelete: () => _deleteCounter(index),
                        isLocked: _isLocked,  // 传递锁定状态
                      ),
                    );
                  },
                  childCount: _counters.length,
                ),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _gridSize.toInt(),
                  childAspectRatio: _calculateAspectRatio(_gridSize),
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 16,
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            onPressed: _toggleLock,
            heroTag: 'lock',  // 添加 heroTag 避免冲突
            child: Icon(_isLocked ? Icons.lock : Icons.lock_open),
          ),
          const SizedBox(height: 16),  // 按钮之间的间距
          FloatingActionButton(
            onPressed: _addCounter,
            heroTag: 'add',  // 添加 heroTag 避免冲突
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withAlpha(200),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 2),
          Text(
            '$value',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
        ],
      ),
    );
  }
}
