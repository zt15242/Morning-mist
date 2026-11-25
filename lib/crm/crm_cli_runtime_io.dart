import 'dart:io';

import '../platform/shell_command_io.dart'
    show WindowsPaths, WindowsShellCommand;

import 'package:bao_remote/local.dart' show AppPaths, ClaudeEnvironment;
import 'package:path/path.dart' as p;

class CrmCliRuntime {
  const CrmCliRuntime(this.file, this.path, this.home, {this.node});
  final String? file;
  final String path;
  final String home;
  final String? node;

  String? get executable => node ?? file;
  List<String> arguments(List<String> args) => [
    if (node != null) file!,
    ...args,
  ];
}

Future<CrmCliRuntime> crmCliRuntime(
  String command, {
  Map<String, String>? environment,
}) async {
  final inherited = environment ?? Platform.environment;
  final shell = environment ?? await ClaudeEnvironment.of();
  final windows = Platform.isWindows;
  final variables = windows
      ? {
          for (final entry in shell.entries)
            entry.key.toUpperCase(): entry.value,
        }
      : shell;
  final home = AppPaths.home(variables);
  final separator = windows ? ';' : ':';
  WindowsPaths? registered;
  if (windows && environment == null) {
    try {
      registered = await WindowsShellCommand().readRegistryPaths();
    } on Object {
      // The process PATH and common install folders are still available.
    }
  }
  final directories = windows
      ? crmWindowsCliDirectories(command, variables, registered: registered)
      : <String>{
          for (final path in [shell['PATH'], inherited['PATH']])
            if (path != null) ...path.split(separator),
          '/opt/homebrew/bin',
          '/usr/local/bin',
          '/usr/bin',
          '/bin',
          if (home.isNotEmpty) ...[
            p.join(home, '.local', 'bin'),
            p.join(home, '.npm-global', 'bin'),
            p.join(home, '.volta', 'bin'),
            p.join(home, '.asdf', 'shims'),
            p.join(home, '.local', 'share', 'mise', 'shims'),
            if (command == 'sf')
              p.join(home, '.local', 'share', 'sf', 'client', 'bin'),
            if (command == 'neo')
              p.join(
                home,
                '.local',
                'share',
                'neocrm-cli-1.1.2',
                'node_modules',
                '.bin',
              ),
          ],
        }.where(p.isAbsolute).toList();
  final path = directories.join(separator);

  String? unresolvedShim;
  for (final directory in directories) {
    for (final name
        in Platform.isWindows ? ['$command.exe', '$command.cmd'] : [command]) {
      final file = File(p.join(directory, name));
      try {
        if (!await file.exists()) continue;
        if (windows && name.endsWith('.cmd')) {
          // Known Node-based launchers can run without cmd.exe interpreting
          // query or CLI arguments as shell syntax.
          final entries = switch (command) {
            'neo' => [
              p.join(directory, 'node_modules', 'neocrm-cli', 'bin', 'run.js'),
            ],
            'sharecrm' => [
              p.join(directory, 'node_modules', 'sharecrm', 'dist', 'index.js'),
            ],
            'sf' => [
              p.join(directory, 'run.js'),
              p.join(directory, 'run'),
              p.join(
                directory,
                'node_modules',
                '@salesforce',
                'cli',
                'bin',
                'run.js',
              ),
            ],
            _ => <String>[],
          };
          for (final entry in entries) {
            if (!await File(entry).exists()) continue;
            for (final bin in [directory, ...directories]) {
              final node = File(p.join(bin, 'node.exe'));
              if (await node.exists()) {
                return CrmCliRuntime(entry, path, home, node: node.path);
              }
            }
          }
          unresolvedShim ??= file.path;
          continue;
        }
        return CrmCliRuntime(await file.resolveSymbolicLinks(), path, home);
      } on FileSystemException {
        // Keep looking when this installation is unavailable.
      }
    }
  }
  if (unresolvedShim != null) {
    throw StateError(
      'Found $unresolvedShim, but its Node.js executable or CLI entry point is missing.',
    );
  }
  return CrmCliRuntime(null, path, home);
}

List<String> crmWindowsCliDirectories(
  String command,
  Map<String, String> environment, {
  WindowsPaths? registered,
}) {
  final env = {
    for (final item in environment.entries) item.key.toUpperCase(): item.value,
  };
  final home = env['USERPROFILE'] ?? env['HOME'];
  final local =
      env['LOCALAPPDATA'] ??
      (home == null ? null : p.windows.join(home, 'AppData', 'Local'));
  final roaming =
      env['APPDATA'] ??
      (home == null ? null : p.windows.join(home, 'AppData', 'Roaming'));
  final seen = <String>{};
  return [
        for (final raw in [
          if (registered != null) ...[registered.machine, registered.user],
          env['PATH'] ?? '',
        ])
          ...raw.split(';'),
        if (roaming != null) p.windows.join(roaming, 'npm'),
        if (local != null && command == 'sf')
          p.windows.join(local, 'sf', 'client', 'bin'),
        if (local != null && command == 'neo') ...[
          p.windows.join(local, 'Programs', 'neocrm-cli'),
          p.windows.join(local, 'Programs', 'neocrm-cli', 'bin'),
        ],
        for (final name in ['PROGRAMFILES', 'PROGRAMFILES(X86)'])
          if (env[name] case final dir?) ...[
            p.windows.join(dir, 'nodejs'),
            if (command == 'sf') p.windows.join(dir, 'Salesforce CLI', 'bin'),
            if (command == 'neo') ...[
              p.windows.join(dir, 'neocrm-cli'),
              p.windows.join(dir, 'neocrm-cli', 'bin'),
            ],
          ],
      ]
      .map(
        (entry) => entry
            .trim()
            .replaceAll('"', '')
            .replaceAllMapped(
              RegExp('%([^%]+)%'),
              (match) => env[match[1]!.toUpperCase()] ?? match[0]!,
            ),
      )
      .where(
        (entry) =>
            p.windows.isAbsolute(entry) &&
            seen.add(p.windows.normalize(entry).toLowerCase()),
      )
      .toList();
}
