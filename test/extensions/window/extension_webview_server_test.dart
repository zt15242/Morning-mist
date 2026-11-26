import 'dart:convert';
import 'dart:io';

import 'package:bao_exthost/bao_exthost.dart';
import 'package:baocode/extensions/window/extension_webview_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'serves a Webview and allows only its declared local resources and origin',
    () async {
      HttpOverrides.global = null;
      final directory = await Directory.systemTemp.createTemp(
        'extension-webview-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final assets = await Directory(p.join(directory.path, 'assets')).create();
      final script = await File(p.join(assets.path, 'script.js'))
          .writeAsString('void 0');
      final outside = await File(p.join(directory.path, 'secret.js'))
          .writeAsString('outside allowed roots');
      if (!Platform.isWindows) {
        await Link(p.join(assets.path, 'link.js')).create(outside.path);
      }
      final received = <String>[];
      Object? state;
      var scripts = true;
      final server = ExtensionWebviewServer(
        readHtml: () =>
            '''
<!doctype html><html><head>
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self' https://*.vscode-cdn.net;">
<script src="https://file+.vscode-resource.vscode-cdn.net${script.uri.path}"></script>
</head></html>''',
        readOptions: () => {
          'enableScripts': scripts,
          'localResourceRoots': [VsUri.file(assets.path).toJson()],
        },
        onMessage: (message) async => received.add(message),
        readState: () => state,
        saveState: (value) => state = value,
      );
      addTearDown(server.close);
      final page = await server.start();
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      Future<({int status, String body, String? policy})> request(
        Uri uri, {
        String? origin,
        String? body,
      }) async {
        final request = await client.openUrl(
          body == null ? 'GET' : 'POST',
          uri,
        );
        if (origin != null) request.headers.set('Origin', origin);
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(body);
        }
        final response = await request.close();
        return (
          status: response.statusCode,
          body: await utf8.decoder.bind(response).join(),
          policy: response.headers.value('Content-Security-Policy'),
        );
      }

      final result = await request(page);
      expect(result.status, 200);
      expect(result.body, contains('acquireVsCodeApi'));
      expect(result.body, contains('nonce-'));
      expect(result.body, isNot(contains('vscode-cdn.net')));
      expect(result.policy, contains("frame-ancestors 'none'"));
      Uri resource(FileSystemEntity file) =>
          page.resolve('resource${file.uri.path}');
      expect((await request(resource(script))).body, 'void 0');
      expect((await request(resource(outside))).status, 404);
      if (!Platform.isWindows) {
        expect(
          (await request(resource(Link(p.join(assets.path, 'link.js')))))
              .status,
          404,
        );
      }
      expect((await request(page.resolve('/wrong-token/page'))).status, 404);
      expect(
        (await request(
          page.resolve('message'),
          origin: 'https://unrelated.example',
          body: '{"x":1}',
        )).status,
        404,
      );
      expect(
        (await request(
          page.resolve('message'),
          origin: page.origin,
          body: '{"x":2}',
        )).status,
        204,
      );
      expect(received, ['{"x":2}']);
      expect(
        (await request(
          page.resolve('state'),
          origin: page.origin,
          body: '{"x":3}',
        )).status,
        204,
      );
      expect(state, {'x': 3});
      expect(server.send('{"x":4}'), isTrue);
      final events = await (await client.getUrl(page.resolve('events')))
          .close();
      final line = await utf8.decoder
          .bind(events)
          .transform(const LineSplitter())
          .firstWhere((line) => line.startsWith('data: '))
          .timeout(const Duration(seconds: 5));
      expect(utf8.decode(base64.decode(line.substring(6))), '{"x":4}');
      scripts = false;
      final disabled = await request(page);
      expect(disabled.policy, contains("script-src 'none'"));
      expect(disabled.body, isNot(contains('acquireVsCodeApi')));
    },
  );
}
