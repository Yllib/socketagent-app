import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import '../models/server_config.dart';
import 'local_route.dart';
import 'websocket_service.dart';
import 'crypto_service.dart';
import 'device_auth.dart';
import 'transport_v2.dart';

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

/// Per-server device registry handshake update (control lane).
class ServerDeviceAuthUpdate {
  final String serverId;
  final DeviceAuthState state;
  ServerDeviceAuthUpdate(this.serverId, this.state);
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

/// Whether [config] is the server on this machine as an account that cannot
/// read its files sees it: a loopback entry with the key from the machine
/// marker and no token. Such an entry asks the server for its pairing (wire
/// spec 5.3), and stays one after the server hands it over.
bool isOtherAccountsLocalServer(ServerConfig config) =>
    config.isLoopbackOnly &&
    !config.useRelay &&
    config.token.isEmpty &&
    config.serverPubkey.isNotEmpty;

/// A pairing a computer handed over on its own control channel.
class ServerPairingChange {
  final String serverId;
  final PairingChange change;
  ServerPairingChange(this.serverId, this.change);
}

/// The route for an auto-routed computer: the relay when it connected while
/// the LAN search ran, since it answered first, then direct when a LAN
/// address answered, otherwise the relay if this phone may use it. Without
/// relay access the LAN is the only way in, so keep retrying it.
ConnectionMode chooseAutoRoute({
  required String? directHost,
  required bool canRelay,
  bool relayConnectedFirst = false,
}) {
  if (canRelay && relayConnectedFirst) return ConnectionMode.relay;
  if (directHost != null) return ConnectionMode.direct;
  return canRelay ? ConnectionMode.relay : ConnectionMode.direct;
}

/// Manages simultaneous WebSocket connections to multiple SocketAgent servers.
///
/// Each server gets its own [WebSocketService] and (if relay) its own
/// [CryptoService] with that server's public key.
class ConnectionManager {
  /// Whether a local entry may ask the server on this machine for its
  /// pairing. Only the Windows desktop app finds such entries. Tests turn
  /// this on to run that path elsewhere.
  @visibleForTesting
  bool localRequests = Platform.isWindows;

  final Map<String, WebSocketService> _connections = {};
  final Map<String, ServerConfig> _configs = {};
  final Map<String, CryptoService> _cryptoServices = {};
  final Map<String, StreamSubscription> _messageSubs = {};
  final Map<String, StreamSubscription> _statusSubs = {};
  final Map<String, StreamSubscription> _deviceAuthSubs = {};
  final Map<String, StreamSubscription> _subscriptionRequiredSubs = {};
  final Map<String, StreamSubscription> _pairingChangeSubs = {};
  // Computers that sent a LAN route without the token: they approved this
  // device's key, so a direct socket can sign in with it.
  final Set<String> _deviceKeyDirect = {};

  String? activeServerId;
  String _subscriberToken = '';
  DeviceIdentity _identity = (name: '', platform: '', appVersion: '');

  /// Called when auto routing moves a computer to another route or address,
  /// so the owner can save it. The manager has already switched the socket.
  void Function(ServerConfig config)? onRouteChanged;
  LocalRouteFinder routeFinder = const LocalRouteFinder();

  /// The phone's current networks. Replaced in tests.
  Future<List<ConnectivityResult>> Function() checkNetwork = () =>
      Connectivity().checkConnectivity();
  final Map<String, Future<void>> _routing = {};
  final Map<String, DateTime> _lastRouted = {};
  // Computers whose relay turned this phone away, and when. The relay is
  // left out of routing for five minutes, or until a new token arrives.
  final Map<String, DateTime> _relayRefused = {};
  // Auto-routed computers waiting on the relay, with the next direct check.
  final Map<String, Timer> _relayWatch = {};
  // LAN addresses that accepted a connection and then gave no answer as
  // the computer, by computer, with when. Routing leaves each out for
  // [_silentHostSkip] or until the network changes, so the next route gets
  // its turn (wire spec 3.8).
  final Map<String, Map<String, DateTime>> _silentHosts = {};
  static const _silentHostSkip = Duration(minutes: 5);
  // The address a computer's direct socket is set to when it is not the
  // stored one: the search found it, and no handshake there has succeeded
  // yet. It is stored in the entry once one does.
  final Map<String, String> _unprovenHost = {};

  /// How long a relay socket may wait for its computer before the phone
  /// checks direct again. Doubles on each check that finds nothing, up to a
  /// minute. Replaced in tests.
  Duration relayPatience = const Duration(seconds: 5);
  StreamSubscription<List<ConnectivityResult>>? _networkChanges;
  Set<ConnectivityResult>? _lastNetwork;
  // Auto-routed computers whose socket belongs to a network the phone left.
  // Their route search reconnects them even when the route stays the same.
  /// Sockets asked to reconnect, keyed by when the request's reason began.
  /// A socket that connected after that moment already satisfies it.
  final Map<String, DateTime> _staleSince = {};

  /// When the current burst of network-change reports began.
  DateTime? _networkChangedAt;

  final _messageController = StreamController<ServerMessage>.broadcast();
  final _statusController = StreamController<ServerStatusUpdate>.broadcast();
  final _deviceAuthController =
      StreamController<ServerDeviceAuthUpdate>.broadcast();
  final _subscriptionRequiredController = StreamController<String>.broadcast();
  final _pairingChangeController =
      StreamController<ServerPairingChange>.broadcast();

  /// Pairings that computers handed over in sealed records on their own
  /// control channels. The owner stores each one in that computer's config.
  Stream<ServerPairingChange> get pairingChanges =>
      _pairingChangeController.stream;

  /// The ID of each computer whose relay turned this phone away for lack of
  /// a subscription. The relay says so, not the computer, so this never
  /// travels on [messages].
  Stream<String> get subscriptionRequired =>
      _subscriptionRequiredController.stream;

  /// Merged message stream from all connected servers.
  Stream<ServerMessage> get messages => _messageController.stream;

  /// Per-server status updates.
  Stream<ServerStatusUpdate> get statusStream => _statusController.stream;

  /// Per-server device registry handshake updates.
  Stream<ServerDeviceAuthUpdate> get deviceAuthStream =>
      _deviceAuthController.stream;

  /// Where the device registry handshake stands for [serverId].
  DeviceAuthState deviceAuthOf(String serverId) =>
      _connections[serverId]?.deviceAuth ?? DeviceAuthState.idle;

  /// How this device introduces itself in `device_auth` and in v2's
  /// message 1.
  DeviceIdentity get deviceIdentity => _identity;

  Future<void> setDeviceIdentity({
    required String name,
    required String platform,
    String appVersion = '',
  }) async {
    _identity = (name: name, platform: platform, appVersion: appVersion);
    for (final config in _configs.values) {
      _connections[config.id]?.setDeviceIdentity(
        name: name,
        platform: platform,
        token: config.token,
        appVersion: appVersion,
      );
    }
  }

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
      final previous = _configs[config.id];
      if (previous != null &&
          (previous.host != config.host ||
              previous.port != config.port ||
              previous.serverPubkey != config.serverPubkey)) {
        // What was learned about the old address says nothing of this one.
        _unprovenHost.remove(config.id);
        _silentHosts.remove(config.id);
      }
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
    ws.setDeviceIdentity(
      name: _identity.name,
      platform: _identity.platform,
      token: config.token,
      appVersion: _identity.appVersion,
    );
    final selectedMode = connectionModeForServerConfig(config);
    // Transport selection is a security boundary. Apply it before touching
    // credentials so a relay-selected server can never retain or open a
    // direct socket while relay configuration is incomplete.
    ws.setMode(selectedMode);
    // The desktop app's entry for the server on its own Windows machine
    // never asks for a carry-over. The owner's account reads the pairing
    // from the server's files, and any other account makes a local request.
    ws.setPairing(
      config.transportPairing,
      carryOver: !(Platform.isWindows && config.isLoopbackOnly),
    );
    // Such an entry asks for its pairing, and asks again when the server
    // stops answering the one it holds. The name it asked under is the name
    // it keeps on that server's list.
    final otherAccounts = localRequests && isOtherAccountsLocalServer(config);
    ws.setLocalRequest(otherAccounts);
    ws.setAccountInName(otherAccounts);

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
        host: _unprovenHost[config.id] ?? config.host,
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
    if (_networkChanges != null) return;
    unawaited(
      checkNetwork().then(
        (network) => _lastNetwork ??= network.toSet(),
        onError: (Object _) => null,
      ),
    );
    _networkChanges = Connectivity().onConnectivityChanged.listen(
      onNetworkChanged,
      onError: (Object _) {},
    );
  }

  /// A socket opened on the network the phone just left is dead, but it only
  /// finds out when a ping goes unanswered, up to 40 seconds later. Reconnect
  /// every live socket now instead. Repeated reports of the same networks
  /// change nothing.
  void onNetworkChanged(List<ConnectivityResult> network) {
    final current = network.toSet();
    final previous = _lastNetwork;
    _lastNetwork = current;
    if (previous != null &&
        previous.length == current.length &&
        previous.containsAll(current)) {
      return;
    }
    // The platform reports one change as a short burst of events. A socket
    // opened after the first of them is on the new network already; replacing
    // it again would resume the session twice.
    // On another network the same addresses are other machines.
    _silentHosts.clear();
    final now = DateTime.now();
    final burstStart = _networkChangedAt;
    if (burstStart == null ||
        now.difference(burstStart) > const Duration(seconds: 10)) {
      _networkChangedAt = now;
    }
    for (final config in _configs.values) {
      final ws = _connections[config.id];
      if (ws == null) continue;
      final live =
          ws.status != ConnectionStatus.disconnected || ws.reconnecting;
      if (live) reconnectServer(config.id, since: _networkChangedAt);
    }
  }

  /// Replaces [serverId]'s socket with a new one. For a socket that looks
  /// connected but has stopped answering, or one left on an old network.
  /// [since] is when the reason to reconnect began; a socket that connected
  /// after it is kept.
  void reconnectServer(String serverId, {DateTime? since}) {
    final config = _configs[serverId];
    final ws = _connections[serverId];
    if (config == null || ws == null) return;
    final staleSince = since ?? DateTime.now();
    if (config.autoRoute) {
      _staleSince[serverId] = staleSince;
      unawaited(routeServer(serverId, force: true));
    } else if (!ws.connectedAfter(staleSince)) {
      ws.connect(force: true);
    }
  }

  /// Reconnects [serverId] and completes true once the new socket is
  /// connected, or false if that takes longer than [timeout]. Only a
  /// connection made after this call counts, never the stale one.
  Future<bool> reconnectAndWait(String serverId, Duration timeout) async {
    final connected = statusStream
        .firstWhere(
          (u) =>
              u.serverId == serverId && u.status == ConnectionStatus.connected,
        )
        .timeout(timeout);
    reconnectServer(serverId);
    try {
      await connected;
      return true;
    } on TimeoutException {
      return false;
    }
  }

  /// Picks direct or relay for an auto-routed computer and switches its
  /// socket if the route or LAN address changed. A live socket reconnects on
  /// the new route; an idle one stays idle. Runs at most once every 30
  /// seconds unless [force] is set, so a computer that is off doesn't keep
  /// the phone searching. A change of route is saved at once. An address
  /// the search found is saved by [_keepProvenHost], once the computer has
  /// answered there.
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
    final started = DateTime.now();
    final canDirect = _canDirect(config);
    final canRelay = _canRelay(config);
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
          skip: _skippedHosts(config.id),
        );
      }
    }
    // The config may have changed while the search ran.
    final staleSince = _staleSince.remove(config.id);
    final latest = _configs[config.id];
    final ws = _connections[config.id];
    if (latest == null || !latest.autoRoute || ws == null) return;
    // The search races the socket's own attempt.
    final mode = canDirect || canRelay
        ? chooseAutoRoute(
            directHost: directHost,
            canRelay: canRelay,
            relayConnectedFirst:
                ws.mode == ConnectionMode.relay && ws.connectedAfter(started),
          )
        : connectionModeForServerConfig(config);
    final stale = staleSince != null && !ws.connectedAfter(staleSince);
    final next = latest.copyWith(useRelay: mode == ConnectionMode.relay);
    // The address for a direct socket: the one the search found, else the
    // unproven one already in use unless it has gone silent, else the
    // stored one, which is all there is to retry.
    final unproven = _unprovenHost[config.id];
    final dialled = unproven ?? latest.host;
    final host =
        directHost ??
        (unproven != null && !_skippedHosts(config.id).contains(unproven)
            ? unproven
            : latest.host);
    final moved =
        next.useRelay != latest.useRelay || (!next.useRelay && host != dialled);
    if (next.useRelay || host == latest.host) {
      _unprovenHost.remove(config.id);
    } else {
      _unprovenHost[config.id] = host;
    }
    final live = ws.status != ConnectionStatus.disconnected || ws.reconnecting;
    if (!moved) {
      if (stale && live) ws.connect(force: true);
      return;
    }
    _configs[config.id] = next;
    await _configureTransport(next);
    if (live) ws.connect(force: true);
    if (next.useRelay != latest.useRelay) onRouteChanged?.call(next);
  }

  /// The addresses routing leaves out for [serverId] just now.
  Set<String> _skippedHosts(String serverId) {
    final silent = _silentHosts[serverId];
    if (silent == null) return const {};
    final now = DateTime.now();
    silent.removeWhere((_, at) => now.difference(at) >= _silentHostSkip);
    return silent.keys.toSet();
  }

  /// [ws] connected. When that was a direct socket to an address the search
  /// found, the computer has now answered there with its key, and the
  /// address is stored in the entry.
  void _keepProvenHost(String serverId, WebSocketService ws) {
    final host = _unprovenHost[serverId];
    final config = _configs[serverId];
    if (host == null ||
        config == null ||
        ws.status != ConnectionStatus.connected ||
        ws.dialledHost != host ||
        !ws.computerAnswered) {
      return;
    }
    _unprovenHost.remove(serverId);
    final proven = config.copyWith(host: host);
    _configs[serverId] = proven;
    onRouteChanged?.call(proven);
  }

  /// [ws] dropped. When its last dial was to a LAN address that still
  /// accepts a connection and the computer never answered there, that
  /// address is left out and the route is picked again without it. An
  /// address that accepts nothing is not marked: the computer may be
  /// restarting, and is found there again as soon as it is back.
  Future<void> _skipIfSilent(String serverId, WebSocketService ws) async {
    final host = ws.dialledHost;
    final config = _configs[serverId];
    if (host == null || config == null || ws.computerAnswered) return;
    if (!await routeFinder.reachable(host, config.port)) return;
    if (_connections[serverId] != ws || _configs[serverId]?.autoRoute != true) {
      return;
    }
    (_silentHosts[serverId] ??= {})[host] = DateTime.now();
    // A search that began before the mark may still pick this address.
    await _routing[serverId];
    await routeServer(serverId, force: true);
  }

  // An encrypted direct socket signs in with the token or, once the
  // computer has approved it, with this device's key. On v2 the handshake
  // is the sign-in.
  bool _canDirect(ServerConfig config) =>
      config.serverPubkey.isNotEmpty &&
      (config.isV2 ||
          config.token.isNotEmpty ||
          _deviceKeyDirect.contains(config.id));

  bool _canRelay(ServerConfig config) {
    final refused = _relayRefused[config.id];
    return config.isRelayPaired &&
        _subscriberToken.isNotEmpty &&
        (refused == null ||
            DateTime.now().difference(refused) >= const Duration(minutes: 5));
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
      if (!config.autoRoute) {
        ws.connect();
        continue;
      }
      // Connect on the last route at once while the route search runs, and
      // keep whichever answers first. A route this phone can't use waits for
      // the search instead.
      final usable = config.useRelay ? _canRelay(config) : _canDirect(config);
      if (usable) {
        ws.connect();
        unawaited(routeServer(config.id, force: true));
      } else {
        unawaited(
          routeServer(config.id, force: true).then((_) => ws.connect()),
        );
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
      _messageController.add(ServerMessage(serverId, data));
    });

    _subscriptionRequiredSubs[serverId] = ws.subscriptionRequired.listen((_) {
      if (_configs[serverId]?.autoRoute == true) {
        // The relay turned us away. The LAN may still work without it.
        _relayRefused[serverId] = DateTime.now();
        // Retrying the relay now would only be refused again.
        unawaited(
          routeServer(serverId, force: true).then((_) {
            if (ws.mode == ConnectionMode.direct) ws.connect();
          }),
        );
      }
      _subscriptionRequiredController.add(serverId);
    });

    _pairingChangeSubs[serverId] = ws.pairingChanges.listen((change) {
      _pairingChangeController.add(ServerPairingChange(serverId, change));
    });

    _deviceAuthSubs[serverId] = ws.deviceAuthStream.listen((state) {
      _deviceAuthController.add(ServerDeviceAuthUpdate(serverId, state));
    });

    _statusSubs[serverId] = ws.statusStream.listen((status) {
      _statusController.add(ServerStatusUpdate(serverId, status));
      if (status == ConnectionStatus.connected) {
        _relayWatch.remove(serverId)?.cancel();
        _keepProvenHost(serverId, ws);
      } else if (status == ConnectionStatus.connecting &&
          ws.mode == ConnectionMode.relay &&
          _configs[serverId]?.autoRoute == true &&
          !_relayWatch.containsKey(serverId)) {
        _watchRelay(serverId, ws, relayPatience);
      }
      // A dropped connection may mean the phone left or joined the
      // computer's network. Only when the socket plans to retry: an
      // intentional disconnect must stay disconnected.
      if ((status == ConnectionStatus.error ||
              status == ConnectionStatus.disconnected) &&
          ws.reconnecting &&
          _configs[serverId]?.autoRoute == true) {
        unawaited(routeServer(serverId));
        unawaited(_skipIfSilent(serverId, ws));
      }
    });
  }

  /// While [ws] waits on the relay for its computer, checks direct every
  /// [wait], backing off, and switches when the computer answers there. The
  /// relay socket keeps waiting in the room otherwise, so it opens the moment
  /// the computer joins.
  void _watchRelay(String serverId, WebSocketService ws, Duration wait) {
    _relayWatch[serverId] = Timer(wait, () async {
      _relayWatch.remove(serverId);
      bool waiting() =>
          _connections[serverId] == ws &&
          ws.mode == ConnectionMode.relay &&
          ws.status == ConnectionStatus.connecting &&
          _configs[serverId]?.autoRoute == true;
      if (!waiting()) return;
      await routeServer(serverId, force: true);
      if (!waiting() || _relayWatch.containsKey(serverId)) return;
      final next = wait * 2;
      const limit = Duration(minutes: 1);
      _watchRelay(serverId, ws, next > limit ? limit : next);
    });
  }

  void _removeServer(String id) {
    _relayWatch.remove(id)?.cancel();
    _messageSubs[id]?.cancel();
    _messageSubs.remove(id);
    _statusSubs[id]?.cancel();
    _statusSubs.remove(id);
    _deviceAuthSubs[id]?.cancel();
    _deviceAuthSubs.remove(id);
    _subscriptionRequiredSubs[id]?.cancel();
    _subscriptionRequiredSubs.remove(id);
    _pairingChangeSubs[id]?.cancel();
    _pairingChangeSubs.remove(id);
    _connections[id]?.dispose();
    _connections.remove(id);
    _configs.remove(id);
    _cryptoServices.remove(id);
    _lastRouted.remove(id);
    _relayRefused.remove(id);
    _deviceKeyDirect.remove(id);
    _silentHosts.remove(id);
    _unprovenHost.remove(id);
  }

  /// [serverId] sent a LAN route without the token, so its direct socket
  /// accepts this device's key. Returns true the first time.
  bool allowDeviceKeyDirect(String serverId) => _deviceKeyDirect.add(serverId);

  /// Get the WebSocketService for a specific server.
  WebSocketService? getConnection(String serverId) => _connections[serverId];

  /// Get the CryptoService for a specific server.
  CryptoService? getCrypto(String serverId) => _cryptoServices[serverId];

  void dispose() {
    _networkChanges?.cancel();
    for (final timer in _relayWatch.values) {
      timer.cancel();
    }
    _relayWatch.clear();
    for (final sub in _messageSubs.values) {
      sub.cancel();
    }
    for (final sub in _statusSubs.values) {
      sub.cancel();
    }
    for (final sub in _deviceAuthSubs.values) {
      sub.cancel();
    }
    for (final sub in _subscriptionRequiredSubs.values) {
      sub.cancel();
    }
    for (final sub in _pairingChangeSubs.values) {
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
    _deviceAuthSubs.clear();
    _subscriptionRequiredSubs.clear();
    _pairingChangeSubs.clear();
    _pairingChangeController.close();
    _messageController.close();
    _statusController.close();
    _deviceAuthController.close();
    _subscriptionRequiredController.close();
  }
}

enum _NetworkKind { local, mobileOnly, other }
