import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/secret_store.dart';
import '../models/codex/codex_oauth.dart' show codexState;
import 'crm_login_stub.dart'
    if (dart.library.io) 'crm_login_io.dart'
    as platform;

import 'sharecrm_cli_stub.dart'
    if (dart.library.io) 'sharecrm_cli_io.dart'
    as sharecrm;

enum CrmProduct {
  neocrm('neo'),
  salesforce('sf'),
  fxiaoke('sharecrm'),
  custom(null);

  const CrmProduct(this.cliCommand);

  final String? cliCommand;
}

enum CrmAuth { browser, clientCredentials, neoCli }

class CrmConnector {
  CrmConnector(Map<String, String> fields) : fields = Map.unmodifiable(fields);

  final Map<String, String> fields;
  String get id => this['id'];
  String get name => this['name'];
  CrmProduct get product => CrmProduct.values.byName(this['product']);
  bool get supportsChat =>
      product == CrmProduct.salesforce ||
      (product == CrmProduct.fxiaoke && hasSharecrmSession) ||
      (product == CrmProduct.neocrm && this['auth'] == CrmAuth.neoCli.name);

  bool get hasSharecrmSession =>
      this['sharecrmUser'].isNotEmpty && this['sharecrmApp'].isNotEmpty;

  bool get authorized {
    if (product == CrmProduct.fxiaoke && hasSharecrmSession) return true;
    final expiry = DateTime.tryParse(this['expiresAt']);
    return this['accessToken'].isNotEmpty &&
        (expiry == null || expiry.isAfter(DateTime.now()));
  }

  CrmAuth get auth => CrmAuth.values.byName(this['auth']);
  String operator [](String key) => fields[key] ?? '';

  CrmConnector withSession(Map<String, String> session) => CrmConnector({
    ...fields,
    'accessToken': '',
    'refreshToken': '',
    'expiresAt': '',
    'instanceUrl': '',
    'sessionTokenUrl': '',
    'tenantId': '',
    ...session,
  });
}

class CrmConnectors {
  CrmConnectors({SecretStore? secrets})
    : _secrets = secrets ?? SecretStore.instance;

  static List<({String id, String name, String host, DateTime? expires})>
  _chatChoices = const [];

  static Iterable<({String id, String name, String host, DateTime? expires})>
  get chatChoices {
    final now = DateTime.now();
    return _chatChoices.where((entry) => entry.expires?.isAfter(now) ?? true);
  }

  static void _updateChatChoices(List<CrmConnector> connectors) {
    _chatChoices = [
      for (final item in connectors)
        if (item.supportsChat && item.authorized)
          (
            id: item.id,
            name: item.name,
            host: httpsUrl(item['baseUrl'])?.host ?? '',
            expires: item.hasSharecrmSession
                ? null
                : DateTime.tryParse(item['expiresAt']),
          ),
    ];
  }

  static const _legacyKey = 'crm.connectors.v1';
  static const _storeKey = 'crm.connectors.v2';
  static const _chunkSize = 900;
  final SecretStore _secrets;

  static Future<void> _pending = Future.value();

  Future<T> _serialize<T>(Future<T> Function() action) {
    final operation = _pending.then((_) => action());
    _pending = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<List<CrmConnector>> load() => _serialize(() async {
    final index = await _secrets.read(_storeKey);
    final List<dynamic> profiles;
    if (index != null) {
      final keys = _chunkKeys(index);
      final encoded = StringBuffer();
      for (final key in keys) {
        final chunk = await _secrets.read(key);
        if (chunk == null) {
          throw const FormatException('Missing CRM credential chunk');
        }
        encoded.write(chunk);
      }
      profiles =
          jsonDecode(utf8.decode(base64Decode(encoded.toString()))) as List;
    } else {
      final stored = await _secrets.read(_legacyKey);
      profiles = stored == null ? [] : _decodeLegacyProfiles(stored);
    }
    final connectors = [
      for (final entry in profiles)
        CrmConnector(Map<String, String>.from(entry as Map)),
    ];
    _updateChatChoices(connectors);
    return connectors;
  });

  List<String> _chunkKeys(String index) {
    final parts = index.split(':');
    final count = parts.length == 2 ? int.tryParse(parts[1]) : null;
    if (count == null ||
        count < 1 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(parts.first)) {
      throw const FormatException('Invalid CRM credentials index');
    }
    return List.generate(count, (i) => '$_storeKey.${parts.first}.$i');
  }

  List<dynamic> _decodeLegacyProfiles(String stored) {
    var json = stored.trim();
    // macOS security returns password bytes as hex for some non-ASCII values.
    if (json.length.isEven && RegExp(r'^[0-9a-fA-F]+$').hasMatch(json)) {
      json = utf8.decode([
        for (var i = 0; i < json.length; i += 2)
          int.parse(json.substring(i, i + 2), radix: 16),
      ], allowMalformed: true);
    }
    try {
      return jsonDecode(json) as List;
    } on FormatException {
      // The original writer could truncate its command at the macOS limit.
      // Parse only complete JSON string fields at the start of each profile.
      if (!json.startsWith('[') || json.endsWith(']')) rethrow;
      final field = RegExp(r'\s*"([A-Za-z]+)"\s*:\s*("(?:[^"\\]|\\.)*")\s*');
      final recovered = <Map<String, String>>[];
      var offset = 1;
      while (offset < json.length && json[offset] == '{') {
        offset++;
        final values = <String, String>{};
        while (offset < json.length) {
          final match = field.matchAsPrefix(json, offset);
          if (match == null) break;
          values[match[1]!] = jsonDecode(match[2]!) as String;
          offset = match.end;
          if (offset >= json.length || json[offset] != ',') break;
          offset++;
        }
        final complete = offset < json.length && json[offset] == '}';
        if (values['id']?.isNotEmpty == true &&
            values['name']?.isNotEmpty == true &&
            httpsUrl(values['baseUrl'] ?? '') != null &&
            CrmProduct.values.any((p) => p.name == values['product']) &&
            CrmAuth.values.any((a) => a.name == values['auth'])) {
          recovered.add(
            complete ? values : CrmConnector(values).withSession({}).fields,
          );
        }
        if (!complete || ++offset >= json.length || json[offset] != ',') break;
        offset++;
      }
      if (recovered.isEmpty) rethrow;
      return recovered;
    }
  }

  Future<void> save(List<CrmConnector> connectors) => _serialize(() async {
    final previous = await _secrets.read(_storeKey);
    final encoded = base64Encode(
      utf8.encode(
        jsonEncode([for (final connector in connectors) connector.fields]),
      ),
    );
    final index =
        '${codexState()}:${(encoded.length + _chunkSize - 1) ~/ _chunkSize}';
    final keys = _chunkKeys(index);
    try {
      for (final (i, key) in keys.indexed) {
        final start = i * _chunkSize;
        final end = (start + _chunkSize).clamp(0, encoded.length);
        await _secrets.write(key, encoded.substring(start, end));
      }
      await _secrets.write(_storeKey, index);
    } catch (_) {
      await _forget(keys);
      rethrow;
    }
    _updateChatChoices(connectors);
    await _forget([if (previous != null) ..._chunkKeys(previous), _legacyKey]);
  });

  Future<void> _forget(List<String> keys) async {
    for (final key in keys) {
      try {
        await _secrets.delete(key);
      } on Object {
        // The new index is already committed.
      }
    }
  }

  Future<CrmConnector> authorizeSharecrm(
    CrmConnector connector,
    void Function(String) showCode,
  ) async {
    final session = await sharecrm.sharecrmCommand(
      connector,
      const [],
      showCode: showCode,
    );
    return CrmConnector({
      ...connector.fields,
      ...session.cast<String, String>(),
    });
  }

  Future<String?> cliVersion(CrmProduct product) {
    final command = product.cliCommand;
    return command == null
        ? Future.value(null)
        : platform.crmCliVersion(command);
  }

  static Uri? httpsUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty &&
            !uri.hasFragment
        ? uri
        : null;
  }

  Future<CrmConnector> connect(
    CrmConnector connector, {
    bool refresh = false,
  }) async {
    if (connector.auth == CrmAuth.neoCli) {
      return connector.withSession(await platform.crmNeoCliSession(connector));
    }
    final isFx = connector.product == CrmProduct.fxiaoke;
    final useRefresh = refresh && connector['refreshToken'].isNotEmpty;
    final useBrowser =
        !isFx && !useRefresh && connector.auth == CrmAuth.browser;
    final tokenUrl = httpsUrl(connector['tokenUrl'])!;
    final endpoint = isFx
        ? tokenUrl.replace(
            queryParameters: {
              ...tokenUrl.queryParameters,
              'thirdTraceId': codexState(),
            },
          )
        : tokenUrl;
    final Map<String, String> code;
    if (useBrowser) {
      code = await platform.crmBrowserCode(connector);
    } else {
      code = const {};
    }
    final secret = connector['clientSecret'];
    final form = {
      'client_id': connector['clientId'],
      if (secret.isNotEmpty) 'client_secret': secret,
      if (useRefresh) ...{
        'grant_type': 'refresh_token',
        'refresh_token': connector['refreshToken'],
      } else if (useBrowser) ...{
        'grant_type': 'authorization_code',
        ...code,
      } else ...{
        'grant_type': 'client_credentials',
        if (connector['scope'].isNotEmpty) 'scope': connector['scope'],
      },
    };
    final client = http.Client();
    try {
      final request = http.Request('POST', endpoint)..followRedirects = false;
      if (isFx) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode({
          'appId': connector['clientId'],
          'appSecret': secret,
          'permanentCode': connector['permanentCode'],
          'grantType': 'app_secret',
        });
      } else {
        request.bodyFields = form;
      }
      final response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CrmHttpException(response.statusCode);
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final access = data[isFx ? 'accessToken' : 'access_token'];
      if (access is! String ||
          access.isEmpty ||
          (isFx && data['errorCode'].toString() != '0')) {
        throw const FormatException('Token missing');
      }
      final expires = int.tryParse(
        data[isFx ? 'expiresIn' : 'expires_in'].toString(),
      );
      return connector.withSession({
        'accessToken': access,
        if (data['instance_url'] case final String instance
            when httpsUrl(instance) != null)
          'instanceUrl': instance,
        'refreshToken':
            data['refresh_token'] as String? ??
            (useRefresh ? connector['refreshToken'] : ''),
        if (expires != null && expires > 0)
          'expiresAt': DateTime.now()
              .add(Duration(seconds: expires))
              .toIso8601String(),
      });
    } finally {
      client.close();
    }
  }

  Future<int> test(CrmConnector connector) async {
    final origin = httpsUrl(connector['baseUrl'])!;
    final checkPath = connector['checkPath'];
    final authenticated =
        checkPath.isNotEmpty && connector['accessToken'].isNotEmpty;
    final checkUrl = authenticated ? crmCheckUrl(origin, checkPath)! : origin;
    final client = http.Client();
    final watch = Stopwatch()..start();
    try {
      final request = http.Request(authenticated ? 'GET' : 'HEAD', checkUrl)
        ..followRedirects = false;
      if (authenticated) {
        request.headers['Authorization'] = "Bearer ${connector['accessToken']}";
      }
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 15));
      await response.stream.drain<void>().timeout(const Duration(seconds: 15));
      if (authenticated
          ? response.statusCode < 200 || response.statusCode >= 300
          : response.statusCode >= 500) {
        throw CrmHttpException(response.statusCode);
      }
      return watch.elapsedMilliseconds;
    } finally {
      client.close();
    }
  }
}

class CrmHttpException implements Exception {
  const CrmHttpException(this.status);
  final int status;
}

Uri? crmLoopbackUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
          uri.scheme == 'http' &&
          const {'localhost', '127.0.0.1'}.contains(uri.host) &&
          uri.hasPort &&
          uri.port > 0 &&
          uri.userInfo.isEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment
      ? uri
      : null;
}

Uri? crmCheckUrl(Uri base, String path) {
  final relative = Uri.tryParse(path);
  if (relative == null ||
      !path.startsWith('/') ||
      relative.hasAuthority ||
      relative.hasFragment ||
      path.contains(r'\')) {
    return null;
  }
  final resolved = base.resolveUri(relative);
  return resolved.origin == base.origin ? resolved : null;
}

const neoSandboxUrl = 'https://crm-sandbox.xiaoshouyi.com';

/// The source connector accepts either a CRM instance or its login hostname.
Uri neoInstance(Uri uri) =>
    uri.host.startsWith(RegExp(r'login[.-]')) &&
        uri.host.endsWith('.xiaoshouyi.com')
    ? uri.replace(host: uri.host.replaceFirst('login', 'crm'))
    : uri;

Uri neoLoginOrigin(Uri instance) => Uri.parse(instance.origin).replace(
  host: instance.host.startsWith('crm')
      ? instance.host.replaceFirst('crm', 'login')
      : instance.host,
);

class CrmNeoCliUnavailable implements Exception {
  const CrmNeoCliUnavailable();
}
