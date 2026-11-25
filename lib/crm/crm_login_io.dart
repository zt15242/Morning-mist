import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/codex/codex_oauth.dart';
import '../models/codex/loopback_login_io.dart';
import '../workspace/editor_launcher.dart';
import 'crm_connectors.dart';
import 'crm_cli_runtime_io.dart';

Future<Map<String, String>> crmBrowserCode(
  CrmConnector connector, {
  Future<bool> Function(String) open = openExternal,
}) async {
  final redirect = crmLoopbackUrl(connector['redirectUri']);
  if (redirect == null) throw const FormatException('Invalid callback');
  final endpoint = CrmConnectors.httpsUrl(connector['authorizeUrl'])!;
  final scope = connector['scope'].isNotEmpty
      ? connector['scope']
      : switch (connector.product) {
          CrmProduct.neocrm => 'all',
          CrmProduct.salesforce => 'refresh_token api',
          _ => '',
        };
  final state = codexState();
  final pkce = CodexPkce.generate();
  final callback = Completer<String?>();
  final url = endpoint.replace(
    queryParameters: {
      ...endpoint.queryParameters,
      'client_id': connector['clientId'],
      'redirect_uri': redirect.toString(),
      'response_type': 'code',
      'state': state,
      'code_challenge': pkce.challenge,
      'code_challenge_method': 'S256',
      if (scope.isNotEmpty) 'scope': scope,
      if (connector.product == CrmProduct.neocrm) ...{
        'oauthType': 'standard',
        'access_type': 'offline',
      },
    },
  );
  final servers = await bindLoopback(redirect.port);
  if (servers.isEmpty) throw StateError('Callback port unavailable');
  try {
    for (final server in servers) {
      server.listen((request) async {
        final response = request.response;
        final query = request.uri.queryParameters;
        if (request.method != 'GET' ||
            request.uri.path != (redirect.path.isEmpty ? '/' : redirect.path) ||
            query['state'] != state ||
            callback.isCompleted) {
          response.statusCode = 400;
          await response.close();
          return;
        }
        final code = query['code'];
        response.write('Return to Morning Mist to finish connecting.');
        try {
          await response.close();
        } finally {
          if (!callback.isCompleted) callback.complete(code);
        }
      });
    }
    if (!await open(url.toString())) {
      throw StateError('Unable to open authorization URL');
    }
    final code = await callback.future.timeout(const Duration(minutes: 3));
    if (code == null || code.isEmpty) {
      throw StateError('Authorization declined');
    }
    return {
      'code': code,
      'redirect_uri': redirect.toString(),
      'code_verifier': pkce.verifier,
    };
  } finally {
    await Future.wait([
      for (final server in servers) server.close(force: true),
    ]);
  }
}

Future<Map<String, String>> crmNeoCliSession(CrmConnector connector) async {
  final runtime = await crmCliRuntime('neo');
  final executable = runtime.executable;
  final home = runtime.home;
  if (executable == null || home.isEmpty) throw const CrmNeoCliUnavailable();
  final project = await Directory.systemTemp.createTemp('morning-mist-crm-');
  File? auth;
  try {
    Future<void> run(List<String> args, Duration timeout) async {
      final Process process;
      try {
        process = await Process.start(
          executable,
          runtime.arguments(args),
          workingDirectory: project.path,
          environment: {
            'PATH': runtime.path,
            if (Platform.isWindows) 'USERPROFILE': home else 'HOME': home,
            'NEO_TELEMETRY': 'false',
          },
        );
      } on ProcessException catch (error) {
        throw StateError(
          'Could not start neo at $executable (OS error ${error.errorCode}).',
        );
      }
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      final exit = await process.exitCode.timeout(
        timeout,
        onTimeout: () {
          process.kill();
          throw TimeoutException('NeoCRM authorization timed out');
        },
      );
      if (exit != 0) throw StateError('NeoCRM CLI operation failed');
    }

    await run([
      'init',
      '-n',
      'Morning Mist CRM',
      '-d',
      '.',
    ], const Duration(seconds: 20));
    final manifest = jsonDecode(
      await File(p.join(project.path, 'neo-project.json')).readAsString(),
    ) as Map;
    final projectId = manifest['projectId'];
    if (projectId is! String ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(projectId)) {
      throw const FormatException('Invalid NeoCRM project ID');
    }
    auth = File(p.join(home, '.neocrm-cli', 'auth', '$projectId.json'));
    final instance = neoInstance(CrmConnectors.httpsUrl(connector['baseUrl'])!);
    final environment = switch (instance.origin) {
      'https://crm.xiaoshouyi.com' => 'production',
      neoSandboxUrl => 'sandbox',
      _ => 'custom',
    };
    await run([
      'login',
      '-e',
      environment,
      if (environment == 'custom') ...[
        '--instance-url',
        instance.origin,
        '--login-url',
        neoLoginOrigin(instance).origin,
      ],
    ], const Duration(minutes: 4));
    final data = jsonDecode(await auth.readAsString()) as Map;
    final access = data['accessToken'];
    if (access is! String || access.isEmpty) {
      throw const FormatException('Missing NeoCRM access token');
    }
    final expiry = data['expiresAt'];
    return {
      'accessToken': access,
      if (data['refreshToken'] case final String token) 'refreshToken': token,
      if (data['instanceUrl'] case final String url
          when CrmConnectors.httpsUrl(url) != null)
        'instanceUrl': url,
      if (data['tokenUrl'] case final String url
          when CrmConnectors.httpsUrl(url) != null)
        'sessionTokenUrl': url,
      if (data['tenantId'] case final Object tenant)
        'tenantId': tenant.toString(),
      if (expiry is int)
        'expiresAt': DateTime.fromMillisecondsSinceEpoch(expiry)
            .toIso8601String(),
    };
  } finally {
    if (auth != null && await auth.exists()) await auth.delete();
    await project.delete(recursive: true);
  }
}

Future<String?> crmCliVersion(String command) async {
  final runtime = await crmCliRuntime(command);
  final executable = runtime.executable;
  if (executable == null) return null;
  final process = await Process.start(
    executable,
    runtime.arguments(['--version']),
    environment: {
      'PATH': runtime.path,
      'NEO_TELEMETRY': 'false',
      'SF_DISABLE_TELEMETRY': 'true',
      'SF_DISABLE_AUTOUPDATE': 'true',
    },
  );
  final output = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final errors = process.stderr.drain<void>();
  await process.stdin.close();
  final status = await process.exitCode.timeout(
    const Duration(seconds: 8),
    onTimeout: () {
      process.kill();
      return -1;
    },
  );
  await errors;
  final version = (await output).trim();
  if (status != 0 || version.isEmpty) {
    throw StateError('$command --version failed (exit $status).');
  }
  return version.split('\n').first;
}
