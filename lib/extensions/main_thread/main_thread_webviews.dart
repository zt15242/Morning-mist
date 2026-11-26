/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

// Main-thread actors for extension Webviews. Custom editors use the text
// editor fallback until their document lifecycle is wired to the workbench.

import 'dart:async';

import 'package:bao_exthost/bao_exthost.dart';

import '../window/webview_degradation.dart';
import '../window/webview_placeholders.dart';
import 'main_thread_context.dart';

/// The UI a session's Webviews degrade with; the workbench passes one, and
/// the shapes fall back to the placeholders alone when it does not.
ExtensionWebviewUi _uiOf(MainThreadContext context) =>
    context.maybeService<ExtensionWebviewUi>() ??
    ExtensionWebviewUi(
      placeholders: context.service<ExtensionWebviewPlaceholders>(),
    );

final class MainThreadWebviews extends MainThreadWebviewsUnsupported {
  MainThreadWebviews(this._ui);

  final ExtensionWebviewUi _ui;

  static RpcActor customer(MainThreadContext context) =>
      MainThreadWebviewsActor(MainThreadWebviews(_uiOf(context)));

  @override
  void $setHtml(String handle, String value) =>
      _ui.placeholders.setHtml(handle, value);

  @override
  void $setOptions(String handle, Map<String, Object?> options) =>
      _ui.placeholders.setOptions(handle, options);

  @override
  Future<bool> $postMessage(
    String handle,
    String value,
    List<RpcBuffer> buffers,
  ) async {
    if (buffers.isNotEmpty) return false;
    final surface = _ui.placeholders.placeholder(handle);
    return surface?.postMessage(value) ?? false;
  }
}

final class MainThreadWebviewPanels extends MainThreadWebviewPanelsUnsupported {
  MainThreadWebviewPanels(this._ui, this._notices, this._proxy, this._webviews);

  final ExtensionWebviewUi _ui;
  final ExtensionWebviewNotices _notices;
  final ExtHostWebviewPanelsProxy _proxy;
  final ExtHostWebviewsProxy _webviews;
  final _handles = <String>{};

  /// The serializers extensions registered; never run (a restored panel is
  /// disposed like a fresh one).
  final Set<String> serializers = {};

  static RpcActor customer(MainThreadContext context) {
    final ui = _uiOf(context);
    final actor = MainThreadWebviewPanels(
      ui,
      ExtensionWebviewNotices(ui),
      ExtHostWebviewPanelsProxy(context.rpc),
      ExtHostWebviewsProxy(context.rpc),
    );
    context.onDispose(() {
      for (final handle in actor._handles) {
        ui.placeholders.remove(handle);
      }
    });
    return MainThreadWebviewPanelsActor(actor);
  }

  @override
  void $createWebviewPanel(
    Map<String, Object?> extension,
    String handle,
    String viewType,
    Map<String, Object?> initData,
    Map<String, Object?> showOptions,
  ) {
    final title = '${initData['title'] ?? viewType}';
    final placeholder = _ui.placeholders.showPanel(
      handle: handle,
      extension: extension,
      viewType: viewType,
      title: title,
    );
    _handles.add(handle);
    if (_ui.placeholders.renderLive) {
      if (initData['webviewOptions'] case final Map options) {
        _ui.placeholders.setOptions(handle, options.cast());
      }
      placeholder.receiveMessage = (value) =>
          _webviews.$onMessage(handle, value, const RpcObjectWithBuffers([]));
      placeholder.closePanel = () async {
        $disposeWebview(handle);
        await _proxy.$onDidDisposeWebviewPanel(handle);
      };
      _ui.placeholders.reveal(handle);
      return;
    }
    _notices.notice(
      extension,
      _ui.strings.windowWebviewPanelDetail(placeholder.extensionName, title),
      primary: webviewFallbackActions(_ui, handle),
      logLine: placeholder.description,
    );
    // The extension's panel closed right away: it sees onDidDispose.
    unawaited(
      _proxy.$onDidDisposeWebviewPanel(handle).catchError((Object _) {}),
    );
  }

  @override
  void $disposeWebview(String handle) {
    _handles.remove(handle);
    _ui.placeholders.remove(handle);
  }

  @override
  void $reveal(String handle, Map<String, Object?> showOptions) =>
      _ui.placeholders.reveal(handle);

  @override
  void $setTitle(String handle, String value) {
    _ui.placeholders.setTitle(handle, value);
  }

  @override
  void $setIconPath(String handle, Map<String, Object?>? value) =>
      _ui.placeholders.icon[handle] = value ?? const {};

  @override
  void $registerSerializer(String viewType, Map<String, Object?> options) =>
      serializers.add(viewType);

  @override
  void $unregisterSerializer(String viewType) => serializers.remove(viewType);
}

final class MainThreadWebviewViews extends MainThreadWebviewViewsUnsupported {
  MainThreadWebviewViews(this._ui, this._proxy, this._webviews);

  final ExtensionWebviewUi _ui;
  final ExtHostWebviewViewsProxy _proxy;
  final ExtHostWebviewsProxy _webviews;
  final _resolved = <String>{};

  /// The view types of the providers that registered
  /// (`$registerWebviewViewProvider`).
  final Map<String, Map<String, Object?>> providers = {};

  static RpcActor customer(MainThreadContext context) {
    final actor = MainThreadWebviewViews(
      _uiOf(context),
      ExtHostWebviewViewsProxy(context.rpc),
      ExtHostWebviewsProxy(context.rpc),
    );
    if (actor._ui.placeholders.renderLive) {
      context.listen(
        actor._ui.placeholders.visibility.listen((event) {
          final (type, visible) = event;
          if (actor.providers.containsKey(type)) {
            actor._setVisible(type, visible);
          }
        }),
      );
    }
    context.onDispose(() {
      for (final type in actor.providers.keys) {
        actor._ui.placeholders.remove('view:$type');
      }
    });
    return MainThreadWebviewViewsActor(actor);
  }

  void _setVisible(String type, bool visible) {
    final surface = _ui.placeholders.viewOf(type);
    if (surface == null) return;
    final handle = surface.handle;
    if (visible && _resolved.add(type)) {
      unawaited(
        _proxy
            .$resolveWebviewView(
              handle,
              type,
              _ui.placeholders.title[handle],
              surface.state,
            )
            .catchError((Object error) {
              _resolved.remove(type);
              _ui.placeholders.logLine(
                'Could not open extension Webview $type: $error',
              );
              _ui.placeholders.setFailure(handle, '$error');
            }),
      );
    } else if (_resolved.contains(type)) {
      unawaited(
        _proxy
            .$onDidChangeWebviewViewVisibility(handle, visible)
            .catchError((Object _) {}),
      );
    }
  }

  @override
  void $registerWebviewViewProvider(
    Map<String, Object?> extension,
    String viewType,
    Map<String, Object?> options,
  ) {
    providers[viewType] = extension;
    final surface = _ui.placeholders.showView(
      viewType: viewType,
      extension: extension,
      title: viewType,
    );
    if (!_ui.placeholders.renderLive) return;
    surface.receiveMessage = (value) => _webviews.$onMessage(
      surface.handle,
      value,
      const RpcObjectWithBuffers([]),
    );
    if (_ui.placeholders.viewVisible(viewType)) _setVisible(viewType, true);
  }

  @override
  void $unregisterWebviewViewProvider(String viewType) {
    providers.remove(viewType);
    final surface = _ui.placeholders.viewOf(viewType);
    if (surface == null) return;
    if (_resolved.remove(viewType)) {
      unawaited(
        _proxy.$disposeWebviewView(surface.handle).catchError((Object _) {}),
      );
    }
    _ui.placeholders.remove(surface.handle);
  }

  @override
  void $setWebviewViewTitle(String handle, String? value) =>
      _ui.placeholders.setTitle(handle, value);

  @override
  void $setWebviewViewDescription(String handle, String? value) =>
      _ui.placeholders.description[handle] = value;

  @override
  void $setWebviewViewBadge(String handle, Map<String, Object?>? badge) =>
      _ui.placeholders.badge[handle] = badge ?? const {};

  @override
  void $show(String handle, bool preserveFocus) =>
      _ui.placeholders.reveal(handle);
}

final class MainThreadCustomEditors extends MainThreadCustomEditorsUnsupported {
  MainThreadCustomEditors(this._ui, this._proxy, this._webviews, this._panels);

  final ExtHostCustomEditorsProxy _proxy;
  final ExtHostWebviewsProxy _webviews;
  final ExtHostWebviewPanelsProxy _panels;
  final _handles = <String>{};
  final _textProviders = <String>{};
  int _next = 0;

  final ExtensionWebviewUi _ui;

  /// The view types of the registered providers; their documents open in
  /// BaoCode's own editors.
  final Map<String, Map<String, Object?>> providers = {};

  static RpcActor customer(MainThreadContext context) {
    final actor = MainThreadCustomEditors(
      _uiOf(context),
      ExtHostCustomEditorsProxy(context.rpc),
      ExtHostWebviewsProxy(context.rpc),
      ExtHostWebviewPanelsProxy(context.rpc),
    );
    context.onDispose(() {
      for (final type in actor._textProviders) {
        actor._ui.placeholders.textEditors.remove(type);
      }
      for (final handle in actor._handles) {
        actor._ui.placeholders.remove(handle);
      }
    });
    return MainThreadCustomEditorsActor(actor);
  }

  Future<WebviewPlaceholder> _openTextEditor(
    Map<String, Object?> extension,
    String viewType,
    String path,
    String title,
  ) async {
    final handle = 'custom-text-editor:${_next++}';
    final model = _ui.placeholders;
    final surface = model.showTextEditor(
      handle: handle,
      viewType: viewType,
      extension: extension,
      title: title,
    );
    _handles.add(handle);
    surface.receiveMessage = (value) =>
        _webviews.$onMessage(handle, value, const RpcObjectWithBuffers([]));
    surface.closePanel = () async {
      if (!_handles.remove(handle)) return;
      model.remove(handle);
      await _panels.$onDidDisposeWebviewPanel(handle);
    };
    try {
      await _proxy.$resolveCustomEditor(VsUri.file(path), handle, viewType, {
        'title': title,
        'contentOptions': <String, Object?>{},
        'options': <String, Object?>{},
        'active': true,
      }, 0);
      return surface;
    } catch (error) {
      _handles.remove(handle);
      model.remove(handle);
      rethrow;
    }
  }

  @override
  void $registerTextEditorProvider(
    Map<String, Object?> extension,
    String viewType,
    Map<String, Object?> options,
    Map<String, Object?> capabilities,
    bool serializeBuffersForPostMessage,
  ) {
    if (!_ui.placeholders.renderLive) {
      _register(extension, viewType);
      return;
    }
    _textProviders.add(viewType);
    _ui.placeholders.textEditors[viewType] = (path, title) =>
        _openTextEditor(extension, viewType, path, title);
  }

  @override
  void $registerCustomEditorProvider(
    Map<String, Object?> extension,
    String viewType,
    Map<String, Object?> options,
    Map<String, Object?> capabilities,
    bool supportsMultipleEditorsPerDocument,
    bool serializeBuffersForPostMessage,
  ) => _register(extension, viewType);

  void _register(Map<String, Object?> extension, String viewType) {
    providers[viewType] = extension;
    final placeholder = _ui.placeholders.showCustomEditor(
      viewType: viewType,
      extension: extension,
    );
    // One line per extension and editor type, in the Output panel: the
    // notice itself would be too much for an editor no document uses yet.
    _ui.placeholders.logLine(placeholder.description);
  }

  @override
  void $unregisterEditorProvider(String viewType) {
    providers.remove(viewType);
    _textProviders.remove(viewType);
    _ui.placeholders.textEditors.remove(viewType);
  }

  /// A resolved custom editor's edits: it never opened one.
  @override
  void $onDidEdit(VsUri resource, String viewType, num editId, String? label) {}

  /// A resolved custom editor's content changed: it never opened one.
  @override
  void $onContentChange(VsUri resource, String viewType) {}
}
