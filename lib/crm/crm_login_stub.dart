import 'crm_connectors.dart';

Future<Map<String, String>> crmBrowserCode(CrmConnector connector) async =>
    throw UnsupportedError(
      'CRM browser authorization requires the desktop app.',
    );

Future<Map<String, String>> crmNeoCliSession(CrmConnector connector) async =>
    throw const CrmNeoCliUnavailable();
