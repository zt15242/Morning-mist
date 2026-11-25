import 'dart:io';

import 'package:baocode/crm/crm_cli_runtime_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'finds a user Salesforce CLI installation outside the app PATH',
    () async {
      final home = await Directory.systemTemp.createTemp('sf-runtime-test-');
      addTearDown(() => home.delete(recursive: true));
      final bin = await Directory(
        p.join(home.path, '.local', 'share', 'sf', 'client', 'bin'),
      ).create(recursive: true);
      final executable = await File(p.join(bin.path, 'sf'))
          .writeAsString('fixture');
      final runtime = await crmCliRuntime(
        'sf',
        environment: {'HOME': home.path, 'PATH': '/fixtures/missing'},
      );
      expect(runtime.executable, await executable.resolveSymbolicLinks());
      expect(runtime.path.split(':'), contains('/usr/bin'));
    },
    skip: Platform.isWindows,
  );
}
