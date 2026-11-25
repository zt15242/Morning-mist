import 'dart:io';

import 'package:baocode/crm/crm_connectors.dart';
import 'package:baocode/crm/crm_login_io.dart';
import 'package:baocode/models/codex/codex_oauth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  test(
    'browser OAuth binds to loopback and verifies callback state',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = reservation.port;
      await reservation.close();
      final redirect = Uri.parse('http://127.0.0.1:$port/callback');
      String? challenge;
      final code = await crmBrowserCode(
        CrmConnector({
          'product': CrmProduct.neocrm.name,
          'clientId': 'demo-client',
          'authorizeUrl': 'https://crm.example/authorize',
          'redirectUri': redirect.toString(),
        }),
        open: (target) async {
          final query = Uri.parse(target).queryParameters;
          expect(query['client_id'], 'demo-client');
          expect(query['code_challenge_method'], 'S256');
          challenge = query['code_challenge'];
          final rejected = await http.get(
            redirect.replace(
              queryParameters: {
                'state': 'not-the-state',
                'code': 'rejected-code',
              },
            ),
          );
          expect(rejected.statusCode, 400);
          final accepted = await http.get(
            redirect.replace(
              queryParameters: {
                'state': query['state']!,
                'code': 'correct-code',
              },
            ),
          );
          expect(accepted.statusCode, 200);
          return true;
        },
      );
      expect(code['code'], 'correct-code');
      expect(CodexPkce.challengeOf(code['code_verifier']!), challenge);
    }, _LoopbackHttpOverrides()),
  );
}
