import 'package:flutter/material.dart';

import '../../../extensions/views/tree_view_widget.dart';
import '../../../extensions/views/view_contributions.dart';
import '../../../extensions/workbench/workspace_extensions.dart';
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

  void _sync(WorkspaceExtensions? extensions, Set<String> visible) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.service.workspaceExtensions != extensions) return;
      if (_visibleIn != extensions) _visibleIn?.views.setVisibleViews({});
      _visibleIn = extensions;
      extensions?.views.setVisibleViews(visible);
    });
  }

  @override
  void dispose() {
    final visibleIn = _visibleIn;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      visibleIn?.views.setVisibleViews({});
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.service,
    builder: (context, _) {
      final extensions = widget.service.workspaceExtensions;
      final views = widget.service.contributedViews;
      _sync(extensions, views.map((view) => view.id).toSet());
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
              Expanded(child: Text(tree?.title ?? descriptor.name)),
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
              ? Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(context.l10n.extViewWebviewUnsupported),
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
