// SyncScheduler: open / resume run a full sync, the foreground timer only
// checks pending actions, background stops the timer, nothing overlaps.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/services/sync_scheduler.dart';
import 'package:ota_counter/services/sync_service.dart';

SyncSettings _settings({bool autoSync = true}) => SyncSettings(
      baseUrl: 'http://127.0.0.1:1',
      token: 't',
      deviceId: 'd',
      autoSync: autoSync,
      lastSyncAt: '',
    );

const _nothing = SyncRunResult(pulled: 0, applied: 0, pending: 0, rev: 1);
const _oneApplied = SyncRunResult(pulled: 1, applied: 1, pending: 0, rev: 2);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const tick = Duration(milliseconds: 40);

  late List<String> calls;
  late int reloads;
  late bool autoSync;
  late SyncRunResult? pendingResult;
  late Completer<void>? gate;
  late SyncScheduler scheduler;

  SyncScheduler build() => SyncScheduler(
        interval: tick,
        onApplied: (_) async => reloads++,
        loadSettings: () async => _settings(autoSync: autoSync),
        fullSync: (_) async {
          calls.add('full');
          return _nothing;
        },
        checkPending: (_) async {
          calls.add('check');
          if (gate != null) await gate!.future;
          return pendingResult;
        },
      );

  setUp(() {
    calls = [];
    reloads = 0;
    autoSync = true;
    pendingResult = null;
    gate = null;
    scheduler = build();
  });
  tearDown(() => scheduler.dispose());

  Future<void> wait(Duration d) => Future<void>.delayed(d);
  void lifecycle(AppLifecycleState state) =>
      scheduler.didChangeAppLifecycleState(state);

  test('opening the app syncs, then the timer only checks pending', () async {
    await scheduler.start();
    expect(calls, ['full']);
    await wait(tick * 3.5);
    expect(calls.first, 'full');
    expect(calls.skip(1), everyElement('check'));
    expect(calls.length, greaterThanOrEqualTo(3));
    expect(reloads, 0, reason: '没有待办时不刷新首页');
  });

  test('an applied check reloads the home page', () async {
    pendingResult = _oneApplied;
    await scheduler.start();
    await wait(tick * 1.6);
    expect(calls, ['full', 'check']);
    expect(reloads, 1);
  });

  test('background stops the timer; coming back syncs at once', () async {
    await scheduler.start();
    lifecycle(AppLifecycleState.inactive);
    lifecycle(AppLifecycleState.hidden);
    lifecycle(AppLifecycleState.paused);
    expect(scheduler.isTicking, isFalse);
    await wait(tick * 3);
    expect(calls, ['full'], reason: '后台不拉');

    lifecycle(AppLifecycleState.resumed);
    await wait(const Duration(milliseconds: 5));
    expect(calls, ['full', 'full']);
    expect(scheduler.isTicking, isTrue);
  });

  test('a slow batch is never overlapped by the next tick', () async {
    gate = Completer<void>();
    await scheduler.start();
    await wait(tick * 4);
    expect(calls, ['full', 'check'], reason: '处理中不再发下一次检查');
    gate!.complete();
    gate = null;
    await wait(tick * 1.6);
    expect(calls.length, greaterThanOrEqualTo(3));
  });

  test('switched off: no network, and switching on takes effect', () async {
    autoSync = false;
    await scheduler.start();
    await wait(tick * 2.5);
    expect(calls, isEmpty);
    autoSync = true;
    await wait(tick * 1.6);
    expect(calls, contains('check'));
  });

  test('a failing sync keeps the timer alive', () async {
    var failures = 0;
    scheduler.dispose();
    scheduler = SyncScheduler(
      interval: tick,
      onApplied: (_) async {},
      loadSettings: () async => _settings(),
      fullSync: (_) async => throw const SocketExceptionLike(),
      checkPending: (_) async {
        failures++;
        throw const SocketExceptionLike();
      },
    );
    await scheduler.start();
    await wait(tick * 2.6);
    expect(failures, greaterThanOrEqualTo(2));
    expect(scheduler.isTicking, isTrue);
  });
}

class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}
