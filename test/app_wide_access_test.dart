import 'dart:io';

import 'package:app/models/message.dart';
import 'package:app/services/chat_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    for (final name in [
      'com.socketagent.app/desktop_window',
      'flutter_tts',
      'dexterous.com/flutter/local_notifications',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
  });

  // A connector client's card: its sessionId is the client's activity log,
  // never the chat on screen.
  final card = {
    'type': 'computer_access_request',
    'requestId': 'req1',
    'sessionId': 'connector-1',
    'kind': 'approval',
    'source': {'name': 'agent-dev', 'publicKey': 'A'},
    'target': {'name': 'agent-dev', 'publicKey': 'A'},
    'action': 'board_access',
    'summary': 'Let Claude use the Wakespeed board.',
    'client': {'name': 'Claude', 'publicKey': 'C'},
    'approvalKey': 'C',
    'appWide': true,
    'expiresAt': DateTime.now()
        .add(const Duration(minutes: 5))
        .millisecondsSinceEpoch,
  };

  test('an app-wide card prompts outside any chat and clears when '
      'resolved', () async {
    final provider = ChatProvider();
    addTearDown(provider.dispose);
    await provider.settingsReady;
    final prompted = <ChatMessage>[];
    final sub = provider.appWideAccessEvents.listen(prompted.add);
    addTearDown(sub.cancel);

    await provider.handleServerMessageForTest(card, 'server-1');
    // The computer sends open cards again on reconnect: still one prompt.
    await provider.handleServerMessageForTest(card, 'server-1');
    await Future<void>.delayed(Duration.zero);
    expect(prompted.map((m) => m.questionId), ['req1']);
    expect(
      provider.messages.where((m) => m.type == MessageType.computerAccess),
      isEmpty,
    );

    // A notification tap closes dialogs, then prompts again while open.
    provider.promptOpenAppWideAccess();
    await Future<void>.delayed(Duration.zero);
    expect(prompted.map((m) => m.questionId), ['req1', 'req1']);

    await provider.handleServerMessageForTest({
      'type': 'computer_access_resolved',
      'requestId': 'req1',
      'sessionId': 'connector-1',
      'decision': 'once',
    }, 'server-1');
    expect(prompted.first.answered, isTrue);
    provider.promptOpenAppWideAccess();
    await Future<void>.delayed(Duration.zero);
    expect(prompted, hasLength(2), reason: 'nothing is open any more');
  });

  test('a card that arrives before the shell listens waits for it', () async {
    final provider = ChatProvider();
    addTearDown(provider.dispose);
    await provider.settingsReady;
    await provider.handleServerMessageForTest(card, 'server-1');
    expect(provider.takeUnpromptedAppWideAccess().map((m) => m.questionId), [
      'req1',
    ]);
    expect(provider.takeUnpromptedAppWideAccess(), isEmpty);
  });
}
