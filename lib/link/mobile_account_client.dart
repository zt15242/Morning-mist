import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:crypto/crypto.dart';
import 'package:pinenacl/ed25519.dart';

import '../channel/account/account_api.dart';

typedef MobileAccountRequest = Future<AccountResponse> Function(
  String method,
  String path, {
  String? mobileAccountToken,
  Map<String, String> headers,
  Object? json,
});

/// The desktop's signed client for Sub2API's account-scoped mobile proxy.
/// Sub2API access tokens and the mobile session remain in memory only.
class MobileAccountClient {
  MobileAccountClient({required this.request, required this.identity});

  final MobileAccountRequest request;
  final LinkIdentity identity;

  MobileAccountSession? _session;

  Future<({String userId, String deviceId})> registerDesktop({
    required DeviceInfo device,
  }) async {
    final session = await _sessionToken();
    final me = await _call('GET', '/me', session: session);
    if (me is! Map || me['user_id'] is! String) {
      throw const AccountError('The mobile account service returned no user.');
    }
    final userId = me['user_id'] as String;
    final publicKey = encodeKey(identity.publicKey);
    final role = 'desktop';
    final challengeData = await _call(
      'POST',
      '/devices/challenges',
      session: session,
      json: {'public_key': publicKey, 'role': role},
    );
    if (challengeData is! Map ||
        challengeData['challenge_id'] is! String ||
        challengeData['challenge'] is! String) {
      throw const AccountError('The device enrollment challenge is invalid.');
    }
    final challengeId = challengeData['challenge_id'] as String;
    final challenge = challengeData['challenge'] as String;
    final registrationProof = utf8.encode(
      [
        'morning-mist-device-register-v1',
        challengeId,
        challenge,
        userId,
        role,
        publicKey,
      ].join('\n'),
    );
    final registration = <String, Object?>{
      'public_key': publicKey,
      'role': role,
      'label': device.name.isEmpty ? 'Morning Mist Desktop' : device.name,
      'platform': [
        device.kind,
        device.system,
      ].where((s) => s.isNotEmpty).join(' '),
      'relays': device.relays,
      'addresses': device.addrs,
      'challenge_id': challengeId,
      'signature': encodeKey(_sign(registrationProof)),
    };
    final result = await _call(
      'POST',
      '/devices',
      session: session,
      json: registration,
    );
    if (result is! Map || result['id'] is! String) {
      throw const AccountError('The mobile device was not registered.');
    }
    return (userId: userId, deviceId: result['id'] as String);
  }

  Future<List<Map<String, Object?>>> phoneDevices() async {
    final session = await _sessionToken();
    final data = await _call('GET', '/devices?role=phone', session: session);
    if (data is! Map || data['devices'] is! List) return const [];
    return [
      for (final item in data['devices'] as List)
        if (item is Map<String, Object?>) item,
    ];
  }

  Future<List<Map<String, Object?>>> devices() async {
    final session = await _sessionToken();
    final data = await _call('GET', '/devices', session: session);
    if (data is! Map || data['devices'] is! List) return const [];
    return [
      for (final item in data['devices'] as List)
        if (item is Map<String, Object?>) item,
    ];
  }

  Future<List<Map<String, Object?>>> pairings(String deviceId) async {
    final session = await _sessionToken();
    final data = await _call(
      'GET',
      '/pairings?device_id=${Uri.encodeQueryComponent(deviceId)}',
      session: session,
      signedPath: '/v1/pairings',
      serviceDeviceId: deviceId,
    );
    if (data is! Map || data['pairings'] is! List) return const [];
    return [
      for (final item in data['pairings'] as List)
        if (item is Map<String, Object?>) item,
    ];
  }

  Future<void> decidePairing({
    required String deviceId,
    required String pairingId,
    required bool approve,
  }) async {
    final session = await _sessionToken();
    final action = approve ? 'approve' : 'reject';
    await _call(
      'POST',
      '/pairings/$pairingId/$action',
      session: session,
      json: {'desktop_id': deviceId},
      signedPath: '/v1/pairings/$pairingId/$action',
      serviceDeviceId: deviceId,
    );
  }

  Future<Object?> _call(
    String method,
    String path, {
    required String session,
    Object? json,
    Map<String, String> headers = const {},
    String? signedPath,
    String? serviceDeviceId,
  }) async {
    final body = json == null ? const <int>[] : utf8.encode(jsonEncode(json));
    var activeSession = session;
    AccountResponse response;
    for (var attempt = 0; ; attempt++) {
      final deviceHeaders = _deviceHeaders(
        method,
        signedPath ?? '/v1${path.split('?').first}',
        body,
        serviceDeviceId: serviceDeviceId,
      );
      response = await request(
        method,
        path,
        mobileAccountToken: activeSession,
        headers: {...headers, ...deviceHeaders},
        json: json,
      );
      if (response.status != 401 || attempt > 0) break;
      _session = null;
      activeSession = await _sessionToken();
    }
    if (response.status < 200 || response.status >= 300) {
      final message = switch (response.json) {
        {'detail': final String detail} => detail,
        {'message': final String message} => message,
        _ => 'HTTP ${response.status}',
      };
      throw AccountError('Mobile account service: $message');
    }
    return response.json;
  }

  Map<String, String> _deviceHeaders(
    String method,
    String path,
    List<int> body, {
    String? serviceDeviceId,
  }) {
    final timestamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final nonce = encodeKey(randomBytes(24));
    final bodyHash = sha256.convert(body).toString();
    final canonical = utf8.encode(
      [method.toUpperCase(), path, timestamp, nonce, bodyHash].join('\n'),
    );
    return {
      'X-Device-ID': serviceDeviceId ?? identity.id,
      'X-Device-Timestamp': timestamp,
      'X-Device-Nonce': nonce,
      'X-Device-Signature': encodeKey(_sign(canonical)),
    };
  }

  Uint8List _sign(List<int> message) =>
      SigningKey.fromSeed(Uint8List.fromList(identity.privateKey))
          .sign(Uint8List.fromList(message))
          .signature
          .asTypedList;

  Future<String> _sessionToken() async {
    final session = _session;
    if (session != null &&
        session.expiresAt.isAfter(
          DateTime.now().add(const Duration(seconds: 30)),
        )) {
      return session.token;
    }
    final response = await request('POST', '/exchange', json: const {});
    if (!response.ok || response.json is! Map) {
      throw AccountError(
        'Mobile account sign-in failed (HTTP ${response.status}).',
      );
    }
    final data = response.json! as Map;
    final token = data['access_token'];
    final expires = data['expires_at'];
    if (token is! String || expires is! num) {
      throw const AccountError('The mobile account session is invalid.');
    }
    return (_session = MobileAccountSession(
      token: token,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expires.toInt() * 1000),
    )).token;
  }

  Future<String> get userId async {
    final data = await _call('GET', '/me', session: await _sessionToken());
    if (data case {'user_id': final String id} when id.isNotEmpty) return id;
    throw const AccountError('The mobile account service returned no user.');
  }
}

class MobileAccountSession {
  const MobileAccountSession({required this.token, required this.expiresAt});

  final String token;
  final DateTime expiresAt;
}
