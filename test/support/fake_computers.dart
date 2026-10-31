import 'package:app/models/message.dart';
import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/connection_manager.dart';
import 'package:app/services/websocket_service.dart' show ConnectionStatus;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Reports a fixed link state per computer and never opens a socket.
class FakeConnectionManager extends ConnectionManager {
  FakeConnectionManager(this.statuses);

  final Map<String, ConnectionStatus> statuses;

  @override
  ConnectionStatus statusOf(String serverId) =>
      statuses[serverId] ?? ConnectionStatus.disconnected;

  @override
  void reconnectServer(String serverId, {DateTime? since}) {}
}

/// A provider whose computers, sessions and per-computer facts are fixed, so
/// the Computers tab can be exercised without sockets.
class FakeComputersProvider extends ChatProvider {
  FakeComputersProvider({
    required this.configs,
    Map<String, ConnectionStatus> statuses = const {},
    this.fakeSessions = const [],
    this.runtime = const {},
    this.backends = const {},
    this.warnings = const {},
    this.push = const {},
    this.health = const {},
  }) : fakeConnMgr = FakeConnectionManager(statuses);

  final List<ServerConfig> configs;
  final FakeConnectionManager fakeConnMgr;
  final List<Session> fakeSessions;
  final Map<String, Map<String, dynamic>> runtime;
  final Map<String, List<String>> backends;
  final Map<String, Map<String, dynamic>> warnings;
  final Map<String, bool> push;
  final Map<String, List<Map<String, dynamic>>> health;

  @override
  List<ServerConfig> get serverConfigs => configs;

  @override
  ConnectionManager get connMgr => fakeConnMgr;

  @override
  List<Session> get sessions => fakeSessions;

  @override
  Map<String, dynamic> serverRuntimeInfo(String serverId) =>
      runtime[serverId] ?? const {};

  @override
  List<String> backendsForServer(String? serverId) =>
      backends[serverId] ?? const ['claude'];

  @override
  Map<String, dynamic>? backendWarningForServer(String serverId) =>
      warnings[serverId];

  @override
  bool isPushRegisteredForServer(String serverId) => push[serverId] ?? false;

  @override
  List<Map<String, dynamic>> backendHealthForServer(String serverId) =>
      health[serverId] ?? const [];
}

ServerConfig fakeConfig(
  String id,
  String name, {
  String host = '',
  int port = 8085,
  bool useRelay = false,
  bool expectedOnline = false,
  int? colorValue,
  String defaultCwd = '',
}) => ServerConfig(
  id: id,
  name: name,
  host: host,
  port: port,
  token: host.isEmpty ? '' : 'token',
  useRelay: useRelay,
  expectedOnline: expectedOnline,
  relayUrl: useRelay ? 'wss://relay.test' : '',
  pairingToken: useRelay ? 'pair' : '',
  serverPubkey: 'pubkey',
  colorValue: colorValue,
  defaultCwd: defaultCwd,
);

Session fakeSession(
  String id,
  String serverId, {
  bool running = false,
  String backend = 'claude',
}) => Session(
  id: id,
  title: 'Session $id',
  cwd: '/home/billy/agents',
  createdAt: DateTime(2026, 10, 31, 9),
  lastActive: DateTime(2026, 10, 31, 14),
  messagePreview: '',
  running: running,
  serverId: serverId,
  backend: backend,
);

Directory? _supportDir;

/// The platform channels a bare [ChatProvider] touches while it loads.
void mockProviderChannels() {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  _supportDir = Directory.systemTemp.createTempSync('computers-test-');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('flutter_tts'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (_) async => _supportDir!.path,
  );
}

void unmockProviderChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    null,
  );
  _supportDir?.deleteSync(recursive: true);
  _supportDir = null;
}
