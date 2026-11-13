import 'dart:convert';
import 'dart:io';

import '../models/server_config.dart';
import 'transport_v2.dart';

/// What discovery should do with the server found on this machine, given the
/// saved computers. Entries pointing at this machine under an older key can
/// never connect again, so they are replaced or removed instead of piling up
/// next to the current one.
class LocalServerPlan {
  const LocalServerPlan({
    this.add,
    this.replace,
    this.update,
    this.remove = const [],
  });

  /// A new entry, when nothing saved is this computer yet.
  final ServerConfig? add;

  /// A stale local entry brought up to date, keeping its ID and name.
  final ServerConfig? replace;

  /// The saved entry for this computer, local or the user's own, with the
  /// pairing the server's files now hold. The key is the one already saved.
  final ServerConfig? update;

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
    final named = saved
        .where(
          (c) => c.serverPubkey == found.serverPubkey && !local.contains(c),
        )
        .firstOrNull;
    if (named != null) {
      return LocalServerPlan(
        update: _pairingUpdate(named, found),
        remove: [for (final c in local) c.id],
      );
    }
    if (current.isNotEmpty) {
      return LocalServerPlan(
        update: _pairingUpdate(current.first, found),
        remove: [for (final c in stale) c.id],
      );
    }
    if (stale.isNotEmpty) {
      return LocalServerPlan(
        // A reinstalled server is a new computer: its key file names it,
        // and whatever v2 pairing the old one had goes with the old key.
        replace: _withPairing(
          stale.first
              .withComputerKey(found.serverPubkey)
              .copyWith(host: found.host, token: found.token),
          found,
        ),
        remove: [for (final c in stale.skip(1)) c.id],
      );
    }
    return LocalServerPlan(add: found);
  }

  /// [entry] with the pairing in [found], when [found] read one from the
  /// server's files and [entry] does not hold it yet. Otherwise null.
  static ServerConfig? _pairingUpdate(ServerConfig entry, ServerConfig found) =>
      found.isV2 &&
          (!entry.isV2 ||
              entry.pairingSecret != found.pairingSecret ||
              entry.pairingToken != found.pairingToken)
      ? _withPairing(entry, found)
      : null;

  /// [entry] with the pairing [found] read from the server's own files,
  /// when it read one.
  static ServerConfig _withPairing(ServerConfig entry, ServerConfig found) =>
      found.isV2
      ? entry.copyWith(
          pairingToken: found.pairingToken,
          pairingSecret: found.pairingSecret,
          transport: 2,
        )
      : entry;
}

/// Reads only this computer's installations: the current Windows user's own,
/// and the machine-wide server another account installed. Never scans the
/// network or obtains credentials from an unauthenticated HTTP endpoint.
class WindowsLocalServer {
  /// The server described by `C:\ProgramData\SocketAgent\machine-server.json`.
  /// It carries no token: an account that cannot read the owner's `.env`
  /// connects with its device key, and the owner approves it once.
  static ServerConfig? machineConfiguration(String text) {
    try {
      final record = jsonDecode(text.replaceFirst('\uFEFF', ''));
      if (record is! Map) return null;
      final port = record['port'];
      final publicKey = record['publicKey'];
      if (port is! int || port < 1 || port > 65535 || publicKey is! String) {
        return null;
      }
      if (base64Decode(publicKey).length != 32) return null;
      return ServerConfig(
        id: 'windows_local_$port',
        name: 'This computer',
        host: '127.0.0.1',
        port: port,
        token: '',
        serverPubkey: publicKey,
      );
    } catch (_) {
      return null;
    }
  }

  /// The text of the machine marker, or null when there is none to believe.
  /// Any account can create a folder in ProgramData before setup runs, so
  /// the marker counts only when [trustsMachineMarker] says setup made the
  /// folder what it is. With that true no ordinary account can swap the
  /// file between the check and the read.
  static Future<String?> _trustedMachineMarker() async {
    final data = Platform.environment['ProgramData'];
    if (data == null) return null;
    final folder = '$data\\SocketAgent';
    final marker = File('$folder\\machine-server.json');
    if (!await marker.exists()) return null;
    final facts = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      machineMarkerFactsScript(folder, marker.path),
    ]);
    if (!trustsMachineMarker(facts.stdout.toString())) return null;
    return marker.readAsString();
  }

  /// The PowerShell that prints what [trustsMachineMarker] reads: the owner
  /// of [folder], the owner of [file], each access rule on the folder, and
  /// `end` once all of it was read. Any error stops it before `end`.
  static String machineMarkerFactsScript(String folder, String file) {
    String quoted(String path) => "'${path.replaceAll("'", "''")}'";
    return [
      r"$ErrorActionPreference = 'Stop'",
      r'$sid = [Security.Principal.SecurityIdentifier]',
      '\$folder = Get-Acl -LiteralPath ${quoted(folder)}',
      r"'folder ' + $folder.GetOwner($sid).Value",
      "'file ' + (Get-Acl -LiteralPath ${quoted(file)}).GetOwner(\$sid).Value",
      r'foreach ($rule in $folder.GetAccessRules($true, $true, $sid)) '
          r"{ 'rule {0} {1} {2}' -f $rule.AccessControlType, "
          r'[int]$rule.FileSystemRights, $rule.IdentityReference.Value }',
      "'end'",
    ].join('; ');
  }

  /// Whether the machine marker is one setup's folder holds, from the
  /// [facts] the script above printed. Setup gives the folder to the
  /// administrators, with full control for them and SYSTEM and read access
  /// for Users, so this asks that SYSTEM or the administrators own the
  /// folder and the file, and that no rule lets any other account do more
  /// in the folder than read it. A folder an ordinary account made, or may
  /// write to, fails. So does output that is cut short or not understood.
  static bool trustsMachineMarker(String facts) {
    const administrators = {'S-1-5-18', 'S-1-5-32-544'};
    // ReadAndExecute with Synchronize, the rights setup grants Users.
    const readOnly = 0x1200A9;
    String? folderOwner;
    String? fileOwner;
    var complete = false;
    for (final line in const LineSplitter().convert(facts)) {
      switch (line.trim().split(' ')) {
        case ['']:
          break;
        case ['folder', final sid]:
          folderOwner = sid;
        case ['file', final sid]:
          fileOwner = sid;
        case ['rule', 'Deny', _, _]:
          break;
        case ['rule', 'Allow', final rights, final sid]:
          if (administrators.contains(sid)) break;
          final mask = int.tryParse(rights);
          if (mask == null || (mask & 0xFFFFFFFF & ~readOnly) != 0) {
            return false;
          }
        case ['end']:
          complete = true;
        default:
          return false;
      }
    }
    return complete &&
        administrators.contains(folderOwner) &&
        administrators.contains(fileOwner);
  }

  /// The servers discovery reports: the owner's [own] installs, and the
  /// [machine] server from the marker unless one of them is on its port.
  /// The owner's own files say which server that port is, with its key and
  /// its token, and a marker does not overrule them.
  static List<ServerConfig> found(
    List<ServerConfig> own,
    ServerConfig? machine,
  ) => [
    ...own,
    if (machine != null && !own.any((c) => c.port == machine.port)) machine,
  ];

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

  /// The current pairing secret in the text of the server's `transport.json`
  /// (wire spec 7.1), or null. The newest secret is first. Nothing else in
  /// that file is the app's to read.
  static String? pairingSecret(String stateFile) {
    try {
      final state = jsonDecode(stateFile.replaceFirst('\uFEFF', ''));
      final secrets = state is Map ? state['secrets'] : null;
      final current = secrets is List && secrets.isNotEmpty
          ? secrets.first
          : null;
      final secret = current is Map ? current['secret'] : null;
      return decodeKey32(secret) == null ? null : secret as String;
    } catch (_) {
      return null;
    }
  }

  /// The owner's own install, from its `.env`, its key file and, when the
  /// server has one, its state file. With [stateFile] the entry is on
  /// transport v2 from the start: the room ID is the `.env`'s
  /// `PAIRING_TOKEN` and the secret comes from the file (wire spec 5.3).
  /// Without it, or when either value is unusable, the entry connects with
  /// the token as before.
  static ServerConfig? configuration(
    Map<String, String> env,
    String publicKey, {
    String? stateFile,
  }) {
    final port = int.tryParse(env['PORT'] ?? '8085');
    final token = env['AUTH_TOKEN'] ?? '';
    if (port == null || port < 1 || port > 65535 || token.isEmpty) return null;
    try {
      if (base64Decode(publicKey).length != 32) return null;
    } catch (_) {
      return null;
    }
    final roomId = env['PAIRING_TOKEN'] ?? '';
    final secret = stateFile == null ? null : pairingSecret(stateFile);
    final paired = secret != null && isValidRoomId(roomId);
    return ServerConfig(
      id: 'windows_local_$port',
      name: 'This computer',
      host: '127.0.0.1',
      port: port,
      token: token,
      serverPubkey: publicKey,
      pairingToken: paired ? roomId : '',
      pairingSecret: paired ? secret : '',
      transport: paired ? 2 : null,
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
          final state = File('$directory/transport.json');
          final config = configuration(
            env,
            json['publicKey']?.toString() ?? '',
            stateFile: await state.exists() ? await state.readAsString() : null,
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
    try {
      final text = await _trustedMachineMarker();
      return WindowsLocalServer.found(
        found,
        text == null ? null : machineConfiguration(text),
      );
    } catch (_) {}
    return found;
  }
}
