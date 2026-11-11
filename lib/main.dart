import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_metadata.dart';
import 'models/activity_record_model.dart';
import 'models/chart_stats_helpers.dart';
import 'models/counter_model.dart';
import 'models/ticket_type_model.dart';
import 'pages/add_idol_page.dart';
import 'pages/batch_capture_page.dart';
import 'pages/chart_page.dart';
import 'pages/face_recognition_settings_page.dart';
import 'pages/group_pricing_page.dart';
import 'pages/idol_activity_events_page.dart';
import 'pages/idol_database_page.dart';
import 'pages/image_page.dart';
import 'pages/member_detail_page.dart';
import 'pages/recent_records_page.dart';
import 'pages/sync_page.dart';
import 'services/database_service.dart';
import 'services/export_import_service.dart';
import 'services/idol_database_service.dart';
import 'services/ota_admin_import_service.dart';
import 'services/settings_service.dart';
import 'services/sync_service.dart';
import 'services/ticket_pricing_service.dart';
import 'services/update_service.dart';
import 'theme/app_theme.dart';
import 'widgets/add_counter_dialog.dart';
import 'widgets/app_page_background.dart';
import 'widgets/cheki_overview_parts.dart';
import 'widgets/counter_card.dart';
import 'widgets/counter_count_sheet.dart';
import 'widgets/ticket_stub_card.dart';

void main() async {
  // 确保 Flutter 绑定初始化
  WidgetsFlutterBinding.ensureInitialized();

  // 仅在非 Android 平台初始化 FFI
  if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  try {
    await SettingsService.loadFontScale();
  } catch (_) {
    // Keep the default size if preferences are unreadable.
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: SettingsService.fontScale,
      builder: (context, cardFontScale, _) => MaterialApp(
        title: kAppDisplayName,
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [
          Locale('zh', 'CN'),
          Locale('en', 'US'),
        ],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        themeMode: ThemeMode.system,
        themeAnimationDuration: const Duration(milliseconds: 260),
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        // 卡片字号 only affects member cards, so nothing is wrapped here.
        home: MyHomePage(cardTextScale: cardFontScale),
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  /// Member-card text scale from the 卡片字号 setting. Pages outside the
  /// member grid ignore it.
  final double? cardTextScale;

  const MyHomePage({super.key, this.cardTextScale});

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

class _HomeOverviewSnapshot {
  final int memberTotal;
  final int overviewTotal;
  final Map<CounterCountField, int> typeTotals;

  const _HomeOverviewSnapshot({
    required this.memberTotal,
    required this.overviewTotal,
    required this.typeTotals,
  });
}

class _MyHomePageState extends State<MyHomePage> {
  static const double _overviewChipSpacing = 6;

  final List<CounterModel> _counters = [];
  final List<ActivityRecordModel> _activityRecords = [];
  int _activityRecordCount = 0;
  TicketStats _ticketStats = TicketStats.empty;
  List<_HomeCounterEntry>? _homeEntriesCache;
  _HomeOverviewSnapshot? _overviewCache;
  bool _initialLoadDone = false;
  bool _startupMaintenanceStarted = false;
  Future<void>? _idolDatabaseInit;
  Future<void>? _packageInfoInit;
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

  double get _cardTextScale =>
      widget.cardTextScale ?? SettingsService.fontScale.value;

  @override
  void initState() {
    super.initState();
    _idolDatabaseInit = _initializeIdolDatabase();
    _packageInfoInit = _loadPackageInfo();
    _loadCounters(reconcileImportedRecords: true);
    _loadSettings();
  }

  Future<void> _initializeIdolDatabase() async {
    await IdolDatabaseService.initializeBuiltInDataIfNeeded();
  }

  Future<void> _syncIdolLibraryInBackground() async {
    try {
      await IdolDatabaseService.syncFromRemoteIfStale();
    } catch (_) {
      // Offline or a bad upstream payload: keep the cached library.
    }
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
    if (!mounted) {
      return;
    }
    setState(() {
      _gridSize = size;
      _sortAscending = sortDirection;
      _sortType = sortType;
      _isLocked = isLocked; // 设置锁定状态
      _showHiddenCounters = showHiddenCounters;
      _selectedOverviewMetricIds = overviewMetricIds.toSet();
      _overviewMetricOrder = overviewMetricOrder;
      _overviewMetricColumns = overviewMetricColumns;
      _applySort(_counters);
      _invalidateHomeCaches();
    });
  }

  Future<void> _loadCounters({bool reconcileImportedRecords = false}) async {
    try {
      final results = await Future.wait([
        DatabaseService.getCounters(),
        DatabaseService.getHomeActivityRecords(),
        DatabaseService.getActivityRecordCount(),
        _loadTicketStats(),
      ]);
      final counters = results[0] as List<CounterModel>;
      final activityRecords = results[1] as List<ActivityRecordModel>;
      final activityRecordCount = results[2] as int;
      final ticketStats = results[3] as TicketStats;
      if (!mounted) {
        return;
      }
      setState(() {
        _counters
          ..clear()
          ..addAll(counters);
        _activityRecords
          ..clear()
          ..addAll(activityRecords);
        _activityRecordCount = activityRecordCount;
        _ticketStats = ticketStats;
        _applySort(_counters);
        _invalidateHomeCaches();
        _initialLoadDone = true;
      });
      if (reconcileImportedRecords) {
        // Imported-record sync, color enrichment and identity repair can each
        // scan a large database. Paint stored cards first, then run the
        // maintenance once and refresh quietly in the background.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _runStartupMaintenance();
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败: ${e.toString()}')),
        );
        setState(() {
          _initialLoadDone = true;
        });
      }
    }
  }

  Future<TicketStats> _loadTicketStats() async {
    try {
      return await TicketPricingService.getStats();
    } catch (_) {
      return TicketStats.empty;
    }
  }

  Future<void> _runStartupMaintenance() async {
    if (_startupMaintenanceStarted) {
      return;
    }
    _startupMaintenanceStarted = true;
    try {
      await _packageInfoInit;
      // A zero build number means package metadata is unavailable. Widget
      // tests use that to opt out of network/update work; skipping heavy
      // background maintenance there also keeps test teardown deterministic.
      if (_appVersionCode <= 0) {
        return;
      }
      await _idolDatabaseInit;
      // Refresh the idol library in the background so the APK's built-in
      // snapshot cannot stay stale. Failure is silent; cached data is kept.
      unawaited(_syncIdolLibraryInBackground());
      await DatabaseService.syncActivityRecordsToCounters('ota_site');
      await DatabaseService.autoAssignCounterThemeColors();
      await DatabaseService.reconcileCounterIdentities();
    } catch (_) {
      return;
    }
    if (!mounted) {
      return;
    }
    await _loadCounters();
    await _runAutoSyncIfEnabled();
  }

  Future<void> _runAutoSyncIfEnabled() async {
    try {
      final settings = await SyncService.loadSettings();
      if (!settings.autoSync || !settings.isConfigured) {
        return;
      }
      final result = await SyncService.syncNow(settings);
      if (result.applied > 0 && mounted) {
        await _loadCounters();
      }
    } catch (_) {
      // Network failures must never block app startup.
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

  int _visibleParticipantCountForMultiRecord(
    ActivityRecordModel record, {
    Set<int>? visibleIds,
  }) {
    final scopedIds = visibleIds ??
        _scopedCounters.map((counter) => counter.id).whereType<int>().toSet();
    if (scopedIds.isEmpty) {
      return 0;
    }

    final matchedIds = <int>{};
    for (final participant in record.effectiveParticipants) {
      final counter =
          DatabaseService.resolveCounterForParticipant(_counters, participant);
      if (counter?.id != null && scopedIds.contains(counter!.id)) {
        matchedIds.add(counter.id!);
      }
    }
    return matchedIds.length;
  }

  void _invalidateHomeCaches() {
    _homeEntriesCache = null;
    _overviewCache = null;
  }

  String _homeEntryKey(CounterModel counter) {
    if (counter.personId != null) {
      return 'person-id:${counter.personId}';
    }

    final personName = counter.personName.trim();
    if (personName.isNotEmpty) {
      return 'person-name:${personName.toLowerCase()}';
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

  Map<String, Map<String, int>> _buildHomeCustomTypeTotalsByEntry(
    Map<String, List<CounterModel>> groupedCounters,
  ) {
    final entryByCounterId = <int, String>{};
    final entryByPersonId = <int, String>{};
    final entryKeysByPersonName = <String, Set<String>>{};
    final entryByFallbackKey = <String, String>{};

    for (final entry in groupedCounters.entries) {
      for (final counter in entry.value) {
        final counterId = counter.id;
        if (counterId != null) {
          entryByCounterId[counterId] = entry.key;
        }
        final personId = counter.personId;
        if (personId != null) {
          entryByPersonId[personId] = entry.key;
        }
        final personName = _normalizedLookupPart(counter.personName);
        if (personName.isNotEmpty) {
          entryKeysByPersonName
              .putIfAbsent(personName, () => <String>{})
              .add(entry.key);
        }
        final fallbackKey =
            '${_normalizedLookupPart(counter.groupName)}|${_normalizedLookupPart(counter.name)}';
        if (fallbackKey != '|') {
          entryByFallbackKey[fallbackKey] = entry.key;
        }
      }
    }

    final entryByUniquePersonName = {
      for (final entry in entryKeysByPersonName.entries)
        if (entry.value.length == 1) entry.key: entry.value.single,
    };
    final totalsByEntry = <String, Map<String, int>>{};
    for (final record in _activityRecords) {
      if (!record.isCounter || record.effectiveCustomChekiCounts.isEmpty) {
        continue;
      }

      String? entryKey;
      final counterId = record.counterId;
      if (counterId != null) {
        entryKey = entryByCounterId[counterId];
      } else {
        final personId = record.personId;
        if (personId != null) {
          entryKey = entryByPersonId[personId];
        } else {
          final personName = _normalizedLookupPart(record.personName);
          if (personName.isNotEmpty) {
            entryKey = entryByUniquePersonName[personName];
          }
          entryKey ??= entryByFallbackKey[
              '${_normalizedLookupPart(record.groupName)}|${_normalizedLookupPart(record.subjectName)}'];
        }
      }
      if (entryKey == null) {
        continue;
      }

      final totals = totalsByEntry.putIfAbsent(entryKey, () => <String, int>{});
      for (final item in record.effectiveCustomChekiCounts) {
        final label = item.label.trim();
        if (label.isEmpty) {
          continue;
        }
        totals[label] = (totals[label] ?? 0) + item.count;
      }
    }
    return totalsByEntry;
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
    final cachedEntries = _homeEntriesCache;
    if (cachedEntries != null) {
      return cachedEntries;
    }

    final scopedCounters = _scopedCounters;

    final groupedCounters = <String, List<CounterModel>>{};
    for (final counter in scopedCounters) {
      groupedCounters
          .putIfAbsent(_homeEntryKey(counter), () => [])
          .add(counter);
    }
    final customTypeTotalsByEntry =
        _buildHomeCustomTypeTotalsByEntry(groupedCounters);

    final entries = groupedCounters.entries.map((entry) {
      final counters = entry.value;
      final primaryCounter = _selectPrimaryCounter(counters);
      final displayCounter = _buildHomeDisplayCounter(counters);
      final customCounts = customTypeTotalsByEntry[entry.key] ?? const {};
      final totalCount = displayCounter.count +
          customCounts.values.fold<int>(0, (sum, value) => sum + value);
      return _HomeCounterEntry(
        key: entry.key,
        displayCounter: displayCounter,
        primaryCounter: primaryCounter,
        sourceCounters: counters,
        customCounts: customCounts,
        totalCount: totalCount,
        breakdownEntries: buildHomeBreakdownEntries(
          displayCounter,
          customCounts,
        ),
      );
    }).toList();

    _applyHomeEntrySort(entries);
    final immutableEntries = List<_HomeCounterEntry>.unmodifiable(entries);
    _homeEntriesCache = immutableEntries;
    return immutableEntries;
  }

  int get _memberTotal => _overviewSnapshot.memberTotal;

  /// Members left out of the home totals because they are hidden and
  /// "显示已隐藏项" is off. Shown in the header so a smaller total is never
  /// mistaken for lost counts.
  int get _hiddenEntryCount {
    if (_showHiddenCounters) {
      return 0;
    }
    final visibleKeys = _homeEntries.map((entry) => entry.key).toSet();
    return _counters
        .where((counter) => counter.isHidden)
        .map(_homeEntryKey)
        .where((key) => !visibleKeys.contains(key))
        .toSet()
        .length;
  }

  _HomeOverviewSnapshot get _overviewSnapshot {
    final cached = _overviewCache;
    if (cached != null) {
      return cached;
    }

    final entries = _homeEntries;
    var memberTotal = 0;
    final typeTotals = <CounterCountField, int>{
      CounterCountField.threeInch: 0,
      CounterCountField.fiveInch: 0,
      CounterCountField.threeInchShukudai: 0,
      CounterCountField.fiveInchShukudai: 0,
      CounterCountField.groupCut: 0,
    };

    for (final entry in entries) {
      memberTotal += entry.totalCount;
      final counter = entry.displayCounter;
      typeTotals[CounterCountField.threeInch] =
          typeTotals[CounterCountField.threeInch]! +
              counter.aggregatedThreeInchCount;
      typeTotals[CounterCountField.fiveInch] =
          typeTotals[CounterCountField.fiveInch]! +
              counter.aggregatedFiveInchCount;
      typeTotals[CounterCountField.threeInchShukudai] =
          typeTotals[CounterCountField.threeInchShukudai]! +
              counter.threeInchShukudaiCount;
      typeTotals[CounterCountField.fiveInchShukudai] =
          typeTotals[CounterCountField.fiveInchShukudai]! +
              counter.fiveInchShukudaiCount;
      typeTotals[CounterCountField.groupCut] =
          typeTotals[CounterCountField.groupCut]! + counter.groupCutCount;
    }

    final visibleIds =
        _scopedCounters.map((counter) => counter.id).whereType<int>().toSet();
    var duplicateContributionTotal = 0;
    final duplicateByField = <CounterCountField, int>{};
    final recordScope = ChartRecordScope(
      counters: _counters,
      records: _activityRecords,
      showHiddenCounters: _showHiddenCounters,
    );
    for (final event in recordScope.multiEvents(recordScope.records)) {
      // Quantity-only legacy rows never touched counter totals.
      final rawField = event.field;
      if (rawField == null) {
        continue;
      }
      // Counter cards retain each source row's contribution. Subtract only the
      // extra visible contributions to the same physical photo event.
      final visibleParticipantCount = event.records.fold<int>(
        0,
        (sum, record) =>
            sum +
            _visibleParticipantCountForMultiRecord(
              record,
              visibleIds: visibleIds,
            ),
      );
      if (visibleParticipantCount <= 1) {
        continue;
      }
      final duplicateContribution =
          event.quantity * (visibleParticipantCount - 1);
      duplicateContributionTotal += duplicateContribution;
      final overviewField = rawField.aggregatedBaseField;
      duplicateByField[overviewField] =
          (duplicateByField[overviewField] ?? 0) + duplicateContribution;
    }

    final adjustedTypeTotals = <CounterCountField, int>{
      for (final field in CounterCountField.values)
        field: math.max(
            0, (typeTotals[field] ?? 0) - (duplicateByField[field] ?? 0)),
    };
    final snapshot = _HomeOverviewSnapshot(
      memberTotal: memberTotal,
      overviewTotal: math.max(0, memberTotal - duplicateContributionTotal),
      typeTotals: adjustedTypeTotals,
    );
    _overviewCache = snapshot;
    return snapshot;
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

  Map<CounterCountField, int> get _overviewTypeTotals =>
      _overviewSnapshot.typeTotals;

  int get _overviewTotal => _overviewSnapshot.overviewTotal;

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

  bool _hasCounterDeltas(Map<CounterCountField, int> deltas) {
    return deltas.values.any((value) => value != 0);
  }

  CounterModel _counterWithCountsFrom(
    CounterModel counter,
    CounterModel countSource,
  ) {
    return counter.copyWith(
      threeInchCount: countSource.threeInchCount,
      fiveInchCount: countSource.fiveInchCount,
      unsignedThreeInchCount: countSource.unsignedThreeInchCount,
      unsignedFiveInchCount: countSource.unsignedFiveInchCount,
      groupCutCount: countSource.groupCutCount,
      threeInchShukudaiCount: countSource.threeInchShukudaiCount,
      fiveInchShukudaiCount: countSource.fiveInchShukudaiCount,
    );
  }

  CounterModel _counterWithZeroCounts(CounterModel counter) {
    return counter.copyWith(
      threeInchCount: 0,
      fiveInchCount: 0,
      unsignedThreeInchCount: 0,
      unsignedFiveInchCount: 0,
      groupCutCount: 0,
      threeInchShukudaiCount: 0,
      fiveInchShukudaiCount: 0,
    );
  }

  CounterModel _resolveSavedCounter(CounterModel requested) {
    if (requested.id != null) {
      for (final counter in _counters) {
        if (counter.id == requested.id) {
          return counter;
        }
      }
    }

    if (requested.personId != null) {
      for (final counter in _counters) {
        if (counter.personId == requested.personId &&
            _normalizedLookupPart(counter.groupName) ==
                _normalizedLookupPart(requested.groupName)) {
          return counter;
        }
      }
    }

    final requestedPersonName = _normalizedLookupPart(requested.personName);
    if (requestedPersonName.isNotEmpty) {
      for (final counter in _counters) {
        if (counter.personId != null &&
            requested.personId != null &&
            counter.personId != requested.personId) {
          continue;
        }
        if (_normalizedLookupPart(counter.groupName) ==
                _normalizedLookupPart(requested.groupName) &&
            _normalizedLookupPart(counter.personName) == requestedPersonName) {
          return counter;
        }
      }
    }

    for (final counter in _counters) {
      if ((counter.personId == null ||
              requested.personId == null ||
              counter.personId == requested.personId) &&
          _normalizedLookupPart(counter.groupName) ==
              _normalizedLookupPart(requested.groupName) &&
          _normalizedLookupPart(counter.name) ==
              _normalizedLookupPart(requested.name)) {
        return counter;
      }
    }
    return requested;
  }

  Future<int?> _recordCounterChange({
    required CounterModel counter,
    required Map<CounterCountField, int> deltas,
    required DateTime occurredAt,
    required String note,
    String activityName = '',
    String venueName = '',
    String sessionLabel = '',
  }) async {
    if (deltas.values.every((value) => value == 0)) {
      return null;
    }

    final pricing = await DatabaseService.getGroupPricingByName(
      counter.groupName,
    );

    return DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.counterAdjustment(
        counter: counter,
        occurredAt: occurredAt,
        deltas: deltas,
        pricing: pricing,
        note: note,
        activityName: activityName,
        venueName: venueName,
        sessionLabel: sessionLabel,
      ),
    );
  }

  Future<CounterSaveResult> _saveCounter(
    CounterModel updatedCounter, {
    required DateTime occurredAt,
    String note = '快捷计数',
    String activityName = '',
    String venueName = '',
    String sessionLabel = '',
    CounterModel? baseCounter,
  }) async {
    final index =
        _counters.indexWhere((counter) => counter.id == updatedCounter.id);
    int? recordId;
    if (index == -1 || updatedCounter.id == null) {
      // Without a confirmed base this is a brand-new card: every count is new.
      final deltas = _buildCounterDeltas(
        baseCounter ?? _counterWithZeroCounts(updatedCounter),
        updatedCounter,
      );

      if (_hasCounterDeltas(deltas)) {
        recordId = await _recordCounterChange(
          // A queued tap may still carry the draft (id-less) copy although
          // the previous save already created the card; link to that card.
          counter: _counterWithZeroCounts(
            updatedCounter.copyWith(id: baseCounter?.id),
          ),
          deltas: deltas,
          occurredAt: occurredAt,
          note: note,
          activityName: activityName,
          venueName: venueName,
          sessionLabel: sessionLabel,
        );
      } else if (baseCounter == null) {
        await DatabaseService.insertCounter(updatedCounter);
      }
      await _loadCounters();
      return CounterSaveResult(
        counter: _resolveSavedCounter(updatedCounter),
        recordId: recordId,
      );
    }

    // The sheet's confirmed base, not this page's cache: the cache can be
    // stale (member detail edits, background sync) and would turn one tap
    // into a larger or negative correction.
    final previousCounter = baseCounter ?? _counters[index];
    final deltas = _buildCounterDeltas(previousCounter, updatedCounter);

    if (_hasCounterDeltas(deltas)) {
      recordId = await _recordCounterChange(
        counter: updatedCounter,
        deltas: deltas,
        occurredAt: occurredAt,
        note: note,
        activityName: activityName,
        venueName: venueName,
        sessionLabel: sessionLabel,
      );
    }

    await _loadCounters();
    return CounterSaveResult(
      counter: _resolveSavedCounter(updatedCounter),
      recordId: recordId,
    );
  }

  Future<CounterModel?> _deleteCounterRecord(
    int recordId,
    CounterModel beforeCounter,
  ) async {
    final deleted =
        await DatabaseService.deleteActivityRecordsWithCounterImpact([recordId]);
    await _loadCounters();
    if (deleted == 0) {
      return null;
    }
    return _resolveSavedCounter(beforeCounter);
  }

  Future<void> _openMemberDetail(_HomeCounterEntry entry) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => MemberDetailPage(
          displayCounter: entry.displayCounter,
          primaryCounter: entry.primaryCounter,
          sourceCounters: entry.sourceCounters,
          onCounterChanged: (
            updatedCounter,
            occurredAt, {
            activityName = '',
            venueName = '',
            sessionLabel = '',
            baseCounter,
          }) async {
            return _saveCounter(
              updatedCounter,
              occurredAt: occurredAt,
              activityName: activityName,
              venueName: venueName,
              sessionLabel: sessionLabel,
              baseCounter: baseCounter,
            );
          },
          onRecordDeleted: _deleteCounterRecord,
        ),
      ),
    );
    if (changed == true) {
      await _loadCounters();
    }
  }

  Future<void> _openCounterSheet(_HomeCounterEntry entry) async {
    if (_isLocked) return;

    var dirty = false;
    final openDetails = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => CounterCountSheet(
        counter: entry.primaryCounter,
        allCounters: _counters,
        onCounterChanged: (
          updatedCounter,
          occurredAt, {
          activityName = '',
          venueName = '',
          sessionLabel = '',
          baseCounter,
        }) async {
          dirty = true;
          return _saveCounter(
            updatedCounter,
            occurredAt: occurredAt,
            activityName: activityName,
            venueName: venueName,
            sessionLabel: sessionLabel,
            baseCounter: baseCounter,
          );
        },
        onRecordDeleted: _deleteCounterRecord,
        onViewDetails: () {
          Navigator.of(sheetContext).pop(true);
        },
      ),
    );
    if (dirty) {
      await _loadCounters();
    }
    if (openDetails == true && mounted) {
      await _openMemberDetail(entry);
    }
  }

  Future<void> _addIdol() async {
    try {
      final counters = await Navigator.of(context).push<List<CounterModel>>(
        MaterialPageRoute(
          builder: (context) => AddIdolPage(
            existingCounters: _counters,
          ),
        ),
      );
      if (counters == null || counters.isEmpty) {
        return;
      }

      for (final counter in counters) {
        await DatabaseService.insertCounter(counter);
      }
      await DatabaseService.autoAssignCounterThemeColors();
      await _loadCounters();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已添加 ${counters.length} 位成员')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('添加失败：$e')),
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
      if (result.counter.hasLowerCountThan(counter)) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('不能通过编辑成员减少数量，请删除对应流水后再重算计数。'),
          ),
        );
        return;
      }

      final deltas = _buildCounterDeltas(counter, result.counter);
      final metadataCounter = _counterWithCountsFrom(
        result.counter.copyWith(id: counter.id),
        counter,
      );
      await DatabaseService.updateCounter(counter.id!, metadataCounter);
      await _recordCounterChange(
        counter: metadataCounter,
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
              ? '确定要删除这位成员吗？会同时删除这张卡对应的成员流水；包含该成员的多人流水会整条删除，并同步更新其他成员计数。'
              : '确定删除 ${entry.displayCounter.name} 名下的 ${entry.sourceCounters.length} 张团体计数卡吗？对应成员流水会一起删除；相关多人流水也会整条删除，并同步更新其他成员计数。',
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

    try {
      await DatabaseService.deleteCounters(
        deletableCounters.map((counter) => counter.id!),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败：$error')),
        );
      }
    } finally {
      if (mounted) await _loadCounters();
    }
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

  Future<void> _recalculateCountersFromRecords() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('从记录重算计数'),
            content: const Text(
              '会把所有成员数量清零，再按现有流水记录重新计算。成员名称、颜色、隐藏状态会保留。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('开始重算'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) {
      return;
    }

    try {
      final replayed =
          await DatabaseService.recalculateCountersFromActivityRecords();
      await _loadCounters();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已从 $replayed 条记录重算计数')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('重算失败: $error')),
      );
    }
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

  void _showFontScaleDialog() {
    showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (context) => ValueListenableBuilder<double>(
        valueListenable: SettingsService.fontScale,
        builder: (context, current, _) => AlertDialog(
          title: const Text('卡片字号'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<double>(
                segments: [
                  for (final entry in SettingsService.fontScaleOptions.entries)
                    ButtonSegment(value: entry.key, label: Text(entry.value)),
                ],
                selected: {current},
                showSelectedIcon: false,
                onSelectionChanged: (value) =>
                    SettingsService.saveFontScale(value.first),
              ),
              const SizedBox(height: 12),
              Text(
                '在手机系统字号基础上，只放大首页成员卡片的名称、团体与计数，'
                '不影响其他页面。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
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
      _invalidateHomeCaches();
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
    _applySort(_counters);
    _invalidateHomeCaches();
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

  /// 「新增」: a ledger record, or 批量拍切 (cut + recognise + save a batch).
  Future<void> _openAddRecordEntry() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_note_rounded),
              title: const Text('记一笔流水'),
              onTap: () => Navigator.pop(context, 'record'),
            ),
            ListTile(
              leading: const Icon(Icons.burst_mode_outlined),
              title: const Text('批量拍切'),
              subtitle: const Text('连拍或从相册多选拍立得，自动切图、认人、入账'),
              onTap: () => Navigator.pop(context, 'batch'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'batch') {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const BatchCapturePage()),
      );
      await _loadCounters();
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const ChartPage(openComposerOnStart: true),
      ),
    );
    await _loadCounters();
  }

  Future<void> _openTicketComposer() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const ChartPage(
          openComposerOnStart: true,
          composerType: ActivityRecordType.ticket,
        ),
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
              '检测到 ${payload.fileName} 是旧版备份。\n'
              '继续后会清空当前成员、价格和流水数据，再导入备份内容。',
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
            content: Text('已导入旧版备份，共 ${payload.counters.length} 项'),
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
          await ExportImportService.disposeImportPayload(payload);
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
          // The restore may switch "显示已隐藏项" so the home totals match
          // the backed-up app; reload it before the counters.
          await _loadSettings();
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

  Widget _buildHomeCounterCard(_HomeCounterEntry entry, int gridColumns) {
    return CounterCard(
      key: ValueKey(entry.key),
      counter: entry.displayCounter,
      totalCount: entry.totalCount,
      breakdownEntries: entry.breakdownEntries,
      percentage: _getPercentage(entry.totalCount),
      onTap: () => _openCounterSheet(entry),
      onLongPress: () => _showHomeEntryActions(entry),
      onEdit: () => _editHomeEntry(entry),
      onDelete: () => _deleteHomeEntry(entry),
      isLocked: _isLocked,
      gridColumns: gridColumns,
      textScale: _cardTextScale,
    );
  }

  double _calculateCardHeight({
    required int gridColumns,
    required double availableWidth,
    required double crossAxisSpacing,
    required double textScale,
    required int breakdownEntryCount,
  }) {
    return counterCardHeight(
      gridColumns: gridColumns,
      availableWidth: availableWidth,
      crossAxisSpacing: crossAxisSpacing,
      textScale: textScale,
      breakdownEntryCount: breakdownEntryCount,
    );
  }

  Widget _buildOverviewCard(BuildContext context) {
    final metrics = _visibleOverviewMetrics;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final isDark = brightness == Brightness.dark;
    final metricExtent =
        (56.0 * MediaQuery.textScalerOf(context).scale(1.0)).clamp(56.0, 96.0);
    final oshi = AppTheme.oshi(brightness);
    const onStage = Colors.white;
    final onStageMuted = Colors.white.withValues(alpha: 0.78);
    final penlights = [
      for (final entry in _homeEntries)
        if (entry.totalCount > 0)
          PenlightData(
            color: entry.displayCounter.colorValue,
            count: entry.totalCount,
          ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = _overviewMetricColumns.clamp(2, 3);
        final compact = constraints.maxWidth < 350;

        // The overview is a cheki print: a white border around a "photo" of
        // the stage, where every member is a penlight in her own color.
        return Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
          decoration: BoxDecoration(
            color: AppTheme.polaroid(brightness),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: scheme.onSurface.withValues(alpha: isDark ? 0.10 : 0.06),
            ),
            boxShadow: isDark
                ? null
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 12,
                      offset: const Offset(0, 2),
                    ),
                  ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: ColoredBox(
                  color: AppTheme.stage(brightness),
                  child: Stack(
                    children: [
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 0,
                        height: 56,
                        child: PenlightCrowd(lights: penlights),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 4, 68),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const ChekiSticker(text: '我的切奇'),
                                const Spacer(),
                                IconButton(
                                  onPressed: _showOverviewMetricsDialog,
                                  tooltip: '配置总览指标',
                                  color: onStageMuted,
                                  icon:
                                      const Icon(Icons.tune_rounded, size: 20),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '累计切奇',
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: onStageMuted,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.baseline,
                                    textBaseline: TextBaseline.alphabetic,
                                    children: [
                                      Text(
                                        '$_overviewTotal',
                                        style: theme.textTheme.displayMedium
                                            ?.copyWith(
                                          fontSize: compact ? 44 : 52,
                                          fontWeight: FontWeight.w600,
                                          height: 1.1,
                                          letterSpacing: -1,
                                          color: onStage,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '张',
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                          color: onStageMuted,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              '${_homeEntries.length} 位成员 · $_activityRecordCount 条记录'
                              '${_hiddenEntryCount > 0 ? ' · 另有 $_hiddenEntryCount 位已隐藏' : ''}',
                              maxLines: 2,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: onStageMuted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (metrics.isNotEmpty)
                      // Plain rows instead of a shrink-wrapped GridView: a
                      // GridView without explicit padding inherits the
                      // Scaffold's MediaQuery padding (status bar + app bar
                      // + gesture bar), which used to open a large empty band
                      // inside this card.
                      for (var start = 0;
                          start < metrics.length;
                          start += columns) ...[
                        if (start > 0)
                          const SizedBox(height: _overviewChipSpacing),
                        SizedBox(
                          height: metricExtent,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // A short last row stretches to the full
                              // width instead of leaving an empty slot.
                              for (var i = start;
                                  i < math.min(start + columns, metrics.length);
                                  i++) ...[
                                if (i > start)
                                  const SizedBox(width: _overviewChipSpacing),
                                Expanded(
                                  child: _OverviewChip(
                                    label: metrics[i].label,
                                    value: metrics[i].value,
                                    isCustom: metrics[i].isCustom,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ]
                    else
                      Text(
                        '当前没有可显示的统计项，点右上角配置',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _openAddRecordEntry,
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: Text(compact ? '新增' : '新增记录'),
                            style: FilledButton.styleFrom(
                              backgroundColor: oshi,
                              foregroundColor: AppTheme.onOshi(brightness),
                              minimumSize: const Size(0, 44),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _showPieChart,
                            icon: const Icon(Icons.insights_rounded, size: 18),
                            label: const Text('查看统计'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: scheme.onSurface,
                              minimumSize: const Size(0, 44),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              side: BorderSide(
                                color: scheme.onSurface.withValues(alpha: 0.16),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHomeSectionHeader(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '成员',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
            fontSize: 20,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${_homeEntries.length} 位',
          style: theme.textTheme.labelLarge?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const Spacer(),
        Text(
          '长按卡片管理',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyHome(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasHiddenMembers = _counters.isNotEmpty && !_showHiddenCounters;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primaryContainer,
            ),
            child: Icon(
              Icons.photo_camera_back_outlined,
              color: scheme.primary,
              size: 30,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            hasHiddenMembers ? '当前没有可见成员' : '还没有成员卡片',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            hasHiddenMembers
                ? '成员被隐藏了，可以在更多菜单或这里重新显示。'
                : '先添加一位成员，之后每次切奇点一下就能记下来。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          if (hasHiddenMembers)
            FilledButton.icon(
              onPressed: _toggleShowHiddenCounters,
              icon: const Icon(Icons.visibility_rounded, size: 18),
              label: const Text('显示已隐藏成员'),
            )
          else
            FilledButton.icon(
              onPressed: _addIdol,
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
              label: const Text('添加第一位偶像'),
            ),
        ],
      ),
    );
  }

  Widget _buildLoadingGrid(int columns) {
    final scheme = Theme.of(context).colorScheme;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: columns * 2,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
        mainAxisExtent: 228,
      ),
      itemBuilder: (context, index) => Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: scheme.outlineVariant),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.outlineVariant.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Container(
                    height: 14,
                    decoration: BoxDecoration(
                      color: scheme.outlineVariant.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ),
            const Spacer(),
            Container(
              height: 38,
              width: 92,
              decoration: BoxDecoration(
                color: scheme.outlineVariant.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              height: 66,
              decoration: BoxDecoration(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight + 8;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor:
            AppTheme.paper(theme.brightness).withValues(alpha: 0.96),
        titleSpacing: 16,
        title: Row(
          children: [
            const PolaroidMark(width: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    kAppBrandName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                      fontSize: 20,
                      height: 1.15,
                    ),
                  ),
                  Text(
                    '$kAppBrandTagline · $_appVersionLabel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _toggleLock,
            tooltip: _isLocked ? '解锁计数' : '锁定计数',
            icon: Icon(
              _isLocked ? Icons.lock_rounded : Icons.lock_open_rounded,
              size: 21,
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort_rounded, size: 21),
            tooltip: '排序',
            onSelected: (value) {
              if (value == 'direction') {
                _toggleSortDirection();
              } else {
                _changeSortType(value);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'direction',
                child: Row(
                  children: [
                    Icon(
                      _sortAscending
                          ? Icons.arrow_downward_rounded
                          : Icons.arrow_upward_rounded,
                      size: 19,
                    ),
                    const SizedBox(width: 8),
                    Text(_sortAscending ? '改为降序' : '改为升序'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(
                value: SettingsService.sortByCount,
                checked: _sortType == SettingsService.sortByCount,
                child: const Text('按数量'),
              ),
              CheckedPopupMenuItem(
                value: SettingsService.sortByName,
                checked: _sortType == SettingsService.sortByName,
                child: const Text('按名称'),
              ),
              CheckedPopupMenuItem(
                value: SettingsService.sortByColor,
                checked: _sortType == SettingsService.sortByColor,
                child: const Text('按颜色'),
              ),
            ],
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 21),
            tooltip: '更多',
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
                case 'sync':
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const SyncPage(),
                    ),
                  );
                  await _loadCounters();
                  break;
                case 'recalculate':
                  await _recalculateCountersFromRecords();
                  break;
                case 'grid':
                  _showGridSizeDialog();
                  break;
                case 'fontScale':
                  _showFontScaleDialog();
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
                case 'activityEvents':
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const IdolActivityEventsPage(),
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
                case 'faceRecognition':
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const FaceRecognitionSettingsPage(),
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
                value: 'sync',
                child: Row(
                  children: [
                    Icon(Icons.hub_rounded),
                    SizedBox(width: 8),
                    Text('MCP 同步'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'grid',
                child: Row(
                  children: [
                    Icon(Icons.grid_view_rounded),
                    SizedBox(width: 8),
                    Text('网格大小'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'fontScale',
                child: Row(
                  children: [
                    Icon(Icons.format_size_rounded),
                    SizedBox(width: 8),
                    Text('卡片字号'),
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
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'export',
                child: Row(
                  children: [
                    Icon(Icons.upload_rounded),
                    SizedBox(width: 8),
                    Text('导出数据'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'import',
                child: Row(
                  children: [
                    Icon(Icons.download_rounded),
                    SizedBox(width: 8),
                    Text('导入数据'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'recalculate',
                child: Row(
                  children: [
                    Icon(Icons.calculate_outlined),
                    SizedBox(width: 8),
                    Text('从记录重算计数'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'image',
                child: Row(
                  children: [
                    Icon(Icons.image_outlined),
                    SizedBox(width: 8),
                    Text('抽取图片'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'idolDb',
                child: Row(
                  children: [
                    Icon(Icons.groups_2_outlined),
                    SizedBox(width: 8),
                    Text('偶像数据库'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'activityEvents',
                child: Row(
                  children: [
                    Icon(Icons.event_note_outlined),
                    SizedBox(width: 8),
                    Text('演出名单'),
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
                value: 'faceRecognition',
                child: Row(
                  children: [
                    Icon(Icons.face_retouching_natural_outlined),
                    SizedBox(width: 8),
                    Text('人脸识别'),
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
                    Icon(Icons.info_outline_rounded),
                    SizedBox(width: 8),
                    Text('关于应用'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: AppPageBackground(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final homeEntries = _homeEntries;
            final gridColumns = _gridSize.toInt();
            final crossAxisSpacing = gridColumns >= 4 ? 10.0 : 12.0;
            final mainAxisSpacing = gridColumns >= 3 ? 12.0 : 16.0;
            final horizontalPadding = constraints.maxWidth > 880
                ? (constraints.maxWidth - 840) / 2
                : 16.0;
            final contentWidth =
                math.max(0.0, constraints.maxWidth - horizontalPadding * 2);
            final maxBreakdownEntries = homeEntries.isEmpty
                ? 4
                : homeEntries.fold<int>(
                    1,
                    (maxEntries, entry) => math.max(
                      maxEntries,
                      entry.breakdownEntries.length,
                    ),
                  );
            final systemTextScale = MediaQuery.textScalerOf(context).scale(1.0);
            final cardHeight = _calculateCardHeight(
              gridColumns: gridColumns,
              availableWidth: contentWidth,
              crossAxisSpacing: crossAxisSpacing,
              textScale: systemTextScale * _cardTextScale,
              breakdownEntryCount: maxBreakdownEntries,
            );

            return RefreshIndicator(
              onRefresh: _loadCounters,
              edgeOffset: topInset - 8,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      topInset,
                      horizontalPadding,
                      0,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: _buildOverviewCard(context),
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      12,
                      horizontalPadding,
                      0,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: TicketStubCard(
                        stats: _ticketStats,
                        onTap: _showPieChart,
                        onAdd: _openTicketComposer,
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      24,
                      horizontalPadding,
                      12,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: _buildHomeSectionHeader(context),
                    ),
                  ),
                  if (!_initialLoadDone)
                    SliverPadding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalPadding,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: _buildLoadingGrid(gridColumns),
                      ),
                    )
                  else if (homeEntries.isEmpty)
                    SliverPadding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalPadding,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: _buildEmptyHome(context),
                      ),
                    )
                  else if (gridColumns <= 2)
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        0,
                        horizontalPadding,
                        0,
                      ),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, rowIndex) {
                            if (gridColumns == 1) {
                              return Padding(
                                padding:
                                    const EdgeInsets.only(bottom: 16),
                                child: _buildHomeCounterCard(
                                  homeEntries[rowIndex],
                                  gridColumns,
                                ),
                              );
                            }
                            final firstIndex = rowIndex * 2;
                            final secondIndex = firstIndex + 1;
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: Row(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: _buildHomeCounterCard(
                                      homeEntries[firstIndex],
                                      gridColumns,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: secondIndex < homeEntries.length
                                        ? _buildHomeCounterCard(
                                            homeEntries[secondIndex],
                                            gridColumns,
                                          )
                                        : const SizedBox.shrink(),
                                  ),
                                ],
                              ),
                            );
                          },
                          childCount: gridColumns == 1
                              ? homeEntries.length
                              : (homeEntries.length + 1) ~/ 2,
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        0,
                        horizontalPadding,
                        0,
                      ),
                      sliver: SliverGrid(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            return _buildHomeCounterCard(
                              homeEntries[index],
                              gridColumns,
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
                  const SliverPadding(
                    padding: EdgeInsets.only(bottom: 112),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addIdol,
        backgroundColor: AppTheme.oshi(theme.brightness),
        foregroundColor: AppTheme.onOshi(theme.brightness),
        icon: const Icon(Icons.person_add_alt_1_rounded, size: 20),
        label: const Text('添加偶像'),
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
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final isDark = brightness == Brightness.dark;
    final color =
        isCustom ? AppTheme.chekiCustom : AppTheme.metricColor(label, scheme);
    // A pastel tile in the metric's own color, like a colored sticker on the
    // print's border. Text stays on the neutral ramp for contrast.
    final background = Color.alphaBlend(
      color.withValues(alpha: isDark ? 0.20 : 0.13),
      AppTheme.polaroid(brightness),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '$value',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontSize: 22,
                      height: 1.1,
                      color: scheme.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 3),
              Text(
                '张',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
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
