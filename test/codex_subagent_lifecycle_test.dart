import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/windows_local_server.dart';
import 'package:app/services/session_transcript_cache.dart';
import 'package:app/models/message_reconciliation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pinenacl/x25519.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cached terminal outcomes survive serialization and acknowledgement deduplication',
    () {
      final event = <String, dynamic>{
        'type': 'tool_result',
        'sessionId': 'root',
        'toolUseId': 'codex-subagent:child',
        'entryId': 'result',
        'sessionSeq': 5,
        'revision': 1,
        'output': 'Agent ended',
        'subagentStatus': 'interrupted',
      };
      final restored =
          jsonDecode(jsonEncode(transcriptCacheEntryFromServerEvent(event)))
              as Map;
      expect(subagentDisplayStatus(restored['subagentStatus']), 'stopped');
      expect(
        acknowledgedSessionEventKey(event),
        isNot(
          acknowledgedSessionEventKey({
            ...event,
            'subagentStatus': 'completed',
          }),
        ),
      );
    },
  );
  test(
    'native terminal outcomes survive snapshots, reopening, and history',
    () async {
      final cache = await Directory.systemTemp.createTemp('subagent-ui-test-');
      final local = await WindowsLocalServer().discover();
      SharedPreferences.setMockInitialValues({
        'windows_local_servers_seen': [
          for (final config in local) '${config.port}:${config.serverPubkey}',
        ],
      });
      final clientKey = PrivateKey.generate();
      final serverKey = PrivateKey.generate();
      final box = Box(
        myPrivateKey: serverKey,
        theirPublicKey: clientKey.publicKey,
      );
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
            id: 'audit-server',
            name: 'Audit',
            host: '127.0.0.1',
            port: server.port,
            token: 'test-token',
            serverPubkey: base64Encode(serverKey.publicKey.asTypedList),
          ),
        );
        socket = await connected.future.timeout(const Duration(seconds: 5));
        socket.add(jsonEncode({'type': 'key_exchange_ack'}));
        provider.resumeSession('audit-root', serverId: 'audit-server');
        Future<void> send(Map<String, dynamic> event) async {
          final encrypted = box.encrypt(
            Uint8List.fromList(
              utf8.encode(jsonEncode({'sessionId': 'audit-root', ...event})),
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

        const id = 'codex-subagent:child';
        Map<String, dynamic> task(String status) => {
          'agentId': 'child',
          'toolUseId': id,
          'description': 'Audit child',
          'subagentType': 'codex',
          'status': status,
        };
        Future<void> snapshot(String? status) => send({
          'type': 'active_subagents',
          'backend': 'codex',
          'replace': true,
          'tasks': [if (status != null) task(status)],
        });
        await send({'type': 'session_state_changed', 'state': 'running'});
        await send({
          'type': 'tool_call',
          'tool': 'Agent',
          'toolUseId': id,
          'input': {'description': 'Audit child', 'subagent_type': 'codex'},
        });
        await snapshot('running');
        expect(provider.subagentTasks[id]?['status'], 'running');
        await send({
          'type': 'tool_result',
          'toolUseId': id,
          'output': 'failure details',
          'subagentStatus': 'errored',
        });
        await send({
          'type': 'subagent_result',
          'parentToolUseId': id,
          'content': 'failure details',
          'subagentStatus': 'errored',
        });
        await snapshot('errored');
        expect(provider.subagentTasks[id]?['status'], 'failed');
        await snapshot(
          null,
        ); // older server's empty replacement must not erase failure
        expect(provider.subagentTasks[id]?['status'], 'failed');
        provider.dismissSubagent(id);
        await snapshot('running');
        expect(provider.subagentTasks[id]?['dismissed'], false);
        expect(provider.subagentTasks[id]?['status'], 'running');
        await snapshot('interrupted');
        expect(provider.subagentTasks[id]?['status'], 'stopped');
        expect(
          provider.messages
              .where((m) => m.toolUseId == id)
              .last
              .toolInput?['_task_status'],
          'stopped',
        );

        provider.resumeSession('audit-root', serverId: 'audit-server');
        final history = <String, dynamic>{
          'type': 'session_history',
          'messages': [
            {
              'role': 'tool_call',
              'entryId': 'history-agent',
              'sessionSeq': 1,
              'revision': 1,
              'toolName': 'Agent',
              'toolUseId': id,
              'content': 'Audit child',
              'toolInput': {
                'description': 'Audit child',
                'subagent_type': 'codex',
              },
              'timestamp': '2026-09-13T22:00:00Z',
            },
            {
              'role': 'tool_result',
              'entryId': 'history-result',
              'sessionSeq': 2,
              'revision': 1,
              'toolUseId': id,
              'content': 'failure details',
              'toolOutput': 'failure details',
              'subagentStatus': 'errored',
              'timestamp': '2026-09-13T22:01:00Z',
            },
          ],
          'total': 2,
          'offset': 0,
        };
        await send(history);
        expect(provider.subagentTasks[id]?['status'], 'failed');
        provider.resumeSession('audit-root', serverId: 'audit-server');
        await snapshot('running');
        await send(history);
        expect(provider.subagentTasks[id]?['status'], 'running');
        expect(
          provider.messages.where((m) => m.toolUseId == id).last.toolStreaming,
          true,
        );
        await send({
          'type': 'rewind_conversation_result',
          'sessionId': 'another-session',
          'success': true,
          'userMessageUuid': 'outside-window',
          'rewindIncludesTarget': true,
        });
        expect(provider.subagentTasks[id]?['status'], 'running');
        await send({
          'type': 'rewind_conversation_result',
          'success': true,
          'userMessageUuid': 'outside-window',
          'rewindIncludesTarget': true,
          'messagesRemoved': 2,
        });
        await send({
          'type': 'session_history',
          'historyKind': 'rewind',
          'messages': [],
          'total': 0,
          'offset': 0,
        });
        expect(provider.subagentTasks, isEmpty);
        expect(provider.messages.where((m) => m.toolUseId == id), isEmpty);
        Map<String, dynamic>? diskCache;
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        do {
          diskCache = await SessionTranscriptCache().load('audit-server', 'audit-root');
          if (diskCache != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        } while (DateTime.now().isBefore(deadline));
        expect(diskCache?['messages'], isEmpty);
      } finally {
        provider.dispose();
        await socket?.close();
        await server.close(force: true);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await cache.delete(recursive: true);
      }
    },
  );
}
