import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'crypto_service.dart';

enum ConnectionStatus { disconnected, connecting, connected, error }

enum ConnectionMode { direct, relay }

class WebSocketService {
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
  }

  void configureRelay({
    required String relayUrl,
    required String pairingToken,
    required CryptoService cryptoService,
    String subscriberToken = '',
  }) {
    _relayUrl = relayUrl;
    _pairingToken = pairingToken;
    _cryptoService = cryptoService;
    _subscriberToken = subscriberToken;
  }

  void setMode(ConnectionMode mode) {
    if (_mode == mode) return;
    disconnect();
    _mode = mode;
  }

  void connect() {
    if (_status == ConnectionStatus.connecting) return;
    _setStatus(ConnectionStatus.connecting);
    _reconnectTimer?.cancel();
    // Cancel old subscription BEFORE closing channel to prevent stale onDone callbacks
    _channelSubscription?.cancel();
    _channelSubscription = null;
    _channel?.sink.close();
    _channel = null;
    // Increment generation so any lingering async callbacks from old connections are ignored
    final gen = ++_connectionGeneration;

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
          queryParameters: encryptedDirect ? {'e2e': '1'} : null,
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
          send({'type': 'client_capabilities', 'binaryEnvelope': true});
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
      _serverSupportsBinary = (raw['binaryEnvelope'] == true);
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
        }
        // We don't expect upload chunks coming back from the server today.
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
        }
      } catch (e) {
        debugPrint('[Direct E2E] Binary decryption failed: $e');
      }
      return;
    }

    // Direct legacy mode: server doesn't currently push binary frames. Ignore.
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
      _serverSupportsBinary = (msg['binaryEnvelope'] == true);
      debugPrint(
        '[Relay] Server supports binary envelope: $_serverSupportsBinary',
      );
      // Fall through so listeners can read other fields (e.g., `backends`).
    }
    _messageController.add(msg);
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
      send({'type': 'direct_auth', 'token': _token, 'binaryEnvelope': true});
      return;
    }
    // Announce that we can speak the binary wire format. Older servers will
    // ignore this message and we'll stay on the legacy JSON envelope.
    send({'type': 'client_capabilities', 'binaryEnvelope': true});
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

  void send(Map<String, dynamic> message) {
    if (_channel == null) return;

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
    } else if (_mode == ConnectionMode.direct && _cryptoService == null) {
      _channel!.sink.add(jsonEncode(message));
    }
  }

  /// Whether the server has confirmed it understands the binary wire format.
  /// Callers (e.g. the upload path) check this to decide between binary and
  /// legacy base64 chunks.
  bool get serverSupportsBinary => _serverSupportsBinary;

  /// Send a binary upload chunk. Builds the standard
  /// `[0x42][1 idLen][idBytes][4 chunkIdx BE][bytes]` plaintext payload and
  /// ships it as a raw binary frame for legacy direct connections or wraps it
  /// in the NaCl binary envelope for relay and encrypted direct connections.
  void sendUploadChunkBinary({
    required String uploadId,
    required int chunkIndex,
    required Uint8List bytes,
  }) {
    if (_channel == null) return;
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
      if (!_encryptionReady || _cryptoService == null) return;
      final envelope = _cryptoService!.encryptBinary(payload);
      _channel!.sink.add(envelope);
    } else if (_mode == ConnectionMode.direct && _cryptoService != null) {
      if (!_encryptionReady) return;
      final envelope = _cryptoService!.encryptBinary(payload);
      _channel!.sink.add(envelope);
    } else {
      _channel!.sink.add(payload);
    }
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
    _reconnectTimer?.cancel();
    _channelSubscription?.cancel();
    _channelSubscription = null;
    _connectionGeneration++; // invalidate any lingering callbacks
    _channel?.sink.close();
    _channel = null;
    _encryptionReady = false;
    _setStatus(ConnectionStatus.disconnected);
  }

  void dispose() {
    disconnect();
    _messageController.close();
    _statusController.close();
  }
}
