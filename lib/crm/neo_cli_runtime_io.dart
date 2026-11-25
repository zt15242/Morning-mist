import 'dart:io';

import 'package:path/path.dart' as p;

Future<String> neoCliExecutable(String? home) async {
  if (home == null) return 'neo';
  for (final executable in [
    if (!Platform.isWindows)
      p.join(
        home,
        '.local',
        'share',
        'neocrm-cli-1.1.2',
        'node_modules',
        '.bin',
        'neo',
      ),
    p.join(home, '.local', 'bin', 'neo'),
  ]) {
    if (await File(executable).exists()) return executable;
  }
  return 'neo';
}
