import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const String _gridSizeKey = 'grid_size';
  static const String _sortDirectionKey = 'sort_direction';
  static const String _sortTypeKey = 'sort_type';
  static const String _isLockedKey = 'is_locked';
  static const String _showHiddenCountersKey = 'show_hidden_counters';
  static const String _otaAdminKey = 'ota_admin_key';

  static const double defaultGridSize = 2;

  static const String sortByCount = 'count';
  static const String sortByName = 'name';
  static const String sortByCreated = 'created';
  static const String sortByColor = 'color';

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
}
