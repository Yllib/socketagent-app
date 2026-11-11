// The session header's context meter, pumped inside the real HomeScreen.
import 'package:app/screens/home_screen.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/websocket_service.dart' show ConnectionStatus;
import 'package:app/widgets/context_window_breakdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_tasks.dart';

/// A Claude session holding 191k tokens that compacts at 322k of a 355k
/// window, on a model whose own window is 1M.
class _Provider extends FakeTasksProvider {
  @override
  Map<String, dynamic>? get lastUsage => const {
    'inputTokens': 1200,
    'cacheReadTokens': 189800,
    'cacheCreateTokens': 0,
    'outputTokens': 12400,
    'contextWindow': 1000000,
  };
  @override
  Map<String, dynamic>? get contextUsage => const {
    'sessionId': 's1',
    'totalTokens': 191000,
    'maxTokens': 355000,
    'autoCompactThreshold': 322000,
    'isAutoCompactEnabled': true,
    'model': 'claude-fable-5-2',
  };
  @override
  int? get claudeAutoCompactWindowEffective => 355000;
  @override
  String? get activeSessionId => 's1';
  @override
  String? get activeSessionBackend => 'claude';
  @override
  String? get activeSessionCwd => '/home/dev/project';
  @override
  ConnectionStatus get connectionStatus => ConnectionStatus.connected;
  @override
  Future<Map<String, dynamic>?> requestClaudeUsage() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterLocalNotificationsPlatform.instance =
      AndroidFlutterLocalNotificationsPlugin();
  setUp(() {
    mockProviderChannels();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dexterous.com/flutter/local_notifications'),
          (call) async => call.method == 'initialize' ? true : null,
        );
  });
  tearDown(unmockProviderChannels);

  testWidgets('the header meter measures toward compaction and opens the '
      'dialog where the limit changes', (tester) async {
    tester.view.physicalSize = const Size(412, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>(
        create: (_) => _Provider(),
        lazy: false,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    final header = find.byKey(const ValueKey('session-header-usage'));
    Finder inHeader(Finder finder) =>
        find.descendant(of: header, matching: finder);
    // 191k of the 322k compaction point, not of the model's 1M.
    expect(inHeader(find.text('59%')), findsOneWidget);
    expect(inHeader(find.text('191k / 322k')), findsOneWidget);
    expect(inHeader(find.byType(ContextMeterBar)), findsOneWidget);
    // Tall enough to hit with a thumb.
    expect(tester.getSize(header).height, greaterThanOrEqualTo(48));

    await tester.tap(header);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('59% used'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('context-change-limit')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('This session'), findsOneWidget);
  });
}
