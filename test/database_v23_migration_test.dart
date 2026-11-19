import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/merch_purchase_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/merch_service.dart';
import 'package:ota_counter/services/ticket_pricing_service.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await useIsolatedTestDatabases();
  });

  test('v22 -> v23 adds the merch ledger without touching existing data',
      () async {
    final path = p.join(await getDatabasesPath(), 'counter_app.db');
    final old = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 22,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE counters(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              group_name TEXT NOT NULL DEFAULT '',
              person_id INTEGER,
              person_name TEXT NOT NULL DEFAULT '',
              count INTEGER NOT NULL,
              color TEXT NOT NULL,
              is_hidden INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await db.execute('''
            CREATE TABLE activity_records(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              record_type TEXT NOT NULL,
              source TEXT NOT NULL DEFAULT 'local',
              source_record_id TEXT,
              counter_id INTEGER,
              person_id INTEGER,
              group_name TEXT NOT NULL DEFAULT '',
              subject_name TEXT NOT NULL,
              occurred_at TEXT NOT NULL,
              ticket_quantity INTEGER NOT NULL DEFAULT 0,
              ticket_unit_price REAL NOT NULL DEFAULT 0,
              total_amount REAL NOT NULL DEFAULT 0,
              ticket_type TEXT NOT NULL DEFAULT '',
              ticket_is_free INTEGER
            )
          ''');
          await db.execute('''
            CREATE TABLE ticket_types(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL UNIQUE,
              default_price REAL NOT NULL DEFAULT 0,
              is_free INTEGER NOT NULL DEFAULT 0,
              sort_order INTEGER NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL
            )
          ''');
          await db.insert('ticket_types', {
            'name': '自定义票',
            'default_price': 66,
            'is_free': 0,
            'sort_order': 99,
            'updated_at': '2026-01-01T00:00:00.000',
          });
          await db.insert('counters', {
            'id': 7,
            'name': '测试成员',
            'group_name': '测试团',
            'count': 3,
            'color': '#ffffff',
          });
          await db.insert('activity_records', {
            'id': 11,
            'record_type': 'ticket',
            'subject_name': '历史门票',
            'occurred_at': '2026-03-15T00:00:00.000',
            'ticket_quantity': 2,
            'ticket_unit_price': 86,
            'total_amount': 172,
            'ticket_type': '',
          });
        },
      ),
    );
    await old.close();

    final db = await DatabaseService.database;
    expect(await db.getVersion(), 23);
    expect((await db.query('counters')).single['name'], '测试成员');
    // v23 also carries the per-member card short name.
    expect(
      (await db.query('counters')).single['short_name'],
      '',
    );
    final ticket = (await db.query('activity_records')).single;
    expect(ticket['subject_name'], '历史门票');
    expect(ticket['ticket_type'], '');
    expect(ticket['ticket_quantity'], 2);

    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final names = tables.map((row) => row['name']).toSet();
    expect(names, contains(DatabaseService.merchKindTableName));
    expect(names, contains(DatabaseService.merchPurchaseTableName));

    final columns = await db.rawQuery(
      'PRAGMA table_info(${DatabaseService.merchPurchaseTableName})',
    );
    expect(
      columns.map((row) => row['name']),
      containsAll([
        'kind',
        'member_name',
        'group_name',
        'event_name',
        'quantity',
        'unit_price',
        'total_amount',
        'photo_path',
        'occurred_at',
      ]),
    );

    final id = await MerchService.savePurchase(
      MerchPurchaseModel.purchase(
        kind: '生写真',
        memberName: '测试成员',
        quantity: 1,
        unitPrice: 30,
        occurredAt: DateTime(2026, 3, 20),
      ),
    );
    expect(id, greaterThan(0));
    final stats = await MerchService.getStats();
    expect(stats.purchaseCount, 1);
    expect(stats.amount, 30);
    final kinds = await MerchService.getKinds();
    expect(kinds.map((kind) => kind.name), contains('生写真'));

    final counterWithShortName = CounterModel(
      id: 7,
      name: '测试成员',
      groupName: '测试团',
      color: '#ffffff',
      shortName: '测',
    );
    await DatabaseService.updateCounter(7, counterWithShortName);
    final saved = await DatabaseService.getCounters();
    expect(saved.single.shortName, '测');
    expect(saved.single.displayShortName, '测');

    final ticketTypes = await TicketPricingService.getTicketTypes();
    final typeNames = ticketTypes.map((type) => type.name).toSet();
    expect(
      typeNames,
      containsAll(['早鸟票', '双人票', '通票', '自定义票']),
    );
    // A type the user deleted before the update must not come back.
    expect(typeNames, isNot(contains('VIP票')));
    expect(
      ticketTypes.singleWhere((type) => type.name == '自定义票').defaultPrice,
      66,
    );
  });
}
