import 'package:baocode/crm/crm_chat_tool.dart';
import 'package:baocode/crm/crm_connectors.dart';
import 'package:baocode/models/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CRM chat requires a selected CLI-compatible authorization', () async {
    final store = CrmConnectors(secrets: MemorySecretStore());
    await store.save([
      for (final auth in [CrmAuth.browser, CrmAuth.neoCli])
        CrmConnector({
          'id': auth.name,
          'name': auth.name,
          'auth': auth.name,
          'baseUrl': 'https://example.test',
          'product': CrmProduct.neocrm.name,
          'accessToken': 'fixture-token',
        }),
    ]);
    expect(CrmConnectors.chatChoices.map((choice) => choice.id), ['neoCli']);
    await expectLater(
      CrmChatTool.read({}, connectorIds: [], store: store),
      throwsStateError,
    );
    await expectLater(
      CrmChatTool.read({}, connectorIds: ['browser'], store: store),
      throwsStateError,
    );
    await expectLater(
      CrmChatTool.read(
        {'connection': 2},
        connectorIds: ['neoCli'],
        store: store,
      ),
      throwsArgumentError,
    );
    await expectLater(
      CrmChatTool.read(
        {
          'object': 'account',
          'fields': ['name FROM other'],
        },
        connectorIds: ['neoCli'],
        store: store,
        records: true,
      ),
      throwsArgumentError,
    );
  });
}
