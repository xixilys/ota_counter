import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_metadata.dart';
import 'models/activity_record_model.dart';
import 'models/counter_model.dart';
import 'pages/chart_page.dart';
import 'pages/group_pricing_page.dart';
import 'pages/idol_database_page.dart';
import 'pages/image_page.dart';
import 'pages/member_detail_page.dart';
import 'pages/recent_records_page.dart';
import 'services/database_service.dart';
import 'services/export_import_service.dart';
import 'services/idol_database_service.dart';
import 'services/ota_admin_import_service.dart';
import 'services/settings_service.dart';
import 'services/update_service.dart';
import 'widgets/add_counter_dialog.dart';
import 'widgets/counter_card.dart';

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
    final lightScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF2F6FED),
      brightness: Brightness.light,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6AA7FF),
      brightness: Brightness.dark,
    );

    return MaterialApp(
      title: kAppDisplayName,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: lightScheme,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: darkScheme,
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

class _HomeCounterEntry {
  final String key;
  final CounterModel displayCounter;
  final CounterModel primaryCounter;
  final List<CounterModel> sourceCounters;
  final Map<String, int> customCounts;
  final int totalCount;
  final List<CounterCountBadgeData> breakdownEntries;

  const _HomeCounterEntry({
    required this.key,
    required this.displayCounter,
    required this.primaryCounter,
    required this.sourceCounters,
    this.customCounts = const <String, int>{},
    required this.totalCount,
    this.breakdownEntries = const <CounterCountBadgeData>[],
  });
}

class _MyHomePageState extends State<MyHomePage> {
  static const double _overviewCardHorizontalPadding = 10;
  static const double _overviewCardVerticalPadding = 10;
  static const double _overviewChipSpacing = 6;

  final List<CounterModel> _counters = [];
  final List<ActivityRecordModel> _activityRecords = [];
  double _gridSize = 2;
  bool _sortAscending = true;
  String _sortType = SettingsService.sortByCount; // 添加排序类型
  bool _isLocked = false;
  bool _showHiddenCounters = false;
  Set<String> _selectedOverviewMetricIds = <String>{};
  List<String> _overviewMetricOrder = const <String>[];
  int _overviewMetricColumns = SettingsService.defaultOverviewMetricColumns;
  String _appVersionLabel = '读取中';
  String _appBuildLabel = '';
  int _appVersionCode = 0;
  bool _autoUpdateCheckScheduled = false;

  @override
  void initState() {
    super.initState();
    _loadCounters();
    _loadSettings();
    _loadPackageInfo();
    _initializeIdolDatabase();
  }

  Future<void> _initializeIdolDatabase() async {
    await IdolDatabaseService.initializeBuiltInDataIfNeeded();
  }

  Future<void> _loadPackageInfo() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final version = packageInfo.version.trim();
      final buildNumber = packageInfo.buildNumber.trim();
      if (!mounted) {
        return;
      }
      setState(() {
        _appVersionLabel = version.isEmpty ? '未知版本' : 'v$version';
        _appBuildLabel =
            buildNumber.isEmpty ? '' : 'Build ${packageInfo.buildNumber}';
        _appVersionCode = int.tryParse(buildNumber) ?? 0;
      });
      _scheduleAutoUpdateCheck();
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _appVersionLabel = '未知版本';
        _appBuildLabel = '';
        _appVersionCode = 0;
      });
    }
  }

  void _scheduleAutoUpdateCheck() {
    if (_autoUpdateCheckScheduled || _appVersionCode <= 0) {
      return;
    }
    _autoUpdateCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForUpdates(manual: false);
    });
  }

  Future<void> _loadSettings() async {
    final size = await SettingsService.getGridSize();
    final sortDirection = await SettingsService.getSortDirection();
    final sortType = await SettingsService.getSortType();
    final isLocked = await SettingsService.getLockState(); // 加载锁定状态
    final showHiddenCounters = await SettingsService.getShowHiddenCounters();
    final overviewMetricIds = await SettingsService.getOverviewMetricIds();
    final overviewMetricOrder = await SettingsService.getOverviewMetricOrder();
    final overviewMetricColumns =
        await SettingsService.getOverviewMetricColumns();
    setState(() {
      _gridSize = size;
      _sortAscending = sortDirection;
      _sortType = sortType;
      _isLocked = isLocked; // 设置锁定状态
      _showHiddenCounters = showHiddenCounters;
      _selectedOverviewMetricIds = overviewMetricIds.toSet();
      _overviewMetricOrder = overviewMetricOrder;
      _overviewMetricColumns = overviewMetricColumns;
    });
  }

  Future<void> _loadCounters() async {
    try {
      await DatabaseService.syncActivityRecordsToCounters('ota_site');
      await DatabaseService.autoAssignCounterThemeColors();
      final counters = await DatabaseService.getCounters();
      final activityRecords = await DatabaseService.getActivityRecords();
      setState(() {
        _counters.clear();
        _counters.addAll(counters);
        _activityRecords
          ..clear()
          ..addAll(activityRecords);
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

  String _normalizedLookupPart(String value) {
    final trimmed = value.trim().toLowerCase();
    if (trimmed.isEmpty) {
      return '';
    }
    return trimmed.replaceAll(
      RegExp(r'[\s·•・_\-~/\\\(\)\[\]\{\}]+'),
      '',
    );
  }

  List<CounterModel> get _scopedCounters {
    return _showHiddenCounters
        ? List<CounterModel>.from(_counters)
        : _counters.where((counter) => !counter.isHidden).toList();
  }

  bool _participantMatchesCounter(
    ActivityParticipant participant,
    CounterModel counter,
  ) {
    final participantGroup = _normalizedLookupPart(participant.groupName);
    final counterGroup = _normalizedLookupPart(counter.groupName);
    if (participantGroup.isNotEmpty &&
        counterGroup.isNotEmpty &&
        participantGroup != counterGroup) {
      return false;
    }

    if (participant.personId != null && counter.personId != null) {
      return participant.personId == counter.personId;
    }

    final participantPersonName = _normalizedLookupPart(participant.personName);
    final counterPersonName = _normalizedLookupPart(counter.personName);
    if (participantPersonName.isNotEmpty && counterPersonName.isNotEmpty) {
      return participantPersonName == counterPersonName;
    }

    return _normalizedLookupPart(participant.memberName) ==
        _normalizedLookupPart(counter.name);
  }

  int _visibleParticipantCountForMultiRecord(ActivityRecordModel record) {
    final scopedCounters = _scopedCounters;
    if (scopedCounters.isEmpty) {
      return 0;
    }

    return record.effectiveParticipants.where((participant) {
      return scopedCounters.any(
        (counter) => _participantMatchesCounter(participant, counter),
      );
    }).length;
  }

  String _homeEntryKey(CounterModel counter) {
    final personName = counter.personName.trim();
    if (personName.isNotEmpty) {
      return 'person-name:${personName.toLowerCase()}';
    }

    if (counter.personId != null) {
      return 'person-id:${counter.personId}';
    }

    return 'counter:${counter.groupName.trim().toLowerCase()}|${counter.name.trim().toLowerCase()}';
  }

  CounterModel _selectPrimaryCounter(List<CounterModel> counters) {
    final sorted = [...counters]..sort((a, b) {
        final countCompare = b.count.compareTo(a.count);
        if (countCompare != 0) {
          return countCompare;
        }

        final groupCompare = a.groupName.toLowerCase().compareTo(
              b.groupName.toLowerCase(),
            );
        if (groupCompare != 0) {
          return groupCompare;
        }

        return a.namePinyin.compareTo(b.namePinyin);
      });
    return sorted.first;
  }

  String _buildHomeGroupLabel(List<CounterModel> counters) {
    final groups = counters
        .map((counter) => counter.groupName.trim())
        .where((groupName) => groupName.isNotEmpty)
        .toSet()
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    if (groups.isEmpty) {
      return '';
    }
    if (groups.length <= 2) {
      return groups.join(' / ');
    }
    return '${groups.take(2).join(' / ')} 等${groups.length}团';
  }

  String _buildHomeDisplayName(
    List<CounterModel> counters,
    CounterModel primaryCounter,
  ) {
    final names = counters
        .map((counter) => counter.name.trim())
        .where((name) => name.isNotEmpty)
        .toSet();
    if (names.length <= 1) {
      return primaryCounter.name;
    }

    final personName = primaryCounter.personName.trim();
    if (personName.isNotEmpty) {
      return personName;
    }
    return primaryCounter.name;
  }

  CounterModel _buildHomeDisplayCounter(List<CounterModel> counters) {
    final primaryCounter = _selectPrimaryCounter(counters);

    int sum(int Function(CounterModel counter) selector) {
      return counters.fold<int>(
          0, (total, counter) => total + selector(counter));
    }

    return primaryCounter.copyWith(
      name: _buildHomeDisplayName(counters, primaryCounter),
      groupName: _buildHomeGroupLabel(counters),
      isHidden: counters.every((counter) => counter.isHidden),
      threeInchCount: sum((counter) => counter.threeInchCount),
      fiveInchCount: sum((counter) => counter.fiveInchCount),
      unsignedThreeInchCount: sum((counter) => counter.unsignedThreeInchCount),
      unsignedFiveInchCount: sum((counter) => counter.unsignedFiveInchCount),
      groupCutCount: sum((counter) => counter.groupCutCount),
      threeInchShukudaiCount: sum((counter) => counter.threeInchShukudaiCount),
      fiveInchShukudaiCount: sum((counter) => counter.fiveInchShukudaiCount),
    );
  }

  bool _counterRecordMatchesCounter(
    ActivityRecordModel record,
    CounterModel counter,
  ) {
    if (!record.isCounter) {
      return false;
    }

    if (record.counterId != null && counter.id != null) {
      return record.counterId == counter.id;
    }

    if (record.personId != null && counter.personId != null) {
      return record.personId == counter.personId;
    }

    final recordPersonName = _normalizedLookupPart(record.personName);
    final counterPersonName = _normalizedLookupPart(counter.personName);
    if (recordPersonName.isNotEmpty && counterPersonName.isNotEmpty) {
      return recordPersonName == counterPersonName;
    }

    return _normalizedLookupPart(record.groupName) ==
            _normalizedLookupPart(counter.groupName) &&
        _normalizedLookupPart(record.subjectName) ==
            _normalizedLookupPart(counter.name);
  }

  Map<String, int> _buildHomeCustomTypeTotals(List<CounterModel> counters) {
    final totals = <String, int>{};
    for (final record in _activityRecords) {
      if (!record.isCounter || record.effectiveCustomChekiCounts.isEmpty) {
        continue;
      }
      final matchesCounter = counters.any(
        (counter) => _counterRecordMatchesCounter(record, counter),
      );
      if (!matchesCounter) {
        continue;
      }

      for (final item in record.effectiveCustomChekiCounts) {
        final label = item.label.trim();
        if (label.isEmpty) {
          continue;
        }
        totals[label] = (totals[label] ?? 0) + item.count;
      }
    }
    return totals;
  }

  List<CounterCountBadgeData> _buildHomeBreakdownEntries(
    CounterModel counter,
    Map<String, int> customCounts,
  ) {
    final sortedCustomEntries = customCounts.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    return [
      CounterCountBadgeData(
        label: CounterCountField.threeInch.shortLabel,
        value: counter.aggregatedThreeInchCount,
      ),
      CounterCountBadgeData(
        label: CounterCountField.fiveInch.shortLabel,
        value: counter.aggregatedFiveInchCount,
      ),
      CounterCountBadgeData(
        label: CounterCountField.threeInchShukudai.shortLabel,
        value: counter.threeInchShukudaiCount,
      ),
      CounterCountBadgeData(
        label: CounterCountField.fiveInchShukudai.shortLabel,
        value: counter.fiveInchShukudaiCount,
      ),
      ...sortedCustomEntries.map((entry) {
        return CounterCountBadgeData(
          label: entry.key,
          value: entry.value,
        );
      }),
    ];
  }

  void _applyHomeEntrySort(List<_HomeCounterEntry> entries) {
    int compareByDirection(int value) => _sortAscending ? value : -value;

    switch (_sortType) {
      case SettingsService.sortByCount:
        entries.sort((a, b) => compareByDirection(
              a.totalCount.compareTo(b.totalCount),
            ));
      case SettingsService.sortByName:
        entries.sort((a, b) => compareByDirection(
              a.displayCounter.namePinyin.compareTo(
                b.displayCounter.namePinyin,
              ),
            ));
      case SettingsService.sortByColor:
        entries.sort((a, b) {
          final aHsv = a.displayCounter.hsvColor;
          final bHsv = b.displayCounter.hsvColor;
          final hueCompare = aHsv.hue.compareTo(bHsv.hue);
          if (hueCompare != 0) {
            return compareByDirection(hueCompare);
          }

          final satCompare = aHsv.saturation.compareTo(bHsv.saturation);
          if (satCompare != 0) {
            return compareByDirection(satCompare);
          }

          return compareByDirection(aHsv.value.compareTo(bHsv.value));
        });
      default:
        entries.sort((a, b) => compareByDirection(
              a.totalCount.compareTo(b.totalCount),
            ));
    }
  }

  List<_HomeCounterEntry> get _homeEntries {
    final scopedCounters = _scopedCounters;

    final groupedCounters = <String, List<CounterModel>>{};
    for (final counter in scopedCounters) {
      groupedCounters
          .putIfAbsent(_homeEntryKey(counter), () => [])
          .add(counter);
    }

    final entries = groupedCounters.entries.map((entry) {
      final counters = entry.value;
      final primaryCounter = _selectPrimaryCounter(counters);
      final displayCounter = _buildHomeDisplayCounter(counters);
      final customCounts = _buildHomeCustomTypeTotals(counters);
      final totalCount = displayCounter.count +
          customCounts.values.fold<int>(0, (sum, value) => sum + value);
      return _HomeCounterEntry(
        key: entry.key,
        displayCounter: displayCounter,
        primaryCounter: primaryCounter,
        sourceCounters: counters,
        customCounts: customCounts,
        totalCount: totalCount,
        breakdownEntries: _buildHomeBreakdownEntries(
          displayCounter,
          customCounts,
        ),
      );
    }).toList();

    _applyHomeEntrySort(entries);
    return List.unmodifiable(entries);
  }

  int get _memberTotal =>
      _homeEntries.fold<int>(0, (sum, entry) => sum + entry.totalCount);

  Map<CounterCountField, int> get _memberTypeTotals {
    return {
      CounterCountField.threeInch: _homeEntries.fold<int>(
        0,
        (sum, entry) => sum + entry.displayCounter.aggregatedThreeInchCount,
      ),
      CounterCountField.fiveInch: _homeEntries.fold<int>(
        0,
        (sum, entry) => sum + entry.displayCounter.aggregatedFiveInchCount,
      ),
      CounterCountField.threeInchShukudai: _homeEntries.fold<int>(
        0,
        (sum, entry) => sum + entry.displayCounter.threeInchShukudaiCount,
      ),
      CounterCountField.fiveInchShukudai: _homeEntries.fold<int>(
        0,
        (sum, entry) => sum + entry.displayCounter.fiveInchShukudaiCount,
      ),
      CounterCountField.groupCut: _homeEntries.fold<int>(
        0,
        (sum, entry) => sum + entry.displayCounter.groupCutCount,
      ),
    };
  }

  Map<String, int> get _overviewCustomTypeTotals {
    final totals = <String, int>{};
    for (final entry in _homeEntries) {
      for (final customEntry in entry.customCounts.entries) {
        final label = customEntry.key.trim();
        if (label.isEmpty) {
          continue;
        }
        totals[label] = (totals[label] ?? 0) + customEntry.value;
      }
    }
    return totals;
  }

  Map<CounterCountField, int> get _overviewTypeTotals {
    final totals = Map<CounterCountField, int>.from(_memberTypeTotals);

    for (final record in _activityRecords.where((record) => record.isMulti)) {
      final visibleParticipantCount =
          _visibleParticipantCountForMultiRecord(record);
      if (visibleParticipantCount <= 1) {
        continue;
      }

      final duplicateContribution =
          record.multiTotalCount * (visibleParticipantCount - 1);
      final rawField = record.multiCountField;
      if (rawField == null) {
        continue;
      }

      final overviewField = rawField.aggregatedBaseField;
      final currentValue = totals[overviewField] ?? 0;
      totals[overviewField] = math.max(
        0,
        currentValue - duplicateContribution,
      );
    }

    return totals;
  }

  int get _overviewTotal {
    var duplicateContributionTotal = 0;
    for (final record in _activityRecords.where((record) => record.isMulti)) {
      final visibleParticipantCount =
          _visibleParticipantCountForMultiRecord(record);
      if (visibleParticipantCount <= 1) {
        continue;
      }
      duplicateContributionTotal +=
          record.multiTotalCount * (visibleParticipantCount - 1);
    }

    return math.max(0, _memberTotal - duplicateContributionTotal);
  }

  String _overviewMetricIdForField(CounterCountField field) {
    return 'builtin:${field.key}';
  }

  String _overviewMetricIdForCustomLabel(String label) {
    return 'custom:${_normalizedLookupPart(label)}';
  }

  List<_OverviewMetricData> get _allOverviewMetrics {
    final builtInTotals = _overviewTypeTotals;
    final customEntries = _overviewCustomTypeTotals.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));

    return [
      _OverviewMetricData(
        id: _overviewMetricIdForField(CounterCountField.threeInch),
        label: CounterCountField.threeInch.shortLabel,
        value: builtInTotals[CounterCountField.threeInch] ?? 0,
        isCustom: false,
      ),
      _OverviewMetricData(
        id: _overviewMetricIdForField(CounterCountField.fiveInch),
        label: CounterCountField.fiveInch.shortLabel,
        value: builtInTotals[CounterCountField.fiveInch] ?? 0,
        isCustom: false,
      ),
      _OverviewMetricData(
        id: _overviewMetricIdForField(CounterCountField.threeInchShukudai),
        label: CounterCountField.threeInchShukudai.shortLabel,
        value: builtInTotals[CounterCountField.threeInchShukudai] ?? 0,
        isCustom: false,
      ),
      _OverviewMetricData(
        id: _overviewMetricIdForField(CounterCountField.fiveInchShukudai),
        label: CounterCountField.fiveInchShukudai.shortLabel,
        value: builtInTotals[CounterCountField.fiveInchShukudai] ?? 0,
        isCustom: false,
      ),
      _OverviewMetricData(
        id: _overviewMetricIdForField(CounterCountField.groupCut),
        label: CounterCountField.groupCut.shortLabel,
        value: builtInTotals[CounterCountField.groupCut] ?? 0,
        isCustom: false,
      ),
      ...customEntries.map((entry) {
        return _OverviewMetricData(
          id: _overviewMetricIdForCustomLabel(entry.key),
          label: entry.key,
          value: entry.value,
          isCustom: true,
        );
      }),
    ];
  }

  List<_OverviewMetricData> get _orderedOverviewMetrics {
    final metrics = List<_OverviewMetricData>.from(_allOverviewMetrics);
    if (_overviewMetricOrder.isEmpty) {
      return metrics;
    }

    final orderIndex = <String, int>{
      for (var index = 0; index < _overviewMetricOrder.length; index++)
        _overviewMetricOrder[index]: index,
    };

    metrics.sort((a, b) {
      final aIndex = orderIndex[a.id];
      final bIndex = orderIndex[b.id];
      if (aIndex != null && bIndex != null) {
        return aIndex.compareTo(bIndex);
      }
      if (aIndex != null) {
        return -1;
      }
      if (bIndex != null) {
        return 1;
      }
      return 0;
    });
    return metrics;
  }

  List<_OverviewMetricData> get _visibleOverviewMetrics {
    final allMetrics = _orderedOverviewMetrics;
    if (_selectedOverviewMetricIds.isEmpty) {
      return allMetrics;
    }

    final visible = allMetrics.where((metric) {
      return _selectedOverviewMetricIds.contains(metric.id);
    }).toList();
    return visible.isEmpty ? allMetrics : visible;
  }

  double _getPercentage(int count) {
    return _memberTotal == 0 ? 0 : count / _memberTotal;
  }

  void _toggleLock() {
    setState(() {
      _isLocked = !_isLocked;
      SettingsService.saveLockState(_isLocked); // 保存锁定状态
    });
  }

  void _showAboutApp() {
    showAboutDialog(
      context: context,
      applicationName: kAppDisplayName,
      applicationVersion: _appBuildLabel.isEmpty
          ? _appVersionLabel
          : '$_appVersionLabel ($_appBuildLabel)',
      applicationLegalese: kAppDescription,
      children: [
        const SizedBox(height: 8),
        Text('开发者 ID：@$kAppAuthorId'),
      ],
    );
  }

  Future<void> _checkForUpdates({required bool manual}) async {
    if (_appVersionCode <= 0) {
      if (manual && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('版本信息还没准备好，请稍后再试')),
        );
      }
      return;
    }

    final ignoredVersionCode =
        manual ? 0 : await SettingsService.getIgnoredUpdateVersionCode();

    AppUpdateInfo? updateInfo;
    try {
      updateInfo = await UpdateService.fetchLatestRelease();
    } catch (error) {
      if (manual && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('检查更新失败: $error')),
        );
      }
      return;
    }

    if (!mounted || updateInfo == null) {
      return;
    }

    if (updateInfo.versionCode <= _appVersionCode) {
      if (manual) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前已经是最新版本')),
        );
      }
      return;
    }

    if (!manual &&
        !updateInfo.force &&
        ignoredVersionCode == updateInfo.versionCode) {
      return;
    }

    await _showUpdateDialog(updateInfo, manual: manual);
  }

  Future<void> _showUpdateDialog(
    AppUpdateInfo updateInfo, {
    required bool manual,
  }) async {
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: !updateInfo.force,
      builder: (context) {
        final notes = updateInfo.notes;
        return AlertDialog(
          title: Text(manual ? '发现可用更新' : '发现新版本'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  updateInfo.title.isEmpty
                      ? updateInfo.versionLabel
                      : updateInfo.title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  '当前版本：$_appVersionLabel${_appBuildLabel.isEmpty ? '' : ' ($_appBuildLabel)'}',
                ),
                Text(
                  '最新版本：${updateInfo.versionLabel} (Build ${updateInfo.versionCode})',
                ),
                if (notes.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    '更新内容',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 8),
                  ...notes.map(
                    (note) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('• $note'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (!updateInfo.force)
              TextButton(
                onPressed: () => Navigator.of(context).pop('ignore'),
                child: Text(manual ? '关闭' : '忽略这版'),
              ),
            if (updateInfo.hasBackupUrl)
              TextButton(
                onPressed: () => Navigator.of(context).pop('backup'),
                child: const Text('备用链接'),
              ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop('primary'),
              child: const Text('去下载'),
            ),
          ],
        );
      },
    );

    if (!mounted || action == null) {
      return;
    }

    if (action == 'ignore') {
      await SettingsService.saveIgnoredUpdateVersionCode(
          updateInfo.versionCode);
      return;
    }

    final targetUrl =
        action == 'backup' ? updateInfo.backupUrl : updateInfo.preferredOpenUrl;
    await _openUpdateUrl(targetUrl);
  }

  Future<void> _openUpdateUrl(String value) async {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('更新链接无效')),
      );
      return;
    }

    final opened = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (opened || !mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('无法打开更新链接')),
    );
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

  Future<CounterModel> _saveCounter(
    CounterModel updatedCounter, {
    required DateTime occurredAt,
    String note = '快捷计数',
  }) async {
    final index =
        _counters.indexWhere((counter) => counter.id == updatedCounter.id);
    if (index == -1 || updatedCounter.id == null) {
      final insertedId = await DatabaseService.insertCounter(updatedCounter);
      final insertedCounter = updatedCounter.copyWith(id: insertedId);
      final deltas = {
        for (final field in CounterCountField.values)
          field: insertedCounter.countForField(field),
      };

      setState(() {
        _counters.add(insertedCounter);
        _applySort(_counters);
      });

      await _recordCounterChange(
        counter: insertedCounter,
        deltas: deltas,
        occurredAt: occurredAt,
        note: note,
      );
      return insertedCounter;
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

    return updatedCounter;
  }

  Future<void> _openCounterSheet(_HomeCounterEntry entry) async {
    if (_isLocked) return;

    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => MemberDetailPage(
          displayCounter: entry.displayCounter,
          primaryCounter: entry.primaryCounter,
          sourceCounters: entry.sourceCounters,
          onCounterChanged: (updatedCounter, occurredAt) async {
            return _saveCounter(
              updatedCounter,
              occurredAt: occurredAt,
            );
          },
        ),
      ),
    );
    if (changed == true) {
      await _loadCounters();
    }
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

  Future<void> _editHomeEntry(_HomeCounterEntry entry) async {
    if (entry.sourceCounters.length == 1) {
      await _editCounter(entry.primaryCounter);
      return;
    }

    final selectedCounter = await showModalBottomSheet<CounterModel>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(entry.displayCounter.name),
              subtitle: const Text('选择要编辑的团体记录'),
            ),
            ...entry.sourceCounters.map((counter) {
              final subtitle = counter.groupName.trim().isEmpty
                  ? '当前总数 ${counter.count}'
                  : '${counter.groupName} · 当前总数 ${counter.count}';
              return ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(counter.name),
                subtitle: Text(subtitle),
                onTap: () => Navigator.of(context).pop(counter),
              );
            }),
          ],
        ),
      ),
    );

    if (selectedCounter == null) {
      return;
    }
    await _editCounter(selectedCounter);
  }

  Future<void> _deleteHomeEntry(_HomeCounterEntry entry) async {
    final deletableCounters =
        entry.sourceCounters.where((counter) => counter.id != null).toList();
    if (deletableCounters.isEmpty) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text(
          entry.sourceCounters.length == 1
              ? '确定要删除这个计数器吗？会同时删除这张卡对应的成员流水记录。'
              : '确定删除 ${entry.displayCounter.name} 名下的 ${entry.sourceCounters.length} 张团体计数卡吗？对应的成员流水记录也会一起删除。',
        ),
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
    );

    if (confirmed != true) {
      return;
    }

    for (final counter in deletableCounters) {
      await DatabaseService.deleteCounter(counter.id!);
    }
    await _loadCounters();
  }

  Future<void> _toggleHomeEntryHidden(_HomeCounterEntry entry) async {
    final countersToUpdate =
        entry.sourceCounters.where((counter) => counter.id != null).toList();
    if (countersToUpdate.isEmpty) {
      return;
    }

    final shouldHide = !countersToUpdate.every((counter) => counter.isHidden);
    for (final counter in countersToUpdate) {
      await DatabaseService.updateCounter(
        counter.id!,
        counter.copyWith(isHidden: shouldHide),
      );
    }

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(shouldHide
            ? '已隐藏 ${entry.displayCounter.name}'
            : '已恢复 ${entry.displayCounter.name}'),
        duration: const Duration(seconds: 2),
      ),
    );
    await _loadCounters();
  }

  Future<void> _showHomeEntryActions(_HomeCounterEntry entry) async {
    if (_isLocked || !mounted) {
      return;
    }

    final shouldHide =
        !entry.sourceCounters.every((counter) => counter.isHidden);

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                shouldHide
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
              ),
              title: Text(shouldHide ? '隐藏这张卡片' : '取消隐藏卡片'),
              subtitle: Text(
                entry.sourceCounters.length == 1
                    ? entry.displayCounter.name
                    : '${entry.displayCounter.name} · ${entry.sourceCounters.length} 个团体',
              ),
              onTap: () async {
                Navigator.of(context).pop();
                await _toggleHomeEntryHidden(entry);
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

  Future<void> _showOverviewMetricsDialog() async {
    final metrics = _orderedOverviewMetrics;
    final initialSelection = _selectedOverviewMetricIds.isEmpty
        ? metrics.map((metric) => metric.id).toSet()
        : Set<String>.from(_selectedOverviewMetricIds);

    final result = await showModalBottomSheet<_OverviewMetricConfigResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        var orderedMetrics = List<_OverviewMetricData>.from(metrics);
        final selected = Set<String>.from(initialSelection);
        var selectedColumns = _overviewMetricColumns.clamp(2, 3);
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: SizedBox(
                height: math.min(
                  MediaQuery.of(context).size.height * 0.82,
                  560,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '总览显示项',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '点按勾选控制显示，拖动右侧手柄调整块的位置顺序。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '每行排布',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 8),
                      SegmentedButton<int>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment<int>(
                            value: 2,
                            label: Text('一排两个'),
                          ),
                          ButtonSegment<int>(
                            value: 3,
                            label: Text('一排三个'),
                          ),
                        ],
                        selected: <int>{selectedColumns},
                        onSelectionChanged: (selection) {
                          setSheetState(() {
                            selectedColumns = selection.first;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          TextButton(
                            onPressed: () {
                              setSheetState(() {
                                selected
                                  ..clear()
                                  ..addAll(
                                    orderedMetrics.map((metric) => metric.id),
                                  );
                              });
                            },
                            child: const Text('全部显示'),
                          ),
                          TextButton(
                            onPressed: () {
                              setSheetState(() {
                                orderedMetrics = List<_OverviewMetricData>.from(
                                  _allOverviewMetrics,
                                );
                                selected
                                  ..clear()
                                  ..addAll(
                                    orderedMetrics.map((metric) => metric.id),
                                  );
                                selectedColumns = SettingsService
                                    .defaultOverviewMetricColumns;
                              });
                            },
                            child: const Text('恢复默认'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ReorderableListView.builder(
                          buildDefaultDragHandles: false,
                          itemCount: orderedMetrics.length,
                          onReorder: (oldIndex, newIndex) {
                            setSheetState(() {
                              if (newIndex > oldIndex) {
                                newIndex -= 1;
                              }
                              final item = orderedMetrics.removeAt(oldIndex);
                              orderedMetrics.insert(newIndex, item);
                            });
                          },
                          itemBuilder: (context, index) {
                            final metric = orderedMetrics[index];
                            final visible = selected.contains(metric.id);
                            return Container(
                              key: ValueKey(metric.id),
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerLow,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 2,
                                ),
                                onTap: () {
                                  setSheetState(() {
                                    if (visible) {
                                      selected.remove(metric.id);
                                    } else {
                                      selected.add(metric.id);
                                    }
                                  });
                                },
                                leading: Checkbox(
                                  value: visible,
                                  onChanged: (value) {
                                    setSheetState(() {
                                      if (value == true) {
                                        selected.add(metric.id);
                                      } else {
                                        selected.remove(metric.id);
                                      }
                                    });
                                  },
                                ),
                                title: Text(metric.label),
                                subtitle: Text(
                                  '${metric.isCustom ? '自定义' : '内置'} · 当前 ${metric.value}',
                                ),
                                trailing: ReorderableDragStartListener(
                                  index: index,
                                  child: const Icon(Icons.drag_indicator),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('取消'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: () {
                                final orderedIds = orderedMetrics
                                    .map((metric) => metric.id)
                                    .toList(growable: false);
                                final visibleIds = orderedMetrics
                                    .where(
                                      (metric) => selected.contains(metric.id),
                                    )
                                    .map((metric) => metric.id)
                                    .toList(growable: false);
                                Navigator.of(context).pop(
                                  _OverviewMetricConfigResult(
                                    orderedIds: orderedIds,
                                    visibleIds: visibleIds.isEmpty
                                        ? orderedIds
                                        : visibleIds,
                                    columns: selectedColumns,
                                  ),
                                );
                              },
                              child: const Text('保存'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    if (result == null) {
      return;
    }

    setState(() {
      _selectedOverviewMetricIds = result.visibleIds.toSet();
      _overviewMetricOrder = result.orderedIds;
      _overviewMetricColumns = result.columns;
    });
    await SettingsService.saveOverviewMetricIds(result.visibleIds);
    await SettingsService.saveOverviewMetricOrder(result.orderedIds);
    await SettingsService.saveOverviewMetricColumns(result.columns);
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
      await ExportImportService.exportData();
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

      if (payload.isFullBackup) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('恢复完整备份'),
            content: Text(
              '检测到 ${payload.fileName} 是完整备份。\n'
              '继续后会覆盖当前的卡片、价格、流水、存图和偶像库数据。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('继续恢复'),
              ),
            ],
          ),
        );

        if (confirmed != true || !mounted || payload.fullBackup == null) {
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
                    Text('正在恢复完整备份...'),
                  ],
                ),
              ),
            ),
          ),
        );

        try {
          await ExportImportService.restoreFullBackup(payload.fullBackup!);
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
              content: Text('${payload.fileName} 已恢复完成'),
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
              '同步 ${result.pricingCount} 个团体配置，'
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

  Widget _buildOverviewCard(BuildContext context) {
    final metrics = _visibleOverviewMetrics;
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = _overviewMetricColumns.clamp(2, 3);
        final compactAddButton = width < 360;
        final subtitle = '${_homeEntries.length} 个成员 / 项目 · 点按配置显示项、顺序和排布';

        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: _showOverviewMetricsDialog,
            child: Ink(
              padding: const EdgeInsets.fromLTRB(
                _overviewCardHorizontalPadding,
                _overviewCardVerticalPadding,
                _overviewCardHorizontalPadding,
                _overviewCardVerticalPadding,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    theme.colorScheme.primary.withAlpha(28),
                    theme.colorScheme.secondary.withAlpha(20),
                  ],
                ),
                border: Border.all(
                  color: theme.colorScheme.primary.withAlpha(24),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '切奇总览',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              subtitle,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 11,
                                color: theme.textTheme.bodyMedium?.color
                                    ?.withValues(
                                  alpha: 0.72,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: theme.colorScheme.surface.withAlpha(196),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '$_overviewTotal',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w900,
                                height: 1,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '总数',
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '拖动排序和勾选显示项都在这里配置',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color:
                                theme.textTheme.bodyMedium?.color?.withValues(
                              alpha: 0.66,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonalIcon(
                        onPressed: _openAddRecordEntry,
                        icon: const Icon(Icons.edit_note_rounded, size: 18),
                        label: compactAddButton
                            ? const Text('新增')
                            : const Text('新增记录'),
                        style: FilledButton.styleFrom(
                          padding: EdgeInsets.symmetric(
                            horizontal: compactAddButton ? 12 : 14,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (metrics.isNotEmpty)
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: metrics.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: _overviewChipSpacing,
                        mainAxisSpacing: _overviewChipSpacing,
                        mainAxisExtent: 52,
                      ),
                      itemBuilder: (context, index) {
                        final metric = metrics[index];
                        return _OverviewChip(
                          label: metric.label,
                          value: metric.value,
                          isCustom: metric.isCustom,
                        );
                      },
                    ),
                  if (metrics.isEmpty) ...[
                    Text(
                      '当前没有可显示的统计项',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopHeaderRow(BuildContext context) {
    return _buildOverviewCard(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor:
            Theme.of(context).colorScheme.inversePrimary.withAlpha(204),
        title: Text('总计 $_overviewTotal'),
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
            onSelected: (value) async {
              switch (value) {
                case 'export':
                  _exportData();
                  break;
                case 'import':
                  _importData();
                  break;
                case 'recentRecords':
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const RecentRecordsPage(),
                    ),
                  );
                  await _loadCounters();
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
                case 'groupPricing':
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const GroupPricingPage(),
                    ),
                  );
                  break;
                case 'checkUpdate':
                  await _checkForUpdates(manual: true);
                  break;
                case 'about':
                  _showAboutApp();
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
                value: 'recentRecords',
                child: Row(
                  children: [
                    Icon(Icons.history_rounded),
                    SizedBox(width: 8),
                    Text('最近提交记录'),
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
              const PopupMenuItem(
                value: 'groupPricing',
                child: Row(
                  children: [
                    Icon(Icons.sell_outlined),
                    SizedBox(width: 8),
                    Text('团体配置'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'checkUpdate',
                child: Row(
                  children: [
                    Icon(Icons.system_update_alt_rounded),
                    SizedBox(width: 8),
                    Text('检查更新'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'about',
                child: Row(
                  children: [
                    Icon(Icons.info_outline),
                    SizedBox(width: 8),
                    Text('关于应用'),
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
            final homeEntries = _homeEntries;
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
                        final entry = homeEntries[index];
                        final counter = entry.displayCounter;
                        return RepaintBoundary(
                          child: CounterCard(
                            key: ValueKey(entry.key),
                            counter: counter,
                            totalCount: entry.totalCount,
                            breakdownEntries: entry.breakdownEntries,
                            percentage: _getPercentage(entry.totalCount),
                            onTap: () => _openCounterSheet(entry),
                            onLongPress: () => _showHomeEntryActions(entry),
                            onEdit: () => _editHomeEntry(entry),
                            onDelete: () => _deleteHomeEntry(entry),
                            isLocked: _isLocked,
                            gridColumns: gridColumns,
                          ),
                        );
                      },
                      childCount: homeEntries.length,
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
  final bool isCustom;

  const _OverviewChip({
    required this.label,
    required this.value,
    this.isCustom = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseColor =
        isCustom ? theme.colorScheme.tertiary : theme.colorScheme.primary;

    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: baseColor.withAlpha(isCustom ? 22 : 18),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: baseColor.withAlpha(48),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontSize: 11,
              color: baseColor.withAlpha(210),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '$value',
              textAlign: TextAlign.right,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w900,
                fontSize: 18,
                height: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OverviewMetricData {
  final String id;
  final String label;
  final int value;
  final bool isCustom;

  const _OverviewMetricData({
    required this.id,
    required this.label,
    required this.value,
    required this.isCustom,
  });
}

class _OverviewMetricConfigResult {
  final List<String> orderedIds;
  final List<String> visibleIds;
  final int columns;

  const _OverviewMetricConfigResult({
    required this.orderedIds,
    required this.visibleIds,
    required this.columns,
  });
}
