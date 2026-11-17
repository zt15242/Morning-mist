import 'mcp_probe.dart';

/// No servers to start or ask (the web).
McpProber? get platformMcpProber => null;

Future<Uri> beginMcpSignIn(
  String name,
  Map<String, Object?> config, {
  Uri? resourceMetadata,
  required void Function(Object?) onSignedIn,
}) => Future.error(UnsupportedError('MCP sign-in is unavailable'));
