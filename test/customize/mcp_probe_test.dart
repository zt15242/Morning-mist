import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:bao_agent/mcp_oauth.dart';
import 'package:baocode/customize/mcp_probe.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:baocode/network/network_proxy_io.dart';
import 'package:baocode/network/proxy_settings.dart';
import 'package:flutter_test/flutter_test.dart';

/// Checking a remote MCP server as `claude mcp list` does: its
/// `initialize` answered.
void main() {
  setUp(() {
    ClaudeEnvironment.use(const {});
    // Real connections: flutter_test's answer every request with 400.
    HttpOverrides.global = null;
  });
  tearDown(() => ClaudeEnvironment.use(null));

  test('remote checks use the configured network proxy', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => proxy.close(force: true));
    final previous = NetworkProxy.instance;
    NetworkProxy.instance = NetworkProxy(
      system: () async =>
          ProxyRoute.manual(ProxyServer('127.0.0.1', proxy.port)),
      environment: () async => {},
    );
    addTearDown(() => NetworkProxy.instance = previous);
    final requested = Completer<Uri>();
    proxy.listen((request) async {
      requested.complete(request.uri);
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
    });
    final result = await platformMcpProber!({
      'type': 'sse',
      'url': 'http://mcp-proxy-test.invalid/api/mcp/sse',
    });
    expect(result.status, McpProbeStatus.needsAuth);
    expect((await requested.future).host, 'mcp-proxy-test.invalid');
  });

  test('OAuth login is shared with the probe and running agent', () async {
    final dir = await Directory.systemTemp.createTemp('mcp-oauth-test-');
    addTearDown(() => dir.delete(recursive: true));
    ClaudeEnvironment.use({'HOME': dir.path, 'USERPROFILE': dir.path});
    final oldProxy = NetworkProxy.instance;
    NetworkProxy.instance = NetworkProxy(
      system: () async => const ProxyRoute.direct(),
      environment: () async => {},
    );
    addTearDown(() => NetworkProxy.instance = oldProxy);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final base = 'http://127.0.0.1:${server.port}';
    var failTokenExchange = false;
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      switch (request.uri.path) {
        case '/.well-known/oauth-protected-resource/mcp':
          request.response.write(
            jsonEncode({
              'authorization_servers': [base],
            }),
          );
        case '/.well-known/oauth-authorization-server':
          request.response.write(
            jsonEncode({
              'authorization_endpoint': '$base/authorize',
              'token_endpoint': '$base/token',
              'registration_endpoint': '$base/register',
            }),
          );
        case '/register':
          request.response.write(jsonEncode({'client_id': 'test-client'}));
        case '/token':
          request.response.write(
            jsonEncode(
              failTokenExchange
                  ? <String, Object?>{}
                  : {'access_token': 'test-token'},
            ),
          );
        case '/mcp':
          if (request.headers.value('authorization') != 'Bearer test-token') {
            request.response.statusCode = 401;
            request.response.headers.set(
              'www-authenticate',
              'Bearer resource_metadata="$base/.well-known/oauth-protected-resource/mcp"',
            );
          } else {
            final body = jsonDecode(await utf8.decodeStream(request)) as Map;
            if (body['method'] == 'notifications/initialized') {
              request.response.statusCode = 202;
            } else {
              request.response.write(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': body['id'],
                  'result': body['method'] == 'tools/list'
                      ? {'tools': []}
                      : {
                          'serverInfo': {'name': 'test'},
                        },
                }),
              );
            }
          }
        default:
          request.response.statusCode = 404;
      }
      await request.response.close();
    });
    final config = <String, Object?>{
      'type': 'http',
      'url': '$base/mcp',
      '_morningMistServerName': 'secure',
    };
    final before = await platformMcpProber!(config);
    expect(before.status, McpProbeStatus.needsAuth);
    expect(
      before.resourceMetadata.toString(),
      '$base/.well-known/oauth-protected-resource/mcp',
    );
    final cachedAgent = McpOAuth(
      storeFile: '${dir.path}/.claude/.baocode-mcp-oauth.json',
    );
    expect(
      cachedAgent.hasToken(McpOAuth.keyOf('secure', Uri.parse('$base/mcp'))),
      false,
    );
    final completed = Completer<Object?>();
    final url = await beginMcpSignIn(
      'secure',
      config,
      resourceMetadata: before.resourceMetadata,
      onSignedIn: completed.complete,
    );
    final redirect = Uri.parse(url.queryParameters['redirect_uri']!);
    final callback = redirect.replace(
      queryParameters: {
        'state': url.queryParameters['state']!,
        'code': 'test-code',
      },
    );
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    await (await client.getUrl(callback))
        .close()
        .then((response) => response.drain<void>());
    expect(await completed.future.timeout(const Duration(seconds: 5)), isNull);
    expect(
      await cachedAgent.headers(
        McpOAuth.keyOf('secure', Uri.parse('$base/mcp')),
      ),
      {'Authorization': 'Bearer test-token'},
    );
    final after = await platformMcpProber!(config);
    expect(after.status, McpProbeStatus.connected, reason: after.message);

    failTokenExchange = true;
    final failed = Completer<Object?>();
    final retry = await beginMcpSignIn(
      'another',
      config,
      resourceMetadata: before.resourceMetadata,
      onSignedIn: failed.complete,
    );
    final failedCallback = Uri.parse(retry.queryParameters['redirect_uri']!)
        .replace(
          queryParameters: {
            'state': retry.queryParameters['state']!,
            'code': 'bad-code',
          },
        );
    final response = await (await client.getUrl(failedCallback)).close();
    final responseBody = await utf8.decodeStream(response);
    expect(response.statusCode, 500);
    expect(responseBody, contains('Sign-in failed'));
    expect(
      await failed.future.timeout(const Duration(seconds: 5)),
      isA<HttpException>(),
    );
  });

  test("Streamable HTTP: initialize sent as plain application/json, which "
      "strict servers insist on", () async {
    // As servers that compare the header whole do: 415 for a charset.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <String?>[];
    final sessions = <String?>[];
    server.listen((request) async {
      final type = request.headers.value(HttpHeaders.contentTypeHeader);
      seen.add(type);
      final body = jsonDecode(await utf8.decodeStream(request)) as Map;
      if (type != 'application/json') {
        request.response
          ..statusCode = HttpStatus.unsupportedMediaType
          ..write("Content-Type must be 'application/json'");
      } else if (body['method'] == 'notifications/initialized') {
        request.response.statusCode = HttpStatus.accepted;
      } else if (body['method'] == 'tools/list') {
        sessions.add(request.headers.value('mcp-session-id'));
        request.response
          ..headers.set(HttpHeaders.contentTypeHeader, 'text/event-stream')
          ..write(
            'event: message\ndata: ${jsonEncode({
              'jsonrpc': '2.0',
              'id': body['id'],
              'result': {
                'tools': [
                  {'name': 'search', 'description': ' Finds things '},
                ],
              },
            })}\n\n',
          );
      } else {
        request.response
          ..headers.set(HttpHeaders.contentTypeHeader, 'application/json')
          ..headers.set('mcp-session-id', 's1')
          ..write(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': body['id'],
              'result': {
                'protocolVersion': '2025-06-18',
                'capabilities': <String, Object?>{},
                'serverInfo': {'name': 'strict', 'version': '1'},
              },
            }),
          );
      }
      await request.response.close();
    });

    final result = await platformMcpProber!({
      'type': 'http',
      'url': 'http://127.0.0.1:${server.port}/mcp',
    });
    expect(seen.toSet(), {'application/json'});
    expect(result.status, McpProbeStatus.connected, reason: result.message);
    // Its tools then, in the session it opened: for their switches.
    expect(sessions, ['s1']);
    expect(result.tools, [(name: 'search', description: 'Finds things')]);
  });

  test('a command: its tools listed once it answers initialize', () async {
    // Answers each request by its id; tools/list with two tools.
    const script = r'''
while IFS= read -r line; do
  case "$line" in
    *'"id":1'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"t","version":"2"}}}' ;;
    *tools/list*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"one","description":"First"},{"name":"two"}]}}' ;;
  esac
done
''';
    final result = await platformMcpProber!({
      'command': 'sh',
      'args': ['-c', script],
    });
    expect(result.status, McpProbeStatus.connected, reason: result.message);
    expect(result.server, 't 2');
    expect(result.tools, [
      (name: 'one', description: 'First'),
      (name: 'two', description: ''),
    ]);
  }, testOn: '!windows');

  test('a command that fails: its exit code and what it said, as said, '
      'lines whole however they come', () async {
    final result = await platformMcpProber!({
      'command': 'sh',
      'args': [
        '-c',
        // 文 split between two writes.
        r"printf '\344\270\255\346\226' >&2; sleep 0.2; "
            r"printf '\207: not found\nnext\n' >&2; exit 1",
      ],
    });
    expect(result.status, McpProbeStatus.failed);
    expect(result.exitCode, 1);
    expect(result.log, '中文: not found\nnext');
  }, testOn: '!windows');
}
