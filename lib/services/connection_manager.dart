import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/server_config.dart';
import 'local_route.dart';
import 'websocket_service.dart';
import 'crypto_service.dart';

/// A message from a server, tagged with which server sent it.
class ServerMessage {
  final String serverId;
  final Map<String, dynamic> data;
  ServerMessage(this.serverId, this.data);
}

/// Per-server connection status update.
class ServerStatusUpdate {
  final String serverId;
  final ConnectionStatus status;
  ServerStatusUpdate(this.serverId, this.status);
}

ConnectionMode connectionModeForServerConfig(ServerConfig config) {
  return config.useRelay ? ConnectionMode.relay : ConnectionMode.direct;
}

/// Resolves the transport for an explicit server without letting another
/// active connection decide whether the requested action needs relay access.
ConnectionMode connectionModeForServerId(
  Iterable<ServerConfig> configs,
  String? serverId, {
  required ConnectionMode fallback,
}) {
  if (serverId == null || serverId.isEmpty) return fallback;
  for (final config in configs) {
    if (config.id == serverId) return connectionModeForServerConfig(config);
  }
  return fallback;
}

/// The route for an auto-routed computer: direct when a LAN address answered,
/// otherwise the relay if this phone may use it. Without relay access the LAN
/// is the only way in, so keep retrying it.
ConnectionMode chooseAutoRoute({
  required String? directHost,
  required bool canRelay,
}) {
  if (directHost != null) return ConnectionMode.direct;
  return canRelay ? ConnectionMode.relay : ConnectionMode.direct;
}

/// Manages simultaneous WebSocket connections to multiple SocketAgent servers.
///
/// Each server gets its own [WebSocketService] and (if relay) its own
/// [CryptoService] with that server's public key.
class ConnectionManager {
  final Map<String, WebSocketService> _connections = {};
  final Map<String, ServerConfig> _configs = {};
  final Map<String, CryptoService> _cryptoServices = {};
  final Map<String, StreamSubscription> _messageSubs = {};
  final Map<String, StreamSubscription> _statusSubs = {};

  String? activeServerId;
  String _subscriberToken = '';

  /// Called when auto routing moves a computer to another route or address,
  /// so the owner can save it. The manager has already switched the socket.
  void Function(ServerConfig config)? onRouteChanged;
  LocalRouteFinder routeFinder = const LocalRouteFinder();

  /// The phone's current networks. Replaced in tests.
  Future<List<ConnectivityResult>> Function() checkNetwork = () =>
      Connectivity().checkConnectivity();
  final Map<String, Future<void>> _routing = {};
  final Map<String, DateTime> _lastRouted = {};
  // Computers whose relay turned this phone away. Cleared with a new token.
  final Set<String> _relayRefused = {};
  StreamSubscription<List<ConnectivityResult>>? _networkChanges;

  final _messageController = StreamController<ServerMessage>.broadcast();
  final _statusController = StreamController<ServerStatusUpdate>.broadcast();

  /// Merged message stream from all connected servers.
  Stream<ServerMessage> get messages => _messageController.stream;

  /// Per-server status updates.
  Stream<ServerStatusUpdate> get statusStream => _statusController.stream;

  /// The active server's WebSocketService, or null if none.
  WebSocketService? get active =>
      activeServerId != null ? _connections[activeServerId] : null;

  /// The active server's config, or null.
  ServerConfig? get activeConfig =>
      activeServerId != null ? _configs[activeServerId] : null;

  /// All configured server configs.
  List<ServerConfig> get configs =>
      _configs.values.toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  /// Connection status for a specific server.
  ConnectionStatus statusOf(String serverId) =>
      _connections[serverId]?.status ?? ConnectionStatus.disconnected;

  /// Whether any server is connected.
  bool get anyConnected =>
      _connections.values.any((ws) => ws.status == ConnectionStatus.connected);

  /// Set the subscriber token (used for relay connections).
  void setSubscriberToken(String token) {
    if (token != _subscriberToken) _relayRefused.clear();
    _subscriberToken = token;
  }

  /// Set (or update) the full list of server configs.
  /// Each server with relay pairing data gets its own CryptoService.
  Future<void> setServers(List<ServerConfig> serverConfigs) async {
    final newIds = serverConfigs.map((c) => c.id).toSet();
    final oldIds = _configs.keys.toSet();

    // Remove deleted servers
    for (final id in oldIds.difference(newIds)) {
      _removeServer(id);
    }

    // Add or update servers
    for (final config in serverConfigs) {
      _configs[config.id] = config;

      if (!_connections.containsKey(config.id)) {
        final ws = WebSocketService();
        _connections[config.id] = ws;
        _subscribeToServer(config.id, ws);
      }

      await _configureTransport(config);
    }

    // Auto-select active server if none set or current was removed
    if (activeServerId == null || !newIds.contains(activeServerId)) {
      activeServerId = serverConfigs.isNotEmpty ? serverConfigs.first.id : null;
    }
  }

  /// Points [config]'s socket at the route its config selects.
  Future<void> _configureTransport(ServerConfig config) async {
    final ws = _connections[config.id]!;
    final selectedMode = connectionModeForServerConfig(config);
    // Transport selection is a security boundary. Apply it before touching
    // credentials so a relay-selected server can never retain or open a
    // direct socket while relay configuration is incomplete.
    ws.setMode(selectedMode);

    if (selectedMode == ConnectionMode.relay) {
      if (!config.isRelayPaired) {
        ws.clearRelayConfiguration();
        return;
      }
      // Per-server relay — each gets its own CryptoService
      var crypto = _cryptoServices[config.id];
      if (crypto == null) {
        crypto = CryptoService();
        _cryptoServices[config.id] = crypto;
      }
      await crypto.ensureKeyPair();
      crypto.setServerPublicKey(config.serverPubkey);
      ws.configureRelay(
        relayUrl: config.relayUrl,
        pairingToken: config.pairingToken,
        cryptoService: crypto,
        subscriberToken: _subscriberToken,
      );
    } else {
      CryptoService? crypto;
      if (config.serverPubkey.isNotEmpty) {
        crypto = _cryptoServices[config.id];
        if (crypto == null) {
          crypto = CryptoService();
          _cryptoServices[config.id] = crypto;
        }
        await crypto.ensureKeyPair();
        crypto.setServerPublicKey(config.serverPubkey);
      }
      ws.configure(
        host: config.host,
        port: config.port,
        token: config.token,
        cryptoService: crypto,
      );
    }
  }

  /// Re-picks the route for every auto-routed computer. Call when the phone
  /// changes networks or the app comes back to the foreground.
  void refreshRoutes() {
    for (final config in _configs.values) {
      if (config.autoRoute) unawaited(routeServer(config.id, force: true));
    }
  }

  /// Re-picks routes whenever the phone changes networks. Called once from
  /// main(), so host tests, which have no connectivity plugin, never start it.
  void watchNetworkChanges() {
    if (!Platform.isAndroid && !Platform.isWindows) return;
    _networkChanges ??= Connectivity().onConnectivityChanged.listen(
      (_) => refreshRoutes(),
      onError: (Object _) {},
    );
  }

  /// Picks direct or relay for an auto-routed computer and switches its
  /// socket if the route or LAN address changed. A live socket reconnects on
  /// the new route; an idle one stays idle. Runs at most once every 30
  /// seconds unless [force] is set, so a computer that is off doesn't keep
  /// the phone searching.
  Future<void> routeServer(String serverId, {bool force = false}) {
    final running = _routing[serverId];
    if (running != null) return running;
    final config = _configs[serverId];
    if (config == null || !config.autoRoute) return Future.value();
    final now = DateTime.now();
    final last = _lastRouted[serverId];
    if (!force &&
        last != null &&
        now.difference(last) < const Duration(seconds: 30)) {
      return Future.value();
    }
    _lastRouted[serverId] = now;
    // A block body: returning the removed future would make this wait on
    // itself.
    final routing = _route(config).whenComplete(() {
      _routing.remove(serverId);
    });
    _routing[serverId] = routing;
    return routing;
  }

  Future<void> _route(ServerConfig config) async {
    final canDirect = config.token.isNotEmpty && config.serverPubkey.isNotEmpty;
    final canRelay =
        config.isRelayPaired &&
        _subscriberToken.isNotEmpty &&
        !_relayRefused.contains(config.id);
    String? directHost;
    if (canDirect) {
      final network = await _networkKind();
      // On mobile data alone the LAN can't answer, so don't make the relay
      // wait on it. A VPN such as Tailscale can still reach the stored host.
      if (network != _NetworkKind.mobileOnly || !canRelay) {
        directHost = await routeFinder.find(
          config,
          searchLan: network == _NetworkKind.local,
          timeout: const Duration(seconds: 2),
        );
      }
    }
    final mode = canDirect || canRelay
        ? chooseAutoRoute(directHost: directHost, canRelay: canRelay)
        : connectionModeForServerConfig(config);

    // The config may have changed while the search ran.
    final latest = _configs[config.id];
    final ws = _connections[config.id];
    if (latest == null || !latest.autoRoute || ws == null) return;
    final next = latest.copyWith(
      useRelay: mode == ConnectionMode.relay,
      host: directHost ?? latest.host,
    );
    final moved =
        next.useRelay != latest.useRelay ||
        (!next.useRelay && next.host != latest.host);
    if (!moved) return;
    final live = ws.status != ConnectionStatus.disconnected || ws.reconnecting;
    _configs[config.id] = next;
    await _configureTransport(next);
    if (live) ws.connect(force: true);
    onRouteChanged?.call(next);
  }

  Future<_NetworkKind> _networkKind() async {
    try {
      final kinds = await checkNetwork().timeout(const Duration(seconds: 1));
      if (kinds.contains(ConnectivityResult.wifi) ||
          kinds.contains(ConnectivityResult.ethernet)) {
        return _NetworkKind.local;
      }
      if (kinds.contains(ConnectivityResult.mobile) &&
          !kinds.contains(ConnectivityResult.vpn)) {
        return _NetworkKind.mobileOnly;
      }
      return _NetworkKind.other;
    } catch (_) {
      // No answer from the platform: assume a LAN may exist.
      return _NetworkKind.local;
    }
  }

  /// Update relay config for a specific server (e.g. after pairing).
  Future<void> configureServerRelay(
    String serverId, {
    required String relayUrl,
    required String pairingToken,
    required String serverPubkey,
  }) async {
    var crypto = _cryptoServices[serverId];
    if (crypto == null) {
      crypto = CryptoService();
      _cryptoServices[serverId] = crypto;
    }
    await crypto.ensureKeyPair();
    crypto.setServerPublicKey(serverPubkey);

    final ws = _connections[serverId];
    if (ws != null) {
      ws.configureRelay(
        relayUrl: relayUrl,
        pairingToken: pairingToken,
        cryptoService: crypto,
        subscriberToken: _subscriberToken,
      );
      ws.setMode(ConnectionMode.relay);
    }
  }

  /// Connect all configured servers.
  void connectAll() {
    final connectedIdentities = <String>{};
    for (final entry in _connections.entries) {
      final config = _configs[entry.key];
      if (config == null) continue;
      // Defend against duplicate stored pairings even before the owning
      // provider has had a chance to migrate them away.
      if (!connectedIdentities.add(config.connectionIdentity)) continue;
      final ws = entry.value;
      if (config.autoRoute) {
        unawaited(
          routeServer(config.id, force: true).then((_) => ws.connect()),
        );
      } else {
        ws.connect();
      }
    }
  }

  /// Disconnect all servers.
  void disconnectAll() {
    for (final ws in _connections.values) {
      ws.disconnect();
    }
  }

  /// Send a message to the active server.
  bool send(Map<String, dynamic> message) {
    return active?.send(message) ?? false;
  }

  /// Send a message to a specific server.
  bool sendToServer(String serverId, Map<String, dynamic> message) {
    return _connections[serverId]?.send(message) ?? false;
  }

  /// Ensure a specific configured server is connecting. Safe to call while a
  /// connection is already healthy or in progress.
  void connectServer(String serverId) {
    _connections[serverId]?.connect();
  }

  /// Send a message to all connected servers.
  void sendToAll(Map<String, dynamic> message) {
    for (final ws in _connections.values) {
      if (ws.status == ConnectionStatus.connected) {
        ws.send(message);
      }
    }
  }

  void _subscribeToServer(String serverId, WebSocketService ws) {
    _messageSubs[serverId] = ws.messages.listen((data) {
      if (data['type'] == 'subscription_required' &&
          _configs[serverId]?.autoRoute == true) {
        // The relay turned us away. The LAN may still work without it.
        _relayRefused.add(serverId);
        // Retrying the relay would only be refused again.
        unawaited(
          routeServer(serverId, force: true).then((_) {
            if (ws.mode == ConnectionMode.direct) ws.connect();
          }),
        );
      }
      _messageController.add(ServerMessage(serverId, data));
    });

    _statusSubs[serverId] = ws.statusStream.listen((status) {
      _statusController.add(ServerStatusUpdate(serverId, status));
      // A dropped connection may mean the phone left or joined the
      // computer's network. Only when the socket plans to retry: an
      // intentional disconnect must stay disconnected.
      if ((status == ConnectionStatus.error ||
              status == ConnectionStatus.disconnected) &&
          ws.reconnecting &&
          _configs[serverId]?.autoRoute == true) {
        unawaited(routeServer(serverId));
      }
    });
  }

  void _removeServer(String id) {
    _messageSubs[id]?.cancel();
    _messageSubs.remove(id);
    _statusSubs[id]?.cancel();
    _statusSubs.remove(id);
    _connections[id]?.dispose();
    _connections.remove(id);
    _configs.remove(id);
    _cryptoServices.remove(id);
    _lastRouted.remove(id);
    _relayRefused.remove(id);
  }

  /// Get the WebSocketService for a specific server.
  WebSocketService? getConnection(String serverId) => _connections[serverId];

  /// Get the CryptoService for a specific server.
  CryptoService? getCrypto(String serverId) => _cryptoServices[serverId];

  void dispose() {
    _networkChanges?.cancel();
    for (final sub in _messageSubs.values) {
      sub.cancel();
    }
    for (final sub in _statusSubs.values) {
      sub.cancel();
    }
    for (final ws in _connections.values) {
      ws.dispose();
    }
    _connections.clear();
    _configs.clear();
    _cryptoServices.clear();
    _messageSubs.clear();
    _statusSubs.clear();
    _messageController.close();
    _statusController.close();
  }
}

enum _NetworkKind { local, mobileOnly, other }
