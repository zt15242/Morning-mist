import 'package:baocode/crm/crm_cli_routing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('identifies terminal CLI calls that could use the workspace login', () {
    for (final command in [
      "cd '/Users/example/Downloads/测试2' && neo loginstatus",
      '"/usr/local/bin/neo" deploy field --object account',
      r'C:\tools\neo.cmd deploy field --object account',
      'sf data query --query "SELECT Id FROM Account"',
      'sharecrm data record query-by-sql --sql "SELECT name FROM AccountObj"',
      'cat ~/.neocrm-cli/auth/project.json',
    ]) {
      expect(usesUnboundCrmCli(command), isTrue, reason: command);
    }
    for (final command in [
      'git status --short',
      'ls neocrm-src',
      'node tool/check_neo_source.js',
    ]) {
      expect(usesUnboundCrmCli(command), isFalse, reason: command);
    }
  });
}
