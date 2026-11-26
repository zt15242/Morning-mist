@Tags(['exthost'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:bao_exthost/bao_exthost.dart' show VsUri;
import 'package:baocode/extensions/gallery/extension_management_backend.dart';
import 'package:baocode/extensions/window/webview_placeholders.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'open_vsx_workspace.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'resolves live views, custom text editors and their message channels',
    () async {
      final workspace = await OpenVsxWorkspace.create(
        extensionIds: const [],
        files: {'a.fixturepreview': 'Fixture document'},
        development: const ['test/fixtures/extensions/degradation-fixture'],
        renderWebviews: true,
      );
      final extensions = workspace.extensions;
      final webviews = extensions.webviews;
      await workspace.activated('baocode-test.degradation-fixture');
      webviews.setViewVisible('degradation.webviewView', true);
      final view = webviews.viewOf('degradation.webviewView')!;
      await eventually('view HTML', () => webviews.html[view.handle]);
      expect(webviews.html[view.handle], contains('fixture sidebar'));
      final sent = <String>[];
      await eventually('extension message', () {
        view.attachRenderer((value) {
          sent.add(value);
          return true;
        });
        return sent.isNotEmpty ? true : null;
      });
      expect(jsonDecode(sent.single), {'ready': true});
      await view.receiveMessage!('{"from":"page"}');
      final state = await extensions.commands.executeCommand(
        'degradation.state',
      );
      expect(jsonDecode(state as String)['viewMessage'], {'from': 'page'});

      final path = await workspace.open('a.fixturepreview');
      final editor = await webviews.textEditors['degradation.preview']!(
        path,
        'Fixture document',
      );
      expect(webviews.html[editor.handle], '<p>Fixture document</p>');
      await editor.closePanel!();
      expect(webviews.placeholder(editor.handle), isNull);

      final command = extensions.commands.executeCommand('degradation.panel');
      final panel = await eventually(
        'panel',
        () => webviews.panels.firstOrNull,
      );
      await eventually('panel HTML', () => webviews.html[panel.handle]);
      await panel.closePanel!();
      expect(await command, 'disposed');
    },
    skip: openVsxSkip(),
  );

  final salesforce = Platform.environment['BAOCODE_SALESFORCE_VSIX_DIR'];
  test(
    'Salesforce SOQL Builder resolves its custom editor and sets HTML',
    () async {
      final workspace = await OpenVsxWorkspace.create(
        extensionIds: const [],
        files: {
          'sfdx-project.json': '{"packageDirectories":[{"path":"force-app","default":true}],"sourceApiVersion":"67.0"}',
          'force-app/.keep': '',
          'query.soql': 'SELECT Id FROM Account LIMIT 1',
        },
        settings: {'telemetry.telemetryLevel': 'off'},
        serverEnvironment: salesforceEnvironment,
        renderWebviews: true,
      );
      final extensions = workspace.extensions;
      final webviews = extensions.webviews;
      for (final name in ['services', 'soql']) {
        await extensions.management.install(
          p.join(salesforce!, '$name.vsix'),
          options: const ExtensionInstallOptions(withDependencies: false),
        );
      }
      final source = await workspace.open('query.soql');
      await extensions.host!.refreshExtensions();
      WebviewPlaceholder? opened;
      webviews.onRevealPanel = (surface) => opened = surface;
      await extensions.commands.executeCommand('soql.builder.toggle', [
        VsUri.file(source),
      ]);
      final surface = await eventually('SOQL custom editor', () => opened);
      expect(surface.viewType, 'soqlCustom.soql');
      final html = await eventually(
        'Salesforce SOQL Builder HTML',
        () => webviews.html[surface.handle],
      );
      expect(html, contains('vscode-resource.vscode-cdn.net'));
      expect(webviews.options[surface.handle]?['enableScripts'], isTrue);
      await surface.closePanel!();
    },
    skip:
        salesforce == null ||
            !File(p.join(salesforce, 'soql.vsix')).existsSync()
        ? 'Set BAOCODE_SALESFORCE_VSIX_DIR with services.vsix and soql.vsix'
        : openVsxSkip(),
  );
  test(
    'Salesforce Metadata Visualizer opens a Flow visualization from its command',
    () async {
      const source = 'force-app/main/default/flows/Hello.flow-meta.xml';
      final workspace = await OpenVsxWorkspace.create(
        extensionIds: const [],
        files: {
          'sfdx-project.json': '{"packageDirectories":[{"path":"force-app","default":true}],"sourceApiVersion":"67.0"}',
          source: '''<Flow xmlns="http://soap.sforce.com/2006/04/metadata">
            <apiVersion>67.0</apiVersion>
            <label>Hello</label>
            <processType>AutoLaunchedFlow</processType>
            <start><locationX>0</locationX><locationY>0</locationY></start>
            <status>Draft</status>
          </Flow>''',
        },
        settings: {'telemetry.telemetryLevel': 'off'},
        serverEnvironment: salesforceEnvironment,
        renderWebviews: true,
      );
      final extensions = workspace.extensions;
      for (final name in ['services', 'core', 'visualizer']) {
        await extensions.management.install(
          p.join(salesforce!, '$name.vsix'),
          options: const ExtensionInstallOptions(withDependencies: false),
        );
      }
      await extensions.host!.refreshExtensions();
      await workspace.show(source);
      await workspace.activated(
        'salesforce.salesforcedx-metadata-visualizer-vscode',
      );
      final actions = await eventually('Visualize editor action', () {
        final actions = extensions.menus
            .menuItems('editor/title', extensions.contextKeys)
            .expand((group) => group.actions);
        return actions
            .where((action) => action.title == 'Visualize')
            .firstOrNull;
      });
      final result = await extensions.commands.executeCommand(
        'sf.metadata.viz.showVisualizerFromEditorTitle',
        [VsUri.file(workspace.path(source))],
      );
      expect(actions.title, 'Visualize');
      final html = await eventually('Salesforce visualization ($result)', () {
        return extensions.webviews.html.values
            .where((html) => html.contains('<script'))
            .firstOrNull;
      });
      expect(html, contains('vscode-resource.vscode-cdn.net'));
    },
    skip:
        salesforce == null ||
            !File(p.join(salesforce, 'visualizer.vsix')).existsSync()
        ? 'Set BAOCODE_SALESFORCE_VSIX_DIR with services, core and visualizer VSIXs'
        : openVsxSkip(),
  );
}

Future<Map<String, String>> salesforceEnvironment() async {
  final home = Directory.systemTemp.createTempSync('webview-salesforce-home-');
  addTearDown(() => home.delete(recursive: true));
  return {
    'HOME': home.path,
    'USERPROFILE': home.path,
    'SFDX_DISABLE_TELEMETRY': 'true',
  };
}
