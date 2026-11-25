import 'package:baocode/crm/crm_connectors.dart';
import 'package:baocode/models/secret_store.dart';
import 'package:baocode/settings/pages/crm_connectors_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('creates a connector and preserves it after reopening settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final original = SecretStore.instance;
    final secrets = MemorySecretStore();
    SecretStore.instance = secrets;
    addTearDown(() => SecretStore.instance = original);

    const app = MaterialApp(home: Scaffold(body: CrmConnectorsPage()));
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add connector'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsWidgets);

    Future<void> enter(String label, String value) async {
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, value);
    }

    await enter('Connector name', 'Sales operation sandbox');
    await enter('CRM environment URL', 'https://login-sandbox.xiaoshouyi.com/');
    expect(find.text('Authorization URL'), findsNothing);
    expect(find.text('Client ID'), findsNothing);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Sales operation sandbox'), findsOneWidget);
    expect(find.textContaining('Not authorized'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    expect(find.text('Sales operation sandbox'), findsOneWidget);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await enter('Connector name', 'Renamed sandbox');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Renamed sandbox'), findsOneWidget);
    final connector = (await CrmConnectors(secrets: secrets).load()).single;
    expect(connector.name, 'Renamed sandbox');
    expect(connector.auth, CrmAuth.neoCli);
    expect(connector['baseUrl'], 'https://crm-sandbox.xiaoshouyi.com/');
    expect(
      connector['tokenUrl'],
      'https://login-sandbox.xiaoshouyi.com/auc/oauth2/token',
    );
  });
}
