import 'dart:io';

import 'package:baocode/crm/crm_connectors.dart';
import 'package:baocode/crm/sharecrm_cli_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'sharecrm keeps sessions in the selected connector and verifies identity',
    () async {
      final root = await Directory.systemTemp.createTemp('sharecrm-command-');
      addTearDown(() => root.delete(recursive: true));
      final cli = File(p.join(root.path, 'fake-sharecrm'));
      await cli.writeAsString(r'''#!/bin/sh
set -eu
test "$FS_CLI_AUTH_BASE_URL" = "https://open.fxiaoke.com/"
profile="${FS_CLI_CONFIG_DIR##*/}"
case "$1 $2" in
  "auth login") printf '%s\n' '设备验证码: AB-CD' ;;
  "auth status") printf '{"appId":"fixture","userId":"%s","tokenStatus":"normal"}\n' "$profile" ;;
  "data describe")
    test "$3 $4 $5" = 'get -d {"apiName":"AccountObj"}'
    printf '{"profile":"%s"}\n' "$profile"
    ;;
  *) exit 9 ;;
esac
''');
      expect((await Process.run('chmod', ['700', cli.path])).exitCode, 0);
      CrmConnector connector(String id, {String? user}) => CrmConnector({
        'id': id,
        'name': id,
        'product': CrmProduct.fxiaoke.name,
        'baseUrl': 'https://open.fxiaoke.com',
        'sharecrmUser': ?user,
        'sharecrmApp': 'fixture',
      });
      String? code;
      final session = await sharecrmCommand(
        connector('first'),
        [],
        showCode: (value) => code = value,
        executableOverride: cli.path,
        configRoot: root.path,
      );
      expect(session['sharecrmUser'], 'first');
      expect(code, 'AB-CD');

      const args = [
        'data',
        'describe',
        'get',
        '-d',
        '{"apiName":"AccountObj"}',
      ];
      Future<Map<String, Object?>> read(CrmConnector profile) =>
          sharecrmCommand(
            profile,
            args,
            executableOverride: cli.path,
            configRoot: root.path,
          );
      final results = await Future.wait([
        read(connector('first', user: 'first')),
        read(connector('second', user: 'second')),
      ]);
      expect(results.map((result) => result['output']), [
        '{"profile":"first"}',
        '{"profile":"second"}',
      ]);
      await expectLater(
        read(connector('second', user: 'first')),
        throwsStateError,
      );
      await expectLater(
        sharecrmCommand(connector('first', user: 'first'), [
          'data',
          'record',
          'create',
        ]),
        throwsArgumentError,
      );
    },
    skip: Platform.isWindows,
  );
}
