import 'dart:convert';

import 'package:baocode/channel/account/account_api.dart';
import 'package:baocode/link/mobile_account_client.dart';
import 'package:bao_link/bao_link.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/ed25519.dart';

void main() {
  test(
    'registers the Link identity and signs account pairings as its device',
    () async {
      final identity = LinkIdentity.generate();
      const userId = 'mobile-user-id';
      const serviceDeviceId = '82d586bf-aadd-4a49-b4a0-4cb02388a020';
      const pairingId = '07e7cffe-041c-4e2a-b846-e6f0a14e8505';
      var exchangeCount = 0;
      var meCount = 0;
      final requests =
          <
            ({
              String method,
              String path,
              String? token,
              Map<String, String> headers,
              Object? json,
            })
          >[];
      final publicKey = VerifyKey(identity.publicKey);
      final client = MobileAccountClient(
        identity: identity,
        request:
            (
              method,
              path, {
              mobileAccountToken,
              headers = const {},
              json,
            }) async {
              requests.add((
                method: method,
                path: path,
                token: mobileAccountToken,
                headers: headers,
                json: json,
              ));
              if (path == '/exchange') {
                exchangeCount++;
                return AccountResponse(200, {
                  'access_token': 'scoped-session',
                  'expires_at':
                      DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
                });
              }
              if (path == '/me' && meCount++ == 0) {
                return const AccountResponse(401, {'detail': 'expired'});
              }
              if (path == '/me') {
                return const AccountResponse(200, {'user_id': userId});
              }
              if (path == '/devices/challenges') {
                return const AccountResponse(200, {
                  'challenge_id': 'enroll-1',
                  'challenge': 'random-challenge',
                });
              }
              if (path == '/devices') {
                final body = json! as Map<String, Object?>;
                final proof = utf8.encode(
                  [
                    'morning-mist-device-register-v1',
                    body['challenge_id'],
                    'random-challenge',
                    userId,
                    'desktop',
                    body['public_key'],
                  ].join('\n'),
                );
                expect(
                  publicKey.verify(
                    signature: Signature(
                      decodeKey(body['signature']! as String),
                    ),
                    message: proof,
                  ),
                  isTrue,
                );
                return const AccountResponse(201, {'id': serviceDeviceId});
              }
              if (path.startsWith('/pairings?')) {
                final timestamp = headers['X-Device-Timestamp']!;
                final nonce = headers['X-Device-Nonce']!;
                final canonical = utf8.encode(
                  [
                    'GET',
                    '/v1/pairings',
                    timestamp,
                    nonce,
                    sha256.convert(const <int>[]).toString(),
                  ].join('\n'),
                );
                expect(headers['X-Device-ID'], serviceDeviceId);
                expect(requests.last.token, 'scoped-session');
                expect(
                  publicKey.verify(
                    signature: Signature(
                      decodeKey(headers['X-Device-Signature']!),
                    ),
                    message: canonical,
                  ),
                  isTrue,
                );
                return const AccountResponse(200, {
                  'pairings': [
                    {
                      'id': pairingId,
                      'desktop_id': serviceDeviceId,
                      'phone_id': 'phone-service-id',
                      'status': 'pending',
                    },
                  ],
                });
              }
              if (path == '/pairings/$pairingId/approve') {
                final body = jsonEncode(json);
                final timestamp = headers['X-Device-Timestamp']!;
                final nonce = headers['X-Device-Nonce']!;
                final canonical = utf8.encode(
                  [
                    'POST',
                    '/v1/pairings/$pairingId/approve',
                    timestamp,
                    nonce,
                    sha256.convert(utf8.encode(body)).toString(),
                  ].join('\n'),
                );
                expect(headers['X-Device-ID'], serviceDeviceId);
                expect(
                  publicKey.verify(
                    signature: Signature(
                      decodeKey(headers['X-Device-Signature']!),
                    ),
                    message: canonical,
                  ),
                  isTrue,
                );
                return const AccountResponse(200, {'status': 'approved'});
              }
              return const AccountResponse(404, null);
            },
      );

      final registration = await client.registerDesktop(
        device: const DeviceInfo(
          name: 'Office Mac',
          kind: 'mac',
          system: 'macOS 27',
          relays: ['https://relay.example'],
          addrs: ['192.168.1.2:47100'],
        ),
      );
      expect(registration.userId, userId);
      expect(registration.deviceId, serviceDeviceId);
      expect(exchangeCount, 2, reason: 'an expired mobile session is renewed');
      expect(requests.first.path, '/exchange');
      expect(requests[1].token, 'scoped-session');

      final pairings = await client.pairings(serviceDeviceId);
      expect(pairings.single['id'], pairingId);
      expect(requests.last.path, '/pairings?device_id=$serviceDeviceId');
      await client.decidePairing(
        deviceId: serviceDeviceId,
        pairingId: pairingId,
        approve: true,
      );
      expect(requests.last.path, '/pairings/$pairingId/approve');
    },
  );
}
