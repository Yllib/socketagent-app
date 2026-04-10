import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'crypto_service.dart';

enum ConnectionStatus { disconnected, connecting, connected, error }
enum ConnectionMode { direct, relay }

class WebSocketService {
  WebSocketChannel? _channel;
  StreamSubscription? _channelSubscription;
  int _connectionGeneration = 0; // prevents stale callbacks from affecting state
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

  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  Stream<ConnectionStatus> get statusStream => _statusController.stream;
  ConnectionStatus get status => _status;
  ConnectionMode get mode => _mode;

  void configure({required String host, required int port, required String token}) {
    _host = host;
    _port = port;
    _token = token;
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
        uri = Uri.parse('$_relayUrl?token=${Uri.encodeComponent(_pairingToken)}&role=phone&subscriber_token=${Uri.encodeComponent(_subscriberToken)}');
        _encryptionReady = false;
        // DO NOT log the full URI - it contains pairing and subscriber tokens
      } else {
        uri = Uri.parse('ws://$_host:$_port?token=${Uri.encodeComponent(_token)}');
      }

      _channel = WebSocketChannel.connect(uri);

      _channelSubscription = _channel!.stream.listen(
        (data) {
          if (gen != _connectionGeneration) return;
          if (_status != ConnectionStatus.connected && _mode == ConnectionMode.direct) {
            _setStatus(ConnectionStatus.connected);
          }
          try {
            final raw = jsonDecode(data as String) as Map<String, dynamic>;
            _handleIncoming(raw);
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
          _setStatus(ConnectionStatus.disconnected);
          _scheduleReconnect();
        },
      );

      // For direct mode, assume connected after a short delay
      if (_mode == ConnectionMode.direct) {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (gen != _connectionGeneration) return;
          if (_status == ConnectionStatus.connecting) {
            _setStatus(ConnectionStatus.connected);
          }
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
        print('[Relay] Subscription required');
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
        print('[Relay] Peer connected — sending key exchange');
        _sendKeyExchange();
        return;
      }
      if (raw['type'] == 'peer_disconnected') {
        print('[Relay] Peer disconnected');
        _encryptionReady = false;
        _setStatus(ConnectionStatus.error);
        _scheduleReconnect();
        return;
      }

      // Encrypted message from server
      if (raw.containsKey('n') && raw.containsKey('c')) {
        if (_cryptoService == null || !_cryptoService!.isReady) {
          print('[Relay] Encrypted msg received but crypto not ready');
          return;
        }
        try {
          final plaintext = _cryptoService!.decrypt(raw);
          final msg = jsonDecode(plaintext) as Map<String, dynamic>;
          print('[Relay] Decrypted message: ${msg['type']}');

          // Check for key exchange ack
          if (msg['type'] == 'key_exchange_ack') {
            _encryptionReady = true;
            _setStatus(ConnectionStatus.connected);
            print('[Relay] Key exchange complete — encryption ready');
            return;
          }

          _messageController.add(msg);
        } catch (e) {
          print('[Relay] Decryption failed: $e');
        }
        return;
      }

      // Plaintext messages in relay mode (only during key exchange)
      if (raw['type'] == 'key_exchange_ack') {
        _encryptionReady = true;

        _setStatus(ConnectionStatus.connected);
        return;
      }

      // Unknown relay message — ignore
      return;
    }

    // Direct mode — pass through
    _messageController.add(raw);
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

    if (_mode == ConnectionMode.relay && _encryptionReady && _cryptoService != null) {
      // Encrypt before sending
      final plaintext = jsonEncode(message);
      final envelope = _cryptoService!.encrypt(plaintext);
      _channel!.sink.add(jsonEncode(envelope));
    } else if (_mode == ConnectionMode.direct) {
      _channel!.sink.add(jsonEncode(message));
    }
    // In relay mode but encryption not ready — drop message (shouldn't happen in normal flow)
  }

  void sendPrompt(String text, {String? sessionId, String? priority, String? messageId}) {
    send({
      'type': 'prompt',
      'text': text,
      if (sessionId != null) 'sessionId': sessionId,
      if (priority != null) 'priority': priority,
      if (messageId != null) 'messageId': messageId,
    });
  }

  void sendAnswer(String questionId, Map<String, String> answers) {
    send({
      'type': 'answer',
      'questionId': questionId,
      'answers': answers,
    });
  }

  void sendNewSession({String? cwd}) {
    send({
      'type': 'new_session',
      if (cwd != null) 'cwd': cwd,
    });
  }

  void sendResumeSession(String sessionId) {
    send({
      'type': 'resume_session',
      'sessionId': sessionId,
    });
  }

  void sendListSessions() {
    send({'type': 'list_sessions'});
  }

  void sendDeleteSession(String sessionId) {
    send({
      'type': 'delete_session',
      'sessionId': sessionId,
    });
  }

  void sendClearContext(String sessionId) {
    send({
      'type': 'clear_context',
      'sessionId': sessionId,
    });
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
    send({'type': 'rewind', 'userMessageUuid': userMessageUuid, 'dryRun': dryRun});
  }

  void sendRewindConversation(String userMessageUuid, {bool dryRun = false, bool rewindFiles = true}) {
    send({'type': 'rewind_conversation', 'userMessageUuid': userMessageUuid, 'dryRun': dryRun, 'rewindFiles': rewindFiles});
  }

  void sendBranchFromMessage(String sessionId, String userMessageUuid) {
    send({'type': 'branch_from_message', 'sessionId': sessionId, 'userMessageUuid': userMessageUuid});
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
