import 'dart:convert';
import 'dart:io';

import '../models/server_config.dart';

/// Reads only the current Windows user's installation. Never scans the network
/// or obtains credentials from an unauthenticated HTTP endpoint.
class WindowsLocalServer {
  static Map<String, String> parseEnvironment(String text) {
    final result = <String, String>{};
    for (var line in const LineSplitter().convert(text)) {
      line = line.replaceFirst('\uFEFF', '').trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final match = RegExp(r'^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$').firstMatch(line);
      if (match == null) continue;
      var value = match[2]!.trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      } else {
        value = value.split('#').first.trim();
      }
      result[match[1]!] = value;
    }
    return result;
  }

  static ServerConfig? configuration(Map<String, String> env, String publicKey) {
    final port = int.tryParse(env['PORT'] ?? '8085');
    final token = env['AUTH_TOKEN'] ?? '';
    if (port == null || port < 1 || port > 65535 || token.isEmpty) return null;
    try {
      if (base64Decode(publicKey).length != 32) return null;
    } catch (_) {
      return null;
    }
    return ServerConfig(
      id: 'windows_local_$port',
      name: 'This computer',
      host: '127.0.0.1',
      port: port,
      token: token,
      serverPubkey: publicKey,
      defaultCwd: env['DEFAULT_CWD'] ?? '',
    );
  }

  Future<List<ServerConfig>> discover() async {
    if (!Platform.isWindows) return const [];
    final home = Platform.environment['USERPROFILE'];
    if (home == null) return const [];
    final installs = <String>{'$home/socketagent', '$home/socketclaude'};
    final local = Platform.environment['LOCALAPPDATA'];
    if (local != null) {
      final marker = File('$local/SocketAgent/install-location.txt');
      if (await marker.exists()) {
        final path = (await marker.readAsString()).replaceFirst('\uFEFF', '').trim();
        if (path.isNotEmpty) installs.add(path);
      }
    }
    final found = <ServerConfig>[];
    for (final install in installs) {
      try {
        final file = File('$install/server/.env');
        if (!await file.exists()) continue;
        final env = parseEnvironment(await file.readAsString());
        final process = Platform.environment;
        final data = env['SOCKET_AGENT_DATA_DIR'] ?? env['SOCKETAGENT_DATA_DIR'] ??
            process['SOCKET_AGENT_DATA_DIR'] ?? process['SOCKETAGENT_DATA_DIR'] ??
            env['SOCKET_AGENT_HOME'] ?? env['SOCKETAGENT_HOME'] ??
            process['SOCKET_AGENT_HOME'] ?? process['SOCKETAGENT_HOME'];
        for (final directory in data == null
            ? ['$home/.socket-agent', '$home/.claude-assistant']
            : [data]) {
          final keys = File('$directory/relay-keys.json');
          if (!await keys.exists()) continue;
          final json = jsonDecode(await keys.readAsString()) as Map;
          final config = configuration(env, json['publicKey']?.toString() ?? '');
          if (config != null && !found.any((c) => c.connectionIdentity == config.connectionIdentity)) {
            found.add(config);
          }
        }
      } catch (_) {
        // Missing/inaccessible/old installations do not prevent normal startup.
      }
    }
    return found;
  }
}
