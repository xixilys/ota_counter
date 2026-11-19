import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/merch_purchase_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/merch_service.dart';
import 'package:ota_counter/services/sync_service.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await useIsolatedTestDatabases();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'OTA Counter',
      packageName: 'top.huangxuanqi.otacounter',
      version: '1.6.2',
      buildNumber: '27',
      buildSignature: '',
    );
    await DatabaseService.clearAppData();
  });

  tearDown(() async {
    await DatabaseService.clearAppData();
  });

  test('preset kinds seed once and custom kinds stay distinct', () async {
    final kinds = await MerchService.getKinds();
    expect(
        kinds.map((kind) => kind.name),
        containsAll([
          '生写真',
          '吧唧',
          '亚克力立牌',
          '应援棒',
          '其他',
        ]));
    expect(kinds.where((kind) => kind.isPreset),
        hasLength(MerchService.presetKinds.length));

    final customId = await MerchService.addCustomKind('应援扇');
    final custom = (await MerchService.getKinds())
        .singleWhere((kind) => kind.name == '应援扇');
    expect(custom.id, customId);
    expect(custom.isPreset, isFalse);

    final again = await MerchService.addCustomKind('应援扇');
    expect(again, customId);
    expect(
      () => MerchService.addCustomKind('生写真'),
      throwsA(isA<StateError>()),
    );
    await MerchService.deleteKind(customId);
    expect(
      (await MerchService.getKinds()).where((kind) => kind.name == '应援扇'),
      isEmpty,
    );
    final presetId = (await MerchService.getKinds()).first.id!;
    expect(
      () => MerchService.deleteKind(presetId),
      throwsA(isA<StateError>()),
    );
  });

  test('purchases aggregate by kind, member and month', () async {
    final first = await MerchService.savePurchase(
      MerchPurchaseModel.purchase(
        kind: '生写真',
        memberName: '林小满',
        groupName: 'Aurora',
        eventName: '定期公演',
        quantity: 2,
        unitPrice: 30,
        occurredAt: DateTime(2026, 3, 5),
      ),
    );
    final second = await MerchService.savePurchase(
      MerchPurchaseModel.purchase(
        kind: '吧唧',
        quantity: 3,
        unitPrice: 15,
        occurredAt: DateTime(2026, 3, 20),
      ),
    );
    final third = await MerchService.savePurchase(
      MerchPurchaseModel.purchase(
        kind: '生写真',
        memberName: '林小满',
        groupName: 'Aurora',
        quantity: 1,
        unitPrice: 50,
        occurredAt: DateTime(2026, 2, 10),
      ),
    );
    expect(first, greaterThan(0));
    expect(second, greaterThan(0));
    expect(third, greaterThan(0));

    final purchases = await MerchService.getPurchases();
    expect(purchases, hasLength(3));
    expect(purchases.first.occurredAt.month, 3);

    final stats = await MerchService.getStats();
    expect(stats.purchaseCount, 3);
    expect(stats.itemCount, 6);
    expect(stats.amount, 155);
    expect(stats.amountByKind['生写真'], 110);
    expect(stats.countByKind['生写真'], 3);
    expect(stats.amountByKind['吧唧'], 45);
    expect(stats.amountByMember['林小满'], 110);
    expect(stats.countByMember['未关联成员'], 3);
    expect(stats.amountByMonth['2026-03'], 105);
    expect(stats.countByMonth['2026-03'], 5);
    expect(stats.amountByMonth['2026-02'], 50);

    final march = await MerchService.getStats(
      from: DateTime(2026, 3, 1),
      to: DateTime(2026, 3, 31),
    );
    expect(march.purchaseCount, 2);
    expect(march.amount, 105);
    expect(
      (await MerchService.getPurchases(
        from: DateTime(2026, 3, 1),
        to: DateTime(2026, 3, 10),
      ))
          .single
          .kind,
      '生写真',
    );

    final learned = (await MerchService.getKinds())
        .singleWhere((kind) => kind.name == '生写真');
    expect(learned.defaultPrice, 30);
  });

  test('total overrides unit price and updates keep the ledger coherent',
      () async {
    final id = await MerchService.savePurchase(
      MerchPurchaseModel.purchase(
        kind: '盲盒',
        quantity: 3,
        unitPrice: 20,
        totalAmount: 55,
        occurredAt: DateTime(2026, 3, 8),
      ),
    );
    final saved = (await MerchService.getPurchases()).single;
    expect(saved.totalAmount, 55);
    expect(saved.unitPrice, 20);

    await MerchService.savePurchase(
      saved.copyWith(note: '抽到隐藏款', quantity: 2, totalAmount: 40),
    );
    final updated = (await MerchService.getPurchases()).single;
    expect(updated.id, id);
    expect(updated.note, '抽到隐藏款');
    expect(updated.quantity, 2);
    expect(updated.resolvedTotalAmount, 40);
  });

  test('delete removes the purchase and its photo file', () async {
    final directory = await Directory.systemTemp.createTemp('merch_photo_test');
    final photo = File('${directory.path}/photo.jpg');
    await photo.writeAsBytes([1, 2, 3]);
    try {
      final id = await MerchService.savePurchase(
        MerchPurchaseModel.purchase(
          kind: '生写真',
          photoPath: photo.path,
          occurredAt: DateTime(2026, 3, 8),
        ),
      );
      expect(await photo.exists(), isTrue);
      await MerchService.deletePurchase(id);
      expect(await photo.exists(), isFalse);
      expect(await MerchService.getPurchases(), isEmpty);
    } finally {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });

  test('sync snapshot carries a safe merch summary, not fake records',
      () async {
    await MerchService.savePurchase(
      MerchPurchaseModel.purchase(
        kind: '应援棒',
        memberName: '苏晚晴',
        groupName: 'Aurora',
        quantity: 1,
        unitPrice: 75,
        occurredAt: DateTime(2026, 3, 8),
      ),
    );
    final snapshot = await SyncService.buildSnapshot(
      const SyncSettings(
        baseUrl: 'http://localhost',
        token: 'test',
        deviceId: 'test-device',
        autoSync: false,
        lastSyncAt: '',
      ),
    );
    final merch = snapshot['merch'] as Map;
    expect(merch['purchase_count'], 1);
    expect(merch['item_count'], 1);
    expect(merch['amount'], 75);
    expect((merch['by_kind'] as Map)['应援棒'], 75);
    expect(snapshot['records'], isEmpty);
    expect(snapshot['summary']['total_count'], 0);
  });
}
