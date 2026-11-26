// The extensions' commands (upstream extensions.contribution.ts: Install
// from VSIX…, File Icon Theme) and Close Editor, which closes an
// extension's page in front as well as a file's.

import 'dart:async';

import '../../../l10n/l10n.dart';
import '../../ide_workspace.dart';
import '../../services/editors.dart';
import '../../services/extensions_view.dart';
import '../actions.dart';
import '../contributions.dart';
import '../environment.dart';
import '../services.dart';

class ExtensionsContribution extends WorkbenchRegistrations {
  ExtensionsContribution(WorkbenchServices services) {
    final extensions = services.get<ExtensionsViewService>();
    add(
      services.get<ActionRegistry>().registerAll([
        WorkbenchAction(
          id: 'workbench.action.closeActiveEditor',
          category: 'View',
          title: 'Close Editor',
          precondition: (services) =>
              services.find<IdeWorkspace>()?.active != null,
          run: (services, _) {
            if (extensions.pageShown) return extensions.closePage();
            if (services.find<IdeWorkspace>()?.active case final doc?) {
              unawaited(services.get<EditorService>().close(doc));
            }
          },
        ),
        WorkbenchAction(
          id: 'workbench.extensions.action.installVSIX',
          category: 'Extensions',
          title: 'Install from VSIX...',
          precondition: (_) => extensions.canInstall,
          run: (_, _) => unawaited(extensions.installFromVsix()),
        ),
        WorkbenchAction(
          id: 'workbench.action.reopenWith',
          category: 'File',
          title: 'Open with Extension Editor...',
          titleFor: (services) =>
              (services.get<WorkbenchHost>().context?.l10n ??
                      englishLocalizations)
                  .extsOpenWithExtensionEditor,
          precondition: (services) =>
              switch (services.find<IdeWorkspace>()?.active) {
                final doc? => extensions.customEditors(doc).isNotEmpty,
                null => false,
              },
          run: (services, _) {
            if (services.find<IdeWorkspace>()?.active case final doc?) {
              extensions.pickCustomEditor(doc);
            }
          },
        ),
        WorkbenchAction(
          id: 'workbench.action.selectIconTheme',
          category: 'Preferences',
          title: 'File Icon Theme',
          precondition: (services) =>
              services.get<WorkbenchEnvironment>().settings != null,
          run: (_, _) => extensions.selectIconTheme(),
        ),
      ]),
    );
  }
}
