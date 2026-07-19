import 'dart:math';

class ServerConfig {
  final String id;
  final String name;
  final String host;
  final int port;
  final String token;
  final bool useRelay;
  final bool expectedOnline;
  final int sortOrder;
  // Per-server relay pairing data
  final String relayUrl;
  final String pairingToken;
  final String serverPubkey;
  final String defaultCwd;
  final int? colorValue; // ARGB color value for badge
  final String
  systemPrompt; // Default system prompt append for all sessions on this server

  ServerConfig({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.token,
    this.useRelay = false,
    this.expectedOnline = false,
    this.sortOrder = 0,
    this.relayUrl = '',
    this.pairingToken = '',
    String serverPubkey = '',
    this.defaultCwd = '',
    this.colorValue,
    this.systemPrompt = '',
  }) : serverPubkey = normalizeServerPubkey(serverPubkey);

  bool get isRelayPaired =>
      relayUrl.isNotEmpty && pairingToken.isNotEmpty && serverPubkey.isNotEmpty;

  /// Stable identity for the physical SocketAgent server represented by this
  /// config. Older app versions could migrate/pair the same server more than
  /// once under different local IDs, which opened duplicate relay sockets and
  /// caused every live event/history snapshot to arrive more than once.
  String get connectionIdentity {
    if (useRelay) {
      if (!isRelayPaired) return ['relay-unconfigured', id].join('\u0001');
      return [
        'relay',
        relayUrl.trim().toLowerCase(),
        pairingToken.trim(),
        serverPubkey.trim(),
      ].join('\u0001');
    }
    return [
      'direct',
      host.trim().toLowerCase(),
      port.toString(),
      token.trim(),
      serverPubkey.trim(),
    ].join('\u0001');
  }

  static String generateId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rand = Random().nextInt(0xFFFF).toRadixString(16).padLeft(4, '0');
    return 'srv_${now}_$rand';
  }

  static String normalizeServerPubkey(String value) {
    final trimmed = value.trim();
    final parts = trimmed.split('|');
    if (parts.length == 3 && (parts[0] == 'SA' || parts[0] == 'SC')) {
      return parts[2].trim();
    }
    return trimmed;
  }

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      port: json['port'] as int,
      token: json['token'] as String,
      useRelay: json['useRelay'] as bool? ?? false,
      expectedOnline: json['expectedOnline'] as bool? ?? false,
      sortOrder: json['sortOrder'] as int? ?? 0,
      relayUrl: json['relayUrl'] as String? ?? '',
      pairingToken: json['pairingToken'] as String? ?? '',
      serverPubkey: json['serverPubkey'] as String? ?? '',
      defaultCwd: json['defaultCwd'] as String? ?? '',
      colorValue: json['colorValue'] as int?,
      systemPrompt: json['systemPrompt'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'token': token,
    'useRelay': useRelay,
    'expectedOnline': expectedOnline,
    'sortOrder': sortOrder,
    'relayUrl': relayUrl,
    'pairingToken': pairingToken,
    'serverPubkey': serverPubkey,
    'defaultCwd': defaultCwd,
    if (colorValue != null) 'colorValue': colorValue,
    if (systemPrompt.isNotEmpty) 'systemPrompt': systemPrompt,
  };

  ServerConfig copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? token,
    bool? useRelay,
    bool? expectedOnline,
    int? sortOrder,
    String? relayUrl,
    String? pairingToken,
    String? serverPubkey,
    String? defaultCwd,
    int? colorValue,
    String? systemPrompt,
  }) {
    return ServerConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      token: token ?? this.token,
      useRelay: useRelay ?? this.useRelay,
      expectedOnline: expectedOnline ?? this.expectedOnline,
      sortOrder: sortOrder ?? this.sortOrder,
      relayUrl: relayUrl ?? this.relayUrl,
      pairingToken: pairingToken ?? this.pairingToken,
      serverPubkey: serverPubkey ?? this.serverPubkey,
      defaultCwd: defaultCwd ?? this.defaultCwd,
      colorValue: colorValue ?? this.colorValue,
      systemPrompt: systemPrompt ?? this.systemPrompt,
    );
  }
}

/// Keeps the first config for each physical server connection. Config IDs are
/// app-local, so they cannot be used to detect a duplicate pairing.
List<ServerConfig> dedupeServerConfigs(Iterable<ServerConfig> configs) {
  final seen = <String>{};
  return configs
      .where((config) => seen.add(config.connectionIdentity))
      .toList();
}
