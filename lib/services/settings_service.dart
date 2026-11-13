import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const String _gridSizeKey = 'grid_size';
  static const String _sortDirectionKey = 'sort_direction';
  static const String _sortTypeKey = 'sort_type';
  static const String _isLockedKey = 'is_locked';
  static const String _showHiddenCountersKey = 'show_hidden_counters';
  static const String _otaAdminKey = 'ota_admin_key';
  static const String _overviewMetricIdsKey = 'overview_metric_ids';
  static const String _overviewMetricOrderKey = 'overview_metric_order';
  static const String _overviewMetricColumnsKey = 'overview_metric_columns';
  static const String _ignoredUpdateVersionCodeKey =
      'ignored_update_version_code';

  static const double defaultGridSize = 2;

  static const String _fontScaleKey = 'font_scale';

  /// 卡片字号: member-card text size on top of the phone's own font setting.
  /// Everything outside the member cards keeps the normal system size.
  static final Map<double, String> fontScaleOptions = {
    1.0: '标准',
    1.15: '大',
    1.3: '特大',
  };

  /// The home page listens to this so a card-size change applies immediately.
  static final ValueNotifier<double> fontScale = ValueNotifier(1.0);

  static Future<void> loadFontScale() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getDouble(_fontScaleKey) ?? 1.0;
    fontScale.value = fontScaleOptions.containsKey(value) ? value : 1.0;
  }

  static Future<void> saveFontScale(double value) async {
    fontScale.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_fontScaleKey, value);
  }

  static const String sortByCount = 'count';
  static const String sortByName = 'name';
  static const String sortByCreated = 'created';
  static const String sortByColor = 'color';
  static const int defaultOverviewMetricColumns = 3;

  static Future<void> saveGridSize(double size) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_gridSizeKey, size);
  }

  static Future<double> getGridSize() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_gridSizeKey) ?? defaultGridSize;
  }

  static Future<void> saveSortDirection(bool ascending) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_sortDirectionKey, ascending);
  }

  static Future<bool> getSortDirection() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_sortDirectionKey) ?? true;
  }

  static Future<void> saveSortType(String type) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sortTypeKey, type);
  }

  static Future<String> getSortType() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_sortTypeKey) ?? sortByCount;
  }

  static Future<void> saveLockState(bool isLocked) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_isLockedKey, isLocked);
  }

  static Future<bool> getLockState() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_isLockedKey) ?? false;
  }

  static Future<void> saveShowHiddenCounters(bool showHidden) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showHiddenCountersKey, showHidden);
  }

  static Future<bool> getShowHiddenCounters() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_showHiddenCountersKey) ?? false;
  }

  static Future<void> saveOtaAdminKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_otaAdminKey, key);
  }

  static Future<String> getOtaAdminKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_otaAdminKey) ?? '';
  }

  static const String _faceMcpUrlKey = 'face_mcp_url';
  static const String _faceMcpTokenKey = 'face_mcp_token';

  /// Local face MCP (Mac).  Override with
  /// --dart-define=OTA_FACE_MCP_URL=... at build time; the token can be
  /// injected with OTA_FACE_MCP_TOKEN so no secret is committed.
  static const String faceMcpDefaultUrl = String.fromEnvironment(
    'OTA_FACE_MCP_URL',
    defaultValue: 'http://192.168.0.117:8789',
  );
  static const String faceMcpDefaultToken =
      String.fromEnvironment('OTA_FACE_MCP_TOKEN', defaultValue: '');

  static Future<String> getFaceMcpUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = (prefs.getString(_faceMcpUrlKey) ?? '').trim();
    return saved.isEmpty ? faceMcpDefaultUrl : saved;
  }

  static Future<void> saveFaceMcpUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_faceMcpUrlKey, url.trim());
  }

  static Future<String> getFaceMcpToken() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = (prefs.getString(_faceMcpTokenKey) ?? '').trim();
    return saved.isEmpty ? faceMcpDefaultToken : saved;
  }

  static Future<void> saveFaceMcpToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_faceMcpTokenKey, token.trim());
  }

  static Future<void> saveOverviewMetricIds(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _overviewMetricIdsKey,
      ids.where((id) => id.trim().isNotEmpty).toList(growable: false),
    );
  }

  static Future<List<String>> getOverviewMetricIds() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_overviewMetricIdsKey) ?? const <String>[];
  }

  static Future<void> saveOverviewMetricOrder(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _overviewMetricOrderKey,
      ids.where((id) => id.trim().isNotEmpty).toList(growable: false),
    );
  }

  static Future<List<String>> getOverviewMetricOrder() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_overviewMetricOrderKey) ?? const <String>[];
  }

  static Future<void> saveOverviewMetricColumns(int columns) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _overviewMetricColumnsKey,
      columns.clamp(2, 3),
    );
  }

  static Future<int> getOverviewMetricColumns() async {
    final prefs = await SharedPreferences.getInstance();
    final value =
        prefs.getInt(_overviewMetricColumnsKey) ?? defaultOverviewMetricColumns;
    return value.clamp(2, 3);
  }

  static Future<void> saveIgnoredUpdateVersionCode(int versionCode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _ignoredUpdateVersionCodeKey,
      versionCode.clamp(0, 1 << 30),
    );
  }

  static Future<int> getIgnoredUpdateVersionCode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_ignoredUpdateVersionCodeKey) ?? 0;
  }

  static const String _faceRecognitionEnabledKey = 'face_recognition_enabled';

  /// 人脸识别 for 批量拍切. Off until the user turns it on (and has read the
  /// on-device / privacy note).
  static Future<bool> getFaceRecognitionEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_faceRecognitionEnabledKey) ?? false;
  }

  static Future<void> saveFaceRecognitionEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_faceRecognitionEnabledKey, enabled);
  }
}
