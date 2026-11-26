@Tags(['exthost'])
library;

import 'dart:io';

import 'package:bao_exthost/bao_exthost.dart';
import 'package:baocode/extensions/workbench/workspace_extensions.dart';
import 'package:baocode/ide/ide_hover.dart';
import 'package:baocode/ide/ide_workbench.dart';
import 'package:baocode/ide/ide_workspace.dart';
import 'package:baocode/ide/lsp/lsp_protocol.dart';
import 'package:baocode/ide/lsp/language_features.dart';
import 'package:baocode/ide/services/extensions_view.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../host/exthost_runtime.dart';
import '../vsix/zip_writer.dart';
import 'open_vsx_workspace.dart';

void main() {
  testWidgets('installed VSIX drives the editor, menus and activity bar', (
    tester,
  ) async {
    const extensionId = 'acme.adaptation';
    const containerId = 'workbench.view.extension.adaptation';
    const fileName = 'first.adaptation';
    late Directory root;
    late ExtensionsApp app;
    late IdeWorkspace workspace;
    final workbench = GlobalKey<IdeWorkbenchState>();
    await tester.runAsync(() async {
      root = Directory.systemTemp.createTempSync('extension-workbench-');
      final project = Directory('${root.path}/project')..createSync();
      File('${project.path}/$fileName').writeAsStringSync('hello');
      final vsix = File('${root.path}/adaptation.vsix')
        ..writeAsBytesSync(
          buildVsix({
            'package.json': {
              'name': 'adaptation',
              'publisher': 'acme',
              'version': '1.0.0',
              'engines': {'vscode': '^1.100.0'},
              'main': './extension.js',
              'activationEvents': ['onLanguage:adaptation'],
              'contributes': {
                'languages': [
                  {
                    'id': 'adaptation',
                    'extensions': ['.adaptation'],
                  },
                ],
                'commands': [
                  {'command': 'adaptation.open', 'title': 'Adaptation Action'},
                ],
                'menus': {
                  'editor/title': [
                    {
                      'command': 'adaptation.open',
                      'group': 'navigation',
                      'when': 'resourceLangId == adaptation',
                    },
                  ],
                  'editor/context': [
                    {
                      'command': 'adaptation.open',
                      'when': 'resourceLangId == adaptation',
                    },
                  ],
                },
                'viewsContainers': {
                  'activitybar': [
                    {
                      'id': 'adaptation',
                      'title': 'Adaptation Tools',
                      'icon': 'icon.svg',
                    },
                  ],
                },
                'views': {
                  'adaptation': [
                    {'id': 'adaptation.results', 'name': 'Adaptation Results'},
                  ],
                },
              },
            },
            'icon.svg': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><circle cx="8" cy="8" r="6"/></svg>',
            'extension.js': '''
const vscode = require('vscode');
exports.activate = ({ subscriptions }) => {
  subscriptions.push(vscode.commands.registerCommand('adaptation.open', () => vscode.window.activeTextEditor?.document.languageId));
  subscriptions.push(vscode.languages.registerHoverProvider('adaptation', {
    provideHover: () => new vscode.Hover('Hover from the extension'),
  }));
  subscriptions.push(vscode.window.registerTreeDataProvider('adaptation.results', {
    getChildren: () => ['Tree item from the extension'],
    getTreeItem: (label) => new vscode.TreeItem(label),
  }));
};
''',
          }),
        );
      app = ExtensionsApp(
        userSettings: AcceptanceSettings({}),
        dataDirectory: '${root.path}/data',
        loadRuntime: () => ExtHostRuntime.load(exthostRuntimeDir()!),
      );
      workspace = IdeWorkspace(project.path);
      addTearDown(() async {
        workspace.dispose();
        await app.dispose();
        await root.delete(recursive: true);
      });
      await app.load();
      await app.trustStore.setUrisTrust([VsUri.file(project.path)], true);
      final installer = app.workspace(project.path);
      try {
        expect((await installer.management.install(vsix.path)).id, extensionId);
      } finally {
        installer.dispose();
      }
      await workspace.open('${project.path}/$fileName');
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: IdeWorkbench(
            key: workbench,
            workspace: workspace,
            project: Project.at(workspace.root),
            visible: true,
            chat: const SizedBox.shrink(),
            onBack: () {},
            extensionsApp: app,
          ),
        ),
      );
    });
    final service = workbench.currentState!.services
        .get<ExtensionsViewService>();
    final extensions = service.workspaceExtensions!;
    final path = '${workspace.root}/$fileName';
    await tester.runAsync(() async {
      expect(
        (await app.installedManifests()).any(
          (manifest) => manifest['name'] == 'adaptation',
        ),
        isTrue,
      );
      await eventually(
        'extension hover provider',
        () => workspace.languages!.supports(path, LanguageRequest.hover)
            ? true
            : null,
        timeout: const Duration(seconds: 20),
      );
      final hover = await workspace.languages!.hover(
        path,
        const LspPosition(0, 0),
      );
      expect(hover?.markdown, contains('Hover from the extension'));
      expect(
        await extensions.commands.executeCommand('adaptation.open'),
        'adaptation',
      );
    });
    expect(service.resourceMenu('editor/context', path), isNotEmpty);
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is IdeActionButton && widget.tooltip == 'Adaptation Action',
      ),
      findsOneWidget,
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey(containerId)));
      await tester.pump();
    });
    await tester.runAsync(() async {
      final tree = extensions.views.treeView('adaptation.results')!;
      await eventually(
        'extension tree data',
        () => tree.rows.isNotEmpty ? true : null,
        timeout: const Duration(seconds: 20),
      );
    });
    await tester.pump();
    expect(find.text('Tree item from the extension'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: openVsxSkip() == false ? false : true);
}
