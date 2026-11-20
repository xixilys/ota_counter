import 'dart:async';

import 'package:flutter/widgets.dart';

import 'sync_service.dart';

/// Applies chat-queued actions without a manual sync.
///
/// While 「自动同步」 is on and the app is in the foreground:
/// * opening the app and coming back to the foreground run a full sync
///   (pull, apply, upload a fresh snapshot);
/// * every [interval] a light check asks the server for pending actions
///   (one small GET) and only syncs when there are some.
///
/// The next tick is scheduled after the current one finishes, so a long
/// batch of photos never overlaps the next check. Nothing runs in the
/// background: the timer stops when the app leaves the foreground.
class SyncScheduler with WidgetsBindingObserver {
  SyncScheduler({
    required this.onApplied,
    this.interval = defaultInterval,
    Future<SyncSettings> Function()? loadSettings,
    Future<SyncRunResult> Function(SyncSettings)? fullSync,
    Future<SyncRunResult?> Function(SyncSettings)? checkPending,
  })  : _loadSettings = loadSettings ?? SyncService.loadSettings,
        _fullSync = fullSync ?? SyncService.syncNow,
        _checkPending = checkPending ?? SyncService.syncIfPending;

  /// One GET per device every 90 s is negligible for the sync server and
  /// keeps a chat-queued action within about a minute and a half.
  static const Duration defaultInterval = Duration(seconds: 90);

  /// Called after a sync that applied at least one action (reload the UI).
  final Future<void> Function(SyncRunResult result) onApplied;
  final Duration interval;
  final Future<SyncSettings> Function() _loadSettings;
  final Future<SyncRunResult> Function(SyncSettings) _fullSync;
  final Future<SyncRunResult?> Function(SyncSettings) _checkPending;

  Timer? _timer;
  bool _started = false;
  bool _foreground = true;
  bool _busy = false;

  bool get isTicking => _timer != null;

  /// Registers for lifecycle changes and runs the opening sync.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    await _run(full: true);
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    _cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_started) return;
    if (state == AppLifecycleState.resumed) {
      if (_foreground) return;
      _foreground = true;
      unawaited(_run(full: true));
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _foreground = false;
      _cancel();
    }
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void _scheduleNext() {
    _cancel();
    if (!_started || !_foreground) return;
    _timer = Timer(interval, () {
      _timer = null;
      unawaited(_run(full: false));
    });
  }

  Future<void> _run({required bool full}) async {
    if (_busy) return;
    _busy = true;
    _cancel();
    try {
      final settings = await _loadSettings();
      // Off or not set up: the tick only re-reads the local settings, so
      // switching it on in 同步 takes effect without restarting the app.
      if (!settings.autoSync || !settings.isConfigured) return;
      final result =
          full ? await _fullSync(settings) : await _checkPending(settings);
      if (result != null && result.applied > 0) {
        await onApplied(result);
      }
    } catch (_) {
      // Offline or server down: try again on the next tick.
    } finally {
      _busy = false;
      _scheduleNext();
    }
  }
}
