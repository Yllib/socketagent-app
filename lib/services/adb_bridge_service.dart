import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/server_config.dart';
import 'crypto_service.dart';
import 'secure_storage_service.dart';

enum AdbBridgeStatus {
  stopped,
  connecting,
  waitingForSidecar,
  connected,
  error,
}

class AdbCommandResult {
  const AdbCommandResult({
    required this.command,
    required this.ok,
    this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.message = '',
  });

  final String command;
  final bool ok;
  final int? exitCode;
  final String stdout;
  final String stderr;
  final String message;

  String get displayMessage {
    final parts = [
      if (stdout.trim().isNotEmpty) stdout.trim(),
      if (stderr.trim().isNotEmpty) stderr.trim(),
      if (message.trim().isNotEmpty) message.trim(),
    ];
    return parts.isEmpty
        ? (ok ? 'adb $command completed.' : 'adb $command failed.')
        : parts.join('\n');
  }
}

class _LocalAdbStreamState {
  _LocalAdbStreamState({required this.completer, this.onEvent});

  final Completer<Map<String, dynamic>> completer;
  final void Function(Map<String, dynamic> event)? onEvent;
}

class AdbBridgeService extends ChangeNotifier {
  static final AdbBridgeService instance = AdbBridgeService._();
  AdbBridgeService._() {
    _native.setMethodCallHandler(_handleNativeMethodCall);
  }

  static const _native = MethodChannel('com.socketagent.app/intent');
  static const int _binMarkerJson = 0x4a;
  static const int _binMarkerAdbData = 0x44;
  static const String _lastConnectPortKey = 'adb_bridge_last_connect_port_v1';
  static const String _lastDeviceLineKey = 'adb_bridge_last_device_line_v1';
  static const String _lastConnectedAtKey = 'adb_bridge_last_connected_at_v1';

  final _secureStorage = SecureStorageService();
  final Map<int, Socket> _streams = {};
  final Map<String, _LocalAdbStreamState> _localAdbStreams = {};
  final Map<String, Completer<AdbCommandResult>> _commandCompleters = {};
  final _pairingInputController = StreamController<String>.broadcast();
  Completer<Map<String, dynamic>>? _localAdbReconnectCompleter;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  CryptoService? _crypto;
  Timer? _reconnectTimer;
  Timer? _pairingInputTimer;
  int _generation = 0;
  bool _encryptionReady = false;
  bool _sidecarSupportsBinary = false;
  bool _manualStop = false;

  AdbBridgeStatus _status = AdbBridgeStatus.stopped;
  String? _error;
  ServerConfig? _server;
  String _targetHost = '127.0.0.1';
  int _targetPort = 0;
  String _channelName = 'adb';
  bool _localAdbPrefsLoaded = false;
  int? _lastLocalAdbConnectPort;
  String? _lastLocalAdbDeviceLine;
  DateTime? _lastLocalAdbConnectedAt;

  AdbBridgeStatus get status => _status;
  String? get error => _error;
  bool get isRunning => _status != AdbBridgeStatus.stopped;
  String get targetHost => _targetHost;
  int get targetPort => _targetPort;
  ServerConfig? get server => _server;
  int? get lastLocalAdbConnectPort => _lastLocalAdbConnectPort;
  String? get lastLocalAdbDeviceLine => _lastLocalAdbDeviceLine;
  DateTime? get lastLocalAdbConnectedAt => _lastLocalAdbConnectedAt;
  Stream<String> get pairingInputs => _pairingInputController.stream;

  Future<void> start({
    required ServerConfig server,
    required String targetHost,
    required int targetPort,
    String channelName = 'adb',
  }) async {
    if (!server.isRelayPaired) {
      throw StateError('ADB bridge requires a relay-paired server.');
    }
    if (targetHost.trim().isEmpty) {
      throw StateError('Target host is required.');
    }
    if (targetPort <= 0 || targetPort > 65535) {
      throw StateError('Target port must be between 1 and 65535.');
    }

    await stop();
    _manualStop = false;
    _server = server;
    _targetHost = targetHost.trim();
    _targetPort = targetPort;
    _channelName = channelName.trim().isEmpty ? 'adb' : channelName.trim();
    await _native.invokeMethod('startAdbBridgeForeground');
    _startPairingInputPolling();
    _connect();
  }

  Future<void> stop() async {
    _manualStop = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pairingInputTimer?.cancel();
    _pairingInputTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _generation++;
    await _channel?.sink.close();
    _channel = null;
    _crypto = null;
    _encryptionReady = false;
    _sidecarSupportsBinary = false;
    for (final completer in _commandCompleters.values) {
      if (!completer.isCompleted) {
        completer.complete(
          const AdbCommandResult(
            command: 'adb',
            ok: false,
            message: 'ADB bridge stopped.',
          ),
        );
      }
    }
    _commandCompleters.clear();
    for (final socket in _streams.values) {
      socket.destroy();
    }
    _streams.clear();
    for (final entry in _localAdbStreams.entries) {
      unawaited(localAdbStopStream(entry.key));
      if (!entry.value.completer.isCompleted) {
        entry.value.completer.complete(<String, dynamic>{
          'ok': false,
          'command': 'adb',
          'stdout': '',
          'stderr': '',
          'message': 'ADB bridge stopped.',
        });
      }
    }
    _localAdbStreams.clear();
    try {
      await _native.invokeMethod('stopAdbBridgeForeground');
    } catch (_) {}
    _setStatus(AdbBridgeStatus.stopped);
  }

  Future<void> openDeveloperSettings() async {
    await openWirelessDebuggingSettings();
  }

  Future<void> openWirelessDebuggingSettings() async {
    await _native.invokeMethod('openDeveloperSettings');
  }

  Future<bool> canDrawOverlays() async {
    return await _native.invokeMethod<bool>('canDrawOverlays') ?? false;
  }

  Future<void> requestOverlayPermission() async {
    await _native.invokeMethod('requestOverlayPermission');
  }

  Future<bool> showAdbPairingOverlay() async {
    await _native.invokeMethod('startAdbBridgeForeground');
    final shown =
        await _native.invokeMethod<bool>('showAdbPairingOverlay', {
          'port': '',
          'code': '',
          'timeoutSeconds': 900,
        }) ??
        false;
    if (shown) _startPairingInputPolling();
    return shown;
  }

  Future<Map<String, dynamic>> localAdbPair({
    required int port,
    required String code,
  }) async {
    final result = await _native.invokeMethod<Map<dynamic, dynamic>>(
      'localAdbPair',
      {'port': port.toString(), 'code': code.trim()},
    );
    return Map<String, dynamic>.from(result ?? const <String, dynamic>{});
  }

  Future<Map<String, dynamic>> localAdbConnect({required int port}) async {
    final result = await _invokeLocalAdbConnect(port);
    if (_isAdbResultOk(result)) {
      await _recordLocalAdbConnectPort(port);
      final devices = await _invokeLocalAdbDevices();
      await _recordLocalAdbDevices(devices);
    }
    return result;
  }

  Future<Map<String, dynamic>> localAdbShell(String command) async {
    await restoreLocalAdbConnection();
    final result = await _native.invokeMethod<Map<dynamic, dynamic>>(
      'localAdbShell',
      {'command': command},
    );
    return Map<String, dynamic>.from(result ?? const <String, dynamic>{});
  }

  Future<Map<String, dynamic>> localAdbCommand(
    List<String> args, {
    int timeoutSeconds = 30,
  }) async {
    await restoreLocalAdbConnection();
    final result = await _native.invokeMethod<Map<dynamic, dynamic>>(
      'localAdbCommand',
      {'args': args, 'timeoutSeconds': timeoutSeconds},
    );
    return Map<String, dynamic>.from(result ?? const <String, dynamic>{});
  }

  Future<Map<String, dynamic>> localAdbInstall(
    String apkPath, {
    List<String> args = const <String>[],
  }) async {
    await restoreLocalAdbConnection();
    final result = await _native.invokeMethod<Map<dynamic, dynamic>>(
      'localAdbInstall',
      {'apkPath': apkPath, 'args': args},
    );
    return Map<String, dynamic>.from(result ?? const <String, dynamic>{});
  }

  Future<Map<String, dynamic>> localAdbStream({
    required String streamId,
    required List<String> args,
    int timeoutSeconds = 30,
    int maxBytes = 1024 * 1024,
    void Function(Map<String, dynamic> event)? onEvent,
  }) async {
    await restoreLocalAdbConnection();
    final completer = Completer<Map<String, dynamic>>();
    _localAdbStreams[streamId] = _LocalAdbStreamState(
      completer: completer,
      onEvent: onEvent,
    );
    try {
      final startResult = await _native
          .invokeMethod<Map<dynamic, dynamic>>('localAdbStartStream', {
            'streamId': streamId,
            'args': args,
            'timeoutSeconds': timeoutSeconds,
            'maxBytes': maxBytes,
          });
      final started = Map<String, dynamic>.from(
        startResult ?? const <String, dynamic>{},
      );
      if (started['ok'] == false && !completer.isCompleted) {
        completer.complete(started);
      }
    } catch (e) {
      _localAdbStreams.remove(streamId);
      rethrow;
    }

    return completer.future.timeout(
      Duration(seconds: timeoutSeconds + 20),
      onTimeout: () async {
        await localAdbStopStream(streamId);
        _localAdbStreams.remove(streamId);
        return <String, dynamic>{
          'ok': false,
          'command': args.isEmpty ? 'adb' : args.first,
          'endpoint': args.length > 1 ? args.skip(1).join(' ') : '',
          'stdout': '',
          'stderr': '',
          'message': 'Timed out waiting for adb stream.',
        };
      },
    );
  }

  Future<bool> localAdbStopStream(String streamId) async {
    final stopped = await _native.invokeMethod<bool>('localAdbStopStream', {
      'streamId': streamId,
    });
    return stopped ?? false;
  }

  Future<Map<String, dynamic>> localAdbDevices() async {
    return restoreLocalAdbConnection();
  }

  Future<void> loadLocalAdbConnectionState() async {
    if (_localAdbPrefsLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    _lastLocalAdbConnectPort = prefs.getInt(_lastConnectPortKey);
    final deviceLine = prefs.getString(_lastDeviceLineKey);
    _lastLocalAdbDeviceLine = deviceLine != null && deviceLine.trim().isNotEmpty
        ? deviceLine.trim()
        : null;
    final connectedAt = prefs.getString(_lastConnectedAtKey);
    _lastLocalAdbConnectedAt = connectedAt == null
        ? null
        : DateTime.tryParse(connectedAt);
    _localAdbPrefsLoaded = true;
    notifyListeners();
  }

  Future<Map<String, dynamic>> restoreLocalAdbConnection({
    bool force = false,
  }) async {
    final existing = _localAdbReconnectCompleter;
    if (existing != null) return existing.future;

    final completer = Completer<Map<String, dynamic>>();
    _localAdbReconnectCompleter = completer;
    unawaited(() async {
      try {
        final result = await _restoreLocalAdbConnectionInner(force: force);
        if (!completer.isCompleted) completer.complete(result);
      } catch (e) {
        if (!completer.isCompleted) {
          completer.complete(<String, dynamic>{
            'ok': false,
            'command': 'devices',
            'stdout': '',
            'stderr': '',
            'message': e.toString(),
          });
        }
      } finally {
        if (identical(_localAdbReconnectCompleter, completer)) {
          _localAdbReconnectCompleter = null;
        }
      }
    }());
    return completer.future;
  }

  Future<Map<String, dynamic>> _restoreLocalAdbConnectionInner({
    required bool force,
  }) async {
    await loadLocalAdbConnectionState();

    final current = await _invokeLocalAdbDevices();
    if (!force && _isLocalAdbDeviceAttached(current)) {
      await _recordLocalAdbDevices(current);
      return current;
    }

    final port = _lastLocalAdbConnectPort;
    if (port == null) return current;

    await _invokeLocalAdbConnect(port);
    final afterConnect = await _invokeLocalAdbDevices();
    if (_isLocalAdbDeviceAttached(afterConnect)) {
      await _recordLocalAdbDevices(afterConnect);
      return afterConnect;
    }

    return afterConnect;
  }

  Future<Map<String, dynamic>> _invokeLocalAdbConnect(int port) async {
    final result = await _native.invokeMethod<Map<dynamic, dynamic>>(
      'localAdbConnect',
      {'port': port.toString()},
    );
    return Map<String, dynamic>.from(result ?? const <String, dynamic>{});
  }

  Future<Map<String, dynamic>> _invokeLocalAdbDevices() async {
    final result = await _native.invokeMethod<Map<dynamic, dynamic>>(
      'localAdbDevices',
    );
    return Map<String, dynamic>.from(result ?? const <String, dynamic>{});
  }

  bool _isAdbResultOk(Map<String, dynamic> result) => result['ok'] == true;

  bool _isLocalAdbDeviceAttached(Map<String, dynamic> result) {
    return _localAdbDeviceLine(result) != null;
  }

  String? _localAdbDeviceLine(Map<String, dynamic> result) {
    final stdout = result['stdout']?.toString() ?? '';
    for (final rawLine in const LineSplitter().convert(stdout)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('List of devices')) continue;
      if (RegExp(r'\bdevice\b').hasMatch(line) &&
          !RegExp(r'\b(?:offline|unauthorized)\b').hasMatch(line)) {
        return line;
      }
    }
    return null;
  }

  Future<void> _recordLocalAdbConnectPort(int port) async {
    await loadLocalAdbConnectionState();
    if (_lastLocalAdbConnectPort == port) return;
    _lastLocalAdbConnectPort = port;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastConnectPortKey, port);
    notifyListeners();
  }

  Future<void> _recordLocalAdbDevices(Map<String, dynamic> result) async {
    final deviceLine = _localAdbDeviceLine(result);
    if (deviceLine == null) return;
    await loadLocalAdbConnectionState();
    final now = DateTime.now();
    if (_lastLocalAdbDeviceLine == deviceLine &&
        _lastLocalAdbConnectedAt != null &&
        now.difference(_lastLocalAdbConnectedAt!) <
            const Duration(seconds: 5)) {
      return;
    }
    _lastLocalAdbDeviceLine = deviceLine;
    _lastLocalAdbConnectedAt = now;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastDeviceLineKey, deviceLine);
    await prefs.setString(_lastConnectedAtKey, now.toIso8601String());
    notifyListeners();
  }

  Future<void> _handleNativeMethodCall(MethodCall call) async {
    if (call.method != 'localAdbStreamEvent') return;
    final raw = call.arguments;
    if (raw is! Map) return;
    final event = Map<String, dynamic>.from(raw);
    final streamId = event['streamId']?.toString() ?? '';
    if (streamId.isEmpty) return;
    final state = _localAdbStreams[streamId];
    if (state == null) return;
    state.onEvent?.call(event);
    if (event['event'] == 'complete') {
      _localAdbStreams.remove(streamId);
      if (!state.completer.isCompleted) {
        state.completer.complete(event);
      }
    }
  }

  void setTarget({required String host, required int port}) {
    final cleanHost = host.trim();
    if (cleanHost.isEmpty) {
      throw StateError('Target host is required.');
    }
    if (port <= 0 || port > 65535) {
      throw StateError('Target port must be between 1 and 65535.');
    }
    _targetHost = cleanHost;
    _targetPort = port;
    notifyListeners();
  }

  Future<AdbCommandResult> pair({
    required String code,
    String? targetHost,
    int? targetPort,
  }) async {
    if (targetHost != null || targetPort != null) {
      setTarget(
        host: targetHost ?? _targetHost,
        port: targetPort ?? _targetPort,
      );
      _closeAllStreams();
    }
    return _sendAdbCommand('pair', {'code': code.trim()});
  }

  Future<AdbCommandResult> connect({
    String? targetHost,
    int? targetPort,
  }) async {
    if (targetHost != null || targetPort != null) {
      setTarget(
        host: targetHost ?? _targetHost,
        port: targetPort ?? _targetPort,
      );
      _closeAllStreams();
    }
    return _sendAdbCommand('connect');
  }

  Future<void> _connect() async {
    final server = _server;
    if (server == null || _manualStop) return;

    _setStatus(AdbBridgeStatus.connecting);
    _error = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _encryptionReady = false;
    _sidecarSupportsBinary = false;
    final gen = ++_generation;

    try {
      final subscriberToken = await _secureStorage.getSubscriberToken() ?? '';
      final crypto = CryptoService();
      await crypto.ensureKeyPair();
      crypto.setServerPublicKey(server.serverPubkey);
      _crypto = crypto;

      final uri = Uri.parse(server.relayUrl).replace(
        queryParameters: {
          'token': _bridgePairingToken(server.pairingToken),
          'role': 'phone',
          'subscriber_token': subscriberToken,
          'channel': _channelName,
        },
      );

      _channel = IOWebSocketChannel.connect(
        uri,
        pingInterval: const Duration(seconds: 20),
      );

      _subscription = _channel!.stream.listen(
        (data) {
          if (gen != _generation) return;
          try {
            if (data is String) {
              _handleText(jsonDecode(data) as Map<String, dynamic>);
            } else if (data is List<int>) {
              _handleBinary(Uint8List.fromList(data));
            }
          } catch (e) {
            debugPrint('[ADB Bridge] message error: $e');
          }
        },
        onError: (error) {
          if (gen != _generation) return;
          _setError(error.toString());
          _scheduleReconnect();
        },
        onDone: () {
          if (gen != _generation || _manualStop) return;
          _setStatus(AdbBridgeStatus.waitingForSidecar);
          _scheduleReconnect();
        },
      );
    } catch (e) {
      _setError(e.toString());
      _scheduleReconnect();
    }
  }

  void _handleText(Map<String, dynamic> raw) {
    final type = raw['type'];

    if (type == 'subscription_required') {
      _setError('Relay subscription required.');
      unawaited(stop());
      return;
    }

    if (type == 'peer_connected') {
      _setStatus(AdbBridgeStatus.waitingForSidecar);
      _sendKeyExchange();
      return;
    }

    if (type == 'peer_disconnected') {
      _encryptionReady = false;
      _sidecarSupportsBinary = false;
      _closeAllStreams();
      _setStatus(AdbBridgeStatus.waitingForSidecar);
      return;
    }

    if (type == 'key_exchange_ack') {
      _encryptionReady = true;
      _setStatus(AdbBridgeStatus.connected);
      _sendJson({
        'type': 'adb_bridge_client_capabilities',
        'binaryEnvelope': true,
      });
      return;
    }

    if (raw.containsKey('n') && raw.containsKey('c')) {
      final crypto = _crypto;
      if (crypto == null) return;
      try {
        final plaintext = crypto.decrypt(raw);
        _handleJson(jsonDecode(plaintext) as Map<String, dynamic>);
      } catch (e) {
        debugPrint('[ADB Bridge] decrypt failed: $e');
      }
    }
  }

  void _handleBinary(Uint8List bytes) {
    final crypto = _crypto;
    if (crypto == null) return;

    try {
      final plaintext = crypto.decryptBinary(bytes);
      if (plaintext.isEmpty) return;
      final marker = plaintext[0];
      if (marker == _binMarkerJson) {
        _handleJson(
          jsonDecode(utf8.decode(plaintext.sublist(1))) as Map<String, dynamic>,
        );
        return;
      }
      if (marker == _binMarkerAdbData) {
        if (plaintext.length < 5) return;
        final streamId =
            ((plaintext[1] << 24) & 0xffffffff) |
            (plaintext[2] << 16) |
            (plaintext[3] << 8) |
            plaintext[4];
        final socket = _streams[streamId];
        socket?.add(plaintext.sublist(5));
      }
    } catch (e) {
      debugPrint('[ADB Bridge] binary decrypt failed: $e');
    }
  }

  void _handleJson(Map<String, dynamic> msg) {
    switch (msg['type']) {
      case 'adb_bridge_server_capabilities':
        _sidecarSupportsBinary = msg['binaryEnvelope'] == true;
        _setStatus(AdbBridgeStatus.connected);
        break;
      case 'adb_command_result':
        _handleCommandResult(msg);
        break;
      case 'adb_stream_open':
        unawaited(_openAdbStream((msg['streamId'] as num).toInt()));
        break;
      case 'adb_stream_close':
        _closeStream((msg['streamId'] as num).toInt(), notifyPeer: false);
        break;
      case 'adb_data':
        final streamId = (msg['streamId'] as num).toInt();
        final socket = _streams[streamId];
        final data = msg['data'] as String? ?? '';
        if (socket != null && data.isNotEmpty) {
          socket.add(base64Decode(data));
        }
        break;
    }
  }

  void _handleCommandResult(Map<String, dynamic> msg) {
    final requestId = msg['requestId'] as String?;
    if (requestId == null) return;
    final completer = _commandCompleters.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    completer.complete(
      AdbCommandResult(
        command: msg['command'] as String? ?? 'adb',
        ok: msg['ok'] == true,
        exitCode: (msg['exitCode'] as num?)?.toInt(),
        stdout: msg['stdout'] as String? ?? '',
        stderr: msg['stderr'] as String? ?? '',
        message: msg['message'] as String? ?? '',
      ),
    );
  }

  Future<AdbCommandResult> _sendAdbCommand(
    String command, [
    Map<String, dynamic> extra = const {},
  ]) async {
    await _waitForConnected();
    final requestId = 'adb_${command}_${DateTime.now().millisecondsSinceEpoch}';
    final completer = Completer<AdbCommandResult>();
    _commandCompleters[requestId] = completer;
    _sendJson({
      'type': command == 'pair' ? 'adb_pair_request' : 'adb_connect_request',
      'requestId': requestId,
      ...extra,
    });
    return completer.future.timeout(
      const Duration(seconds: 40),
      onTimeout: () {
        _commandCompleters.remove(requestId);
        return AdbCommandResult(
          command: command,
          ok: false,
          message: 'Timed out waiting for adb $command.',
        );
      },
    );
  }

  Future<void> _waitForConnected() async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (_status == AdbBridgeStatus.connected && _encryptionReady) return;
      if (_status == AdbBridgeStatus.error) {
        throw StateError(_error ?? 'ADB bridge is not connected.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('Timed out waiting for the PC sidecar.');
  }

  void _startPairingInputPolling() {
    _pairingInputTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_drainPairingInputs()),
    );
    unawaited(_drainPairingInputs());
  }

  Future<void> _drainPairingInputs() async {
    try {
      final raw = await _native.invokeMethod<List<dynamic>>(
        'takeAdbPairingInputs',
      );
      if (raw == null) return;
      for (final item in raw) {
        final value = item?.toString().trim() ?? '';
        if (value.isNotEmpty) _pairingInputController.add(value);
      }
    } catch (e) {
      debugPrint('[ADB Bridge] pairing input poll failed: $e');
    }
  }

  Future<void> _openAdbStream(int streamId) async {
    try {
      final socket = await Socket.connect(
        _targetHost,
        _targetPort,
        timeout: const Duration(seconds: 8),
      );
      _streams[streamId] = socket;
      _sendJson({'type': 'adb_stream_opened', 'streamId': streamId});

      socket.listen(
        (data) => _sendAdbData(streamId, Uint8List.fromList(data)),
        onDone: () => _closeStream(streamId, notifyPeer: true),
        onError: (_) => _closeStream(streamId, notifyPeer: true),
        cancelOnError: true,
      );
    } catch (e) {
      _sendJson({
        'type': 'adb_stream_error',
        'streamId': streamId,
        'message': e.toString(),
      });
    }
  }

  void _closeStream(int streamId, {required bool notifyPeer}) {
    final socket = _streams.remove(streamId);
    if (socket == null) return;
    socket.destroy();
    if (notifyPeer) {
      _sendJson({'type': 'adb_stream_close', 'streamId': streamId});
    }
  }

  void _closeAllStreams() {
    for (final socket in _streams.values) {
      socket.destroy();
    }
    _streams.clear();
  }

  void _sendKeyExchange() {
    final crypto = _crypto;
    if (crypto == null || !crypto.hasKeyPair) return;
    _channel?.sink.add(
      jsonEncode({'type': 'key_exchange', 'pubkey': crypto.publicKeyBase64}),
    );
  }

  void _sendJson(Map<String, dynamic> message) {
    final crypto = _crypto;
    if (_channel == null || crypto == null || !_encryptionReady) return;

    final plaintext = jsonEncode(message);
    if (_sidecarSupportsBinary) {
      final jsonBytes = utf8.encode(plaintext);
      final payload = Uint8List(jsonBytes.length + 1);
      payload[0] = _binMarkerJson;
      payload.setRange(1, payload.length, jsonBytes);
      _channel!.sink.add(crypto.encryptBinary(payload));
    } else {
      _channel!.sink.add(jsonEncode(crypto.encrypt(plaintext)));
    }
  }

  void _sendAdbData(int streamId, Uint8List data) {
    final crypto = _crypto;
    if (_channel == null || crypto == null || !_encryptionReady) return;

    if (!_sidecarSupportsBinary) {
      _sendJson({
        'type': 'adb_data',
        'streamId': streamId,
        'data': base64Encode(data),
      });
      return;
    }

    final payload = Uint8List(data.length + 5);
    payload[0] = _binMarkerAdbData;
    payload[1] = (streamId >> 24) & 0xff;
    payload[2] = (streamId >> 16) & 0xff;
    payload[3] = (streamId >> 8) & 0xff;
    payload[4] = streamId & 0xff;
    payload.setRange(5, payload.length, data);
    _channel!.sink.add(crypto.encryptBinary(payload));
  }

  void _scheduleReconnect() {
    if (_manualStop) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), _connect);
  }

  void _setStatus(AdbBridgeStatus status) {
    _status = status;
    if (status != AdbBridgeStatus.error) _error = null;
    notifyListeners();
  }

  void _setError(String error) {
    _error = error;
    _status = AdbBridgeStatus.error;
    notifyListeners();
  }

  String _bridgePairingToken(String pairingToken) {
    final digest = crypto.sha256.convert(
      utf8.encode('$pairingToken:adb-bridge'),
    );
    return 'adb-$digest';
  }
}
