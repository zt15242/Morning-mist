@Tags(['exthost'])
library;

import 'dart:io';

import 'package:bao_editor/monaco/flutter/editor_surface.dart';
import 'package:bao_exthost/bao_exthost.dart';
import 'package:baocode/extensions/workbench/workspace_extensions.dart';
import 'package:baocode/ide/ide_hover.dart';
import 'package:baocode/ide/ide_menu.dart';
import 'package:baocode/ide/ide_workbench.dart';
import 'package:baocode/ide/ide_workspace.dart';
import 'package:baocode/ide/lsp/lsp_protocol.dart';
import 'package:baocode/ide/lsp/language_features.dart';
import 'package:baocode/ide/services/extensions_view.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/gestures.dart';
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
                  {
                    'command': 'adaptation.file',
                    'title': 'Extension File Action',
                  },
                  {
                    'command': 'adaptation.selection',
                    'title': 'Extension Selection Action',
                  },
                  {
                    'command': 'adaptation.lastPath',
                    'title': 'Last Action Path',
                  },
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
                    {
                      'command': 'adaptation.file',
                      'when': r'isFileSystemResource && !editorReadonly && !editorHasSelection && editorLangId == adaptation && resource =~ /\.adaptation$/ && fixture:has_target_org',
                    },
                    {
                      'command': 'adaptation.selection',
                      'when': 'isFileSystemResource && editorHasSelection && fixture:has_target_org',
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
  let lastPath;
  subscriptions.push(vscode.commands.registerCommand('adaptation.file', uri => { lastPath = uri.fsPath; }));
  subscriptions.push(vscode.commands.registerCommand('adaptation.lastPath', () => lastPath));
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
    List<String> labels({bool selection = false, bool readOnly = false}) =>
        service
            .resourceMenu(
              'editor/context',
              path,
              editorHasSelection: selection,
              editorReadonly: readOnly,
            )
            .expand((group) => group.whereType<IdeMenuAction>())
            .map((action) => action.label)
            .toList();
    expect(labels(), isNot(contains('Extension File Action')));
    await tester.runAsync(
      () => extensions.commands.executeCommand('setContext', [
        'fixture:has_target_org',
        true,
      ]),
    );
    expect(labels(), contains('Extension File Action'));
    expect(labels(readOnly: true), isNot(contains('Extension File Action')));
    expect(labels(selection: true), contains('Extension Selection Action'));
    expect(labels(selection: true), isNot(contains('Extension File Action')));
    await tester.runAsync(() async {
      await tester.tapAt(
        tester.getTopLeft(find.byType(EditorSurface)) + const Offset(70, 14),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Extension File Action'), findsOneWidget);
      await tester.tap(find.text('Extension File Action'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await eventually(
        'right-click command received the file URI',
        () => extensions.commands.executeCommand('adaptation.lastPath'),
        timeout: const Duration(seconds: 5),
      );
      expect(
        await extensions.commands.executeCommand('adaptation.lastPath'),
        path,
      );
    });
    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey('ide.activity.extensionViews')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Adaptation Tools'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
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
