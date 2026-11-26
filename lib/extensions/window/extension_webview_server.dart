import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data' show BytesBuilder;

import 'package:bao_exthost/bao_exthost.dart';
import 'package:html/parser.dart' as html;
import 'package:path/path.dart' as p;

/// Each surface gets a separate loopback origin and an unguessable URL.
/// Only the extension's localResourceRoots are served from that origin.
final class ExtensionWebviewServer {
  ExtensionWebviewServer({
    required this.readHtml,
    required this.readOptions,
    required this.onMessage,
    required this.readState,
    required this.saveState,
  });

  final String Function() readHtml;
  final Map<String, Object?> Function() readOptions;
  final Future<void> Function(String message) onMessage;
  final Object? Function() readState;
  final void Function(Object? state) saveState;

  final String _token = _random();
  HttpServer? _server;
  Uri? _page;
  bool _closed = false;
  HttpResponse? _messages;
  final _pending = <String>[];

  static String _random() {
    final random = Random.secure();
    return base64Url.encode(List.generate(24, (_) => random.nextInt(256)));
  }

  Future<Uri> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      throw StateError('Webview was closed');
    }
    _server = server;
    final page = _page = Uri.parse(
      'http://127.0.0.1:${server.port}/$_token/page',
    );
    server.listen((request) => unawaited(_serve(request)));
    return page;
  }

  Future<void> close() async {
    _closed = true;
    _messages = null;
    _pending.clear();
    await _server?.close(force: true);
  }

  bool send(String json) {
    if (_closed || _server == null || _pending.length >= 100) return false;
    if (_messages case final response?) {
      _writeMessage(response, json);
    } else {
      _pending.add(json);
    }
    return true;
  }

  void _writeMessage(HttpResponse response, String json) {
    final encoded = base64.encode(utf8.encode(json));
    response.write('data: $encoded\n\n');
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Referrer-Policy', 'no-referrer')
      ..set('Cross-Origin-Resource-Policy', 'same-origin')
      ..set('Cache-Control', 'no-store');
    final origin = _page!.origin;
    final source = request.headers.value('Origin');
    final segments = request.uri.pathSegments;
    if (request.headers.value(HttpHeaders.hostHeader) != _page!.authority ||
        segments.length < 2 ||
        segments.first != _token ||
        (source != null && source != origin)) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    try {
      if (request.method == 'GET' &&
          segments.length == 2 &&
          segments[1] == 'page') {
        final scripts = readOptions()['enableScripts'] == true;
        response.headers
          ..contentType = ContentType.html
          ..set(
            'Content-Security-Policy',
            "frame-ancestors 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'; worker-src blob:; ${scripts ? '' : "script-src 'none';"}",
          );
        response.write(_document(scripts));
      } else if (request.method == 'GET' &&
          segments.length == 2 &&
          segments[1] == 'events' &&
          readOptions()['enableScripts'] == true) {
        unawaited(
          _messages?.close().then<void>((_) {}, onError: (Object _) {}),
        );
        _messages = response;
        response.bufferOutput = false;
        response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        response.write(': ready\n\n');
        for (final json in _pending) {
          _writeMessage(response, json);
        }
        _pending.clear();
        unawaited(
          response.done.then<void>(
            (_) {
              if (_messages == response) _messages = null;
            },
            onError: (Object _) {
              if (_messages == response) _messages = null;
            },
          ),
        );
        return;
      } else if (request.method == 'POST' &&
          segments.length == 2 &&
          (segments[1] == 'message' || segments[1] == 'state') &&
          request.headers.value('Origin') == origin &&
          request.headers.contentType?.mimeType == 'application/json' &&
          readOptions()['enableScripts'] == true) {
        final chunks = BytesBuilder(copy: false);
        await for (final chunk in request) {
          if (chunks.length + chunk.length > 1024 * 1024) {
            response.statusCode = HttpStatus.requestEntityTooLarge;
            await response.close();
            return;
          }
          chunks.add(chunk);
        }
        final encoded = utf8.decode(chunks.takeBytes());
        final value = jsonDecode(encoded);
        if (segments[1] == 'state') {
          saveState(value);
        } else {
          await onMessage(encoded);
        }
        response.statusCode = HttpStatus.noContent;
      } else if (request.method == 'GET' &&
          segments.length > 2 &&
          segments[1] == 'resource') {
        await _resource(response, segments.sublist(2));
      } else {
        response.statusCode = HttpStatus.notFound;
      }
    } on Object {
      response.statusCode = HttpStatus.badRequest;
    }
    await response.close();
  }

  String _document(bool scripts) {
    final document = html.parse(
      readHtml().replaceAll(
        'https://file+.vscode-resource.vscode-cdn.net/',
        '/$_token/resource/',
      ),
    );
    final head = document.head!;
    final nonce = _random();
    final policies = head
        .querySelectorAll('meta[http-equiv]')
        .where(
          (meta) =>
              meta.attributes['http-equiv']?.toLowerCase() ==
              'content-security-policy',
        );
    for (final meta in policies) {
      final content = meta.attributes['content'];
      if (content == null) continue;
      final directives = <String, String>{};
      for (final raw in content.split(';')) {
        final parts = raw.trim().split(RegExp(r'\s+'));
        if (parts.first.isEmpty) continue;
        directives.putIfAbsent(
          parts.first.toLowerCase(),
          () => parts.skip(1).join(' '),
        );
      }
      final fallback = directives['default-src'];
      for (final name in ['connect-src', 'script-src', 'script-src-elem']) {
        final current =
            directives[name] ??
            (name == 'script-src-elem' ? directives['script-src'] : null) ??
            fallback;
        if (current == null || !scripts) continue;
        final extra = name == 'connect-src' ? "'self'" : "'nonce-$nonce'";
        directives[name] = current == "'none'" ? extra : '$current $extra';
      }
      meta.attributes['content'] = directives.entries
          .map(
            (entry) =>
                '${entry.key} ${entry.value.replaceAll("https://*.vscode-cdn.net", "'self'")}',
          )
          .join('; ');
    }
    if (scripts) {
      final state = base64.encode(utf8.encode(jsonEncode(readState())));
      final bootstrap = html
          .parseFragment('''<script nonce="$nonce">
(() => {
  const decode = (s) => JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(s), c => c.charCodeAt(0))));
  let state = decode('$state');
  let acquired = false;
  const send = (path, value) => {
    const body = JSON.stringify(value);
    if (body !== undefined) {
      fetch('/$_token/' + path, {
        method: 'POST', headers: {'Content-Type': 'application/json'}, body,
        credentials: 'omit', redirect: 'error',
      }).catch(() => {});
    }
  };
  Object.defineProperty(window, 'acquireVsCodeApi', {
    value: () => {
      if (acquired) throw new Error('VS Code API is already acquired');
      acquired = true;
      return Object.freeze({
        postMessage: (message) => send('message', message),
        getState: () => state,
        setState: (value) => { state = value; send('state', value); return value; },
      });
    },
  });
  const events = new EventSource('/$_token/events');
  const deliver = ({data}) => window.dispatchEvent(new MessageEvent('message', {data: decode(data)}));
  events.onmessage = (event) => {
    if (document.readyState === 'complete') deliver(event);
    else window.addEventListener('load', () => deliver(event), {once: true});
  };
})();
</script>''')
          .nodes
          .single;
      final lastPolicy = policies.lastOrNull;
      if (lastPolicy == null) {
        head.nodes.insert(0, bootstrap);
      } else {
        head.nodes.insert(head.nodes.indexOf(lastPolicy) + 1, bootstrap);
      }
    }
    return document.outerHtml;
  }

  Future<void> _resource(HttpResponse response, List<String> segments) async {
    response.statusCode = HttpStatus.notFound;
    if (segments.any(
      (segment) =>
          segment == '..' || segment.contains('/') || segment.contains('\\'),
    )) {
      return;
    }
    final path = VsUri.parse(
      'file:///${segments.map(Uri.encodeComponent).join('/')}',
    ).fsPath();
    if (!p.isAbsolute(path) ||
        await FileSystemEntity.type(path) != FileSystemEntityType.file) {
      return;
    }
    final real = await File(path).resolveSymbolicLinks();
    final configured = readOptions()['localResourceRoots'];
    if (configured is! List) return;
    for (final root in configured) {
      final uri = root is Map ? VsUri.tryRevive(root) : null;
      if (uri == null || uri.scheme != 'file' || uri.authority.isNotEmpty) {
        continue;
      }
      final directory = Directory(uri.fsPath());
      if (!await directory.exists()) continue;
      final realRoot = await directory.resolveSymbolicLinks();
      if (!p.isWithin(realRoot, real)) continue;
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType.parse(switch (p
          .extension(real)
          .toLowerCase()) {
        '.js' || '.mjs' => 'text/javascript',
        '.css' => 'text/css',
        '.json' || '.map' => 'application/json',
        '.svg' => 'image/svg+xml',
        '.png' => 'image/png',
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.gif' => 'image/gif',
        '.webp' => 'image/webp',
        '.woff' => 'font/woff',
        '.woff2' => 'font/woff2',
        '.ttf' => 'font/ttf',
        '.wasm' => 'application/wasm',
        _ => 'application/octet-stream',
      });
      await response.addStream(File(real).openRead());
      return;
    }
  }
}
