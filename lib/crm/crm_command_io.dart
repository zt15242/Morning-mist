import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/codex/codex_oauth.dart' show codexState;
import 'crm_connectors.dart';
import 'crm_cli_runtime_io.dart';

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
}) async {
  if (retrieveInto != null && (object == null || !p.isAbsolute(retrieveInto))) {
    throw ArgumentError('Select an object and open a local workspace first.');
  }
  var stopped = false;
  cancelled?.then((_) => stopped = true);
  final sf = connector.product == CrmProduct.salesforce;
  if (!sf && connector.auth != CrmAuth.neoCli) return null;
  final command = sf ? 'sf' : 'neo';
  final runtime = executableOverride == null
      ? await crmCliRuntime(command)
      : null;
  final executable = executableOverride ?? runtime?.executable;
  if (executable == null) {
    throw StateError(
      '$command CLI not found in the login shell PATH or common install locations.',
    );
  }
  final directory = await Directory.systemTemp.createTemp(
    'morning-mist-crm-read-',
  );
  final env = {
    for (final entry in Platform.environment.entries)
      if (!const {
            'SF_ACCESS_TOKEN',
            'SFDX_ACCESS_TOKEN',
            'HOME',
            'USERPROFILE',
          }.contains(entry.key.toUpperCase()) &&
          (runtime == null || entry.key.toUpperCase() != 'PATH'))
        entry.key: entry.value,
    if (runtime != null) 'PATH': runtime.path,
    'HOME': directory.path,
    'USERPROFILE': directory.path,
    'NEO_TELEMETRY': 'false',
    'NO_COLOR': '1',
    'SF_DISABLE_TELEMETRY': 'true',
    'SF_DISABLE_AUTOUPDATE': 'true',
    'SF_USE_GENERIC_UNIX_KEYCHAIN': 'true',
  };
  try {
    Future<String> run(
      List<String> args, {
      String? stdin,
      bool optional = false,
      String? cwd,
      bool showOutputOnError = false,
    }) async {
      if (stopped) throw StateError('CRM command cancelled.');
      final Process process;
      try {
        process = await Process.start(
          executable,
          runtime?.arguments(args) ?? args,
          workingDirectory: cwd ?? directory.path,
          environment: env,
          includeParentEnvironment: false,
        );
      } on ProcessException catch (error) {
        if (optional) return '';
        throw StateError(
          'Could not start $command CLI at $executable (OS error ${error.errorCode}): ${error.message}',
        );
      }
      cancelled?.then((_) => process.kill());
      final output = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final errors = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      if (stdin != null) process.stdin.writeln(stdin);
      await process.stdin.close();
      final exit = await process.exitCode.timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          process.kill();
          throw StateError('$command CLI timed out.');
        },
      );
      final errorText = await errors;
      final text = await output;
      if (exit != 0) {
        if (optional) return '';
        throw StateError(
          '$command CLI ${stdin != null ? 'authorization' : args.take(2).join(' ')} '
          'failed (exit $exit).'
          '${showOutputOnError ? '\n${_redactCliOutput('$text\n$errorText', connector)}' : ' Check the selected connector’s session and permissions.'}',
        );
      }
      return text;
    }

    if (!sf) {
      if (query != null) {
        final help = await run(['query', '--help'], optional: true);
        if (!help.contains('--sql') || !help.contains('--json')) {
          throw StateError(
            'This neo CLI does not support query --sql --json. Use neo 1.1.2 or newer.',
          );
        }
      }
      var project = 'morning-mist-crm';
      var workdir = directory.path;
      var initialize = false;
      var requiresApproval = false;
      var previewOnly = false;
      if (neoCommand case final request?) {
        final args = request.args;
        if (args.isEmpty ||
            args.contains('--') ||
            args.any(
              (value) =>
                  value.startsWith('--no-dry-run') ||
                  value.startsWith('--dry-run='),
            )) {
          throw ArgumentError('Pass neo arguments as separate values.');
        }
        final first = args.first;
        if (const {
          'init',
          'login',
          'logout',
          'loginstatus',
          'telemetry',
        }.contains(first)) {
          throw ArgumentError(
            'Manage connector authorization in CRM settings.',
          );
        }
        final help =
            (args.length == 1 &&
                const {
                  'help',
                  '--help',
                  '-h',
                  '--version',
                  '-v',
                }.contains(first)) ||
            (args.length <= 3 &&
                const {'--help', '-h'}.contains(args.last) &&
                args
                    .take(args.length - 1)
                    .every(
                      (part) => RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(part),
                    ));
        final knownRead =
            const {'query', 'list', 'describe', 'validate'}.contains(first) ||
            (first == 'platform' && args.elementAtOrNull(1) == 'search');
        final workspace = Directory(request.workspace);
        if (!p.isAbsolute(workspace.path) || !await workspace.exists()) {
          throw StateError(
            'Open a local workspace to run neo with this connector.',
          );
        }
        final root = await workspace.resolveSymbolicLinks();
        final manifest = File(p.join(root, 'neo-project.json'));
        if (!help && await manifest.exists()) {
          if (!p.isWithin(root, await manifest.resolveSymbolicLinks())) {
            throw StateError(
              'The NeoCRM project manifest is outside this workspace.',
            );
          }
          final data = jsonDecode(await manifest.readAsString());
          final id = data is Map ? data['projectId'] : null;
          if (id is! String ||
              !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
            throw const FormatException('Invalid NeoCRM projectId.');
          }
          project = id;
          workdir = root;
        } else if (!help && !knownRead) {
          if (const {'deploy', 'enable', 'disable'}.contains(first)) {
            throw StateError(
              'Open the NeoCRM project containing the source and neo-project.json.',
            );
          }
          workdir = root;
          initialize = true;
          project = codexState();
        }
        previewOnly =
            const {'deploy', 'enable', 'disable'}.contains(first) &&
            args.length >= 3 &&
            RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(args[1]) &&
            args.contains('--dry-run');
        // describe --out writes a local file. Known read-only command groups
        // are exempt only when they do not request a file output.
        final writesFile = args.any(
          (arg) =>
              arg.startsWith('-o') ||
              arg.startsWith('--out') ||
              arg == '--md-file' ||
              arg.startsWith('--output'),
        );
        requiresApproval = !help && !previewOnly && (!knownRead || writesFile);
      }
      final manifest = File(p.join(workdir, 'neo-project.json'));
      Future<void> initializeProject() async {
        await manifest.create(exclusive: true);
        await manifest.writeAsString(
          jsonEncode({
            'name': project,
            'projectId': project,
            'sourceDir': 'neocrm-src',
          }),
        );
      }

      if (workdir == directory.path) await initializeProject();
      final auth = Directory(p.join(directory.path, '.neocrm-cli', 'auth'));
      await auth.create(recursive: true);
      final base =
          CrmConnectors.httpsUrl(connector['instanceUrl'])?.origin ??
          connector['baseUrl'];
      await File(p.join(auth.path, '$project.json')).writeAsString(
        jsonEncode({
          'env': 'custom',
          'instanceUrl': base,
          'tokenUrl':
              CrmConnectors.httpsUrl(connector['sessionTokenUrl'])
                  ?.toString() ??
              connector['tokenUrl'],
          // A disposable CLI project must not rotate the saved refresh token.
          if (connector['tenantId'].isNotEmpty)
            'tenantId': connector['tenantId'],
          'accessToken': connector['accessToken'],
          'tokenType': 'Bearer',
          'expiresAt':
              DateTime.tryParse(connector['expiresAt'])
                  ?.millisecondsSinceEpoch ??
              DateTime.now()
                  .add(const Duration(minutes: 5))
                  .millisecondsSinceEpoch,
          'savedAt': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      if (neoCommand case final request?) {
        final args = request.args;
        final command = ['neo', ...args].join(' ');
        var details = '工作目录：$workdir';
        if (initialize) details += '\n将创建 neo-project.json。';
        if (requiresApproval) {
          if (!initialize &&
              const {'deploy', 'enable', 'disable'}.contains(args.first) &&
              args.length >= 2) {
            final help = await run(
              [args.first, args[1], '--help'],
              cwd: workdir,
              optional: true,
            );
            if (RegExp(
              r'(^|\s)--dry-run(?=\s|,|$)',
              multiLine: true,
            ).hasMatch(help)) {
              final dryRun = await run(
                [
                  ...args.take(2),
                  '--dry-run',
                  ...args.skip(2).where((arg) => arg != '--confirm'),
                ],
                cwd: workdir,
                showOutputOnError: true,
              );
              details += '\n\n预演输出：\n${_redactCliOutput(dryRun, connector)}';
            }
          }
          if (stopped || !await request.approve(command, details) || stopped) {
            return {'status': 'cancelled', 'command': command};
          }
        }
        if (initialize) await initializeProject();
        final commandArgs = previewOnly
            ? [
                ...args.take(2),
                '--dry-run',
                ...args
                    .skip(2)
                    .where((arg) => arg != '--dry-run' && arg != '--confirm'),
              ]
            : args;
        final output = await run(
          commandArgs,
          cwd: workdir,
          showOutputOnError: true,
        );
        return {
          'status': 'completed',
          'command': command,
          'workspace': workdir == directory.path ? request.workspace : workdir,
          'output': _redactCliOutput(output, connector),
        };
      }
      if (query != null) {
        return jsonDecode(await run(['query', '--sql', query, '--json']));
      }
      if (fieldDeployment case final deployment?) {
        if (!p.isAbsolute(deployment.workspace)) {
          throw StateError(
            'Open a local workspace before deploying field source.',
          );
        }
        if (object == null) throw ArgumentError('Select the target object.');
        final workspace = await Directory(deployment.workspace)
            .resolveSymbolicLinks();
        final source = File(p.join(workspace, deployment.path));
        final resolved = await source.resolveSymbolicLinks();
        if (!p.isWithin(workspace, resolved) ||
            !resolved.endsWith('.field.json')) {
          throw ArgumentError('Choose a field JSON file inside the workspace.');
        }
        final file = File(resolved);
        if (await file.length() > 64 * 1024) {
          throw ArgumentError('The field source exceeds the supported size.');
        }
        final contents = await file.readAsString();
        final definition = jsonDecode(contents);
        if (definition is! Map || definition['apiKey'] != deployment.field) {
          throw ArgumentError(
            'The field source API key does not match the request.',
          );
        }
        final staged = File(
          p.join(
            directory.path,
            'neocrm-src',
            'objects',
            object,
            'fields',
            '${deployment.field}.field.json',
          ),
        );
        await staged.create(recursive: true);
        await staged.writeAsString(contents);
        final args = [
          'deploy',
          'field',
          '--object',
          object,
          '--api-key',
          deployment.field,
        ];
        final preview = await run([...args, '--dry-run']);
        if (stopped ||
            !await deployment.approve(contents, preview) ||
            stopped) {
          return {'status': 'not_deployed', 'preview': preview};
        }
        final output = await run(args);
        return {
          'status': 'executed',
          'command': 'neo ${args.join(' ')}',
          'preview': preview,
          'output': output,
        };
      }
      if (retrieveInto != null) {
        final args = ['retrieve', 'object', '--api-key', object!];
        final output = await run(args);
        if (stopped) throw StateError('CRM command cancelled.');
        return {
          'command': 'neo ${args.join(' ')}',
          'output': String.fromCharCodes(output.runes.take(30000)),
          'files': await _copyRetrievedSource(
            directory,
            Directory(retrieveInto),
          ),
        };
      }
      final args = object == null
          ? [
              'list',
              resource ?? 'object',
              if (resource == null && custom != null)
                custom ? '--custom' : '--standard',
            ]
          : ['describe', 'object', '--api-key', object, '--md'];
      final output = await run(args);
      return {
        'command': 'neo ${args.join(' ')}',
        'output': String.fromCharCodes(output.runes.take(30000)),
      };
    }

    const alias = 'morning-mist-connector';
    final instance =
        CrmConnectors.httpsUrl(connector['instanceUrl']) ??
        CrmConnectors.httpsUrl(connector['baseUrl'])!;
    await run([
      'org',
      'login',
      'access-token',
      '--instance-url',
      instance.origin,
      '--alias',
      alias,
      '--json',
    ], stdin: connector['accessToken']);
    final args = switch ((query, object)) {
      (final String sql, _) => ['data', 'query', '--query', sql],
      (_, final String name) => ['sobject', 'describe', '--sobject', name],
      _ => ['sobject', 'list', '--sobject', 'all'],
    };
    final result = jsonDecode(
      await run([...args, '--target-org', alias, '--json']),
    );
    if (result is! Map || result['status'] != 0) {
      throw StateError('Salesforce CLI returned an unsuccessful result.');
    }
    final payload = result['result'];
    if (query != null) return {'data': payload};
    if (object != null && payload is Map && payload['fields'] is List) {
      return {
        'records': [
          for (final field in (payload['fields'] as List).whereType<Map>())
            {
              'apiKey': field['name'],
              'label': field['label'],
              'itemType': field['type'],
            },
        ],
      };
    }
    if (payload is List) {
      return {
        'records': [
          for (final name in payload.whereType<String>())
            if (custom == null || name.endsWith('__c') == custom)
              {'apiKey': name},
        ],
      };
    }
    throw const FormatException('Unexpected Salesforce CLI response.');
  } finally {
    await directory.delete(recursive: true);
  }
}

Future<List<String>> _copyRetrievedSource(
  Directory project,
  Directory workspace,
) async {
  final root = await workspace.resolveSymbolicLinks();
  final source = Directory(p.join(project.path, 'neocrm-src'));
  final output = <String>[];
  final additions = <(File, File)>[];
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final relative = p.relative(entity.path, from: project.path);
    final parts = p.split(relative);
    var parent = root;
    for (final part in parts.take(parts.length - 1)) {
      parent = p.join(parent, part);
      final type = await FileSystemEntity.type(parent, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory) {
        throw StateError('Cannot safely write $relative in this workspace.');
      }
    }
    final target = File(p.join(root, relative));
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      additions.add((entity, target));
    } else if (type != FileSystemEntityType.file ||
        base64Encode(await target.readAsBytes()) !=
            base64Encode(await entity.readAsBytes())) {
      throw StateError('Existing workspace file differs: $relative.');
    }
    output.add(relative);
  }
  if (output.isEmpty) {
    throw StateError('neo did not write any object source files.');
  }
  final created = <File>[];
  try {
    for (final (input, target) in additions) {
      await target.parent.create(recursive: true);
      await target.create(exclusive: true);
      created.add(target);
      await target.writeAsBytes(await input.readAsBytes(), flush: true);
    }
  } catch (_) {
    for (final file in created.reversed) {
      try {
        await file.delete();
      } on FileSystemException {
        // Keep reporting the original write failure.
      }
    }
    rethrow;
  }
  return output..sort();
}

String _redactCliOutput(String value, CrmConnector connector) {
  for (final secret in [connector['accessToken'], connector['refreshToken']]) {
    if (secret.isNotEmpty) value = value.replaceAll(secret, '[redacted]');
  }
  return String.fromCharCodes(value.runes.take(30000));
}
