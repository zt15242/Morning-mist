import 'dart:io';

import 'package:baocode/crm/crm_cli_runtime_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('Windows discovery includes fresh registry PATH and npm locations', () {
    const env = {
      'Path': r'C:\stale;C:\Node',
      'UserProfile': r'C:\Users\Example',
      'ProgramFiles': r'C:\Program Files',
      'LOCALAPPDATA': r'C:\Users\Example\AppData\Local',
    };
    const registered = (
      user: r'"%userprofile%\Tools";c:\node',
      machine: r'%PROGRAMFILES%\Acme CLI\bin',
    );
    final paths = crmWindowsCliDirectories('neo', env, registered: registered);
    expect(paths.take(3), [
      r'C:\Program Files\Acme CLI\bin',
      r'C:\Users\Example\Tools',
      r'c:\node',
    ]);
    expect(paths, isNot(contains(r'C:\Node')));
    expect(paths, contains(r'C:\Users\Example\AppData\Roaming\npm'));
    expect(
      paths,
      contains(r'C:\Users\Example\AppData\Local\Programs\neocrm-cli\bin'),
    );
    expect(
      crmWindowsCliDirectories('sf', env),
      contains(r'C:\Program Files\Salesforce CLI\bin'),
    );
  });

  test(
    'Windows npm shims resolve to Node with the original argument list',
    () async {
      final root = await Directory.systemTemp.createTemp('crm-windows-cli-');
      addTearDown(() => root.delete(recursive: true));
      final env = {'USERPROFILE': root.path, 'PATH': root.path};
      final node = await File(p.join(root.path, 'node.exe')).create();
      for (final (command, segments) in [
        ('neo', ['neocrm-cli', 'bin', 'run.js']),
        ('sf', ['@salesforce', 'cli', 'bin', 'run.js']),
        ('sharecrm', ['sharecrm', 'dist', 'index.js']),
      ]) {
        await File(p.join(root.path, '$command.cmd')).create();
        final entry = await File(
          p.joinAll([root.path, 'node_modules', ...segments]),
        ).create(recursive: true);
        final runtime = await crmCliRuntime(command, environment: env);
        expect(runtime.executable, node.path);
        expect(runtime.arguments(['--version']), [entry.path, '--version']);
      }
    },
    skip: !Platform.isWindows,
  );
}
