import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/data_dir.dart';
import '../workspace/editor_launcher.dart';
import 'crm_cli_runtime_io.dart';
import 'crm_connectors.dart';

Future<Map<String, Object?>> sharecrmCommand(
  CrmConnector connector,
  List<String> args, {
  void Function(String)? showCode,
  Future<void>? cancelled,
  String? executableOverride,
  String? configRoot,
}) async {
  if (connector.product != CrmProduct.fxiaoke ||
      !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(connector.id)) {
    throw ArgumentError('Choose a valid FxiaoKe connector.');
  }
  final login = showCode != null;
  final help = args.length == 4 && args.last == '--help';
  final route = args.take(3).join(' ');
  var arguments = args;
  if (!login) {
    if (!const {
      'data describe get',
      'data record query-by-sql',
      'data record query-aggregate-by-sql',
      'data record query-by-fields',
      'data record get-by-id',
    }.contains(route)) {
      throw ArgumentError('Choose a supported read-only sharecrm command.');
    }
    if (!help) {
      if (args.length != 5 || !const {'-d', '--data'}.contains(args[3])) {
        throw ArgumentError(
          'Use -d followed by a single JSON object, or --help.',
        );
      }
      final payload = jsonDecode(args[4]);
      if (payload is! Map) {
        throw ArgumentError('sharecrm requires a JSON object.');
      }
      if (route.endsWith('-by-sql')) {
        final sql = payload['sql'];
        if (sql is! String ||
            !RegExp(
              r'^SELECT\s',
              caseSensitive: false,
            ).hasMatch(sql.trimLeft()) ||
            sql.contains(';')) {
          throw ArgumentError(
            'Use one SELECT statement for a sharecrm SQL query.',
          );
        }
      }
      arguments = [...args.take(3), '-d', jsonEncode(payload)];
    }
  }

  final runtime = await crmCliRuntime('sharecrm');
  final executable = executableOverride ?? runtime.executable;
  if (executable == null) throw StateError('sharecrm executable not found.');
  final cloud = CrmConnectors.httpsUrl(connector['baseUrl']);
  if (cloud == null) throw StateError('Invalid FxiaoKe cloud URL.');
  final config = p.join(
    configRoot ?? DataDirectory.current.stateDir,
    'sharecrm',
    connector.id,
  );
  final env = {
    for (final entry in Platform.environment.entries)
      if (!entry.key.toUpperCase().startsWith('FS_CLI_') &&
          entry.key.toUpperCase() != 'PATH')
        entry.key: entry.value,
    'PATH': runtime.path,
    'FS_CLI_CONFIG_DIR': config,
    'FS_CLI_AUTH_BASE_URL': '${cloud.origin}/',
    'FS_CLI_API_BASE_URL': '${cloud.origin}/cli/',
  };
  var stopped = false;
  cancelled?.then((_) => stopped = true);
  Future<String> run(List<String> arguments, {bool authorize = false}) async {
    if (stopped) throw StateError('sharecrm command cancelled.');
    final process = await Process.start(
      executable,
      executableOverride == null ? runtime.arguments(arguments) : arguments,
      environment: env,
      includeParentEnvironment: false,
    );
    cancelled?.then((_) => process.kill());
    unawaited(process.stdin.close());
    final errors = process.stderr.drain<void>();
    final output = StringBuffer();
    final lines = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());
    final read = lines.forEach((line) {
      output.writeln(line);
      if (!authorize) return;
      final uri = CrmConnectors.httpsUrl(line.trim());
      if (uri != null &&
          (uri.host == 'fxiaoke.com' || uri.host.endsWith('.fxiaoke.com'))) {
        unawaited(
          openExternal(uri.toString())
              .then<void>((_) {}, onError: (Object _) {}),
        );
      }
      final code = RegExp(r'^设备验证码\s*[:：]\s*(\S+)').firstMatch(line);
      if (code != null) showCode!(code[1]!);
    });
    final status = await process.exitCode.timeout(
      authorize ? const Duration(minutes: 5) : const Duration(seconds: 45),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    await Future.wait([read, errors]);
    if (status != 0) {
      throw StateError(
        'sharecrm ${arguments.take(3).join(' ')} failed (exit $status).',
      );
    }
    return output.toString().trim();
  }

  if (login) await run(['auth', 'login'], authorize: true);
  final status = jsonDecode(await run(['auth', 'status']));
  final user = status is Map ? status['userId']?.toString() : null;
  final app = status is Map ? status['appId']?.toString() : null;
  if (user == null ||
      user.isEmpty ||
      app == null ||
      app.isEmpty ||
      (login && (status as Map)['tokenStatus'] != 'normal') ||
      (!login &&
          (user != connector['sharecrmUser'] ||
              app != connector['sharecrmApp']))) {
    throw StateError(
      'Authorize the selected connector using sharecrm in CRM settings.',
    );
  }
  if (login) return {'sharecrmUser': user, 'sharecrmApp': app};
  final output = await run(arguments);
  return {
    'source': 'sharecrm CLI',
    'connector': connector.name,
    'command': ['sharecrm', ...arguments].join(' '),
    'output': String.fromCharCodes(output.runes.take(help ? 16000 : 60000)),
  };
}
