import 'dart:io';

import 'package:baocode/crm/crm_command_io.dart';
import 'package:baocode/crm/crm_connectors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('Salesforce CLI uses an isolated alias and sets the token only for non-interactive authorization', () async {
    final folder = await Directory.systemTemp.createTemp('crm-command-test-');
    addTearDown(() => folder.delete(recursive: true));
    final cli = File(p.join(folder.path, 'fake-sf'));
    await cli.writeAsString(r'''#!/bin/sh
set -eu
test "$(cd "$HOME" && pwd -P)" = "$(pwd -P)"
case "$1 $2 $3" in
  "org login access-token")
    test "$5" = "https://sandbox.example"
    test "$7" = "morning-mist-connector"
    test "$8 $9" = "--no-prompt --json"
    test "$SF_ACCESS_TOKEN" = "fixture-token"
    test -z "${SFDX_ACCESS_TOKEN+x}"
    printf '%s\n' '{"status":0}'
    ;;
  "data query --query")
    test -z "${SF_ACCESS_TOKEN+x}"
    test "$4" = "SELECT Name FROM Account LIMIT 10"
    test "$5 $6" = "--target-org morning-mist-connector"
    printf '%s\n' '{"status":0,"result":{"records":[{"Name":"Example"}]}}'
    ;;
  "sobject describe --sobject")
    printf '%s\n' '{"name":"InvalidSessionId","message":"Expired fixture-token","stack":"hidden-stack"}'
    exit 2
    ;;
  *) exit 1 ;;
esac
''');
    expect((await Process.run('chmod', ['700', cli.path])).exitCode, 0);
    final connector = CrmConnector({
      'name': 'Salesforce Sandbox',
      'product': CrmProduct.salesforce.name,
      'baseUrl': 'https://sandbox.example/',
      'accessToken': 'fixture-token',
    });
    final result = await crmCliRead(
      connector,
      query: 'SELECT Name FROM Account LIMIT 10',
      executableOverride: cli.path,
    );
    await expectLater(
      crmCliRead(connector, object: 'Account', executableOverride: cli.path),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'diagnostic',
          allOf(
            contains('sobject describe failed (exit 2)'),
            contains('InvalidSessionId: Expired [redacted]'),
            isNot(contains('fixture-token')),
            isNot(contains('hidden-stack')),
          ),
        ),
      ),
    );
    expect(result, {
      'data': {
        'records': [
          {'Name': 'Example'},
        ],
      },
    });
  }, skip: Platform.isWindows);
  test(
    'neo uses separate CLI authorizations for connectors on the same host',
    () async {
      final folder = await Directory.systemTemp.createTemp('neo-command-test-');
      addTearDown(() => folder.delete(recursive: true));
      final cli = File(p.join(folder.path, 'fake-neo'));
      await cli.writeAsString(r'''#!/bin/sh
set -eu
test "$1 $2 $3" = "describe object --api-key"
test "$4 $5" = "account --md"
test "$(cd "$HOME" && pwd -P)" = "$(pwd -P)"
test -f neo-project.json
auth="$HOME/.neocrm-cli/auth/morning-mist-crm.json"
if grep -q '"accessToken":"fixture-pav"' "$auth"; then
  printf 'PAV fields'
elif grep -q '"accessToken":"fixture-uat"' "$auth"; then
  printf 'UAT fields'
else
  exit 1
fi
''');
      expect((await Process.run('chmod', ['700', cli.path])).exitCode, 0);
      final results = await Future.wait([
        for (final profile in ['pav', 'uat'])
          crmCliRead(
            CrmConnector({
              'product': CrmProduct.neocrm.name,
              'auth': CrmAuth.neoCli.name,
              'baseUrl': 'https://crm-sandbox.xiaoshouyi.com',
              'accessToken': 'fixture-$profile',
              'tenantId': profile,
            }),
            object: 'account',
            executableOverride: cli.path,
          ),
      ]);
      expect(results, [
        {
          'command': 'neo describe object --api-key account --md',
          'output': 'PAV fields',
        },
        {
          'command': 'neo describe object --api-key account --md',
          'output': 'UAT fields',
        },
      ]);
    },
    skip: Platform.isWindows,
  );
  test(
    'neo retrieve writes source into the workspace and preserves changed files',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'neo-retrieve-test-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final workspace = await Directory(p.join(folder.path, 'workspace'))
          .create();
      final cli = File(p.join(folder.path, 'fake-neo'));
      await cli.writeAsString(r'''#!/bin/sh
set -eu
test "$1 $2 $3 $4" = "retrieve object --api-key account"
mkdir -p neocrm-src/objects/account
printf '%s' '{"apiKey":"account"}' > neocrm-src/objects/account/object.json
''');
      expect((await Process.run('chmod', ['700', cli.path])).exitCode, 0);
      Future<Object?> retrieve() => crmCliRead(
        CrmConnector({
          'product': CrmProduct.neocrm.name,
          'auth': CrmAuth.neoCli.name,
          'baseUrl': 'https://crm-sandbox.xiaoshouyi.com',
          'accessToken': 'fixture-token',
        }),
        object: 'account',
        retrieveInto: workspace.path,
        executableOverride: cli.path,
      );
      final relative = p.join(
        'neocrm-src',
        'objects',
        'account',
        'object.json',
      );
      expect(await retrieve(), {
        'command': 'neo retrieve object --api-key account',
        'output': '',
        'files': [relative],
      });
      final target = File(p.join(workspace.path, relative));
      expect(await target.readAsString(), '{"apiKey":"account"}');
      expect(
        await File(p.join(workspace.path, 'neo-project.json')).exists(),
        isFalse,
      );
      await target.writeAsString('local edit');
      await expectLater(retrieve(), throwsStateError);
      expect(await target.readAsString(), 'local edit');
    },
    skip: Platform.isWindows,
  );
  test('field deployment uses the selected auth, dry run and approved source snapshot', () async {
    final folder = await Directory.systemTemp.createTemp('neo-deploy-test-');
    addTearDown(() => folder.delete(recursive: true));
    final workspace = await Directory(p.join(folder.path, 'workspace'))
        .create();
    final source = await File(p.join(workspace.path, 'field.field.json'))
        .writeAsString('{"apiKey":"test1125__c","label":"approved"}');
    final cli = File(p.join(folder.path, 'fake-neo'));
    await cli.writeAsString(r'''#!/bin/sh
set -eu
test "$1 $2 $3 $4 $5 $6" = "deploy field --object account --api-key test1125__c"
grep -q '"accessToken":"uat-token"' "$HOME/.neocrm-cli/auth/morning-mist-crm.json"
grep -q '"label":"approved"' neocrm-src/objects/account/fields/test1125__c.field.json
if [ "${7:-}" = "--dry-run" ]; then
  touch preview-complete
  printf 'dry run'
else
  test -f preview-complete
  printf 'field written'
fi
''');
    expect((await Process.run('chmod', ['700', cli.path])).exitCode, 0);
    final connector = CrmConnector({
      'product': CrmProduct.neocrm.name,
      'auth': CrmAuth.neoCli.name,
      'baseUrl': 'https://crm-sandbox.xiaoshouyi.com',
      'accessToken': 'uat-token',
    });
    Future<Object?> deploy(Future<bool> Function(String, String) approve) =>
        crmCliRead(
          connector,
          object: 'account',
          executableOverride: cli.path,
          fieldDeployment: (
            workspace: workspace.path,
            path: 'field.field.json',
            field: 'test1125__c',
            approve: approve,
          ),
        );
    expect(await deploy((_, _) async => false), {
      'status': 'not_deployed',
      'preview': 'dry run',
    });
    final deployed = await deploy((snapshot, preview) async {
      expect(snapshot, contains('approved'));
      expect(preview, 'dry run');
      await source.writeAsString('{"apiKey":"test1125__c","label":"changed"}');
      return true;
    });
    expect((deployed as Map)['output'], 'field written');
    expect(await source.readAsString(), contains('changed'));
  }, skip: Platform.isWindows);
  test('generic neo forwards new commands with the selected workspace authorization', () async {
    final folder = await Directory.systemTemp.createTemp('neo-generic-test-');
    addTearDown(() => folder.delete(recursive: true));
    final workspace = await Directory(p.join(folder.path, 'workspace'))
        .create();
    final manifest = File(p.join(workspace.path, 'neo-project.json'));
    const original = '{"projectId":"workspace-project","sourceDir":"src"}';
    await manifest.writeAsString(original);
    final cli = File(p.join(folder.path, 'fake-neo'));
    await cli.writeAsString(r'''#!/bin/sh
set -eu
test "$1 $2" = "deploy future-feature"
test -f neo-project.json
grep -q '"accessToken":"uat-fixture"' "$HOME/.neocrm-cli/auth/workspace-project.json"
if [ "$3" = "--help" ]; then
  printf '%s\n' '  --dry-run   Preview only'
elif [ "$3" = "--dry-run" ]; then
  test "$4 $5" = "--api-key item"
  printf '%s' 'dry run okay'
else
  test "$3 $4" = "--api-key item"
  printf '%s' 'completed by CLI'
fi
''');
    expect((await Process.run('chmod', ['700', cli.path])).exitCode, 0);
    final connector = CrmConnector({
      'product': CrmProduct.neocrm.name,
      'auth': CrmAuth.neoCli.name,
      'baseUrl': 'https://crm-sandbox.xiaoshouyi.com',
      'accessToken': 'uat-fixture',
    });
    Future<Object?> invoke(Future<bool> Function(String, String) approve) =>
        crmCliRead(
          connector,
          executableOverride: cli.path,
          neoCommand: (
            args: ['deploy', 'future-feature', '--api-key', 'item'],
            workspace: workspace.path,
            approve: approve,
          ),
        );
    final cancelled = await invoke((command, details) async {
      expect(command, 'neo deploy future-feature --api-key item');
      expect(details, contains('dry run okay'));
      return false;
    });
    expect((cancelled as Map)['status'], 'cancelled');
    final completed = await invoke((_, _) async => true);
    expect((completed as Map)['output'], 'completed by CLI');
    expect(await manifest.readAsString(), original);
  }, skip: Platform.isWindows);
}
