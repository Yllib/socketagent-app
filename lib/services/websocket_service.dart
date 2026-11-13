import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/file_download_frame.dart';
import '../models/server_config.dart' show isLoopbackHost;
import 'crypto_service.dart';
import 'device_auth.dart';
import 'socket_frame_decoder.dart';
import 'transport_v2.dart';
import '../models/browser_frame_wire.dart';

enum ConnectionStatus { disconnected, connecting, connected, error }

enum ConnectionMode { direct, relay }

enum TransportLane { control, bulk }

const int transportLaneVersion = 1;
const int uploadAckVersion = 1;
const String bulkRelayPairingSuffix = ':bulk:v1';

String pairingTokenForLane(String pairingToken, TransportLane lane) =>
    lane == TransportLane.bulk
    ? '$pairingToken$bulkRelayPairingSuffix'
    : pairingToken;

bool shouldStartWebSocketConnection(
  ConnectionStatus status, {
  bool force = false,
}) {
  return force ||
      (status != ConnectionStatus.connecting &&
          status != ConnectionStatus.connected);
}

bool relayTransportIsConfigured({
  required String relayUrl,
  required String pairingToken,
  required bool cryptoReady,
}) {
  final uri = Uri.tryParse(relayUrl.trim());
  if (uri == null || uri.host.isEmpty) return false;
  // TLS always. Plain `ws` is for a relay on this machine, which tests use.
  final secure =
      uri.scheme == 'wss' || (uri.scheme == 'ws' && isLoopbackHost(uri.host));
  return secure && pairingToken.trim().isNotEmpty && cryptoReady;
}

bool relayConfigurationChanged({
  required String currentRelayUrl,
  required String nextRelayUrl,
  required String currentPairingToken,
  required String nextPairingToken,
  required String currentSubscriberToken,
  required String nextSubscriberToken,
  required bool sameCryptoService,
}) {
  return currentRelayUrl != nextRelayUrl ||
      currentPairingToken != nextPairingToken ||
      currentSubscriberToken != nextSubscriberToken ||
      !sameCryptoService;
}

/// One computer's socket on one lane. It speaks transport v2 when the
/// computer's config carries a pairing ([setPairing]) and the old transport
/// otherwise. The choice is made per connection from stored config and
/// nothing a computer or relay sends changes it: a v2 socket never sends
/// `key_exchange`, and a computer this device has dialled over v2 is never
/// dialled the old way again.
class WebSocketService {
  static const int _sessionEventAckVersion = 2;

  /// The old transport's handshake and sign-in messages, which a v2 socket
  /// never sends.
  static const _oldTransportOnly = {
    'key_exchange',
    'device_auth',
    'direct_auth',
    'client_capabilities',
  };

  /// A computer that refused this device, or stayed silent twice, is asked
  /// again no sooner than this.
  static const _refusedRetry = Duration(minutes: 1);

  /// A relay that wants a subscription is asked again no sooner than this.
  static const _subscriptionRetry = Duration(minutes: 5);

  /// [v2Available] says whether this device can run the v2 handshake. Tests
  /// replace it to stand in for a device where libsodium does not load, and
  /// shorten [hs2Wait], how long a handshake waits for its answer.
  ///
  /// [pinsV2] is false for a probe of a computer the user has not saved. A
  /// v2 dial then leaves no mark on the computer's key, so a code that fails
  /// its probe cannot hold a saved entry for that key to v2.
  WebSocketService({
    TransportLane lane = TransportLane.control,
    bool manageBulkLane = true,
    bool Function() v2Available = transportV2Available,
    Duration hs2Wait = hs2Timeout,
    bool pinsV2 = true,
  }) : _lane = lane,
       _manageBulkLane = manageBulkLane,
       _v2Available = v2Available,
       _hs2Wait = hs2Wait,
       _pinsV2 = pinsV2 {
    if (_manageBulkLane) {
      final bulk = WebSocketService(
        lane: TransportLane.bulk,
        manageBulkLane: false,
        v2Available: v2Available,
        hs2Wait: hs2Wait,
      );
      _bulkLane = bulk;
      _bulkMessageSubscription = bulk.messages.listen((message) {
        if (message['type'] == 'server_capabilities') return;
        final routed = Map<String, dynamic>.from(message);
        routed['__transportLane'] = 'bulk';
        _handleBulkLifecycleMessage(routed);
        _messageController.add(routed);
      });
    }
  }

  final TransportLane _lane;
  final bool _manageBulkLane;
  final bool Function() _v2Available;
  final Duration _hs2Wait;
  final bool _pinsV2;
  WebSocketService? _bulkLane;
  StreamSubscription<Map<String, dynamic>>? _bulkMessageSubscription;
  WebSocketChannel? _channel;
  // The dart:io socket under [_channel], once it has connected. The
  // channel's own close takes only 1000 or 3000 to 4999, and a rejected v2
  // record closes a direct socket with 1008.
  WebSocket? _rawSocket;
  StreamSubscription? _channelSubscription;
  int _connectionGeneration =
      0; // prevents stale callbacks from affecting state
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  final _statusController = StreamController<ConnectionStatus>.broadcast();
  final _subscriptionRequiredController = StreamController<void>.broadcast();
  final _pairingChangeController = StreamController<PairingChange>.broadcast();
  ConnectionStatus _status = ConnectionStatus.disconnected;
  String _host = '192.168.1.100';
  int _port = 8085;
  String _token = '';
  Timer? _reconnectTimer;

  // Relay mode fields
  ConnectionMode _mode = ConnectionMode.direct;
  String _relayUrl = '';
  String _pairingToken = '';
  String _subscriberToken = '';
  CryptoService? _cryptoService;
  bool _encryptionReady = false;
  // Set by this lane's server_capabilities. A bulk lane counts as ready only
  // after it, or the first upload would go out before the lane knows whether
  // the server takes binary chunks and acks them.
  bool _serverCapabilitiesReceived = false;
  // This connection's key exchange and cipher. Both reset on every connect,
  // so nothing sealed for an earlier socket opens on this one.
  SessionOffer? _sessionOffer;
  PeerChannel? _peerChannel;
  bool _requireTrustedDirectKey = true;
  // Whether this socket has a pinned computer key: every relay socket, and a
  // direct one opened with `e2e`. Fixed per connection. On a keyed socket a
  // frame is a sealed message or a transport signal, and nothing else gets
  // past [_onFrame].
  bool _socketKeyed = false;

  // Transport v2. The pairing comes from the computer's stored config, and
  // null leaves this socket on the old transport.
  TransportPairing? _pairing;
  // Whether this connection is a v2 one. Fixed per connection.
  bool _socketV2 = false;
  // This socket's handshake, from `hs1` going out to the first `hs2`.
  TransportHandshake? _handshake;
  // A socket runs one handshake. To run another the app dials again.
  bool _handshakeSent = false;
  Timer? _hs2Timer;
  // Handshakes in a row that got no `hs2`, since the last one that
  // verified. The two routes are counted apart: a silent address on the
  // LAN says nothing about the computer in the relay room.
  int _silentRelayHandshakes = 0;
  int _silentDirectHandshakes = 0;
  // Whether the computer has answered on the current connection, and the
  // address a direct one was opened to. See the getters.
  bool _computerAnswered = false;
  String? _dialledHost;
  // A v2 channel the computer holds until a paired device answers. Only the
  // verdict is read from it.
  bool _held = false;
  // Carry-over on the old transport: whether this socket may ask the
  // computer for a pairing, whether this connection has, and the request it
  // is waiting on.
  bool _carryOver = true;
  bool _upgradeAsked = false;
  String? _upgradeRequestId;
  // The request a desktop app makes of the server on its own machine when
  // it holds no token for it and no secret that server answers (wire spec
  // 5.3). The owner turns it on for such a computer. The socket uses it
  // only in direct mode, to a loopback address, on the control lane.
  bool _localRequest = false;
  // Set once that server has left two handshakes in a row unanswered under
  // the stored pairing, which is what `socketagent pair --reset` on the
  // computer leaves behind. The next dial asks again instead.
  bool _askLocalServerAgain = false;
  // Set when that second request was held for approval, so the server has
  // this key on record no longer and a person has to allow it. An account
  // the owner removed asks once per run, not once a minute. A request the
  // server refused outright showed nobody a prompt and does not set this.
  bool _askedAgainUnrecorded = false;
  // Whether this connection is that request. Fixed per connection. Such a
  // channel is never an application channel: it sends `transport_ready` and
  // reads the grant or the refusal.
  bool _socketLocalRequest = false;
  // Whether the device name carries the Windows account, see
  // [setAccountInName].
  bool _accountInName = false;

  /// The signed-in Windows account. Tests replace it.
  @visibleForTesting
  String Function() windowsAccount = () =>
      Platform.environment['USERNAME']?.trim() ?? '';
  // A server from before transport v2 answers the request's upgrade with an
  // HTTP error. The next dial then goes the old way, as the released app
  // does, and the one after asks again.
  bool _upgradeRefused = false;
  bool _skipLocalRequest = false;
  // The computer key this socket's handshake or key exchange was made with.
  // The owner may set another key on the crypto service while the socket is
  // still open, and a pairing read here belongs to this one.
  String? _channelKey;
  // This socket's own retries wait for these moments. The first is about
  // the computer, the second about the relay. A dial the owner asks for,
  // such as the one after the user subscribes, goes out at once as before.
  DateTime? _retryNotBefore;
  DateTime? _relayJoinNotBefore;

  // Device registry handshake (relay only). The computer may hold the peer
  // after key exchange until this device proves it knows AUTH_TOKEN or
  // another device approves it.
  final DeviceAuthHandshake _deviceAuth = DeviceAuthHandshake();
  final _deviceAuthController = StreamController<DeviceAuthState>.broadcast();
  String _deviceName = '';
  String _devicePlatform = '';
  String _appVersion = '';
  // Set once a handshake ended waiting for approval, so the next retry after
  // the computer drops the held peer waits instead of knocking every 3 s.
  bool _lastHandshakeAwaited = false;

  // Wire-format flag — flips to true once the server replies to our
  // client_capabilities announcement. Until then we keep the legacy
  // text-JSON envelope so older servers don't choke.
  bool _serverSupportsBinary = false;
  bool _serverSupportsTransportLanes = false;
  bool _serverSupportsUploadAcks = false;
  final Map<String, bool> _uploadUsesBulkLane = {};
  final Map<String, bool> _downloadUsesBulkLane = {};

  // Binary plaintext markers (also defined server-side).
  static const int _binMarkerJson = 0x4A; // 'J'
  static const int _binMarkerUploadChunk = 0x42; // 'B'

  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  Stream<ConnectionStatus> get statusStream => _statusController.stream;
  ConnectionStatus get status => _status;
  ConnectionMode get mode => _mode;

  /// Whether the computer has answered on this connection, or on the last
  /// one once the socket has closed: with an `hs2` that verified, or on the
  /// old transport with a key exchange answer the app accepted. False for a
  /// dial that reached nothing, and for one that reached something which
  /// never showed it was the computer.
  bool get computerAnswered => _computerAnswered;

  /// The LAN address this connection, or the last one, was opened to. Null
  /// on the relay and before the first dial.
  String? get dialledHost => _dialledHost;

  /// Fires when the relay turns this phone away for lack of a subscription.
  /// A relay signal, so it stays off [messages], which carries only what the
  /// computer sealed.
  Stream<void> get subscriptionRequired =>
      _subscriptionRequiredController.stream;

  /// A pairing the computer handed over in a sealed record on this control
  /// channel: the carry-over answer on the old transport, or a new secret on
  /// v2. The owner stores it and calls [setPairing]. These messages never
  /// appear on [messages].
  Stream<PairingChange> get pairingChanges => _pairingChangeController.stream;

  /// Where the device registry handshake stands on this lane.
  Stream<DeviceAuthState> get deviceAuthStream => _deviceAuthController.stream;
  DeviceAuthState get deviceAuth => _deviceAuth.state;

  /// What `device_auth` and v2's message 1 say about this device. [token] is
  /// the computer's AUTH_TOKEN when the app has it; it only ever leaves
  /// inside the box, and never on v2.
  void setDeviceIdentity({
    required String name,
    required String platform,
    required String token,
    String appVersion = '',
  }) {
    _deviceName = name;
    _devicePlatform = platform;
    _token = token;
    _appVersion = appVersion;
    _bulkLane?.setDeviceIdentity(
      name: name,
      platform: platform,
      token: token,
      appVersion: appVersion,
    );
  }

  /// Puts this socket on transport v2 with [pairing], or on the old
  /// transport with null. Both come from the computer's stored config. A new
  /// secret alone leaves an open channel as it is, because the next
  /// handshake proves it. Moving between transports or rooms closes the
  /// socket, and the caller connects again.
  ///
  /// [carryOver] lets a control connection on the old transport ask a
  /// computer that speaks v2 for its pairing.
  void setPairing(TransportPairing? pairing, {bool carryOver = true}) {
    final previous = _pairing;
    _carryOver = carryOver;
    _bulkLane?.setPairing(pairing, carryOver: false);
    if (previous == pairing) return;
    _pairing = pairing;
    // What the computer refused was the old pairing.
    _retryNotBefore = null;
    _silentRelayHandshakes = 0;
    _silentDirectHandshakes = 0;
    _askLocalServerAgain = false;
    _askedAgainUnrecorded = false;
    if (_channel != null &&
        (previous == null ||
            pairing == null ||
            previous.roomId != pairing.roomId)) {
      disconnect();
    }
  }

  /// Lets this socket ask the server on its own machine for a pairing. It
  /// asks while [setPairing] holds none, and again once the server has left
  /// two handshakes in a row unanswered under the one it holds. Has no
  /// effect off loopback.
  void setLocalRequest(bool localRequest) => _localRequest = localRequest;

  /// Puts the Windows account in front of the device name this socket
  /// sends, as "kayla on DESKTOP". The owner turns it on for the server on
  /// the app's own machine when another account runs that server, so the
  /// computer's device list tells the accounts on one PC apart.
  void setAccountInName(bool accountInName) {
    _accountInName = accountInName;
    _bulkLane?.setAccountInName(accountInName);
  }

  /// Whether a retry is scheduled. False after an intentional [disconnect].
  bool get reconnecting => _reconnectTimer?.isActive ?? false;

  void configure({
    required String host,
    required int port,
    required String token,
    CryptoService? cryptoService,
    bool requireTrustedDirectKey = true,
  }) {
    _host = host;
    _port = port;
    _token = token;
    _cryptoService = cryptoService;
    _requireTrustedDirectKey = requireTrustedDirectKey;
    _bulkLane?.configure(
      host: host,
      port: port,
      token: token,
      cryptoService: cryptoService,
      requireTrustedDirectKey: requireTrustedDirectKey,
    );
  }

  void configureRelay({
    required String relayUrl,
    required String pairingToken,
    required CryptoService cryptoService,
    String subscriberToken = '',
  }) {
    final changed = relayConfigurationChanged(
      currentRelayUrl: _relayUrl,
      nextRelayUrl: relayUrl,
      currentPairingToken: _pairingToken,
      nextPairingToken: pairingToken,
      currentSubscriberToken: _subscriberToken,
      nextSubscriberToken: subscriberToken,
      sameCryptoService: identical(_cryptoService, cryptoService),
    );
    if (changed && _channel != null) disconnect();
    if (changed) _relayJoinNotBefore = null;
    _relayUrl = relayUrl;
    _pairingToken = pairingToken;
    _cryptoService = cryptoService;
    _subscriberToken = subscriberToken;
    _bulkLane?.configureRelay(
      relayUrl: relayUrl,
      pairingToken: pairingTokenForLane(pairingToken, TransportLane.bulk),
      cryptoService: cryptoService,
      subscriberToken: subscriberToken,
    );
  }

  void clearRelayConfiguration() {
    disconnect();
    _relayUrl = '';
    _pairingToken = '';
    _subscriberToken = '';
    _cryptoService = null;
    _encryptionReady = false;
    _bulkLane?.clearRelayConfiguration();
  }

  void setMode(ConnectionMode mode) {
    if (_mode == mode) return;
    disconnect();
    _mode = mode;
    _bulkLane?.setMode(mode);
  }

  void connect({bool force = false}) {
    // App startup and shell initialization can both request a connection.
    // Replacing a healthy channel here creates a late resume/history snapshot
    // and races it against live turn completion.
    if (!shouldStartWebSocketConnection(_status, force: force)) {
      return;
    }
    if (_mode == ConnectionMode.relay &&
        !relayTransportIsConfigured(
          relayUrl: _relayUrl,
          pairingToken: _pairingToken,
          cryptoReady: _cryptoService?.isReady == true,
        )) {
      debugPrint(
        '[Relay] Connection blocked: relay transport is selected but its trusted pairing is incomplete',
      );
      _reconnectTimer?.cancel();
      _setStatus(ConnectionStatus.error);
      return;
    }
    _setStatus(ConnectionStatus.connecting);
    _reconnectTimer?.cancel();
    // A forced reconnect must finish closing the previous socket before the
    // replacement is opened. Cancelling/closing without awaiting leaves two
    // relay peers alive for the same phone; each peer can independently resume
    // the session and race a history snapshot against the live final message.
    final previousSubscription = _channelSubscription;
    final previousChannel = _channel;
    _channelSubscription = null;
    _channel = null;
    // Increment generation so any lingering async callbacks from old connections are ignored
    final gen = ++_connectionGeneration;
    _computerAnswered = false;
    _dialledHost = null;
    unawaited(
      _connectAfterClosingPrevious(gen, previousSubscription, previousChannel),
    );
  }

  Future<void> _connectAfterClosingPrevious(
    int gen,
    StreamSubscription? previousSubscription,
    WebSocketChannel? previousChannel,
  ) async {
    try {
      await previousSubscription?.cancel();
    } catch (_) {}
    try {
      await previousChannel?.sink.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    if (gen != _connectionGeneration) return;
    _resetPeerChannel();
    _serverCapabilitiesReceived = false;
    final crypto = _cryptoService;
    try {
      await crypto?.loadServerPins();
    } catch (error) {
      debugPrint('[E2E] Could not read stored key state: $error');
    }
    if (gen != _connectionGeneration) return;
    final pairing = _pairing;
    final skipLocalRequest = _skipLocalRequest;
    _skipLocalRequest = false;
    _upgradeRefused = false;
    final askAgain = _askLocalServerAgain;
    _askLocalServerAgain = false;
    _socketLocalRequest =
        (pairing == null || askAgain) &&
        _localRequest &&
        !skipLocalRequest &&
        _mode == ConnectionMode.direct &&
        _lane == TransportLane.control &&
        isLoopbackHost(_host) &&
        crypto != null &&
        crypto.hasKeyPair &&
        crypto.isReady &&
        _v2Available();
    _socketV2 = pairing != null || _socketLocalRequest;
    final blocked = _transportBlocked(pairing, crypto);
    if (blocked != null) {
      debugPrint('[Transport] Connection blocked: $blocked');
      _setStatus(ConnectionStatus.error);
      return;
    }
    if (pairing != null && _pinsV2) {
      // Saved before the first frame goes out, so this computer never gets
      // the old transport from this device again.
      try {
        await crypto?.markServerV2();
      } catch (error) {
        debugPrint('[Transport] Could not save the v2 pin: $error');
      }
      if (gen != _connectionGeneration) return;
    }

    try {
      final Uri uri;
      Map<String, dynamic>? headers;
      _dialledHost = _mode == ConnectionMode.direct ? _host : null;
      if (_mode == ConnectionMode.relay) {
        // A new-style join, for v2 and the old transport alike: the room and
        // the subscriber token ride in headers, never in the URL.
        final relay = Uri.parse(_relayUrl);
        uri = Uri(
          scheme: relay.scheme,
          host: relay.host,
          port: relay.hasPort ? relay.port : null,
          path: '/',
        );
        headers = {
          'X-SocketAgent-Protocol': '2',
          'X-SocketAgent-Role': 'phone',
          'X-SocketAgent-Room': Uri.encodeComponent(_pairingToken),
          if (_subscriberToken.isNotEmpty)
            'X-SocketAgent-Subscriber': _subscriberToken,
        };
        _encryptionReady = false;
        _socketKeyed = true;
      } else if (_socketV2) {
        // No token, no lane, nothing else in the URL or the headers.
        uri = Uri(
          scheme: 'ws',
          host: _host,
          port: _port,
          path: '/',
          queryParameters: {'e2e': '2'},
        );
        _encryptionReady = false;
        _socketKeyed = true;
      } else {
        final encryptedDirect =
            _cryptoService != null && _cryptoService!.isReady;
        if (_requireTrustedDirectKey && !encryptedDirect) {
          debugPrint(
            '[Direct E2E] Direct connection blocked: missing trusted server public key',
          );
          _setStatus(ConnectionStatus.error);
          return;
        }
        uri = Uri(
          scheme: 'ws',
          host: _host,
          port: _port,
          queryParameters: {
            if (encryptedDirect) 'e2e': '1',
            if (_lane == TransportLane.bulk) 'lane': 'bulk',
          },
        );
        _encryptionReady = false;
        _socketKeyed = encryptedDirect;
        if (!encryptedDirect) headers = {'Authorization': 'Bearer $_token'};
      }

      // Opened exactly as IOWebSocketChannel.connect opens it, so binary
      // frames work and pingInterval turns a silently broken socket into
      // onDone. The one difference is that this keeps the dart:io socket.
      _rawSocket = null;
      _channel = IOWebSocketChannel(
        WebSocket.connect(uri.toString(), headers: headers).then(
          (socket) {
            socket.pingInterval = const Duration(seconds: 20);
            if (gen == _connectionGeneration) _rawSocket = socket;
            return socket;
          },
          onError: (Object error, StackTrace stack) {
            // The server answered over HTTP and would not upgrade.
            if (gen == _connectionGeneration && error is WebSocketException) {
              _upgradeRefused = true;
            }
            Error.throwWithStackTrace(error, stack);
          },
        ),
      );

      // A dial that fails is reported once, on the stream below.
      _channel!.ready.ignore();

      _channelSubscription = _channel!.stream
          .asyncMap((data) => _onFrame(data, gen))
          .listen(
            (_) {},
            onError: (error) {
              if (gen != _connectionGeneration) return;
              _abandonHandshake();
              if (_socketLocalRequest && _upgradeRefused) {
                // This machine's server is from before transport v2.
                _skipLocalRequest = true;
                connect(force: true);
                return;
              }
              _setStatus(ConnectionStatus.error);
              _scheduleReconnect();
            },
            onDone: () {
              if (gen != _connectionGeneration) return;
              _abandonHandshake();
              _encryptionReady = false;
              _serverCapabilitiesReceived = false;
              _serverSupportsBinary = false;
              _serverSupportsUploadAcks = false;
              _deviceAuth.reset();
              _emitDeviceAuth();
              _setStatus(ConnectionStatus.disconnected);
              _scheduleReconnect();
            },
          );

      if (_socketV2) {
        // On the relay the handshake waits for `peer_connected`.
        if (_mode == ConnectionMode.direct) _sendHs1();
      } else if (_mode == ConnectionMode.direct &&
          _cryptoService != null &&
          _cryptoService!.isReady) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (gen != _connectionGeneration) return;
          _sendKeyExchange();
        });
        Future.delayed(const Duration(seconds: 5), () {
          if (gen != _connectionGeneration) return;
          if (_mode == ConnectionMode.direct &&
              !_encryptionReady &&
              _status == ConnectionStatus.connecting) {
            debugPrint('[Direct E2E] Key exchange timed out');
            _setStatus(ConnectionStatus.error);
            _scheduleReconnect();
          }
        });
      }

      // For direct mode without crypto, assume connected after a short delay.
      if (_mode == ConnectionMode.direct) {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (gen != _connectionGeneration) return;
          if (_cryptoService != null && _cryptoService!.isReady) return;
          if (_status == ConnectionStatus.connecting) {
            _setStatus(ConnectionStatus.connected);
          }
          // Probe for binary support. New server replies with server_capabilities;
          // old server ignores the unknown type and we stay on legacy.
          send({
            'type': 'client_capabilities',
            'lane': _lane.name,
            ..._clientCapabilities,
            'sessionKeyVersion': sessionKeyVersion,
          });
        });
      }
    } catch (e) {
      _setStatus(ConnectionStatus.error);
      _scheduleReconnect();
    }
  }

  /// What this build can do, as `client_capabilities` announces it on the
  /// old transport and message 1 carries it on v2.
  static const Map<String, Object> _clientCapabilities = {
    'binaryEnvelope': true,
    'binaryFileDownloadVersion': binaryFileDownloadVersion,
    'binaryBrowserFrameVersion': binaryBrowserFrameVersion,
    'transportLaneVersion': transportLaneVersion,
    'uploadAckVersion': uploadAckVersion,
    'sessionEventAckVersion': _sessionEventAckVersion,
  };

  /// How long this socket's next retry has to wait for a computer or relay
  /// that turned it away.
  Duration _retryWait() {
    final now = DateTime.now();
    var wait = Duration.zero;
    for (final until in [
      _retryNotBefore,
      if (_mode == ConnectionMode.relay) _relayJoinNotBefore,
    ]) {
      if (until != null && until.difference(now) > wait) {
        wait = until.difference(now);
      }
    }
    return wait;
  }

  /// Why this connection may not be dialled at all, or null when it may.
  /// Nothing here falls back to the other transport: the socket shows its
  /// connection error and stays closed until its config changes.
  String? _transportBlocked(TransportPairing? pairing, CryptoService? crypto) {
    if (pairing == null) {
      return crypto != null && crypto.serverIsV2
          ? 'this computer is on transport v2 and has no stored pairing'
          : null;
    }
    if (crypto == null || !crypto.hasKeyPair || !crypto.isReady) {
      return 'transport v2 needs the pinned computer key';
    }
    if (decodeKey32(pairing.secret) == null || !isValidRoomId(pairing.roomId)) {
      return 'the stored v2 pairing is incomplete';
    }
    if (!_v2Available()) return 'this device cannot run the v2 handshake';
    return null;
  }

  /// Sends this socket's one `hs1` and starts the wait for `hs2`.
  void _sendHs1() {
    final pairing = _pairing;
    final crypto = _cryptoService;
    final secret = decodeKey32(pairing?.secret);
    if (crypto == null) return;
    if (!_socketLocalRequest && (pairing == null || secret == null)) return;
    final TransportHandshake handshake;
    final String frame;
    try {
      handshake = _socketLocalRequest || pairing == null || secret == null
          ? crypto.startLocalRequest()
          : crypto.startHandshake(
              path: _mode == ConnectionMode.relay ? 'relay' : 'direct',
              lane: _lane.name,
              roomId: pairing.roomId,
              secret: secret,
            );
      frame = handshake.hs1(
        deviceHandshakePayload(
          appVersion: _appVersion,
          name: _socketLocalRequest || _accountInName
              ? _nameWithAccount()
              : _deviceName,
          platform: _devicePlatform,
          capabilities: _clientCapabilities,
        ),
      );
    } catch (error) {
      // A pinned key the handshake cannot use. Dialling again changes
      // nothing, so the socket stays closed.
      debugPrint('[Transport] Handshake could not start: ${error.runtimeType}');
      _closeSocket();
      _setStatus(ConnectionStatus.error);
      return;
    }
    _handshake = handshake;
    _handshakeSent = true;
    _channelKey = crypto.serverKeyBase64;
    _channel?.sink.add(frame);
    final gen = _connectionGeneration;
    _hs2Timer?.cancel();
    _hs2Timer = Timer(_hs2Wait, () {
      if (gen == _connectionGeneration) _onHs2Timeout();
    });
  }

  /// No `hs2` came. On the relay the computer is in the room, so two silent
  /// handshakes in a row mean what `not_approved` means. On a direct socket
  /// the address may simply be wrong, and the next route gets its turn. The
  /// server on this machine is the exception: it is there, so two silent
  /// handshakes mean it no longer knows the stored secret, and an app that
  /// may ask it for a pairing asks on the next dial.
  void _onHs2Timeout() {
    _handshake = null;
    if (_mode == ConnectionMode.relay) {
      if (++_silentRelayHandshakes >= 2) {
        _retryNotBefore = DateTime.now().add(_refusedRetry);
      }
    } else if (++_silentDirectHandshakes >= 2 &&
        _localRequest &&
        !_socketLocalRequest &&
        !_askedAgainUnrecorded) {
      _askLocalServerAgain = true;
      _silentDirectHandshakes = 0;
    }
    _refuseConnection('no hs2 in time');
  }

  /// The first `hs2` decides the handshake. One that does not verify closes
  /// the socket, and the next dial starts a new handshake.
  void _onHs2(String frame) {
    final handshake = _handshake;
    final socket = _channel;
    if (handshake == null || socket == null) return;
    _abandonHandshake();
    final HandshakeResult result;
    try {
      result = handshake.readHs2(frame);
    } on HandshakeRefused catch (error) {
      _refuseConnection('hs2 refused: ${error.reason}');
      return;
    }
    _silentRelayHandshakes = 0;
    _silentDirectHandshakes = 0;
    _computerAnswered = true;
    final channel = PeerChannel.transport(
      sendKey: result.keys.sendKey,
      receiveKey: result.keys.receiveKey,
    );
    _peerChannel = channel;
    // The first record of every v2 channel, whatever the answer was.
    socket.sink.add(jsonEncode(channel.sealText(transportReadyMessage)));
    switch (result.answer.status) {
      case HandshakeStatus.open:
        // A local request that is let in has the grant coming and nothing
        // else. It never becomes a channel the app talks on.
        if (!_socketLocalRequest) _onTransportOpen();
      case HandshakeStatus.pending:
        // The channel exists but carries nothing until a paired device
        // allows this one. Both sides show the same code. A second local
        // request that comes to this has now put its prompt before the
        // paired devices, and is not made again this run.
        if (_socketLocalRequest && _pairing != null) {
          _askedAgainUnrecorded = true;
        }
        _held = true;
        _lastHandshakeAwaited = true;
        _deviceAuth.held(approvalCode(result.keys.handshakeHash));
        _emitDeviceAuth();
      case HandshakeStatus.refused:
        _onNotApproved('refused: ${result.answer.reason}');
    }
  }

  void _onTransportOpen() {
    _held = false;
    _encryptionReady = true;
    _lastHandshakeAwaited = false;
    _retryNotBefore = null;
    _deviceAuth.opened();
    _emitDeviceAuth();
    _setStatus(ConnectionStatus.connected);
    debugPrint('[Transport] v2 ${_lane.name} channel open');
  }

  /// The computer will not admit this device now. The socket closes and its
  /// next retry waits a minute.
  void _onNotApproved(String reason) {
    _retryNotBefore = DateTime.now().add(_refusedRetry);
    _refuseConnection(reason);
  }

  void _abandonHandshake() {
    _hs2Timer?.cancel();
    _hs2Timer = null;
    _handshake = null;
  }

  /// Sorts one incoming frame. On a keyed socket it is either a sealed
  /// message, which goes to [_routeDecryptedMessage], or a transport signal,
  /// which goes to [_handleSignal]. Anything else is dropped on the relay.
  /// On a direct socket it is dropped until the key exchange is done and
  /// closes the socket after. Frames must be awaited in order.
  Future<void> _onFrame(Object? data, int gen) async {
    if (gen != _connectionGeneration) return;
    if (!_socketKeyed) return _onUnkeyedFrame(data, gen);
    final channel = _peerChannel;
    if (_socketV2 && channel == null) return _onFrameBeforeChannel(data);
    // A binary frame or a `{n, c}` envelope claims to be a record.
    final record = data is! String || data.startsWith('{"n":');
    final DecodedSocketFrame? decoded;
    try {
      decoded = await decodeSocketFrame(
        data,
        cipher: channel?.receiveCipher,
        encryptedBinary: true,
      );
    } catch (error) {
      if (gen == _connectionGeneration) {
        _rejectFrame(
          'frame did not open (${error.runtimeType})',
          record: record,
        );
      }
      return;
    }
    // Reconnects can finish while a large frame is being decoded.
    if (gen != _connectionGeneration || decoded == null) return;
    if (!decoded.encrypted) {
      _handleSignal(decoded.message);
      return;
    }
    if (channel == null) return;
    try {
      channel.accept(decoded.nonce);
    } catch (error) {
      _rejectFrame('$error', record: true);
      return;
    }
    _routeDecryptedMessage(decoded.message);
  }

  /// A frame on a v2 socket that has no channel yet. Only the relay's
  /// signals and the first `hs2` mean anything, and the length is checked
  /// before anything is parsed.
  void _onFrameBeforeChannel(Object? data) {
    if (data is! String) return _rejectFrame('binary frame before a channel');
    if (data.length > maxHandshakeFrameBytes) {
      // Too big to be a relay signal. While `hs2` is awaited it is a failed
      // message 2.
      if (_handshake != null) return _refuseConnection('oversized hs2');
      return _rejectFrame('oversized frame before a channel');
    }
    final Object? json;
    try {
      json = jsonDecode(data);
    } on FormatException {
      return _rejectFrame('unreadable frame before a channel');
    }
    if (json is! Map<String, dynamic>) {
      return _rejectFrame('unreadable frame before a channel');
    }
    if (json['type'] == 'hs2' && _handshake != null) return _onHs2(data);
    _handleSignal(json);
  }

  /// A frame on a keyed socket that is neither a sealed message nor a
  /// transport signal. The relay forwards whatever a room member sends, so
  /// there it is only dropped. On a direct socket nothing honest sends one
  /// once the key exchange is done, or at any time on v2, and the socket
  /// closes.
  ///
  /// [record] marks a frame that claimed to be a record and was rejected:
  /// it did not open, or its nonce was wrong. On v2 that closes the channel
  /// on either path, with code 1008 on a direct socket.
  void _rejectFrame(String reason, {bool record = false}) {
    final direct = _mode == ConnectionMode.direct;
    if (_socketV2 && record) {
      _refuseConnection(
        'record rejected: $reason',
        closeCode: direct ? WebSocketStatus.policyViolation : null,
      );
      return;
    }
    if (direct && (_socketV2 || _peerChannel != null)) {
      _refuseConnection('unsealed or unreadable frame: $reason');
      return;
    }
    debugPrint('[WebSocket] Incoming frame dropped: $reason');
  }

  /// The plaintext token socket, which has no pinned key and so nothing to
  /// seal with. The app opens one only when told the key is not required.
  Future<void> _onUnkeyedFrame(Object? data, int gen) async {
    if (_status != ConnectionStatus.connected && _token.isNotEmpty) {
      _setStatus(ConnectionStatus.connected);
    }
    try {
      final decoded = await decodeSocketFrame(data);
      if (gen != _connectionGeneration || decoded == null) return;
      final raw = decoded.message;
      // Peek at server_capabilities for the binary-envelope flag, then
      // forward the message so listeners can read fields like `backends`.
      if (raw['type'] == 'server_capabilities') _applyServerCapabilities(raw);
      _messageController.add(raw);
    } catch (error) {
      debugPrint('[WebSocket] Incoming frame rejected: ${error.runtimeType}');
    }
  }

  /// An unsealed frame on a keyed socket. Only the relay's own signals and,
  /// on the old transport, the key exchange answer mean anything, and all
  /// they can change is this connection's state. None of them reaches
  /// [messages]. The `hs2` a v2 socket is waiting for never comes here.
  void _handleSignal(Map<String, dynamic> raw) {
    final type = raw['type'];
    if (_mode == ConnectionMode.relay) {
      // Subscription gate
      if (type == 'subscription_required') {
        debugPrint('[Relay] Subscription required');
        if (!_subscriptionRequiredController.isClosed) {
          _subscriptionRequiredController.add(null);
        }
        // The user may subscribe on another device, so the socket tries the
        // join again by itself, but no more than once every five minutes.
        _relayJoinNotBefore = DateTime.now().add(_subscriptionRetry);
        _closeSocket();
        _setStatus(ConnectionStatus.disconnected);
        _scheduleReconnect();
        return;
      }
      if (type == 'peer_connected') {
        if (!_socketV2) {
          debugPrint('[Relay] Peer connected — sending key exchange');
          _sendKeyExchange();
        } else if (!_handshakeSent) {
          _sendHs1();
        } else {
          // The computer rejoined the room and has forgotten this peer. A
          // socket runs one handshake, so dial again.
          connect(force: true);
        }
        return;
      }
      if (type == 'peer_disconnected') {
        debugPrint('[Relay] Peer disconnected');
        if (_socketV2) {
          // Both sides drop the channel.
          _refuseConnection('the computer left the room');
          return;
        }
        _encryptionReady = false;
        _setStatus(ConnectionStatus.error);
        _scheduleReconnect();
        return;
      }
      if (type == 'key_exchange_ack' && !_socketV2) {
        if (_completeKeyExchange(raw)) _onKeyExchangeAck(raw);
        return;
      }
      // Anything else unsealed in the room is dropped.
      return;
    }

    // Direct, old transport. The one unsealed frame a computer sends is its
    // answer to this socket's key exchange.
    if (type == 'key_exchange_ack' && !_socketV2 && _peerChannel == null) {
      if (_completeKeyExchange(raw)) _onEncryptionEstablished();
      return;
    }
    _rejectFrame('unsealed $type');
  }

  /// Common post-decrypt routing: surfaces the message to listeners and
  /// transparently absorbs the wire-format handshake messages.
  void _routeDecryptedMessage(Map<String, dynamic> msg) {
    final t = msg['type'];
    if (_socketLocalRequest) {
      // Two things come back from a local request: the pairing, or word
      // that nobody allowed it. The grant is read on this channel alone.
      if (t == 'pairing_grant') {
        _onPairingGrant(msg);
      } else if (t == 'device_auth_result' && msg['ok'] != true) {
        _onNotApproved('not approved');
      }
      return;
    }
    if (_held) {
      // Only the verdict is read from a held channel.
      if (t == 'device_auth_result') {
        if (msg['ok'] == true) {
          _onTransportOpen();
        } else {
          // Denied, or nobody answered in ten minutes.
          _onNotApproved('not approved');
        }
      }
      return;
    }
    if (t == 'pairing_update' ||
        t == 'pairing_grant' ||
        t == 'pairing_upgrade_result') {
      _onPairingMessage(msg);
      return;
    }
    if (t == 'key_exchange_ack') {
      if (!_socketV2) _onKeyExchangeAck(msg);
      return;
    }
    if (t == 'device_auth_result') {
      switch (_deviceAuth.onAuthResult(msg)) {
        case DeviceAuthAction.open:
          // A direct socket without a token is open once approved; the
          // server sends its capabilities next.
          if (_mode == ConnectionMode.direct) {
            _lastHandshakeAwaited = false;
            _emitDeviceAuth();
            _setStatus(ConnectionStatus.connected);
          } else {
            _onEncryptionEstablished();
          }
        case DeviceAuthAction.wait:
          _lastHandshakeAwaited = true;
          _emitDeviceAuth();
        case DeviceAuthAction.sendAuth:
        case DeviceAuthAction.none:
          break;
      }
      _messageController.add(msg);
      return;
    }
    if (t == 'server_capabilities') {
      final channel = _peerChannel;
      if (channel != null &&
          channel.kind == ChannelKind.staticBox &&
          ((msg['sessionKeyVersion'] as num?)?.toInt() ?? 0) >=
              sessionKeyVersion) {
        // The computer speaks session keys, so the handshake that set up
        // this static-box channel was stripped on the way.
        _cryptoService?.markServerSessionKeyed();
        _refuseConnection('server supports session keys but none was agreed');
        return;
      }
      _applyServerCapabilities(msg);
      debugPrint(
        '[${_lane.name}] Server capabilities: binary=$_serverSupportsBinary '
        'bulk=$_serverSupportsTransportLanes uploadAcks=$_serverSupportsUploadAcks',
      );
      _askForPairing(msg);
      // Fall through so listeners can read other fields (e.g., `backends`).
    }
    _messageController.add(msg);
  }

  /// Carry-over, wire spec 9.3. A computer that speaks v2 hands its pairing
  /// to a recorded device over a session-keyed channel of the old transport.
  /// One request per connection. With no answer this connection carries on
  /// as it is, and the next one asks again. A device that cannot run the
  /// handshake never asks.
  void _askForPairing(Map<String, dynamic> capabilities) {
    if (_socketV2 || !_carryOver || _upgradeAsked) return;
    if (_lane != TransportLane.control) return;
    if (_peerChannel?.sessionKeyed != true) return;
    final transport = capabilities['transport'];
    final version = transport is Map ? transport['version'] : null;
    if (version is! num || version < transportVersion) return;
    if (!_v2Available()) return;
    _upgradeAsked = true;
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-'
        '${Random.secure().nextInt(1 << 32)}';
    if (_sendOnCurrentLane({
      'type': 'pairing_upgrade',
      'requestId': requestId,
    })) {
      _upgradeRequestId = requestId;
    }
  }

  /// The pairing a local request was after. The owner stores it and dials
  /// again with an ordinary `direct` handshake. The computer closes this
  /// socket once it has sent the grant, so nothing is left to do with it.
  void _onPairingGrant(Map<String, dynamic> msg) {
    final key = _channelKey;
    if (key == null) return;
    final change = PairingChange.parse(msg, withRoute: true, computerKey: key);
    if (change == null) return;
    _closeSocket();
    _lastHandshakeAwaited = false;
    _deviceAuth.reset();
    _emitDeviceAuth();
    _setStatus(ConnectionStatus.disconnected);
    // Dials again by itself should the owner not get to it.
    _scheduleReconnect();
    if (!_pairingChangeController.isClosed) {
      _pairingChangeController.add(change);
    }
  }

  /// The three sealed messages that carry a pairing secret, on any channel
  /// but a local request. They stop here whatever happens, so no listener
  /// ever sees a secret. Each counts only where the spec lets it:
  /// `pairing_update` on an open v2 control channel, and
  /// `pairing_upgrade_result` as the answer this old-transport control
  /// channel asked for. `pairing_grant` counts only on a local request,
  /// which [_onPairingGrant] reads, so here it is dropped.
  void _onPairingMessage(Map<String, dynamic> msg) {
    if (_lane != TransportLane.control) return;
    final key = _channelKey;
    if (key == null) return;
    final PairingChange? change;
    if (msg['type'] == 'pairing_update' && _socketV2) {
      change = PairingChange.parse(msg, withRoute: false, computerKey: key);
    } else if (msg['type'] == 'pairing_upgrade_result' &&
        !_socketV2 &&
        _upgradeRequestId != null &&
        msg['requestId'] == _upgradeRequestId &&
        _peerChannel?.sessionKeyed == true) {
      _upgradeRequestId = null;
      change = PairingChange.parse(msg, withRoute: true, computerKey: key);
    } else {
      change = null;
    }
    if (change != null && !_pairingChangeController.isClosed) {
      _pairingChangeController.add(change);
    }
  }

  void _applyServerCapabilities(Map<String, dynamic> msg) {
    _serverCapabilitiesReceived = true;
    _serverSupportsBinary = msg['binaryEnvelope'] == true;
    _serverSupportsUploadAcks =
        ((msg['uploadAckVersion'] as num?)?.toInt() ?? 0) >= uploadAckVersion;
    final lanes = msg['transportLanes'];
    _serverSupportsTransportLanes =
        lanes is Map &&
        ((lanes['version'] as num?)?.toInt() ?? 0) >= transportLaneVersion &&
        lanes['bulk'] == true;
    if (_manageBulkLane && _serverSupportsTransportLanes) {
      final bulk = _bulkLane;
      if (bulk != null &&
          bulk.status != ConnectionStatus.connected &&
          bulk.status != ConnectionStatus.connecting) {
        debugPrint('[Transport] Opening isolated bulk lane');
        bulk.connect();
      }
    }
  }

  void _handleBulkLifecycleMessage(Map<String, dynamic> msg) {
    final type = msg['type'];
    final uploadId = msg['uploadId'] as String?;
    final fileId = msg['fileId'] as String?;
    if (type == 'upload_complete' && uploadId != null) {
      _uploadUsesBulkLane.remove(uploadId);
    }
    if ((type == 'file_complete' || type == 'file_error') && fileId != null) {
      _downloadUsesBulkLane.remove(fileId);
    }
  }

  /// The server's answer to our public key. Over the relay it may hold the
  /// peer until `device_auth` passes; direct connections keep AUTH_TOKEN.
  void _onKeyExchangeAck(Map<String, dynamic> msg) {
    if (_mode != ConnectionMode.relay) {
      _onEncryptionEstablished();
      return;
    }
    if (_deviceAuth.onKeyExchangeAck(msg['device']) == DeviceAuthAction.open) {
      _onEncryptionEstablished();
      return;
    }
    // Held: the box works, but the peer is closed to everything except
    // device_auth, so status stays connecting and application sends wait.
    _encryptionReady = true;
    _emitDeviceAuth();
    _sendOnCurrentLane(
      deviceAuthMessage(
        token: _token,
        name: _deviceName,
        platform: _devicePlatform,
      ),
    );
  }

  /// Sets up this connection's cipher from the plaintext key_exchange_ack.
  /// False when the answer is refused and the socket is being dropped.
  bool _completeKeyExchange(Map<String, dynamic> ack) {
    final crypto = _cryptoService;
    if (crypto == null) return false;
    final offer = _sessionOffer;
    _sessionOffer = null;
    if (offer == null) {
      // An ack nobody asked for cannot replace a channel, and only a computer
      // that never used session keys may open one this way.
      if (_peerChannel != null) return false;
      if (crypto.serverRequiresSession) {
        _refuseConnection('unrequested static-box key exchange answer');
        return false;
      }
      _peerChannel = PeerChannel.legacy(crypto.cipherForLegacyChannel);
      _computerAnswered = true;
      return true;
    }
    try {
      // A channel that has session keys is never replaced by the static box,
      // whatever the stored pin says.
      final channel = offer.accept(
        ack,
        required:
            crypto.serverRequiresSession || _peerChannel?.sessionKeyed == true,
      );
      if (channel.sessionKeyed) crypto.markServerSessionKeyed();
      _peerChannel?.dispose();
      _peerChannel = channel;
      // A carry-over request belongs to the channel it was sent on. An
      // answer to the old channel's request means nothing on this one.
      _upgradeAsked = false;
      _upgradeRequestId = null;
      _computerAnswered = true;
      return true;
    } catch (error) {
      _refuseConnection('key exchange refused: $error');
      return false;
    }
  }

  /// Forgets everything that belonged to one socket: its key exchange or
  /// handshake, its channel, and what it had asked the computer.
  void _resetPeerChannel() {
    _sessionOffer = null;
    _peerChannel?.dispose();
    _peerChannel = null;
    _abandonHandshake();
    _handshakeSent = false;
    _held = false;
    _upgradeAsked = false;
    _upgradeRequestId = null;
    _channelKey = null;
  }

  /// Closes the current socket and its channel. The caller sets the status
  /// and decides whether to dial again.
  void _closeSocket([int? closeCode]) {
    _reconnectTimer?.cancel();
    _channelSubscription?.cancel();
    _channelSubscription = null;
    _connectionGeneration++;
    // The first close decides the code the computer sees.
    if (closeCode != null) unawaited(_rawSocket?.close(closeCode));
    _rawSocket = null;
    _channel?.sink.close();
    _channel = null;
    _encryptionReady = false;
    _serverCapabilitiesReceived = false;
    _resetPeerChannel();
  }

  /// Drops a socket whose encryption cannot be trusted and retries later.
  void _refuseConnection(String reason, {int? closeCode}) {
    debugPrint('[E2E] Dropping connection: $reason');
    final wasHeld = _held;
    _closeSocket(closeCode);
    if (wasHeld) {
      // The approval code belonged to the handshake that just ended.
      _deviceAuth.reset();
      _emitDeviceAuth();
    }
    _setStatus(ConnectionStatus.error);
    _scheduleReconnect();
  }

  void _emitDeviceAuth() {
    if (_deviceAuthController.isClosed) return;
    _deviceAuthController.add(_deviceAuth.state);
  }

  void _onEncryptionEstablished() {
    _encryptionReady = true;
    if (_mode == ConnectionMode.direct && _token.isEmpty) {
      _sendTokenlessDirectAuth();
      return;
    }
    _lastHandshakeAwaited = false;
    if (_mode == ConnectionMode.relay &&
        _deviceAuth.state.phase != DeviceAuthPhase.approved) {
      _deviceAuth.onKeyExchangeAck('approved');
    }
    _emitDeviceAuth();
    _setStatus(ConnectionStatus.connected);
    debugPrint(
      _mode == ConnectionMode.relay
          ? '[Relay] Key exchange complete — encryption ready'
          : '[Direct E2E] Key exchange complete — encryption ready',
    );
    if (_mode == ConnectionMode.direct) {
      send({
        'type': 'direct_auth',
        'token': _token,
        'lane': _lane.name,
        ..._clientCapabilities,
        'sessionKeyVersion': sessionKeyVersion,
      });
      return;
    }
    // Announce that we can speak the binary wire format. Older servers will
    // ignore this message and we'll stay on the legacy JSON envelope.
    send({
      'type': 'client_capabilities',
      'lane': _lane.name,
      ..._clientCapabilities,
      'sessionKeyVersion': sessionKeyVersion,
    });
  }

  /// The desktop app under a Windows account that cannot read the server's
  /// `.env` proves its device key instead. The server holds the socket until
  /// a device approves the key, as it does for a new phone on the relay, so
  /// status stays connecting until `device_auth_result` says ok. The name
  /// carries the Windows account, since every account shares the computer.
  void _sendTokenlessDirectAuth() {
    _deviceAuth.onKeyExchangeAck('pending');
    _emitDeviceAuth();
    _sendOnCurrentLane({
      'type': 'direct_auth',
      'name': _nameWithAccount(),
      'platform': _devicePlatform,
      'lane': _lane.name,
      ..._clientCapabilities,
      'sessionKeyVersion': sessionKeyVersion,
    });
  }

  /// This device's name with the Windows account in front, for the server
  /// on this machine when another account runs it.
  String _nameWithAccount() {
    final account = windowsAccount();
    return account.isEmpty ? _deviceName : '$account on $_deviceName';
  }

  /// Send our public key to the server for NaCl key exchange
  void _sendKeyExchange() {
    final crypto = _cryptoService;
    if (_socketV2) return;
    if (crypto == null || !crypto.hasKeyPair || !crypto.isReady) return;

    // Key exchange is sent PLAINTEXT — server needs our public key to start
    // encrypting. The session offer in it is public too.
    final offer = crypto.startSession();
    _sessionOffer = offer;
    _channelKey = crypto.serverKeyBase64;
    _channel?.sink.add(jsonEncode(offer.message()));
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    // A device waiting for approval gets opened in place when another device
    // approves it. Only after the computer drops the held peer (10 minutes)
    // does a retry help, and a fast loop would just repeat the prompt.
    var delay = _lastHandshakeAwaited
        ? const Duration(seconds: 30)
        : const Duration(seconds: 3);
    final wait = _retryWait();
    if (wait > delay) delay = wait;
    _reconnectTimer = Timer(delay, () {
      if (_status != ConnectionStatus.connected) {
        connect();
      }
    });
  }

  /// When the current socket became usable; null until it does.
  DateTime? connectedAt;

  /// Whether this socket connected after [moment]. A socket opened after a
  /// network change is already on the new network and need not be replaced.
  bool connectedAfter(DateTime moment) =>
      _status == ConnectionStatus.connected &&
      (connectedAt?.isAfter(moment) ?? false);

  void _setStatus(ConnectionStatus status) {
    // The handshake reports "connected" from more than one step (encryption
    // established, device approved). Listeners resync the whole session on
    // each report, so a status the socket already has is not reported again.
    if (_status == status) return;
    if (status == ConnectionStatus.connected) connectedAt = DateTime.now();
    _status = status;
    _statusController.add(status);
  }

  bool get _canSendApplicationMessages {
    if (_channel == null || _status != ConnectionStatus.connected) return false;
    if (_mode == ConnectionMode.relay) return _encryptionReady;
    if (_cryptoService != null) return _encryptionReady;
    return true;
  }

  bool get bulkLaneReady =>
      _bulkLane?._canSendApplicationMessages == true &&
      _bulkLane?._serverCapabilitiesReceived == true;

  bool _shouldUseBulkLane(Map<String, dynamic> message) {
    if (!_manageBulkLane) return false;
    final type = message['type'] as String? ?? '';
    final uploadId = message['uploadId'] as String?;
    final fileId = message['fileId'] as String?;

    if (type == 'upload_start' || type == 'file_manager_upload_start') {
      final useBulk = bulkLaneReady;
      if (uploadId != null) _uploadUsesBulkLane[uploadId] = useBulk;
      return useBulk;
    }
    if (type == 'upload_chunk' || type == 'upload_chunk_bin') {
      return uploadId != null && _uploadUsesBulkLane[uploadId] == true;
    }
    if (type == 'request_file' || type == 'file_manager_download') {
      final useBulk = bulkLaneReady && fileId != null;
      if (fileId != null) _downloadUsesBulkLane[fileId] = useBulk;
      return useBulk;
    }
    if (type == 'file_download_ack') {
      return fileId != null && _downloadUsesBulkLane[fileId] == true;
    }
    return bulkLaneReady &&
        const {
          'file_manager_read_text',
          'file_manager_write_text',
          'load_more_history',
          'get_archive_history',
          'get_sdk_event_history',
        }.contains(type);
  }

  bool send(Map<String, dynamic> message) {
    final useBulk = _shouldUseBulkLane(message);
    if (useBulk) {
      final sent = _bulkLane?._sendOnCurrentLane(message) ?? false;
      if (sent) return true;

      // Initial requests may safely fall back before any transfer bytes have
      // moved. Never split an in-flight transfer across lanes.
      final type = message['type'] as String? ?? '';
      if (type == 'upload_chunk' ||
          type == 'upload_chunk_bin' ||
          type == 'file_download_ack') {
        return false;
      }
      final uploadId = message['uploadId'] as String?;
      final fileId = message['fileId'] as String?;
      if (uploadId != null) _uploadUsesBulkLane[uploadId] = false;
      if (fileId != null) _downloadUsesBulkLane[fileId] = false;
    }
    return _sendOnCurrentLane(message);
  }

  bool _sendOnCurrentLane(Map<String, dynamic> message) {
    if (_channel == null || _socketLocalRequest) return false;
    if (_socketV2 && _oldTransportOnly.contains(message['type'])) return false;

    try {
      final peerChannel = _peerChannel;
      if ((_mode == ConnectionMode.relay ||
              (_mode == ConnectionMode.direct && _cryptoService != null)) &&
          _encryptionReady &&
          peerChannel != null) {
        final plaintext = jsonEncode(message);
        if (_serverSupportsBinary) {
          // Binary envelope: 1-byte JSON marker + UTF-8 JSON.
          final jsonBytes = utf8.encode(plaintext);
          final payload = Uint8List(jsonBytes.length + 1);
          payload[0] = _binMarkerJson;
          payload.setRange(1, payload.length, jsonBytes);
          _channel!.sink.add(peerChannel.sealBinary(payload));
        } else {
          // Legacy text-JSON envelope.
          _channel!.sink.add(jsonEncode(peerChannel.sealText(plaintext)));
        }
        return true;
      } else if (_mode == ConnectionMode.direct && _cryptoService == null) {
        _channel!.sink.add(jsonEncode(message));
        return true;
      }
    } catch (error) {
      debugPrint('[WebSocket] Send failed: $error');
    }
    return false;
  }

  /// Whether the server has confirmed it understands the binary wire format.
  /// Callers (e.g. the upload path) check this to decide between binary and
  /// legacy base64 chunks.
  bool get serverSupportsBinary => bulkLaneReady
      ? (_bulkLane?._serverSupportsBinary ?? _serverSupportsBinary)
      : _serverSupportsBinary;

  bool get serverSupportsUploadAcks => bulkLaneReady
      ? (_bulkLane?._serverSupportsUploadAcks ?? _serverSupportsUploadAcks)
      : _serverSupportsUploadAcks;

  /// Send a binary upload chunk. Builds the standard
  /// `[0x42][1 idLen][idBytes][4 chunkIdx BE][bytes]` plaintext payload and
  /// ships it as a raw binary frame for legacy direct connections or wraps it
  /// in the NaCl binary envelope for relay and encrypted direct connections.
  bool sendUploadChunkBinary({
    required String uploadId,
    required int chunkIndex,
    required Uint8List bytes,
  }) {
    if (_manageBulkLane && _uploadUsesBulkLane[uploadId] == true) {
      return _bulkLane?._sendUploadChunkBinaryOnCurrentLane(
            uploadId: uploadId,
            chunkIndex: chunkIndex,
            bytes: bytes,
          ) ??
          false;
    }
    return _sendUploadChunkBinaryOnCurrentLane(
      uploadId: uploadId,
      chunkIndex: chunkIndex,
      bytes: bytes,
    );
  }

  bool _sendUploadChunkBinaryOnCurrentLane({
    required String uploadId,
    required int chunkIndex,
    required Uint8List bytes,
  }) {
    if (_channel == null) return false;
    final idBytes = utf8.encode(uploadId);
    if (idBytes.length > 255) {
      throw StateError('uploadId too long for binary frame');
    }
    final payload = Uint8List(2 + idBytes.length + 4 + bytes.length);
    payload[0] = _binMarkerUploadChunk;
    payload[1] = idBytes.length;
    payload.setRange(2, 2 + idBytes.length, idBytes);
    final off = 2 + idBytes.length;
    payload[off] = (chunkIndex >> 24) & 0xFF;
    payload[off + 1] = (chunkIndex >> 16) & 0xFF;
    payload[off + 2] = (chunkIndex >> 8) & 0xFF;
    payload[off + 3] = chunkIndex & 0xFF;
    payload.setRange(off + 4, payload.length, bytes);

    final peerChannel = _peerChannel;
    if (_mode == ConnectionMode.relay ||
        (_mode == ConnectionMode.direct && _cryptoService != null)) {
      if (!_encryptionReady || peerChannel == null) return false;
      _channel!.sink.add(peerChannel.sealBinary(payload));
    } else {
      _channel!.sink.add(payload);
    }
    return true;
  }

  void sendPrompt(
    String text, {
    String? sessionId,
    String? priority,
    String? messageId,
    String? cwd,
    bool? codexFastMode,
  }) {
    send({
      'type': 'prompt',
      'text': text,
      'sessionId': ?sessionId,
      'priority': ?priority,
      'messageId': ?messageId,
      'cwd': ?cwd,
      'codexFastMode': ?codexFastMode,
    });
  }

  void sendRetractQueuedPrompt(String messageId) {
    send({'type': 'retract_queued_prompt', 'messageId': messageId});
  }

  void sendAnswer(String questionId, Map<String, String> answers) {
    send({'type': 'answer', 'questionId': questionId, 'answers': answers});
  }

  void sendNewSession({String? cwd}) {
    send({'type': 'new_session', 'cwd': ?cwd});
  }

  void sendResumeSession(String sessionId) {
    send({'type': 'resume_session', 'sessionId': sessionId});
  }

  void sendListSessions() {
    send({'type': 'list_sessions'});
  }

  void sendDeleteSession(String sessionId) {
    send({'type': 'delete_session', 'sessionId': sessionId});
  }

  void sendClearContext(String sessionId) {
    send({'type': 'clear_context', 'sessionId': sessionId});
  }

  void sendArchiveSession(String sessionId) {
    send({'type': 'archive_session', 'sessionId': sessionId});
  }

  void sendListArchives() {
    send({'type': 'list_archives'});
  }

  void sendGetArchiveHistory(String sid, String ts) {
    send({'type': 'get_archive_history', 'sid': sid, 'ts': ts});
  }

  void sendRestoreArchive(String sid, String ts) {
    send({'type': 'restore_archive', 'sid': sid, 'ts': ts});
  }

  void sendDeleteArchive(String sid, String ts) {
    send({'type': 'delete_archive', 'sid': sid, 'ts': ts});
  }

  void sendAbort({String? sessionId}) {
    send({'type': 'abort', 'sessionId': ?sessionId});
  }

  void sendStopTask(String taskId) {
    send({'type': 'stop_task', 'taskId': taskId});
  }

  void sendStopMonitor(String taskId) {
    send({'type': 'stop_monitor', 'taskId': taskId});
  }

  void sendInterrupt() {
    send({'type': 'interrupt'});
  }

  void sendSetModel(String? model) {
    send({'type': 'set_model', 'model': ?model});
  }

  void sendSetPermissionMode(String mode) {
    send({'type': 'set_permission_mode', 'mode': mode});
  }

  void sendMcpStatus() {
    send({'type': 'mcp_status'});
  }

  void sendMcpLogin(String serverName) {
    send({'type': 'mcp_login', 'serverName': serverName});
  }

  void sendMcpReconnect(String serverName) {
    send({'type': 'mcp_reconnect', 'serverName': serverName});
  }

  void sendMcpToggle(String serverName, bool enabled) {
    send({'type': 'mcp_toggle', 'serverName': serverName, 'enabled': enabled});
  }

  void sendRewind(String userMessageUuid, {bool dryRun = false}) {
    send({
      'type': 'rewind',
      'userMessageUuid': userMessageUuid,
      'dryRun': dryRun,
    });
  }

  void sendRewindConversation(
    String userMessageUuid, {
    String? sessionId,
    bool dryRun = false,
    bool rewindFiles = true,
  }) {
    send({
      'type': 'rewind_conversation',
      'sessionId': ?sessionId,
      'userMessageUuid': userMessageUuid,
      'dryRun': dryRun,
      'rewindFiles': rewindFiles,
    });
  }

  void sendBranchFromMessage(String sessionId, String userMessageUuid) {
    send({
      'type': 'branch_from_message',
      'sessionId': sessionId,
      'userMessageUuid': userMessageUuid,
    });
  }

  void disconnect() {
    _bulkLane?.disconnect();
    _reconnectTimer?.cancel();
    _channelSubscription?.cancel();
    _channelSubscription = null;
    _connectionGeneration++; // invalidate any lingering callbacks
    _rawSocket = null;
    _channel?.sink.close();
    _channel = null;
    _encryptionReady = false;
    _serverCapabilitiesReceived = false;
    _resetPeerChannel();
    _serverSupportsTransportLanes = false;
    _serverSupportsUploadAcks = false;
    _uploadUsesBulkLane.clear();
    _downloadUsesBulkLane.clear();
    _lastHandshakeAwaited = false;
    _deviceAuth.reset();
    _emitDeviceAuth();
    _setStatus(ConnectionStatus.disconnected);
  }

  void dispose() {
    disconnect();
    _bulkMessageSubscription?.cancel();
    _bulkMessageSubscription = null;
    _bulkLane?.dispose();
    _bulkLane = null;
    _messageController.close();
    _statusController.close();
    _subscriptionRequiredController.close();
    _pairingChangeController.close();
    _deviceAuthController.close();
  }
}
