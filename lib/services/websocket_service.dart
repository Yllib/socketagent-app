import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/file_download_frame.dart';
import 'crypto_service.dart';

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
  return uri != null &&
      (uri.scheme == 'wss' || uri.scheme == 'ws') &&
      uri.host.isNotEmpty &&
      pairingToken.trim().isNotEmpty &&
      cryptoReady;
}

class WebSocketService {
  static const int _sessionEventAckVersion = 2;
  WebSocketService({
    TransportLane lane = TransportLane.control,
    bool manageBulkLane = true,
  }) : _lane = lane,
       _manageBulkLane = manageBulkLane {
    if (_manageBulkLane) {
      final bulk = WebSocketService(
        lane: TransportLane.bulk,
        manageBulkLane: false,
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
  WebSocketService? _bulkLane;
  StreamSubscription<Map<String, dynamic>>? _bulkMessageSubscription;
  WebSocketChannel? _channel;
  StreamSubscription? _channelSubscription;
  int _connectionGeneration =
      0; // prevents stale callbacks from affecting state
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  final _statusController = StreamController<ConnectionStatus>.broadcast();
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
  bool _requireTrustedDirectKey = true;

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
    final changed =
        _relayUrl != relayUrl ||
        _pairingToken != pairingToken ||
        !identical(_cryptoService, cryptoService);
    if (changed && _channel != null) disconnect();
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

    try {
      final Uri uri;
      if (_mode == ConnectionMode.relay) {
        uri = Uri.parse(
          '$_relayUrl?token=${Uri.encodeComponent(_pairingToken)}&role=phone&subscriber_token=${Uri.encodeComponent(_subscriberToken)}',
        );
        _encryptionReady = false;
        // DO NOT log the full URI - it contains pairing and subscriber tokens
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
      }

      // Use the IOWebSocketChannel.connect factory so it builds the underlying
      // dart:io WebSocket the same way the abstract WebSocketChannel.connect
      // does (and binary frame plumbing works correctly), plus we get
      // pingInterval for free. Without pingInterval, a silently-broken socket
      // would just hang forever instead of firing onDone.
      _channel = IOWebSocketChannel.connect(
        uri,
        headers:
            _mode == ConnectionMode.direct &&
                !(_cryptoService != null && _cryptoService!.isReady)
            ? {'Authorization': 'Bearer $_token'}
            : null,
        pingInterval: const Duration(seconds: 20),
      );

      _channelSubscription = _channel!.stream.listen(
        (data) {
          if (gen != _connectionGeneration) return;
          if (_status != ConnectionStatus.connected &&
              _mode == ConnectionMode.direct) {
            _setStatus(ConnectionStatus.connected);
          }
          try {
            if (data is String) {
              final raw = jsonDecode(data) as Map<String, dynamic>;
              _handleIncoming(raw);
            } else if (data is List<int>) {
              _handleIncomingBinary(Uint8List.fromList(data));
            }
          } catch (_) {}
        },
        onError: (error) {
          if (gen != _connectionGeneration) return;
          _setStatus(ConnectionStatus.error);
          _scheduleReconnect();
        },
        onDone: () {
          if (gen != _connectionGeneration) return;
          _encryptionReady = false;
          _serverSupportsBinary = false;
          _serverSupportsUploadAcks = false;
          _setStatus(ConnectionStatus.disconnected);
          _scheduleReconnect();
        },
      );

      if (_mode == ConnectionMode.direct &&
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
            'binaryEnvelope': true,
            'binaryFileDownloadVersion': binaryFileDownloadVersion,
            'transportLaneVersion': transportLaneVersion,
            'uploadAckVersion': uploadAckVersion,
            'sessionEventAckVersion': _sessionEventAckVersion,
          });
        });
      }
    } catch (e) {
      _setStatus(ConnectionStatus.error);
      _scheduleReconnect();
    }
  }

  /// Handle incoming messages — relay control, encrypted, or plain
  void _handleIncoming(Map<String, dynamic> raw) {
    if (_mode == ConnectionMode.relay) {
      // Subscription gate
      if (raw['type'] == 'subscription_required') {
        debugPrint('[Relay] Subscription required');
        _messageController.add(raw);
        // Don't reconnect — user needs to subscribe first
        _reconnectTimer?.cancel();
        _channelSubscription?.cancel();
        _channelSubscription = null;
        _connectionGeneration++;
        _channel?.sink.close();
        _channel = null;
        _encryptionReady = false;
        _setStatus(ConnectionStatus.disconnected);
        return;
      }

      // Relay control messages
      if (raw['type'] == 'peer_connected') {
        debugPrint('[Relay] Peer connected — sending key exchange');
        _sendKeyExchange();
        return;
      }
      if (raw['type'] == 'peer_disconnected') {
        debugPrint('[Relay] Peer disconnected');
        _encryptionReady = false;
        _setStatus(ConnectionStatus.error);
        _scheduleReconnect();
        return;
      }

      // Encrypted message from server
      if (raw.containsKey('n') && raw.containsKey('c')) {
        if (_cryptoService == null || !_cryptoService!.isReady) {
          debugPrint('[Relay] Encrypted msg received but crypto not ready');
          return;
        }
        try {
          final plaintext = _cryptoService!.decrypt(raw);
          final msg = jsonDecode(plaintext) as Map<String, dynamic>;
          debugPrint('[Relay] Decrypted message: ${msg['type']}');
          _routeDecryptedMessage(msg);
        } catch (e) {
          debugPrint('[Relay] Decryption failed: $e');
        }
        return;
      }

      // Plaintext messages in relay mode (only during key exchange)
      if (raw['type'] == 'key_exchange_ack') {
        _onEncryptionEstablished();
        return;
      }

      // Unknown relay message — ignore
      return;
    }

    // Direct mode with a server public key uses the same NaCl envelope as relay.
    if (_mode == ConnectionMode.direct &&
        _cryptoService != null &&
        _cryptoService!.isReady) {
      if (raw['type'] == 'key_exchange_ack') {
        _onEncryptionEstablished();
        return;
      }

      if (raw.containsKey('n') && raw.containsKey('c')) {
        try {
          final plaintext = _cryptoService!.decrypt(raw);
          final msg = jsonDecode(plaintext) as Map<String, dynamic>;
          _routeDecryptedMessage(msg);
        } catch (e) {
          debugPrint('[Direct E2E] Decryption failed: $e');
        }
        return;
      }
    }

    // Direct legacy mode — pass through. We also peek at server_capabilities to
    // capture the binary-envelope flag (purely internal), then forward the
    // message so listeners can read fields like `backends`.
    if (raw['type'] == 'server_capabilities') {
      _applyServerCapabilities(raw);
    }
    _messageController.add(raw);
  }

  /// Handle a binary WebSocket frame.
  ///   - In relay mode the frame is `[24-byte nonce | ciphertext]` and we
  ///     decrypt before parsing.
  ///   - In direct mode it's `[1 marker | payload]` plain.
  void _handleIncomingBinary(Uint8List bytes) {
    if (_mode == ConnectionMode.relay) {
      if (_cryptoService == null || !_cryptoService!.isReady) return;
      try {
        final plaintext = _cryptoService!.decryptBinary(bytes);
        if (plaintext.isEmpty) return;
        final marker = plaintext[0];
        if (marker == _binMarkerJson) {
          final json = utf8.decode(plaintext.sublist(1));
          final msg = jsonDecode(json) as Map<String, dynamic>;
          _routeDecryptedMessage(msg);
        } else if (marker == binaryFileDownloadMarker) {
          final msg = decodeBinaryFileDownloadFrame(plaintext);
          if (msg != null) _routeDecryptedMessage(msg);
        }
      } catch (e) {
        debugPrint('[Relay] Binary decryption failed: $e');
      }
      return;
    }
    if (_mode == ConnectionMode.direct &&
        _cryptoService != null &&
        _cryptoService!.isReady) {
      try {
        final plaintext = _cryptoService!.decryptBinary(bytes);
        if (plaintext.isEmpty) return;
        final marker = plaintext[0];
        if (marker == _binMarkerJson) {
          final json = utf8.decode(plaintext.sublist(1));
          final msg = jsonDecode(json) as Map<String, dynamic>;
          _routeDecryptedMessage(msg);
        } else if (marker == binaryFileDownloadMarker) {
          final msg = decodeBinaryFileDownloadFrame(plaintext);
          if (msg != null) _routeDecryptedMessage(msg);
        }
      } catch (e) {
        debugPrint('[Direct E2E] Binary decryption failed: $e');
      }
      return;
    }

    final msg = decodeBinaryFileDownloadFrame(bytes);
    if (msg != null) _routeDecryptedMessage(msg);
  }

  /// Common post-decrypt routing: surfaces the message to listeners and
  /// transparently absorbs the wire-format handshake messages.
  void _routeDecryptedMessage(Map<String, dynamic> msg) {
    final t = msg['type'];
    if (t == 'key_exchange_ack') {
      _onEncryptionEstablished();
      return;
    }
    if (t == 'server_capabilities') {
      _applyServerCapabilities(msg);
      debugPrint(
        '[${_lane.name}] Server capabilities: binary=$_serverSupportsBinary '
        'bulk=$_serverSupportsTransportLanes uploadAcks=$_serverSupportsUploadAcks',
      );
      // Fall through so listeners can read other fields (e.g., `backends`).
    }
    _messageController.add(msg);
  }

  void _applyServerCapabilities(Map<String, dynamic> msg) {
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

  void _onEncryptionEstablished() {
    _encryptionReady = true;
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
        'binaryEnvelope': true,
        'binaryFileDownloadVersion': binaryFileDownloadVersion,
        'transportLaneVersion': transportLaneVersion,
        'uploadAckVersion': uploadAckVersion,
        'sessionEventAckVersion': _sessionEventAckVersion,
      });
      return;
    }
    // Announce that we can speak the binary wire format. Older servers will
    // ignore this message and we'll stay on the legacy JSON envelope.
    send({
      'type': 'client_capabilities',
      'lane': _lane.name,
      'binaryEnvelope': true,
      'binaryFileDownloadVersion': binaryFileDownloadVersion,
      'transportLaneVersion': transportLaneVersion,
      'uploadAckVersion': uploadAckVersion,
      'sessionEventAckVersion': _sessionEventAckVersion,
    });
  }

  /// Send our public key to the server for NaCl key exchange
  void _sendKeyExchange() {
    if (_cryptoService == null || !_cryptoService!.hasKeyPair) return;

    // Key exchange is sent PLAINTEXT — server needs our public key to start encrypting
    final msg = jsonEncode({
      'type': 'key_exchange',
      'pubkey': _cryptoService!.publicKeyBase64,
    });
    _channel?.sink.add(msg);
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (_status != ConnectionStatus.connected) {
        connect();
      }
    });
  }

  void _setStatus(ConnectionStatus status) {
    _status = status;
    _statusController.add(status);
  }

  bool get _canSendApplicationMessages {
    if (_channel == null || _status != ConnectionStatus.connected) return false;
    if (_mode == ConnectionMode.relay) return _encryptionReady;
    if (_cryptoService != null) return _encryptionReady;
    return true;
  }

  bool get bulkLaneReady => _bulkLane?._canSendApplicationMessages == true;

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
    if (_channel == null) return false;

    try {
      if ((_mode == ConnectionMode.relay ||
              (_mode == ConnectionMode.direct && _cryptoService != null)) &&
          _encryptionReady &&
          _cryptoService != null) {
        final plaintext = jsonEncode(message);
        if (_serverSupportsBinary) {
          // Binary envelope: 1-byte JSON marker + UTF-8 JSON.
          final jsonBytes = utf8.encode(plaintext);
          final payload = Uint8List(jsonBytes.length + 1);
          payload[0] = _binMarkerJson;
          payload.setRange(1, payload.length, jsonBytes);
          final envelope = _cryptoService!.encryptBinary(payload);
          _channel!.sink.add(envelope);
        } else {
          // Legacy text-JSON envelope.
          final envelope = _cryptoService!.encrypt(plaintext);
          _channel!.sink.add(jsonEncode(envelope));
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

    if (_mode == ConnectionMode.relay) {
      if (!_encryptionReady || _cryptoService == null) return false;
      final envelope = _cryptoService!.encryptBinary(payload);
      _channel!.sink.add(envelope);
    } else if (_mode == ConnectionMode.direct && _cryptoService != null) {
      if (!_encryptionReady) return false;
      final envelope = _cryptoService!.encryptBinary(payload);
      _channel!.sink.add(envelope);
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
      if (sessionId != null) 'sessionId': sessionId,
      if (priority != null) 'priority': priority,
      if (messageId != null) 'messageId': messageId,
      if (cwd != null) 'cwd': cwd,
      if (codexFastMode != null) 'codexFastMode': codexFastMode,
    });
  }

  void sendRetractQueuedPrompt(String messageId) {
    send({'type': 'retract_queued_prompt', 'messageId': messageId});
  }

  void sendAnswer(String questionId, Map<String, String> answers) {
    send({'type': 'answer', 'questionId': questionId, 'answers': answers});
  }

  void sendNewSession({String? cwd}) {
    send({'type': 'new_session', if (cwd != null) 'cwd': cwd});
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
    send({'type': 'abort', if (sessionId != null) 'sessionId': sessionId});
  }

  void sendStopTask(String taskId) {
    send({'type': 'stop_task', 'taskId': taskId});
  }

  void sendStopMonitor(String taskId) {
    send({'type': 'stop_monitor', 'taskId': taskId});
  }

  void sendForkSession(String sessionId) {
    send({'type': 'fork_session', 'sessionId': sessionId});
  }

  void sendInterrupt() {
    send({'type': 'interrupt'});
  }

  void sendSetModel(String? model) {
    send({'type': 'set_model', if (model != null) 'model': model});
  }

  void sendSetPermissionMode(String mode) {
    send({'type': 'set_permission_mode', 'mode': mode});
  }

  void sendMcpStatus() {
    send({'type': 'mcp_status'});
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
    bool dryRun = false,
    bool rewindFiles = true,
  }) {
    send({
      'type': 'rewind_conversation',
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
    _channel?.sink.close();
    _channel = null;
    _encryptionReady = false;
    _serverSupportsTransportLanes = false;
    _serverSupportsUploadAcks = false;
    _uploadUsesBulkLane.clear();
    _downloadUsesBulkLane.clear();
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
  }
}
