// Run with the verified Salesforce Core and Services VSIX files from the
// same release. This uses an empty Salesforce project and no CRM login.
@Tags(['exthost'])
library;

import 'dart:io';

import 'package:baocode/extensions/gallery/extension_management_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'open_vsx_workspace.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final directory = Platform.environment['BAOCODE_SALESFORCE_VSIX_DIR'];

  test(
    'activates the official Salesforce CLI extension and executes its command',
    () async {
      final home = await Directory.systemTemp.createTemp('salesforce-home-');
      addTearDown(() => home.delete(recursive: true));
      final workspace = await OpenVsxWorkspace.create(
        extensionIds: const [],
        serverEnvironment: () async => {
          'HOME': home.path,
          'USERPROFILE': home.path,
          'SFDX_DISABLE_TELEMETRY': 'true',
        },
        files: {
          'sfdx-project.json': '''
{
  "packageDirectories": [{"path": "force-app", "default": true}],
  "namespace": "",
  "sourceApiVersion": "67.0"
}
''',
          'force-app/.keep': '',
        },
        settings: {
          'telemetry.telemetryLevel': 'off',
          'salesforcedx-vscode-core.telemetry.enabled': false,
        },
      );
      final extensions = workspace.extensions;
      for (final name in ['services', 'core']) {
        final extension = await extensions.management.install(
          p.join(directory!, '$name.vsix'),
          options: const ExtensionInstallOptions(withDependencies: false),
        );
        expect(extension.id, 'salesforce.salesforcedx-vscode-$name');
        await workspace.activated(extension.id);
      }

      final palette = extensions.palette.commandsById();
      expect(palette['sf.config.list']?.enabled, isTrue);
      await extensions.commands.executeCommand('sf.config.list');
    },
    skip: directory == null ? 'Set BAOCODE_SALESFORCE_VSIX_DIR' : openVsxSkip(),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
