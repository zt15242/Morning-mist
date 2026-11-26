import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'extension_webview_server.dart';
import 'webview_placeholders.dart';

/// One extension's browser surface, with its own content and message origin.
class ExtensionWebview extends StatefulWidget {
  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  const ExtensionWebview({
    super.key,
    required this.model,
    required this.surface,
  });

  final ExtensionWebviewPlaceholders model;
  final WebviewPlaceholder surface;

  @override
  State<ExtensionWebview> createState() => _ExtensionWebviewState();
}

class _ExtensionWebviewState extends State<ExtensionWebview> {
  ExtensionWebviewServer? _server;
  InAppWebViewController? _controller;
  Uri? _page;
  Object? _error;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_update);
    _update();
  }

  void _update() {
    final surface = widget.surface;
    final markup = widget.model.html[surface.handle];
    if (markup == null) {
      if (surface.failure != null) setState(() => _error = surface.failure);
      return;
    }
    if (_server == null) {
      final server = _server = ExtensionWebviewServer(
        readHtml: () => widget.model.html[surface.handle] ?? '',
        readOptions: () => widget.model.options[surface.handle] ?? const {},
        onMessage: (value) async => surface.receiveMessage?.call(value),
        readState: () => surface.state,
        saveState: (value) => surface.state = value,
      );
      unawaited(
        server.start().then(
          (page) {
            if (!mounted) return;
            surface.attachRenderer(server.send);
            setState(() => _page = page);
          },
          onError: (Object error) {
            if (mounted) setState(() => _error = error);
          },
        ),
      );
    }
    if (_revision != surface.revision) {
      _revision = surface.revision;
      unawaited(_controller?.reload());
    }
  }

  @override
  void dispose() {
    widget.model.removeListener(_update);
    widget.surface.deliverMessage = null;
    unawaited(_server?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    if (_error case final error?) {
      return Center(child: SelectableText('$error'));
    }
    if (page == null) return const Center(child: CircularProgressIndicator());
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(page.toString())),
      initialSettings: InAppWebViewSettings(
        javaScriptCanOpenWindowsAutomatically: false,
        useShouldOverrideUrlLoading: true,
        allowFileAccess: false,
        allowFileAccessFromFileURLs: false,
        allowUniversalAccessFromFileURLs: false,
        incognito: true,
        isInspectable: false,
      ),
      onWebViewCreated: (controller) => _controller = controller,
      onReceivedError: (_, request, error) {
        if (request.isForMainFrame == true && mounted) {
          setState(() => _error = error.description);
        }
      },
      shouldOverrideUrlLoading: (_, action) async {
        final url = action.request.url;
        return action.isForMainFrame &&
                url != null &&
                Uri.tryParse(url.toString())?.removeFragment() == page
            ? NavigationActionPolicy.ALLOW
            : NavigationActionPolicy.CANCEL;
      },
    );
  }
}
