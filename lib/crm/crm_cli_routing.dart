/// Recognizes raw CRM CLI invocations in the agent's terminal commands so a
/// connector-scoped turn cannot accidentally use the workspace's login.
bool usesUnboundCrmCli(String command) {
  return _cli.hasMatch(command) || _authPath.hasMatch(command);
}

final _cli = RegExp(
  r'''(?:^|[\s/\\'"\x60;&|()])(?:neo|sf|sharecrm)(?:\.(?:cmd|exe|bat))?(?=$|[\s'"\x60;&|()])''',
  caseSensitive: false,
);

final _authPath = RegExp(
  r'(?:\.neocrm-cli[/\\]auth\b|\.neo-cli[/\\]token\.json\b)',
  caseSensitive: false,
);
