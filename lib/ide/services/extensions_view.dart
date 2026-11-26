// The workbench's extensions (upstream `IExtensionsWorkbenchService` with
// the extension editor): the Extensions view's tab (the color and file
// icon theme extensions of lib/extensions/, and the language servers), a
// theme extension's page among the editors', .vsix files installed or
// dropped on the window, and the file icon theme picked.

import 'dart:async';

import 'package:bao_exthost/bao_exthost.dart' show VsUri;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../extensions/theme_extensions.dart';
import '../../extensions/menus/menu_widgets.dart';
import '../../extensions/views/view_contributions.dart';
import '../../extensions/workbench/workspace_extensions.dart';
import '../../extensions/ui/extensions_model.dart';
import '../../extensions/ui/vsix_drop.dart';
import '../../l10n/l10n.dart';
import '../../theme/file_icon_theme.dart';
import '../../workspace/window_controls.dart';
import '../extensions/ide_extensions.dart';
import '../extensions/ide_extensions_view.dart';
import '../ide_quick_input.dart';
import '../ide_workspace.dart';

import 'package:bao_editor/monaco/vs/base/common/glob.dart' as glob;

import '../ide_menu.dart';
import '../workbench/contributions.dart';
import '../workbench/environment.dart';
import '../workbench/views.dart';
import 'quick_input.dart';

/// What the Extensions view shows.
enum ExtensionsTab { themes, languageServers }

class ExtensionsViewService extends ChangeNotifier {
  ExtensionsViewService({
    required this.host,
    required this.environment,
    required this.quickInput,
    required this._themes,
    this._workspaceExtensions,
    required this._languageServers,
    required this._notify,
  });

  final WorkbenchHost host;
  final WorkbenchEnvironment environment;
  final QuickInputService quickInput;

  /// The theme extensions, where the app has them; the language servers'.
  final ThemeExtensions? Function() _themes;
  final IdeExtensions? Function() _languageServers;
  ThemeExtensions? get themes => _themes();
  final WorkspaceExtensions? Function()? _workspaceExtensions;
  WorkspaceExtensions? get workspaceExtensions => _workspaceExtensions?.call();
  ExtensionsModel? get model =>
      workspaceExtensions?.extensionsModel ?? themes?.model;
  WorkspaceExtensions? _boundExtensions;
  VoidCallback? _stopContext;
  String? _container;
  String? get container => _container;
  final Set<String> _revealedViews = {};

  List<ExtensionViewDescriptor> get contributedViews {
    final extensions = workspaceExtensions;
    if (extensions == null || _container == null) return const [];
    return [
      for (final view in extensions.views.contributions.viewsIn(_container!))
        if ((!view.hideByDefault || _revealedViews.contains(view.id)) &&
            extensions.contextKeys.contextMatchesRules(view.when))
          view,
    ];
  }

  List<ViewContainerDescriptor> get containers {
    final extensions = workspaceExtensions;
    if (extensions == null) return const [];
    final contributions = extensions.views.contributions;
    return [
      for (final container in contributions.containers)
        if (contributions.viewsIn(container.id).isNotEmpty) container,
      for (final (id, title) in [
        (BuiltinViewContainers.explorer, host.context?.l10n.wbExplorer),
        (BuiltinViewContainers.scm, host.context?.l10n.scmTitle),
        (BuiltinViewContainers.debug, 'Debug'),
        (BuiltinViewContainers.testing, 'Testing'),
      ])
        if (contributions.viewsIn(id).isNotEmpty)
          ViewContainerDescriptor(
            id: id,
            title: title ?? id,
            icon: null,
            extensionId: '',
            location: ViewContainerLocation.sidebar,
            order: 0,
          ),
    ];
  }

  void bindViews(WorkspaceExtensions? extensions) {
    _boundExtensions?.views.removeListener(_viewsChanged);
    _boundExtensions?.views.opener = null;
    _stopContext?.call();
    _boundExtensions = extensions;
    _container = null;
    _revealedViews.clear();
    if (extensions == null) return;
    extensions.views.addListener(_viewsChanged);
    _stopContext = extensions.contextKeys.onDidChangeContext(
      (_) => _viewsChanged(),
    );
    extensions.views.opener = (id, {required focus}) async {
      final view = extensions.views.contributions.view(id);
      if (view == null) return;
      _revealedViews.add(id);
      showContainer(view.containerId);
    };
  }

  void _viewsChanged() {
    if (_container != null &&
        !containers.any((entry) => entry.id == _container)) {
      _container = null;
      if (host.view == IdeSideView.contributed) {
        host.showView(IdeSideView.explorer);
      }
    }
    notifyListeners();
  }

  void showContainer(String id) {
    _container = id;
    host.showView(IdeSideView.contributed);
    notifyListeners();
  }

  List<List<IdeMenuEntry>> resourceMenu(
    String menu,
    String path, {
    bool directory = false,
    List<String>? selected,
  }) {
    final extensions = workspaceExtensions;
    if (extensions == null) return const [];
    final uri = VsUri.file(path);
    final language = extensions.languageIdFor(path);
    final context = extensions.contextKeys.createOverlay({
      'resource': uri.toString(),
      'resourceScheme': uri.scheme,
      'resourceFilename': p.basename(path),
      'resourceBasename': p.basenameWithoutExtension(path),
      'resourceExtname': p.extension(path),
      'resourcePath': path,
      'resourceLangId': language,
      if (menu == 'editor/context') 'editorLangId': language,
      'explorerResourceIsFolder': directory,
    });
    return [
      for (final group in extensions.menus.menuItems(
        menu,
        context,
        args: [
          uri,
          if (selected != null) [for (final path in selected) VsUri.file(path)],
        ],
      ))
        [for (final action in group.actions) ?ideMenuEntryOf(action)],
    ];
  }

  Map<String, String> customEditors(IdeDocument document) {
    final extensions = workspaceExtensions;
    if (extensions == null ||
        !extensions.webviews.renderLive ||
        !document.isFile ||
        document.readOnly ||
        document.diff != null) {
      return const {};
    }
    final matches = <String, String>{};
    for (final extension in extensions.commands.extensions) {
      final editors = extension.contributes['customEditors'];
      if (editors is! List) continue;
      for (final entry in editors) {
        if (entry case {
          'viewType': final String id,
          'selector': final List selectors,
        }) {
          if (selectors.any((selector) {
            if (selector case {'filenamePattern': final String pattern}) {
              return glob.match(pattern, p.basename(document.path));
            }
            return false;
          })) {
            matches[id] = '${entry['displayName'] ?? id}';
          }
        }
      }
    }
    return matches;
  }

  void pickCustomEditor(IdeDocument document) {
    final editors = customEditors(document);
    if (editors.isEmpty) return;
    final items = {
      for (final MapEntry(:key, :value) in editors.entries)
        IdeQuickPickItem(label: value, description: key): key,
    };
    quickInput.showModel(
      IdeQuickPick(
        items: items.keys.toList(),
        onDidAccept: (item) {
          final id = items[item];
          if (id != null) unawaited(_openCustomEditor(document, id));
        },
      ),
    );
  }

  Future<void> _openCustomEditor(IdeDocument document, String id) async {
    final extensions = workspaceExtensions;
    if (extensions == null) return;
    try {
      await extensions.activateCustomEditor(id);
      if (extensions != workspaceExtensions) return;
      final provider = extensions.webviews.textEditors[id];
      if (provider == null) throw StateError(id);
      final surface = await provider(document.path, document.name);
      if (extensions != workspaceExtensions) {
        await surface.closePanel?.call();
        return;
      }
      surface.saveDocument = () => extensions.workspaceSave(document);
      extensions.webviews.reveal(surface.handle);
    } catch (error) {
      host.report(error);
    }
  }

  bool get canInstall => workspaceExtensions != null || themes != null;

  /// [message] told as an error notification.
  final ValueChanged<String> _notify;
  void reportMessage(String message) => _notify(message);

  /// The view's tab: the language servers alone without theme extensions.
  ExtensionsTab get tab => !canInstall ? ExtensionsTab.languageServers : _tab;
  ExtensionsTab _tab = ExtensionsTab.themes;
  set tab(ExtensionsTab tab) {
    if (_tab == tab) return;
    _tab = tab;
    notifyListeners();
  }

  /// The language servers' listing and search, made when it first shows.
  IdeExtensionsSession get session => _session ??= IdeExtensionsSession(
    _languageServers() ?? IdeLanguageServerExtensions(),
  );
  IdeExtensionsSession? _session;

  /// The theme extension whose page has a tab among the editors', as
  /// VS Code's extension editor; and whether its tab is the one in front
  /// (another selected, it stays).
  ExtensionEntry? get page => !canInstall ? null : _page;
  ExtensionEntry? _page;
  bool get pageShown => page != null && _pageShown;
  bool _pageShown = false;

  /// Opens [entry]'s page as an editor, in front of the one open.
  void openPage(ExtensionEntry entry) {
    _page = entry;
    _pageShown = true;
    notifyListeners();
  }

  /// Its tab selected again.
  void showPage() {
    _pageShown = true;
    notifyListeners();
  }

  void closePage() {
    _page = null;
    _pageShown = false;
    notifyListeners();
  }

  /// An editor brought to the front: the page goes behind it.
  void editorShown() {
    if (!_pageShown) return;
    _pageShown = false;
    notifyListeners();
  }

  /// Install from VSIX...: one picked in the open panel.
  Future<void> installFromVsix() async {
    final extensions = workspaceExtensions;
    final backend = extensions?.management ?? themes;
    if (backend == null) return;
    final paths = await WindowControls.pickOpenFiles(multiple: false);
    final context = host.context;
    if (paths.isEmpty || context == null || !context.mounted) return;
    await showVsixInstallSheet(
      context,
      paths.first,
      backend: backend,
      locale: extensions?.app.language ?? themes?.locale,
    );
  }

  /// Takes the .vsix files among [paths] dropped on the window.
  bool drop(List<String> paths) {
    final extensions = workspaceExtensions;
    final backend = extensions?.management ?? themes;
    final context = host.context;
    if (backend == null ||
        context == null ||
        !paths.any((path) => path.toLowerCase().endsWith('.vsix'))) {
      return false;
    }
    unawaited(
      handleExtensionDrop(
        context,
        paths.where((path) => path.toLowerCase().endsWith('.vsix')).toList(),
        backend: backend,
        locale: extensions?.app.language ?? themes?.locale,
        onLoadDevelopmentFolder: (_) {},
      ),
    );
    return true;
  }

  /// Preferences: File Icon Theme: the bundled theme and the extensions';
  /// moving through them previews each, accepting keeps it in
  /// settings.json (`workbench.iconTheme`).
  void selectIconTheme() {
    final context = host.context;
    if (context == null) return;
    final service = FileIconThemeService.instance;
    final current = service.setting;
    final l10n = context.l10n;
    final ids = Map<IdeQuickPickItem, String?>.identity();
    IdeQuickPickItem item(String label, String? id, {String? description}) {
      final entry = IdeQuickPickItem(label: label, description: description);
      ids[entry] = id;
      return entry;
    }

    final bundled = item(
      'Material Icon Theme',
      null,
      description: l10n.themeIconThemeBuiltIn,
    );
    final themes = service.themes
      ..sort((a, b) => ideLocaleCompare(a.label, b.label));
    final items = [
      bundled,
      for (final theme in themes) item(theme.label, theme.id),
    ];
    var accepted = false;
    quickInput.showModel(
      IdeQuickPick(
        items: items,
        placeholder: l10n.themeSelectIconThemePlaceholder,
        activeItems: [
          items.firstWhere(
            (candidate) => ids[candidate] == current,
            orElse: () => bundled,
          ),
        ],
        sortByLabel: false,
        onDidChangeActive: (item) {
          if (item != null) unawaited(service.select(ids[item]));
        },
        onDidAccept: (item) {
          if (item == null) return;
          accepted = true;
          final id = ids[item];
          unawaited(service.select(id));
          unawaited(
            environment.settings?.edit(
              const ['workbench.iconTheme'],
              id,
              remove: id == null,
            ),
          );
        },
        onDidHide: () {
          if (!accepted) unawaited(service.select(current));
        },
      ),
    );
  }

  @override
  void dispose() {
    bindViews(null);
    _session?.dispose();
    super.dispose();
  }
}
