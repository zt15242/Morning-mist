import 'package:flutter/material.dart';

import '../../../extensions/views/tree_view_widget.dart';
import '../../../extensions/views/view_contributions.dart';
import '../../../extensions/workbench/workspace_extensions.dart';
import '../../../extensions/window/extension_webview.dart';
import '../../../l10n/l10n.dart';
import '../../../workspace/editor_launcher.dart';
import '../../services/extensions_view.dart';

/// Hosts extension-contributed trees while their activity-bar item is open.
class ExtensionViewsPart extends StatefulWidget {
  const ExtensionViewsPart({super.key, required this.service});

  final ExtensionsViewService service;

  @override
  State<ExtensionViewsPart> createState() => _ExtensionViewsPartState();
}

class _ExtensionViewsPartState extends State<ExtensionViewsPart> {
  WorkspaceExtensions? _visibleIn;
  Set<String> _visibleWebviews = const {};

  void _sync(
    WorkspaceExtensions? extensions,
    List<ExtensionViewDescriptor> views,
  ) {
    final visible = {for (final view in views) view.id};
    final webviews = {
      for (final view in views)
        if (view.type == ExtensionViewType.webview) view.id,
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.service.workspaceExtensions != extensions) return;
      if (_visibleIn != extensions) {
        _visibleIn?.views.setVisibleViews({});
        for (final id in _visibleWebviews) {
          _visibleIn?.webviews.setViewVisible(id, false);
        }
        _visibleWebviews = const {};
      }
      for (final id in _visibleWebviews.difference(webviews)) {
        extensions?.webviews.setViewVisible(id, false);
      }
      for (final id in webviews.difference(_visibleWebviews)) {
        extensions?.webviews.setViewVisible(id, true);
      }
      _visibleWebviews = webviews;
      _visibleIn = extensions;
      extensions?.views.setVisibleViews(visible);
    });
  }

  @override
  void dispose() {
    final visibleIn = _visibleIn;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      visibleIn?.views.setVisibleViews({});
      for (final id in _visibleWebviews) {
        visibleIn?.webviews.setViewVisible(id, false);
      }
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.service,
    builder: (context, _) {
      final extensions = widget.service.workspaceExtensions;
      final views = widget.service.contributedViews;
      _sync(extensions, views);
      if (extensions == null) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final descriptor in views)
            Expanded(
              key: ValueKey(descriptor.id),
              child: _view(context, extensions, descriptor),
            ),
        ],
      );
    },
  );

  Widget _view(
    BuildContext context,
    WorkspaceExtensions extensions,
    ExtensionViewDescriptor descriptor,
  ) {
    final tree = extensions.views.treeView(descriptor.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(
                child: tree != null
                    ? Text(tree.title)
                    : ListenableBuilder(
                        listenable: extensions.webviews,
                        builder: (context, _) {
                          final model = extensions.webviews;
                          final surface = model.viewOf(descriptor.id);
                          return Text(
                            model.title[surface?.handle] ?? descriptor.name,
                          );
                        },
                      ),
              ),
              ExtensionViewTitleActions(
                viewId: descriptor.id,
                menus: extensions.menus,
                contextKeys: extensions.contextKeys,
                treeView: tree,
              ),
            ],
          ),
        ),
        Expanded(
          child: tree == null
              ? ListenableBuilder(
                  listenable: extensions.webviews,
                  builder: (context, _) {
                    if (!extensions.webviews.renderLive) {
                      return Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(context.l10n.extViewWebviewUnsupported),
                      );
                    }
                    final surface = extensions.webviews.viewOf(descriptor.id);
                    if (surface == null) return const SizedBox.shrink();
                    return ExtensionWebview(
                      key: ObjectKey(surface),
                      model: extensions.webviews,
                      surface: surface,
                    );
                  },
                )
              : ExtensionTreeViewBody(
                  treeView: tree,
                  menus: extensions.menus,
                  contextKeys: extensions.contextKeys,
                  executeCommand: extensions.commands.executeCommand,
                  welcome: extensions.views.contributions.welcomeFor(
                    descriptor.id,
                  ),
                  decorations: extensions.decorations,
                  openLink: (href) {
                    final uri = Uri.tryParse(href);
                    if (uri != null &&
                        (uri.scheme == 'https' || uri.scheme == 'http')) {
                      openExternal(href);
                    }
                  },
                  onFocusChange: (focused) => extensions.views.setFocusedView(
                    focused ? descriptor.id : null,
                  ),
                  onError: widget.service.reportMessage,
                ),
        ),
      ],
    );
  }
}
