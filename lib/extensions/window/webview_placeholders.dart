// Webview lifecycle state shared by the extension host and Fast IDE.

import 'dart:async';

import 'package:flutter/foundation.dart';

/// The kinds of surfaces a VS Code extension can request.
enum WebviewKind { panel, view, customEditor, notebook }

/// One extension surface and its connection to the host.
final class WebviewPlaceholder {
  WebviewPlaceholder({
    required this.handle,
    required this.kind,
    required this.extension,
    required this.viewType,
    required this.title,
  });

  /// The extension host's handle, or the view type for a view.
  final String handle;
  final WebviewKind kind;

  /// The extension that asked (`IExtensionDescription`'s fields).
  final Map<String, Object?> extension;

  /// The panel's or provider's `viewType`.
  final String viewType;

  /// Its title, as the extension set it.
  String title;

  /// It was shown again after being hidden.
  bool revealed = false;

  /// Wiring for live surfaces. Kept on the handle so a renderer never
  /// sends messages to another extension or a replacement host.
  Future<void> Function(String)? receiveMessage;
  bool Function(String)? deliverMessage;
  Future<void> Function()? closePanel;
  Future<void> Function()? saveDocument;
  Object? state;
  int revision = 0;
  String? failure;
  final _queued = <String>[];

  bool postMessage(String value) {
    if (receiveMessage == null || value.length > 1024 * 1024) return false;
    final deliver = deliverMessage;
    if (deliver != null) return deliver(value);
    if (_queued.length >= 100) return false;
    _queued.add(value);
    return true;
  }

  void attachRenderer(bool Function(String) deliver) {
    deliverMessage = deliver;
    for (final message in _queued) {
      deliver(message);
    }
    _queued.clear();
  }

  /// `IExtensionDescription.identifier`, or a `WebviewExtensionDescription`'s
  /// `id` (all a panel, view or custom editor is sent).
  String get extensionId =>
      switch (extension['identifier'] ?? extension['id']) {
        final Map<Object?, Object?> id => '${id['value']}',
        final String id => id,
        _ => '${extension['publisher']}.${extension['name']}',
      };

  /// The extension's display name, when the workbench knows it.
  String? displayName;

  String get extensionName =>
      '${displayName ?? extension['displayName'] ?? extensionId}';

  /// The line the Output panel gets: what could not be shown, and why.
  String get description => kind == WebviewKind.notebook
      ? 'The $extensionName extension\'s notebook type "$title" ($viewType) '
            'needs a notebook editor, which BaoCode does not support; its '
            'files open as text.'
      : 'The $extensionName extension\'s ${switch (kind) {
              WebviewKind.panel => 'panel',
              WebviewKind.view => 'view',
              _ => 'editor',
            }} "$title" ($viewType) needs a Webview, which BaoCode does not '
            'support.';
}

/// Every Webview an extension asked for in a session.
final class ExtensionWebviewPlaceholders extends ChangeNotifier {
  final Map<String, WebviewPlaceholder> _placeholders = {};
  bool renderLive = false;
  void Function(WebviewPlaceholder)? onRevealPanel;
  void Function(String)? onRevealView;
  final textEditors =
      <
        String,
        Future<WebviewPlaceholder> Function(String path, String title)
      >{};

  WebviewPlaceholder showTextEditor({
    required String handle,
    required String viewType,
    required Map<String, Object?> extension,
    required String title,
  }) => _add(
    WebviewPlaceholder(
      handle: handle,
      kind: WebviewKind.customEditor,
      extension: extension,
      viewType: viewType,
      title: title,
    ),
  );
  final _visibleViews = <String>{};
  bool _disposed = false;
  final _visibility = StreamController<(String, bool)>.broadcast(sync: true);
  Stream<(String, bool)> get visibility => _visibility.stream;
  bool viewVisible(String id) => _visibleViews.contains(id);

  void setViewVisible(String id, bool visible) {
    final changed = visible ? _visibleViews.add(id) : _visibleViews.remove(id);
    if (changed && !_visibility.isClosed) _visibility.add((id, visible));
  }

  void setTitle(String handle, String? value) {
    title[handle] = value;
    if (value != null) _placeholders[handle]?.title = value;
    notifyListeners();
  }

  void setFailure(String handle, String failure) {
    _placeholders[handle]?.failure = failure;
    notifyListeners();
  }

  void setHtml(String handle, String value) {
    html[handle] = value;
    final surface = _placeholders[handle];
    if (surface == null) return;
    surface.revision++;
    notifyListeners();
  }

  void setOptions(String handle, Map<String, Object?> value) {
    final previous = options[handle];
    options[handle] = value;
    final surface = _placeholders[handle];
    if (surface == null) return;
    if (previous?['enableScripts'] != value['enableScripts']) {
      surface.revision++;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_visibility.close());
    super.dispose();
  }

  /// The lines the Output panel's "Extension Host" channel gets, in
  /// order: one per Webview an extension asked for.
  final List<String> logLines = [];

  /// Where each line goes as it is added (the Output panel's "Extension
  /// Host" channel).
  void Function(String line)? onLogLine;

  /// An extension's display name by id, for the notices and lines.
  String? Function(String extensionId)? nameOf;

  /// Adds [line] for the Output panel.
  void logLine(String line) {
    logLines.add(line);
    onLogLine?.call(line);
    notifyListeners();
  }

  /// The HTML each webview was given, by handle.
  final Map<String, String> html = {};

  /// The content options each webview was given.
  final Map<String, Map<String, Object?>> options = {};

  /// The title an extension set on a webview or a view.
  final Map<String, String?> title = {};

  /// The description a view was given.
  final Map<String, String?> description = {};

  /// The badge a view was given.
  final Map<String, Map<String, Object?>> badge = {};

  /// The icon a panel was given.
  final Map<String, Map<String, Object?>> icon = {};

  /// The placeholders, most recent first.
  List<WebviewPlaceholder> get placeholders =>
      _placeholders.values.toList().reversed.toList();

  /// The panels among them.
  List<WebviewPlaceholder> get panels => _ofKind(WebviewKind.panel);

  /// The views among them.
  List<WebviewPlaceholder> get views => _ofKind(WebviewKind.view);

  /// The custom editors among them.
  List<WebviewPlaceholder> get customEditors =>
      _ofKind(WebviewKind.customEditor);

  List<WebviewPlaceholder> _ofKind(WebviewKind kind) => [
    for (final placeholder in placeholders)
      if (placeholder.kind == kind) placeholder,
  ];

  WebviewPlaceholder? placeholder(String handle) => _placeholders[handle];

  WebviewPlaceholder? viewOf(String viewType) =>
      _placeholders['view:$viewType'];

  /// A panel was created (`$createWebviewPanel`).
  WebviewPlaceholder showPanel({
    required String handle,
    required Map<String, Object?> extension,
    required String viewType,
    required String title,
  }) => _add(
    WebviewPlaceholder(
      handle: handle,
      kind: WebviewKind.panel,
      extension: extension,
      viewType: viewType,
      title: title,
    ),
  );

  /// A view provider registered (`$registerWebviewViewProvider`).
  WebviewPlaceholder showView({
    required String viewType,
    required Map<String, Object?> extension,
    required String title,
  }) => _add(
    WebviewPlaceholder(
      handle: 'view:$viewType',
      kind: WebviewKind.view,
      extension: extension,
      viewType: viewType,
      title: title,
    ),
  );

  /// A custom editor provider registered
  /// (`$registerCustomEditorProvider`).
  WebviewPlaceholder showCustomEditor({
    required String viewType,
    required Map<String, Object?> extension,
  }) => _add(
    WebviewPlaceholder(
      handle: 'editor:$viewType',
      kind: WebviewKind.customEditor,
      extension: extension,
      viewType: viewType,
      title: viewType,
    ),
  );

  /// A notebook serializer registered (`$registerNotebookSerializer`).
  WebviewPlaceholder showNotebook({
    required String viewType,
    required Map<String, Object?> extension,
    required String title,
  }) => _add(
    WebviewPlaceholder(
      handle: 'notebook:$viewType',
      kind: WebviewKind.notebook,
      extension: extension,
      viewType: viewType,
      title: title,
    ),
  );

  /// The notebook types among them.
  List<WebviewPlaceholder> get notebooks => _ofKind(WebviewKind.notebook);

  WebviewPlaceholder _add(WebviewPlaceholder placeholder) {
    placeholder.displayName ??= nameOf?.call(placeholder.extensionId);
    _placeholders[placeholder.handle] = placeholder;
    notifyListeners();
    return placeholder;
  }

  /// It was shown again (`$reveal`, `$show`): the placeholder notes it,
  /// where upstream would bring the view forward.
  void reveal(String handle) {
    final placeholder = _placeholders[handle];
    if (placeholder == null) return;
    placeholder.revealed = true;
    if (renderLive && placeholder.kind == WebviewKind.view) {
      onRevealView?.call(placeholder.viewType);
    }
    if (renderLive &&
        (placeholder.kind == WebviewKind.panel ||
            placeholder.kind == WebviewKind.customEditor)) {
      onRevealPanel?.call(placeholder);
    }
    notifyListeners();
  }

  void remove(String handle) {
    if (_disposed) return;
    if (_placeholders.remove(handle) == null) return;
    html.remove(handle);
    options.remove(handle);
    title.remove(handle);
    icon.remove(handle);
    description.remove(handle);
    badge.remove(handle);
    notifyListeners();
  }

  /// Forgets everything (the session ended).
  void clear() {
    _placeholders.clear();
    logLines.clear();
    html.clear();
    options.clear();
    title.clear();
    description.clear();
    badge.clear();
    icon.clear();
    notifyListeners();
  }
}
