import 'dart:async';
import '../models/server_config.dart';
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

  String? _activeServerId;
  String _subscriberToken = '';

  final _messageController = StreamController<ServerMessage>.broadcast();
  final _statusController = StreamController<ServerStatusUpdate>.broadcast();

  /// Merged message stream from all connected servers.
  Stream<ServerMessage> get messages => _messageController.stream;

  /// Per-server status updates.
  Stream<ServerStatusUpdate> get statusStream => _statusController.stream;

  /// The currently active server ID (the one the active session is on).
  String? get activeServerId => _activeServerId;
  set activeServerId(String? id) => _activeServerId = id;

  /// The active server's WebSocketService, or null if none.
  WebSocketService? get active =>
      _activeServerId != null ? _connections[_activeServerId] : null;

  /// The active server's config, or null.
  ServerConfig? get activeConfig =>
      _activeServerId != null ? _configs[_activeServerId] : null;

  /// All configured server configs.
  List<ServerConfig> get configs => _configs.values.toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  /// Connection status for a specific server.
  ConnectionStatus statusOf(String serverId) =>
      _connections[serverId]?.status ?? ConnectionStatus.disconnected;

  /// Whether any server is connected.
  bool get anyConnected =>
      _connections.values.any((ws) => ws.status == ConnectionStatus.connected);

  /// Set the subscriber token (used for relay connections).
  void setSubscriberToken(String token) {
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

      final ws = _connections[config.id]!;

      if (config.useRelay && config.isRelayPaired) {
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
        ws.setMode(ConnectionMode.relay);
      } else {
        ws.configure(host: config.host, port: config.port, token: config.token);
      }
    }

    // Auto-select active server if none set or current was removed
    if (_activeServerId == null || !newIds.contains(_activeServerId)) {
      _activeServerId = serverConfigs.isNotEmpty ? serverConfigs.first.id : null;
    }
  }

  /// Update relay config for a specific server (e.g. after pairing).
  Future<void> configureServerRelay(String serverId, {
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
    for (final entry in _connections.entries) {
      final config = _configs[entry.key];
      if (config == null) continue;
      entry.value.connect();
    }
  }

  /// Disconnect all servers.
  void disconnectAll() {
    for (final ws in _connections.values) {
      ws.disconnect();
    }
  }

  /// Send a message to the active server.
  void send(Map<String, dynamic> message) {
    active?.send(message);
  }

  /// Send a message to a specific server.
  void sendToServer(String serverId, Map<String, dynamic> message) {
    _connections[serverId]?.send(message);
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
      _messageController.add(ServerMessage(serverId, data));
    });

    _statusSubs[serverId] = ws.statusStream.listen((status) {
      _statusController.add(ServerStatusUpdate(serverId, status));
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
  }

  /// Get the WebSocketService for a specific server.
  WebSocketService? getConnection(String serverId) => _connections[serverId];

  /// Get the CryptoService for a specific server.
  CryptoService? getCrypto(String serverId) => _cryptoServices[serverId];

  void dispose() {
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
