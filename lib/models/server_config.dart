import 'dart:math';

/// The relay every computer uses unless its pairing code names another. It
/// is also the only relay the app's own account work goes to: subscription,
/// billing, reports and the vault.
const String defaultRelayUrl = 'wss://relay.jarofdirt.info';

/// Whether [host] names this machine, so nothing sent to it crosses a
/// network.
bool isLoopbackHost(String host) =>
    const {'127.0.0.1', 'localhost', '::1'}.contains(host);

/// [value] as a relay address a config may hold: `wss://` or `https://`, or
/// `ws://` or `http://` to this machine. The relay's first address becomes
/// [defaultRelayUrl]. Anything else comes back empty, and the config keeps
/// that it was refused in [ServerConfig.relayRefused].
/// Every [ServerConfig] is built through this, so an address from a pairing
/// code, an import, the vault or a text field is checked once, where it is
/// stored, and the subscriber token never follows one over plain HTTP.
String storableRelayUrl(String value) {
  final trimmed = value.trim();
  if (trimmed == 'ws://jarofdirt.info:9988') return defaultRelayUrl;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.host.isEmpty) return '';
  final allowed = switch (uri.scheme) {
    'wss' || 'https' => true,
    'ws' || 'http' => isLoopbackHost(uri.host),
    _ => false,
  };
  return allowed ? trimmed : '';
}

class ServerConfig {
  final String id;
  final String name;
  final String host;
  final int port;
  final String token;

  /// The route in use. With [autoRoute] the app updates it as the phone moves
  /// between the computer's network and anywhere else.
  final bool useRelay;

  /// Whether the app picks direct or relay on each connect. Off means
  /// [useRelay] is the user's fixed choice.
  final bool autoRoute;
  final bool expectedOnline;
  final int sortOrder;
  // Per-server relay pairing data
  final String relayUrl;

  /// Whether the last relay address given for this computer was one
  /// [storableRelayUrl] refuses. Such an entry has no relay until the user
  /// gives it another address. It is never moved to the default relay.
  final bool relayRefused;

  /// The computer's relay room ID. The name is from the old transport, where
  /// this value was also the pairing secret.
  final String pairingToken;
  final String serverPubkey;

  /// Base64 of the computer's current pairing secret, or empty. Transport v2
  /// proves it in every handshake and never sends it.
  final String pairingSecret;

  /// 2 once this computer is on transport v2 for this account, otherwise
  /// null. Nothing sets it back: from then on the app never speaks the old
  /// transport to this computer.
  final int? transport;
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
    this.autoRoute = false,
    this.expectedOnline = false,
    this.sortOrder = 0,
    String relayUrl = '',
    bool relayRefused = false,
    this.pairingToken = '',
    String serverPubkey = '',
    this.pairingSecret = '',
    int? transport,
    this.defaultCwd = '',
    this.colorValue,
    this.systemPrompt = '',
  }) : serverPubkey = normalizeServerPubkey(serverPubkey),
       relayUrl = storableRelayUrl(relayUrl),
       // An address decides this by itself. No address leaves it as it was.
       relayRefused = relayUrl.trim().isEmpty
           ? relayRefused
           : storableRelayUrl(relayUrl).isEmpty,
       transport = transport == 2 ? 2 : null;

  /// Whether this computer is on transport v2 here, for good.
  bool get isV2 => transport == 2;

  /// What a v2 socket to this computer handshakes with, or null while the
  /// computer is on the old transport.
  ({String roomId, String secret})? get transportPairing =>
      isV2 ? (roomId: pairingToken, secret: pairingSecret) : null;

  /// This entry with [key] as its computer. A different key is a different
  /// computer, so the v2 pairing made with the old one does not carry over.
  /// Only a pairing code, the account, an import or the user typing may
  /// supply [key]. Nothing a computer or relay sends reaches this.
  ServerConfig withComputerKey(String key) {
    final normalized = normalizeServerPubkey(key);
    if (normalized == serverPubkey) return this;
    return ServerConfig.fromJson(
      toJson()
        ..['serverPubkey'] = normalized
        ..remove('pairingSecret')
        ..remove('transport'),
    );
  }

  /// This entry as the next state of [previous]. "This computer is v2" is
  /// set once and nothing clears it. A v2 pairing is its secret and its room
  /// ID together: an update for the same computer that brings both replaces
  /// the pair, and one that brings neither, or only one, keeps the previous
  /// pair. An update that names no relay keeps the one a v2 entry had. So no
  /// edit, import or vault entry can leave a v2 computer without its pairing.
  ServerConfig after(ServerConfig previous) {
    if (previous.serverPubkey != serverPubkey || !previous.isV2) return this;
    final bringsPairing = pairingSecret.isNotEmpty && pairingToken.isNotEmpty;
    return copyWith(
      pairingSecret: bringsPairing ? null : previous.pairingSecret,
      pairingToken: bringsPairing ? null : previous.pairingToken,
      relayUrl: relayUrl.isEmpty ? previous.relayUrl : null,
      transport: 2,
    );
  }

  /// The relay this computer is on once it has a room: the stored one, or
  /// the default when none was ever given. Null when the address given was
  /// refused, so a room ID the computer sends later puts it on no relay.
  String? get relayOrDefault => relayUrl.isNotEmpty
      ? relayUrl
      : relayRefused
      ? null
      : defaultRelayUrl;

  bool get isRelayPaired =>
      relayUrl.isNotEmpty && pairingToken.isNotEmpty && serverPubkey.isNotEmpty;

  /// Reachable only from the machine the server runs on. Discovery adds these
  /// on Windows; another device can't use 127.0.0.1 to reach this computer.
  bool get isLoopbackOnly =>
      !isRelayPaired && (host == '127.0.0.1' || host == 'localhost');

  /// Stable identity for the physical SocketAgent server represented by this
  /// config. Older app versions could migrate/pair the same server more than
  /// once under different local IDs, which opened duplicate relay sockets and
  /// caused every live event/history snapshot to arrive more than once.
  String get connectionIdentity {
    // An auto-routed computer is the same server on either route.
    if (useRelay || (autoRoute && isRelayPaired)) {
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
    final oldCode =
        (parts.length == 3 || parts.length == 6) &&
        (parts[0] == 'SA' || parts[0] == 'SC');
    final v2Code =
        (parts.length == 6 || parts.length == 7) && parts[0] == 'SA3';
    return oldCode || v2Code ? parts[2].trim() : trimmed;
  }

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      port: json['port'] as int,
      token: json['token'] as String,
      useRelay: json['useRelay'] as bool? ?? false,
      // Computers saved before auto routing keep direct if the user chose it.
      // Relay computers start finding a direct route once the server sends one.
      autoRoute: json['autoRoute'] as bool? ?? json['useRelay'] == true,
      expectedOnline: json['expectedOnline'] as bool? ?? false,
      sortOrder: json['sortOrder'] as int? ?? 0,
      relayUrl: json['relayUrl'] as String? ?? '',
      relayRefused: json['relayRefused'] == true,
      pairingToken: json['pairingToken'] as String? ?? '',
      serverPubkey: json['serverPubkey'] as String? ?? '',
      pairingSecret: json['pairingSecret'] as String? ?? '',
      transport: (json['transport'] as num?)?.toInt(),
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
    'autoRoute': autoRoute,
    'expectedOnline': expectedOnline,
    'sortOrder': sortOrder,
    'relayUrl': relayUrl,
    if (relayRefused) 'relayRefused': true,
    'pairingToken': pairingToken,
    'serverPubkey': serverPubkey,
    // Written only when set, so an entry from a device still on the old
    // transport carries neither and cannot blank them when it merges.
    if (pairingSecret.isNotEmpty) 'pairingSecret': pairingSecret,
    if (isV2) 'transport': 2,
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
    bool? autoRoute,
    bool? expectedOnline,
    int? sortOrder,
    String? relayUrl,
    String? pairingToken,
    String? serverPubkey,
    String? pairingSecret,
    int? transport,
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
      autoRoute: autoRoute ?? this.autoRoute,
      expectedOnline: expectedOnline ?? this.expectedOnline,
      sortOrder: sortOrder ?? this.sortOrder,
      relayUrl: relayUrl ?? this.relayUrl,
      relayRefused: relayRefused,
      pairingToken: pairingToken ?? this.pairingToken,
      serverPubkey: serverPubkey ?? this.serverPubkey,
      pairingSecret: pairingSecret ?? this.pairingSecret,
      transport: transport ?? this.transport,
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
