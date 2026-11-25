import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../crm/crm_connectors.dart';
import '../../ide/ide_button.dart';
import '../../ide/ide_dialog.dart';
import '../../l10n/l10n.dart';
import '../../models/codex/codex_oauth.dart' show codexState;
import 'model_dialogs.dart';
import 'settings_widgets.dart';

class CrmConnectorsPage extends StatefulWidget {
  const CrmConnectorsPage({super.key});

  @override
  State<CrmConnectorsPage> createState() => _CrmConnectorsPageState();
}

class _CrmConnectorsPageState extends State<CrmConnectorsPage> {
  final _store = CrmConnectors();
  List<CrmConnector>? _connections;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) unawaited(_load());
  }

  Future<void> _load() => _run(() async {
    final items = await _store.load();
    if (mounted) setState(() => _connections = items);
  });

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        final l10n = context.l10n;
        setState(
          () => _message = error is CrmHttpException
              ? l10n.crmHttpError(error.status)
              : error is CrmNeoCliUnavailable
              ? l10n.crmNeoCliUnavailable
              : _connections == null
              ? l10n.crmLoadFailed
              : l10n.crmOperationFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(List<CrmConnector> items) async {
    await _store.save(items);
    if (mounted) setState(() => _connections = items);
  }

  Future<void> _put(CrmConnector item) {
    final items = [..._connections!];
    final index = items.indexWhere((entry) => entry.id == item.id);
    if (index == -1) {
      items.add(item);
    } else {
      items[index] = item;
    }
    return _save(items);
  }

  Future<void> _edit([CrmConnector? connector]) async {
    final result = await showDialog<CrmConnector>(
      context: context,
      builder: (_) => _ConnectorEditor(connector: connector),
    );
    if (mounted && result != null) await _run(() => _put(result));
  }

  Future<void> _delete(CrmConnector connector) async {
    final l10n = context.l10n;
    final answer = await showIdeDialog(
      context,
      message: l10n.crmDeleteQuestion(connector.name),
      buttons: [l10n.commonDelete],
    );
    if (mounted && answer == 0) {
      await _run(
        () => _save([
          for (final item in _connections!)
            if (item.id != connector.id) item,
        ]),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = _connections;
    final disabled = _busy;
    return SettingsPage(
      title: l10n.crmConnectors,
      description: kIsWeb ? l10n.crmDesktopOnly : l10n.crmDescription,
      children: [
        if (!kIsWeb && (items != null || _message != null))
          SettingsCard(
            children: [
              SettingsRow(
                label:
                    _message ??
                    (disabled ? l10n.crmWorking : l10n.crmConnections),
                description: items != null && items.isEmpty
                    ? l10n.crmEmpty
                    : null,
                trailing: items == null
                    ? IdeButton(
                        label: l10n.crmRetryLoad,
                        onPressed: disabled ? null : () => unawaited(_load()),
                      )
                    : IdeButton(
                        label: l10n.crmAdd,
                        onPressed: disabled ? null : () => unawaited(_edit()),
                      ),
              ),
              for (final item in items ?? const <CrmConnector>[])
                _row(context, item, disabled),
            ],
          ),
        if (_busy && items == null) const LinearProgressIndicator(),
      ],
    );
  }

  Widget _row(BuildContext context, CrmConnector connector, bool disabled) {
    final l10n = context.l10n;
    final stored = connector['accessToken'].isNotEmpty;
    final expiry = DateTime.tryParse(connector['expiresAt'])?.toLocal();
    final expired = expiry?.isBefore(DateTime.now()) ?? false;
    final status = !stored
        ? l10n.crmDisconnected
        : expired
        ? l10n.crmExpired
        : l10n.crmConnected;
    final deadline = expiry == null
        ? ''
        : ' · ${MaterialLocalizations.of(context).formatShortDate(expiry)} ${TimeOfDay.fromDateTime(expiry).format(context)}';
    return SettingsRow(
      label: connector.name,
      description:
          '${_product(context, connector.product)} · ${connector['baseUrl']}\n$status$deadline',
      below: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            IdeButton(
              label: stored ? l10n.crmRenew : l10n.crmConnect,
              onPressed: disabled
                  ? null
                  : () => unawaited(
                      _run(() async {
                        final item = await _store.connect(
                          connector,
                          refresh: stored,
                        );
                        await _put(item);
                      }),
                    ),
            ),
            IdeButton(
              secondary: true,
              label: l10n.crmTest,
              onPressed: disabled
                  ? null
                  : () => unawaited(
                      _run(() async {
                        final elapsed = await _store.test(connector);
                        if (mounted) {
                          setState(() => _message = l10n.crmReachable(elapsed));
                        }
                      }),
                    ),
            ),
            IdeButton(
              secondary: true,
              label: l10n.crmEdit,
              onPressed: disabled ? null : () => unawaited(_edit(connector)),
            ),
            if (stored)
              IdeButton(
                secondary: true,
                label: l10n.crmDisconnect,
                onPressed: disabled
                    ? null
                    : () => unawaited(
                        _run(() => _put(connector.withSession(const {}))),
                      ),
              ),
            IdeButton(
              secondary: true,
              label: l10n.commonDelete,
              onPressed: disabled ? null : () => unawaited(_delete(connector)),
            ),
          ],
        ),
      ],
    );
  }
}

String _product(BuildContext context, CrmProduct product) => switch (product) {
  CrmProduct.neocrm => 'NeoCRM',
  CrmProduct.salesforce => 'Salesforce',
  CrmProduct.fxiaoke => context.l10n.crmFx,
  CrmProduct.custom => context.l10n.crmCustom,
};

class _ConnectorEditor extends StatefulWidget {
  const _ConnectorEditor({this.connector});
  final CrmConnector? connector;

  @override
  State<_ConnectorEditor> createState() => _ConnectorEditorState();
}

class _ConnectorEditorState extends State<_ConnectorEditor> {
  final _form = GlobalKey<FormState>();
  late CrmProduct _productType = widget.connector?.product ?? CrmProduct.neocrm;
  late CrmAuth _auth = switch (widget.connector?.auth) {
    null || CrmAuth.neoCli => CrmAuth.browser,
    final auth => auth,
  };
  late bool _customNeoAuth =
      widget.connector != null && widget.connector!.auth != CrmAuth.neoCli;
  late final _controllers = {
    for (final key in [
      'name',
      'baseUrl',
      'authorizeUrl',
      'tokenUrl',
      'clientId',
      'clientSecret',
      'permanentCode',
      'redirectUri',
      'scope',
      'checkPath',
    ])
      key: TextEditingController(
        text:
            widget.connector?[key] ??
            switch (key) {
              'redirectUri' => 'http://localhost:1028',
              'baseUrl' => neoSandboxUrl,
              _ => '',
            },
      ),
  };

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    final existing = widget.connector;
    final fx = _productType == CrmProduct.fxiaoke;
    final neo = _productType == CrmProduct.neocrm;
    final base = CrmConnectors.httpsUrl(_controllers['baseUrl']!.text.trim())!;
    final instance = neo ? neoInstance(base) : base;
    final values = {
      'id': existing?.id ?? codexState(),
      'product': _productType.name,
      'auth':
          (neo && !_customNeoAuth
                  ? CrmAuth.neoCli
                  : fx
                  ? CrmAuth.clientCredentials
                  : _auth)
              .name,
      for (final entry in _controllers.entries)
        entry.key: fx && entry.key == 'checkPath'
            ? ''
            : entry.value.text.trim(),
      'baseUrl': instance.toString(),
      if (neo) ...{
        for (final (key, path) in [
          ('authorizeUrl', '/auc/oauth2/auth'),
          ('tokenUrl', '/auc/oauth2/token'),
        ])
          if (!_customNeoAuth || _controllers[key]!.text.trim().isEmpty)
            key: neoLoginOrigin(instance).replace(path: path).toString(),
        if (!_customNeoAuth) 'clientId': '',
        if (!_customNeoAuth) 'clientSecret': '',
      },
    };
    final sameAuthorization =
        existing != null &&
        values.entries.every(
          (entry) =>
              entry.key == 'name' ||
              entry.key == 'checkPath' ||
              existing[entry.key] == entry.value,
        );
    Navigator.pop(
      context,
      CrmConnector({if (sameAuthorization) ...existing.fields, ...values}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final fx = _productType == CrmProduct.fxiaoke;
    final neo = _productType == CrmProduct.neocrm;
    final showAuth = !neo || _customNeoAuth;
    final browser = !fx && _auth == CrmAuth.browser;

    Widget field(
      String key,
      String label, {
      bool secret = false,
      bool required = true,
      bool url = false,
      bool redirect = false,
      bool checkPath = false,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: _controllers[key],
        decoration: InputDecoration(labelText: label),
        obscureText: secret,
        enableSuggestions: !secret,
        autocorrect: !secret,
        validator: (text) {
          final value = text?.trim() ?? '';
          if (required && value.isEmpty) return l10n.crmRequired;
          if (url &&
              (required || value.isNotEmpty) &&
              CrmConnectors.httpsUrl(value) == null) {
            return l10n.crmHttpsRequired;
          }
          if (redirect && crmLoopbackUrl(value) == null) {
            return l10n.crmLoopbackRequired;
          }
          if (checkPath && value.isNotEmpty) {
            final base = CrmConnectors.httpsUrl(
              _controllers['baseUrl']!.text.trim(),
            );
            if (base == null || crmCheckUrl(base, value) == null) {
              return l10n.crmPathRequired;
            }
          }
          return null;
        },
      ),
    );

    return ModelDialogFrame(
      title: widget.connector == null ? l10n.crmAdd : l10n.crmEdit,
      actions: [
        IdeButton(
          secondary: true,
          label: l10n.commonCancel,
          onPressed: () => Navigator.pop(context),
        ),
        IdeButton(label: l10n.commonSave, onPressed: _submit),
      ],
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            children: [
              field('name', l10n.crmName),
              DropdownButtonFormField<CrmProduct>(
                initialValue: _productType,
                decoration: InputDecoration(labelText: l10n.crmProduct),
                items: [
                  for (final product in CrmProduct.values)
                    DropdownMenuItem(
                      value: product,
                      child: Text(_product(context, product)),
                    ),
                ],
                onChanged: (value) => setState(() {
                  if (value == null || value == _productType) return;
                  _productType = value;
                  _customNeoAuth = false;
                  _auth = CrmAuth.browser;
                  for (final entry in _controllers.entries) {
                    if (entry.key == 'name') continue;
                    entry.value.text = switch (entry.key) {
                      'baseUrl' when value == CrmProduct.neocrm =>
                        neoSandboxUrl,
                      'redirectUri' => 'http://localhost:1028',
                      _ => '',
                    };
                  }
                }),
              ),
              field('baseUrl', l10n.crmBaseUrl, url: true),
              if (neo)
                Material(
                  type: MaterialType.transparency,
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.crmCustomOAuth),
                    subtitle: _customNeoAuth
                        ? null
                        : Text(l10n.crmNeoCliDefault),
                    value: _customNeoAuth,
                    onChanged: (value) =>
                        setState(() => _customNeoAuth = value),
                  ),
                ),
              if (showAuth && !fx)
                DropdownButtonFormField<CrmAuth>(
                  initialValue: _auth,
                  decoration: InputDecoration(labelText: l10n.crmAuthMethod),
                  items: [
                    DropdownMenuItem(
                      value: CrmAuth.browser,
                      child: Text(l10n.crmBrowserAuth),
                    ),
                    DropdownMenuItem(
                      value: CrmAuth.clientCredentials,
                      child: Text(l10n.crmClientAuth),
                    ),
                  ],
                  onChanged: (value) => setState(() => _auth = value!),
                ),
              if (showAuth) ...[
                if (browser)
                  field(
                    'authorizeUrl',
                    l10n.crmAuthorizeUrl,
                    url: true,
                    required: !neo,
                  ),
                field('tokenUrl', l10n.crmTokenUrl, url: true, required: !neo),
                field('clientId', fx ? 'App ID' : 'Client ID'),
                field(
                  'clientSecret',
                  fx ? 'App Secret' : 'Client Secret',
                  secret: true,
                  required: !browser,
                ),
                if (fx)
                  field('permanentCode', l10n.crmPermanentCode, secret: true),
                if (browser)
                  field('redirectUri', l10n.crmRedirectUri, redirect: true),
                if (!fx) ...[
                  field('scope', l10n.crmScope, required: false),
                  field(
                    'checkPath',
                    l10n.crmCheckPath,
                    required: false,
                    checkPath: true,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
