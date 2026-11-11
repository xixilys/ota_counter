import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/pages/sync_page.dart';
import 'package:ota_counter/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('sync page saves URL, token and auto flag', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const SyncPage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MCP 同步'), findsOneWidget);
    expect(find.text('一键同步'), findsOneWidget);
    expect(find.text('连接设置'), findsOneWidget);

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), '192.168.1.20:8787');
    await tester.enterText(fields.at(1), 'test-token');
    await tester.tap(find.byType(Switch).first);
    await tester.pump();

    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('mcp_sync_base_url'), '192.168.1.20:8787');
    expect(prefs.getString('mcp_sync_token'), 'test-token');
    expect(prefs.getBool('mcp_sync_auto'), isTrue);
    expect(tester.takeException(), isNull);
  });
}
