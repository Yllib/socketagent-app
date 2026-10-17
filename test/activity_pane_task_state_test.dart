import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/windows_local_server.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pinenacl/x25519.dart';

/// Drives a ChatProvider through a loopback server so the private task
/// handlers run exactly as they do for a live session.
Future<void> withConnectedProvider(
  Future<void> Function(
    ChatProvider provider,
    Future<void> Function(Map<String, dynamic> event) send,
  )
  body,
) async {
  final cache = await Directory.systemTemp.createTemp('activity-pane-test-');
  final local = await WindowsLocalServer().discover();
  SharedPreferences.setMockInitialValues({
    'windows_local_servers_seen': [
      for (final config in local) '${config.port}:${config.serverPubkey}',
    ],
  });
  final clientKey = PrivateKey.generate();
  final serverKey = PrivateKey.generate();
  final box = Box(myPrivateKey: serverKey, theirPublicKey: clientKey.publicKey);
  FlutterSecureStorage.setMockInitialValues({
    'relay_secret_key': base64Encode(clientKey.asTypedList),
    'relay_public_key': base64Encode(clientKey.publicKey.asTypedList),
  });
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (_) async => cache.path,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('flutter_tts'),
    (_) async => null,
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final connected = Completer<WebSocket>();
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    socket.listen((_) {});
    connected.complete(socket);
  });
  final provider = ChatProvider();
  WebSocket? socket;
  try {
    await provider.settingsReady;
    await provider.addServer(
      ServerConfig(
        id: 'pane-server',
        name: 'Pane',
        host: '127.0.0.1',
        port: server.port,
        token: 'test-token',
        serverPubkey: base64Encode(serverKey.publicKey.asTypedList),
      ),
    );
    socket = await connected.future.timeout(const Duration(seconds: 5));
    socket.add(jsonEncode({'type': 'key_exchange_ack'}));
    provider.resumeSession('pane-root', serverId: 'pane-server');
    Future<void> send(Map<String, dynamic> event) async {
      final encrypted = box.encrypt(
        Uint8List.fromList(
          utf8.encode(jsonEncode({'sessionId': 'pane-root', ...event})),
        ),
      );
      socket!.add(
        jsonEncode({
          'n': base64Encode(encrypted.nonce),
          'c': base64Encode(encrypted.cipherText),
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }

    await send({'type': 'session_state_changed', 'state': 'running'});
    await body(provider, send);
  } finally {
    provider.dispose();
    await socket?.close();
    await server.close(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await cache.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterLocalNotificationsPlatform.instance =
      AndroidFlutterLocalNotificationsPlugin();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter/local_notifications'),
        (call) async => call.method == 'initialize' ? true : null,
      );

  test('a cancelled tool call ends its subagent instead of restarting it', () {
    return withConnectedProvider((provider, send) async {
      await send({
        'type': 'tool_call',
        'tool': 'Agent',
        'toolUseId': 'agent-a',
        'input': {'description': 'Audit', 'subagent_type': 'Explore'},
      });
      expect(provider.subagentTasks['agent-a']?['status'], 'running');
      await send({
        'type': 'task_notification',
        'taskId': '',
        'status': 'cancelled',
        'summary': 'Claude Code cancelled this tool call before running it.',
        'originToolUseId': 'agent-a',
      });
      expect(provider.subagentTasks['agent-a']?['status'], 'stopped');
      expect(provider.subagentTasks['agent-a']?['isBackgrounded'], false);
      expect(provider.backgroundTasks, isEmpty);
    });
  });

  test('a foreground command gets a pane row only once it is backgrounded', () {
    return withConnectedProvider((provider, send) async {
      await send({
        'type': 'tool_call',
        'tool': 'Bash',
        'toolUseId': 'bash-t',
        'input': {
          'command': 'npm test && echo done',
          'description': 'Run tests',
        },
      });
      await send({
        'type': 'task_started',
        'taskId': 'b1',
        'toolUseId': 'bash-t',
        'description': 'Run tests',
        'taskType': 'local_bash',
        'isBackgrounded': false,
      });
      expect(provider.backgroundTasks, isEmpty);
      await send({
        'type': 'task_updated',
        'taskId': 'b1',
        'toolUseId': 'bash-t',
        'patch': {'isBackgrounded': true},
      });
      expect(provider.backgroundTasks['b1']?['summary'], 'Run tests');
      expect(provider.backgroundTasks['b1']?['originToolUseId'], 'bash-t');
      final card = provider.messages.firstWhere((m) => m.toolUseId == 'bash-t');
      expect(card.isBackgrounded, true);
      expect(card.backgroundTaskId, 'b1');
      await send({
        'type': 'task_notification',
        'taskId': 'b1',
        'status': 'completed',
        'summary': 'Background command "npm test" completed',
        'originToolUseId': 'bash-t',
      });
      expect(provider.backgroundTasks, isEmpty);
      expect(card.toolStreaming, false);
    });
  });

  test('the heartbeat settles background work the server no longer runs', () {
    return withConnectedProvider((provider, send) async {
      await send({
        'type': 'tool_call',
        'tool': 'Agent',
        'toolUseId': 'agent-bg',
        'input': {'description': 'Long audit', 'subagent_type': 'Explore'},
      });
      await send({
        'type': 'task_started',
        'taskId': 'a1',
        'toolUseId': 'agent-bg',
        'description': 'Long audit',
        'taskType': 'local_agent',
        'subagentType': 'Explore',
        'isBackgrounded': true,
      });
      await send({
        'type': 'tool_call',
        'tool': 'Agent',
        'toolUseId': 'agent-fg',
        'input': {'description': 'Quick check', 'subagent_type': 'Explore'},
      });
      await send({
        'type': 'task_started',
        'taskId': 'w1',
        'toolUseId': 'workflow-t',
        'description': 'Review changes',
        'taskType': 'local_workflow',
        'workflowName': 'review',
        'isBackgrounded': true,
      });
      Future<void> heartbeat(List<String> taskIds) => send({
        'type': 'status_sync',
        'running': true,
        'runningSessions': ['pane-root'],
        'backgroundTaskIds': taskIds,
      });
      await heartbeat(['a1', 'w1']);
      expect(provider.subagentTasks['agent-bg']?['status'], 'running');
      expect(provider.workflowTasks['w1']?['status'], 'running');

      // A restarted server reports nothing it never registered.
      await heartbeat([]);
      expect(provider.subagentTasks['agent-bg']?['status'], 'stopped');
      expect(provider.subagentTasks['agent-bg']?['isBackgrounded'], false);
      expect(provider.workflowTasks['w1']?['status'], 'stopped');
      // Foreground subagents are not in the heartbeat and are left alone.
      expect(provider.subagentTasks['agent-fg']?['status'], 'running');
      final card = provider.messages.firstWhere(
        (m) => m.toolUseId == 'agent-bg',
      );
      expect(card.toolStreaming, false);
      expect(card.toolInput?['_task_status'], 'stopped');
    });
  });
}
