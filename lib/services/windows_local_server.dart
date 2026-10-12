import 'dart:convert';
import 'dart:io';

import '../models/server_config.dart';

/// What discovery should do with the server found on this machine, given the
/// saved computers. Entries pointing at this machine under an older key can
/// never connect again, so they are replaced or removed instead of piling up
/// next to the current one.
class LocalServerPlan {
  const LocalServerPlan({this.add, this.replace, this.remove = const []});

  /// A new entry, when nothing saved is this computer yet.
  final ServerConfig? add;

  /// A stale local entry brought up to date, keeping its ID and name.
  final ServerConfig? replace;

  /// IDs of local entries to drop: stale keys, or duplicates of a computer
  /// the user already saved another way.
  final List<String> remove;

  static LocalServerPlan of(List<ServerConfig> saved, ServerConfig found) {
    final local = [
      for (final c in saved)
        if (!c.useRelay && c.isLoopbackOnly && c.port == found.port) c,
    ];
    final stale = [
      for (final c in local)
        if (c.serverPubkey != found.serverPubkey) c,
    ];
    final current = [
      for (final c in local)
        if (c.serverPubkey == found.serverPubkey) c,
    ];
    // The user's own entry for this computer, such as one paired over the
    // relay and named by them. Auto routing reaches it locally anyway.
    final named = saved.any(
      (c) => c.serverPubkey == found.serverPubkey && !local.contains(c),
    );
    if (named) return LocalServerPlan(remove: [for (final c in local) c.id]);
    if (current.isNotEmpty) {
      return LocalServerPlan(remove: [for (final c in stale) c.id]);
    }
    if (stale.isNotEmpty) {
      return LocalServerPlan(
        replace: stale.first.copyWith(
          host: found.host,
          token: found.token,
          serverPubkey: found.serverPubkey,
        ),
        remove: [for (final c in stale.skip(1)) c.id],
      );
    }
    return LocalServerPlan(add: found);
  }
}

/// Reads only the current Windows user's installation. Never scans the network
/// or obtains credentials from an unauthenticated HTTP endpoint.
class WindowsLocalServer {
  static Map<String, String> parseEnvironment(String text) {
    final result = <String, String>{};
    for (var line in const LineSplitter().convert(text)) {
      line = line.replaceFirst('\uFEFF', '').trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final match = RegExp(
        r'^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$',
      ).firstMatch(line);
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

  static ServerConfig? configuration(
    Map<String, String> env,
    String publicKey,
  ) {
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
        final path = (await marker.readAsString())
            .replaceFirst('\uFEFF', '')
            .trim();
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
        final data =
            env['SOCKET_AGENT_DATA_DIR'] ??
            env['SOCKETAGENT_DATA_DIR'] ??
            process['SOCKET_AGENT_DATA_DIR'] ??
            process['SOCKETAGENT_DATA_DIR'] ??
            env['SOCKET_AGENT_HOME'] ??
            env['SOCKETAGENT_HOME'] ??
            process['SOCKET_AGENT_HOME'] ??
            process['SOCKETAGENT_HOME'];
        for (final directory
            in data == null
                ? ['$home/.socket-agent', '$home/.claude-assistant']
                : [data]) {
          final keys = File('$directory/relay-keys.json');
          if (!await keys.exists()) continue;
          final json = jsonDecode(await keys.readAsString()) as Map;
          final config = configuration(
            env,
            json['publicKey']?.toString() ?? '',
          );
          if (config != null &&
              !found.any(
                (c) => c.connectionIdentity == config.connectionIdentity,
              )) {
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
