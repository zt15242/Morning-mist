import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../extensions/language/registry_language_features.dart';
import 'language_features.dart';
import 'lsp_protocol.dart';

/// Routes editor requests to registered VS Code providers or native LSP.
/// A completion or action is resolved by the source that produced it.
final class WorkbenchLanguageFeatures implements LanguageFeatures {
  WorkbenchLanguageFeatures(this.extensions, this.native)
    : _changes = Listenable.merge([extensions, native]);

  final RegistryLanguageFeatures extensions;
  final LanguageFeatures? native;
  final Listenable _changes;
  final _extensionCommands = Expando<bool>();

  LanguageFeatures _provider(String path, LanguageRequest request) =>
      extensions.supports(path, request) ? extensions : native ?? extensions;

  @override
  void addListener(VoidCallback listener) => _changes.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _changes.removeListener(listener);

  @override
  bool supports(String path, LanguageRequest request) =>
      extensions.supports(path, request) ||
      (native?.supports(path, request) ?? false);

  @override
  List<LspDiagnostic> diagnosticsFor(String path) => [
    ...extensions.diagnosticsFor(path),
    ...?native?.diagnosticsFor(path),
  ];

  @override
  Map<String, List<LspDiagnostic>> get allDiagnostics {
    final extensionDiagnostics = extensions.allDiagnostics;
    final nativeDiagnostics =
        native?.allDiagnostics ?? const <String, List<LspDiagnostic>>{};
    return {
      for (final path in {
        ...extensionDiagnostics.keys,
        ...nativeDiagnostics.keys,
      })
        path: [...?extensionDiagnostics[path], ...?nativeDiagnostics[path]],
    };
  }

  @override
  Set<String> completionTriggerCharacters(String path) => _provider(
    path,
    LanguageRequest.completion,
  ).completionTriggerCharacters(path);

  @override
  Set<String> signatureHelpTriggerCharacters(String path) => _provider(
    path,
    LanguageRequest.signatureHelp,
  ).signatureHelpTriggerCharacters(path);

  @override
  Set<String> signatureHelpRetriggerCharacters(String path) => _provider(
    path,
    LanguageRequest.signatureHelp,
  ).signatureHelpRetriggerCharacters(path);

  @override
  Future<LspCompletionList> completion(
    String path,
    LspPosition position, {
    String? triggerCharacter,
    bool retrigger = false,
  }) async {
    final provider = _provider(path, LanguageRequest.completion);
    final result = await provider.completion(
      path,
      position,
      triggerCharacter: triggerCharacter,
      retrigger: retrigger,
    );
    if (identical(provider, extensions)) {
      for (final item in result.items) {
        _rememberCommand(item.command);
      }
    }
    return result;
  }

  @override
  Future<LspCompletionItem> resolveCompletion(
    String path,
    LspCompletionItem item,
  ) async {
    if (!extensions.ownsResult(item)) {
      return native?.resolveCompletion(path, item) ?? Future.value(item);
    }
    final resolved = await extensions.resolveCompletion(path, item);
    _rememberCommand(resolved.command);
    return resolved;
  }

  @override
  Future<LspSignatureHelp?> signatureHelp(
    String path,
    LspPosition position, {
    String? triggerCharacter,
    bool retrigger = false,
  }) => _provider(path, LanguageRequest.signatureHelp).signatureHelp(
    path,
    position,
    triggerCharacter: triggerCharacter,
    retrigger: retrigger,
  );

  @override
  Future<List<LspLocation>> references(
    String path,
    LspPosition position, {
    bool includeDeclaration = true,
  }) => _provider(
    path,
    LanguageRequest.references,
  ).references(path, position, includeDeclaration: includeDeclaration);

  @override
  Future<({LspRange range, String placeholder})?> prepareRename(
    String path,
    LspPosition position,
  ) => _provider(path, LanguageRequest.rename).prepareRename(path, position);

  @override
  Future<LspWorkspaceEdit?> rename(
    String path,
    LspPosition position,
    String newName,
  ) => _provider(path, LanguageRequest.rename).rename(path, position, newName);

  @override
  Future<List<LspTextEdit>> format(
    String path, {
    LspRange? range,
    required int tabSize,
    required bool insertSpaces,
  }) => _provider(
    path,
    range == null ? LanguageRequest.format : LanguageRequest.rangeFormat,
  ).format(path, range: range, tabSize: tabSize, insertSpaces: insertSpaces);

  @override
  Future<List<LspDocumentSymbol>> documentSymbols(String path) =>
      _provider(path, LanguageRequest.documentSymbols).documentSymbols(path);

  @override
  Future<List<LspCodeAction>> codeActions(
    String path,
    LspRange range, {
    List<LspDiagnostic> diagnostics = const [],
    List<String>? only,
  }) async {
    final provider = _provider(path, LanguageRequest.codeActions);
    final result = await provider.codeActions(
      path,
      range,
      diagnostics: diagnostics,
      only: only,
    );
    if (identical(provider, extensions)) {
      for (final action in result) {
        _rememberCommand(action.command);
      }
    }
    return result;
  }

  @override
  Future<LspCodeAction> resolveCodeAction(
    String path,
    LspCodeAction action,
  ) async {
    if (!extensions.ownsResult(action)) {
      return native?.resolveCodeAction(path, action) ?? Future.value(action);
    }
    final resolved = await extensions.resolveCodeAction(path, action);
    _rememberCommand(resolved.command);
    return resolved;
  }

  void _rememberCommand(LspCommand? command) {
    if (command != null) _extensionCommands[command] = true;
  }

  @override
  Future<void> executeCommand(
    String path,
    LspCommand command, {
    String? serverId,
  }) =>
      (_extensionCommands[command] == true ? extensions : native ?? extensions)
          .executeCommand(path, command, serverId: serverId);

  @override
  Future<List<LspSemanticToken>?> semanticTokens(String path) =>
      _provider(path, LanguageRequest.semanticTokens).semanticTokens(path);

  @override
  Stream<LspApplyEditRequest> get workspaceEdits => Stream.multi((output) {
    final local = native?.workspaceEdits.listen(
      output.addSync,
      onError: output.addErrorSync,
    );
    final extension = extensions.workspaceEdits.listen(
      output.addSync,
      onError: output.addErrorSync,
    );
    output.onCancel = () async {
      await Future.wait([
        if (local != null) local.cancel(),
        extension.cancel(),
      ]);
    };
  });

  @override
  Stream<LspServerMessage> get serverMessages =>
      native?.serverMessages ?? const Stream.empty();

  @override
  Listenable get progressChanges =>
      native?.progressChanges ?? extensions.progressChanges;

  @override
  List<LanguageServerStatus> statusFor(String path) =>
      native?.statusFor(path) ?? const [];

  @override
  List<String> logFor(String serverId, {String? path}) =>
      native?.logFor(serverId, path: path) ?? const [];

  @override
  void retry(String serverId, {String? path}) =>
      native?.retry(serverId, path: path);

  @override
  Future<void> install(String serverId, {String? path}) async =>
      native?.install(serverId, path: path);

  @override
  Future<LspHover?> hover(String path, LspPosition position) =>
      _provider(path, LanguageRequest.hover).hover(path, position);

  @override
  Future<List<LspLocation>> definition(String path, LspPosition position) =>
      _provider(path, LanguageRequest.definition).definition(path, position);

  @override
  Future<List<LspLocation>> typeDefinition(String path, LspPosition position) =>
      _provider(
        path,
        LanguageRequest.typeDefinition,
      ).typeDefinition(path, position);

  @override
  Future<List<LspLocation>> implementation(String path, LspPosition position) =>
      _provider(
        path,
        LanguageRequest.implementation,
      ).implementation(path, position);
}
