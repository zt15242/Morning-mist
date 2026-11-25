import 'dart:convert';

import '../kernel/claude_code/claude_sdk_tools.dart';
import '../kernel/kernel_types.dart';
import '../remote/remote_location.dart';
import 'crm_connectors.dart';
import 'crm_command_stub.dart'
    if (dart.library.io) 'crm_command_io.dart'
    as platform;

import 'sharecrm_cli_stub.dart'
    if (dart.library.io) 'sharecrm_cli_io.dart'
    as sharecrm;

abstract final class CrmChatTool {
  static void register() {
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'crm_metadata',
        description:
            'Read NeoCRM or Salesforce object or field metadata using only a CRM connector '
            'explicitly selected in the conversation. Select by its '
            '1-based position when the user included more than one connector. '
            'Supply object to read its fields, or omit it to list objects. '
            'For NeoCRM you can also list approval processes, global picklists, '
            'relationships and UI components via neoResource.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'connection': {'type': 'integer', 'minimum': 1},
            'object': {'type': 'string'},
            'custom': {'type': 'boolean'},
            'neoResource': {
              'type': 'string',
              'enum': [
                'approvalprocess',
                'globalpick',
                'relationship',
                'uicomponent',
              ],
              'description': 'List this NeoCRM metadata category via the selected neo CLI session.',
            },
          },
          'additionalProperties': false,
        },
        run: (input, call) => read(
          input,
          connectorIds: call.crmConnectorIds,
          cancelled: call.cancelled,
        ),
      ),
    );

    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'crm_records',
        description:
            'Read NeoCRM or Salesforce business records from a connector explicitly selected '
            'for the conversation. Use crm_metadata first if object '
            'or field API names are unknown. Request only fields relevant to '
            'the user’s question. Index connectors from 1.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'connection': {'type': 'integer', 'minimum': 1},
            'object': {'type': 'string'},
            'fields': {
              'type': 'array',
              'minItems': 1,
              'maxItems': 30,
              'items': {'type': 'string'},
            },
            'limit': {'type': 'integer', 'minimum': 1, 'maximum': 100},
          },
          'required': ['object', 'fields'],
          'additionalProperties': false,
        },
        run: (input, call) => read(
          input,
          connectorIds: call.crmConnectorIds,
          cancelled: call.cancelled,
          records: true,
        ),
      ),
    );
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'crm_retrieve_object',
        description:
            'Run neo retrieve object and save the retrieved NeoCRM object source '
            'in the current local workspace under neocrm-src. Use this for '
            'requests to pull or save metadata files. Use crm_metadata to '
            'inspect metadata without creating files.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'connection': {'type': 'integer', 'minimum': 1},
            'object': {'type': 'string'},
          },
          'required': ['object'],
          'additionalProperties': false,
        },
        run: (input, call) => read(
          input,
          connectorIds: call.crmConnectorIds,
          cancelled: call.cancelled,
          retrieveInto: call.cwd,
        ),
      ),
    );
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'crm_deploy_field',
        description:
            'Dry-run and deploy exactly one existing NeoCRM custom field source '
            'using the selected connector. The app requests explicit approval before deployment.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'connection': {'type': 'integer', 'minimum': 1},
            'object': {'type': 'string'},
            'field': {'type': 'string'},
            'path': {
              'type': 'string',
              'description':
                  'Workspace-relative path to the existing .field.json file.',
            },
          },
          'required': ['object', 'field', 'path'],
          'additionalProperties': false,
        },
        asksItself: true,
        run: (input, call) => read(
          input,
          connectorIds: call.crmConnectorIds,
          cancelled: call.cancelled,
          deployFrom: call.cwd,
          ask: call.ask,
        ),
      ),
    );
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'crm_neo',
        description:
            'Run the native NeoCRM CLI with the selected connector authorization in the local workspace. '
            'Pass CLI arguments as separate strings, without neo or shell syntax. '
            'Use subcommand --help to inspect the installed CLI. Uses the CLI’s own '
            'options and commands, including generate, retrieve, deploy, enable and disable. '
            'The app will explicitly confirm commands that write.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'connection': {'type': 'integer', 'minimum': 1},
            'args': {
              'type': 'array',
              'minItems': 1,
              'maxItems': 60,
              'items': {'type': 'string'},
            },
          },
          'required': ['args'],
          'additionalProperties': false,
        },
        alwaysLoad: true,
        asksItself: true,
        run: (input, call) => read(
          input,
          connectorIds: call.crmConnectorIds,
          cancelled: call.cancelled,
          neoWorkspace: call.cwd,
          ask: call.ask,
        ),
      ),
    );
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'crm_sharecrm',
        description:
            'Read FxiaoKe through the sharecrm CLI and the selected connector. '
            'Pass separate arguments for data describe get, data record query-by-sql, '
            'data record query-by-fields, data record query-aggregate-by-sql, or data record get-by-id. '
            'Append --help to inspect options, or pass -d followed by one JSON object, e.g. {"apiName":"AccountObj"} for describe. '
            'Use describe get to verify field names before querying.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'connection': {'type': 'integer', 'minimum': 1},
            'args': {
              'type': 'array',
              'minItems': 3,
              'maxItems': 32,
              'items': {'type': 'string'},
            },
          },
          'required': ['args'],
        },
        run: (input, call) => read(
          input,
          connectorIds: call.crmConnectorIds,
          cancelled: call.cancelled,
          sharecrmRead: true,
        ),
      ),
    );
  }

  static const _neoResources = {
    'approvalprocess',
    'globalpick',
    'relationship',
    'uicomponent',
  };

  static final _identifier = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,127}$');

  static Future<String> read(
    Map<String, Object?> input, {
    required List<String> connectorIds,
    CrmConnectors? store,
    Future<void>? cancelled,
    bool records = false,
    bool sharecrmRead = false,
    String? retrieveInto,
    String? deployFrom,
    String? neoWorkspace,
    ClaudeSdkAsk? ask,
  }) async {
    if (connectorIds.isEmpty) {
      throw StateError('Select a CRM connector for this conversation with @.');
    }
    final position =
        input['connection'] ?? (connectorIds.length == 1 ? 1 : null);
    if (position is! int || position < 1 || position > connectorIds.length) {
      throw ArgumentError('Use a valid selected connector position.');
    }
    final id = connectorIds[position - 1];
    final connectors = await (store ?? CrmConnectors()).load();
    final connector = connectors.where((entry) => entry.id == id).firstOrNull;
    if (connector == null || !connector.supportsChat || !connector.authorized) {
      throw StateError(
        'The selected CRM connector is unavailable. Reauthorize it in settings.',
      );
    }
    if (sharecrmRead) {
      final args = input['args'];
      if (connector.product != CrmProduct.fxiaoke ||
          args is! List ||
          args.length < 3 ||
          args.length > 32 ||
          args.any((arg) => arg is! String || arg.contains('\u0000'))) {
        throw ArgumentError(
          'Select an authorized FxiaoKe connector and pass sharecrm arguments separately.',
        );
      }
      return jsonEncode(
        await sharecrm.sharecrmCommand(
          connector,
          args.cast<String>(),
          cancelled: cancelled,
        ),
      );
    }
    if (connector.product == CrmProduct.fxiaoke) {
      throw StateError('Use crm_sharecrm for this FxiaoKe connector.');
    }
    final base = CrmConnectors.httpsUrl(connector['baseUrl']);
    if (base == null) throw StateError('Invalid CRM instance URL.');

    if (neoWorkspace != null) {
      final args = input['args'];
      if (args is! List ||
          args.isEmpty ||
          args.length > 60 ||
          args.any(
            (arg) => arg is! String || arg.isEmpty || arg.contains('\u0000'),
          ) ||
          RemoteLocation.isRemote(neoWorkspace) ||
          connector.product != CrmProduct.neocrm ||
          connector.auth != CrmAuth.neoCli) {
        throw StateError(
          'Choose a NeoCRM CLI connector and a local workspace.',
        );
      }
      final result = await platform.crmCliRead(
        connector,
        cancelled: cancelled,
        neoCommand: (
          args: args.cast<String>(),
          workspace: neoWorkspace,
          approve: (command, details) async {
            if (ask == null) return false;
            final approval = await ask(
              ApprovalRequest(
                id: '',
                title: '在 ${connector.name} 执行 neo',
                toolName: 'crm_neo',
                requireExplicitApproval: true,
                reason:
                    '连接器：${connector.name} · ${connector['tenantId'].isEmpty ? base.host : connector['tenantId']}',
                preview: TextPreview('$command\n\n$details'),
              ),
            );
            if (approval != ApprovalDecision.allowOnce) return false;
            final current = await (store ?? CrmConnectors()).load();
            return current.any(
              (item) =>
                  item.id == connector.id &&
                  item.authorized &&
                  item['accessToken'] == connector['accessToken'] &&
                  item['baseUrl'] == connector['baseUrl'],
            );
          },
        ),
      );
      return jsonEncode({
        'source': 'neo CLI',
        'connector': connector.name,
        'result': result,
      });
    }

    final object = input['object'];
    if (object != null &&
        (object is! String || !_identifier.hasMatch(object))) {
      throw ArgumentError('Use a valid CRM object API name.');
    }
    if (deployFrom != null) {
      final field = input['field'];
      final path = input['path'];
      if (object is! String ||
          field is! String ||
          !_identifier.hasMatch(field) ||
          !field.endsWith('__c') ||
          path is! String ||
          path.isEmpty ||
          RemoteLocation.isRemote(deployFrom) ||
          connector.product != CrmProduct.neocrm ||
          connector.auth != CrmAuth.neoCli ||
          ask == null) {
        throw StateError(
          'Deployment requires a local workspace, custom field source, and selected NeoCRM CLI connector.',
        );
      }
      final result = await platform.crmCliRead(
        connector,
        object: object,
        cancelled: cancelled,
        fieldDeployment: (
          workspace: deployFrom,
          path: path,
          field: field,
          approve: (source, preview) async {
            final approval = await ask(
              ApprovalRequest(
                id: '',
                title: '部署 $object.$field 到 ${connector.name}',
                toolName: 'crm_deploy_field',
                requireExplicitApproval: true,
                reason:
                    '目标连接器：${connector.name} · ${connector['tenantId'].isEmpty ? base.host : connector['tenantId']}',
                preview: TextPreview('$path\n\n$preview\n\n$source'),
              ),
            );
            if (approval != ApprovalDecision.allowOnce) return false;
            final current = await (store ?? CrmConnectors()).load();
            return current.any(
              (item) =>
                  item.id == connector.id &&
                  item.authorized &&
                  item['accessToken'] == connector['accessToken'] &&
                  item['baseUrl'] == connector['baseUrl'],
            );
          },
        ),
      );
      return jsonEncode({
        'source': 'neo CLI',
        'connector': connector.name,
        'result': result,
      });
    }
    if (retrieveInto != null) {
      if (object is! String ||
          RemoteLocation.isRemote(retrieveInto) ||
          connector.product != CrmProduct.neocrm ||
          connector.auth != CrmAuth.neoCli) {
        throw StateError(
          'Retrieval requires a local workspace and a NeoCRM CLI connector.',
        );
      }
      final retrieved = await platform.crmCliRead(
        connector,
        object: object,
        retrieveInto: retrieveInto,
        cancelled: cancelled,
      );
      return jsonEncode({
        'source': 'neo CLI',
        'connector': connector.name,
        'result': retrieved,
      });
    }
    if (records) {
      final fields = input['fields'];
      final limit = input['limit'] ?? 10;
      if (object == null ||
          fields is! List ||
          fields.isEmpty ||
          fields.length > 30 ||
          fields.any(
            (field) => field is! String || !_identifier.hasMatch(field),
          ) ||
          limit is! int ||
          limit < 1 ||
          limit > 100) {
        throw ArgumentError(
          'Supply valid object and field API names and a limit from 1 to 100.',
        );
      }
      final query =
          'SELECT ${fields.toSet().join(', ')} FROM $object LIMIT $limit';
      final data = await platform.crmCliRead(
        connector,
        query: query,
        cancelled: cancelled,
      );
      final code = data is Map ? data['code'] : null;
      if (code != null && !const {'0', '200'}.contains(code.toString())) {
        throw StateError(
          'NeoCRM rejected the record query (code $code). Verify the selected fields and the account’s read permissions.',
        );
      }
      final rows = switch (data) {
        {'data': {'records': final List rows}} => rows,
        {'result': {'records': final List rows}} => rows,
        {'records': final List rows} => rows,
        _ => throw const FormatException(
          'Unexpected NeoCRM record query response.',
        ),
      };
      return jsonEncode({
        'source': connector.product == CrmProduct.salesforce
            ? 'sf CLI'
            : 'neo CLI',
        if (connector.product == CrmProduct.neocrm)
          'command': 'neo query --sql <XOQL SELECT> --json',
        'connection': position,
        'connector': connector.name,
        'records': [
          for (final row in rows.whereType<Map>().take(limit))
            {
              for (final field in fields.cast<String>())
                if (row.containsKey(field)) field: row[field],
            },
        ],
      });
    }
    final custom = input['custom'];
    if (custom != null && custom is! bool) {
      throw ArgumentError('The custom filter must be a boolean.');
    }
    if (connector.product == CrmProduct.salesforce) {
      final rows = _metadataRows(
        await platform.crmCliRead(
          connector,
          object: object as String?,
          custom: custom as bool?,
        ),
      );
      return jsonEncode({
        'source': 'sf CLI',
        'connector': connector.name,
        'total': rows.length,
        'records': rows.take(500).toList(),
      });
    }
    final resource = input['neoResource'];
    if (resource != null &&
        (resource is! String ||
            !_neoResources.contains(resource) ||
            object != null ||
            custom != null)) {
      throw ArgumentError(
        'Choose one NeoCRM metadata category without object filters.',
      );
    }
    final neoData = await platform.crmCliRead(
      connector,
      object: object as String?,
      custom: custom as bool?,
      resource: resource as String?,
    );
    return jsonEncode({
      'source': 'neo CLI',
      'connection': position,
      'connector': connector.name,
      'result': neoData,
    });
  }

  static List<Map<String, Object?>> _metadataRows(Object? data) {
    final records = switch (data) {
      {'data': {'records': final List records}} => records,
      {'records': final List records} => records,
      _ => throw const FormatException('Unexpected CRM metadata response.'),
    };
    return [
      for (final record in records.whereType<Map>())
        {
          for (final key in ['apiKey', 'label', 'itemType', 'objectType'])
            if (record[key] is String || record[key] is num) key: record[key],
        },
    ];
  }
}
