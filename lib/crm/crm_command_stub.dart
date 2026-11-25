import 'crm_connectors.dart';

Future<Object?> crmCliRead(
  CrmConnector connector, {
  String? query,
  String? object,
  bool? custom,
  String? resource,
  String? retrieveInto,
  ({
    List<String> args,
    String workspace,
    Future<bool> Function(String command, String details) approve,
  })?
  neoCommand,
  ({
    String workspace,
    String path,
    String field,
    Future<bool> Function(String source, String preview) approve,
  })?
  fieldDeployment,
  Future<void>? cancelled,
  String? executableOverride,
}) async => throw UnsupportedError('CRM CLI requires the desktop app.');
