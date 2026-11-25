import 'crm_connectors.dart';

Future<Map<String, Object?>> sharecrmCommand(
  CrmConnector connector,
  List<String> args, {
  void Function(String)? showCode,
  Future<void>? cancelled,
}) async => throw UnsupportedError('sharecrm requires the desktop app.');
