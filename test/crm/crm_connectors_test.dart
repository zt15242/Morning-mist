import 'dart:convert';

import 'package:baocode/crm/crm_connectors.dart';
import 'package:baocode/models/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

CrmConnector connector(CrmProduct product) => CrmConnector({
  'id': 'crm',
  'name': 'Sandbox',
  'product': product.name,
  'auth': CrmAuth.clientCredentials.name,
  'baseUrl': 'https://crm.example/',
  'tokenUrl': 'https://auth.example/token',
  'clientId': 'client',
  'clientSecret': 'local-secret',
  'permanentCode': 'company-code',
});

void main() {
  test('recovers truncated profiles, then saves long credentials in chunks', () async {
    final first = connector(CrmProduct.neocrm)
        .withSession({'accessToken': 'first-token'});
    final partial = {
      ...connector(CrmProduct.neocrm).fields,
      'id': 'second',
      'name': '润丰UAT模拟',
    };
    final legacy =
        '[${jsonEncode(first.fields)},${jsonEncode(partial).substring(0, jsonEncode(partial).length - 1)},"accessToken":"truncated';
    final secrets = MemorySecretStore({'crm.connectors.v1': legacy});
    final store = CrmConnectors(secrets: secrets);
    final recovered = await store.load();
    expect(recovered.first['accessToken'], 'first-token');
    expect(recovered.last.name, '润丰UAT模拟');
    expect(recovered.last['accessToken'], isEmpty);
    final authorized = recovered.last.withSession({'accessToken': 'x' * 5000});
    await store.save([recovered.first, authorized]);
    expect((await store.load()).last.fields, authorized.fields);
    expect(await secrets.read('crm.connectors.v1'), isNull);
  });

  test('reads localized profiles from macOS keychain hex output', () async {
    final fields = {...connector(CrmProduct.neocrm).fields, 'name': 'PAV模拟'};
    final hex = utf8
        .encode(jsonEncode([fields]))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    final store = CrmConnectors(
      secrets: MemorySecretStore({'crm.connectors.v1': '$hex\n'}),
    );
    expect((await store.load()).single.fields, fields);
  });

  test(
    'keeps multiple profiles and clears only the selected session',
    () async {
      final store = CrmConnectors(secrets: MemorySecretStore());
      final sf = connector(CrmProduct.salesforce).withSession({
        'accessToken': 'previous-token',
        'refreshToken': 'refresh-token',
        'expiresAt': '2026-11-30T12:00:00Z',
      });
      final fx = CrmConnector({
        ...connector(CrmProduct.fxiaoke).fields,
        'id': 'fx',
      });
      await store.save([sf, fx]);
      final saved = await store.load();
      expect(saved.map((item) => item.id), ['crm', 'fx']);
      expect(saved.first['accessToken'], 'previous-token');
      await store.save([saved.first.withSession({}), saved.last]);
      final disconnected = await store.load();
      expect(disconnected.first['accessToken'], isEmpty);
      expect(disconnected.first['refreshToken'], isEmpty);
      expect(disconnected.last['permanentCode'], 'company-code');
    },
  );

  test(
    'FxiaoKe exchanges application credentials with its JSON contract',
    () async {
      final store = CrmConnectors(secrets: MemorySecretStore());
      final connected = await http.runWithClient(
        () => store.connect(connector(CrmProduct.fxiaoke)),
        () => MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.followRedirects, isFalse);
          expect(request.url.queryParameters['thirdTraceId'], isNotEmpty);
          expect(jsonDecode(request.body), {
            'appId': 'client',
            'appSecret': 'local-secret',
            'permanentCode': 'company-code',
            'grantType': 'app_secret',
          });
          return http.Response(
            '{"errorCode":0,"accessToken":"fx-access","expiresIn":7200}',
            200,
          );
        }),
      );
      expect(connected['accessToken'], 'fx-access');
      expect(
        DateTime.parse(connected['expiresAt']).isAfter(DateTime.now()),
        isTrue,
      );
    },
  );

  test(
    'OAuth refresh retains an existing refresh token when omitted',
    () async {
      final store = CrmConnectors(secrets: MemorySecretStore());
      final original = connector(CrmProduct.neocrm).withSession({
        'accessToken': 'old-access',
        'refreshToken': 'old-refresh',
      });
      final connected = await http.runWithClient(
        () => store.connect(original, refresh: true),
        () => MockClient((request) async {
          expect(request.followRedirects, isFalse);
          expect(request.bodyFields, {
            'client_id': 'client',
            'client_secret': 'local-secret',
            'grant_type': 'refresh_token',
            'refresh_token': 'old-refresh',
          });
          return http.Response('{"access_token":"new-access"}', 200);
        }),
      );
      expect(connected['accessToken'], 'new-access');
      expect(connected['refreshToken'], 'old-refresh');
    },
  );

  test('only accepts HTTPS endpoints and local OAuth callbacks', () {
    expect(CrmConnectors.httpsUrl('https://user@crm.example'), isNull);
    expect(CrmConnectors.httpsUrl('http://crm.example'), isNull);
    expect(crmLoopbackUrl('http://crm.example:1028'), isNull);
    expect(crmLoopbackUrl('http://localhost:1028/callback')?.port, 1028);
  });
}
