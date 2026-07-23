import 'package:app/models/composer_attachment.dart';
import 'package:app/models/message.dart';
import 'package:app/widgets/chat_view.dart';
import 'package:app/widgets/message_bubble.dart';
import 'package:app/widgets/tool_output_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('fills a short initial history page automatically', (
    WidgetTester tester,
  ) async {
    final key = GlobalKey<_HistoryHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _HistoryHarness(
          key: key,
          initiallyLoadingHistory: true,
          messageCount: 1,
        ),
      ),
    );

    key.currentState!.finishInitialLoad();
    await tester.pump();
    await tester.pump();

    expect(key.currentState!.loadMoreCalls, 1);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('prefetches near the oldest row and preserves the viewport', (
    WidgetTester tester,
  ) async {
    final key = GlobalKey<_HistoryHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _HistoryHarness(
          key: key,
          initiallyLoadingHistory: false,
          messageCount: 80,
        ),
      ),
    );
    await tester.pump();

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(position.maxScrollExtent - 10);
    await tester.pump();

    expect(key.currentState!.loadMoreCalls, 1);
    final anchoredPixels = position.pixels;

    key.currentState!.completeLoad(prependCount: 20);
    await tester.pump();
    await tester.pump();

    expect(position.pixels, closeTo(anchoredPixels, 0.5));
  });

  testWidgets('authoritative history replacement discards the old extent', (
    WidgetTester tester,
  ) async {
    final key = GlobalKey<_HistoryHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _HistoryHarness(
          key: key,
          initiallyLoadingHistory: false,
          messageCount: 160,
        ),
      ),
    );
    await tester.pump();

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(position.maxScrollExtent * 0.7);
    await tester.pump();
    expect(position.pixels, greaterThan(0));

    // Reproduce a resume whose cached delta exceeded the wire budget: the
    // authoritative reply replaces a long cached window with a bounded tail
    // while the same ChatView remains mounted.
    key.currentState!.replaceHistoryWindow(messageCount: 6);
    await tester.pump();
    await tester.pump();

    expect(position.pixels, closeTo(position.minScrollExtent, 0.5));
    expect(find.text('History response 5'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('streaming text preserves the viewport while the reader is up', (
    WidgetTester tester,
  ) async {
    final key = GlobalKey<_HistoryHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _HistoryHarness(
          key: key,
          initiallyLoadingHistory: false,
          messageCount: 40,
        ),
      ),
    );
    await tester.pump();

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    key.currentState!.appendStreamingText(30);
    await tester.pump();
    await tester.pump();
    position.jumpTo(8);
    await tester.pump();
    final anchorBefore = _topVisibleMessage(tester);
    final pixelsBefore = position.pixels;

    key.currentState!.appendStreamingText(30);
    await tester.pump();
    await tester.pump();

    expect(position.pixels, greaterThan(pixelsBefore));
    expect(
      _messageTop(tester, anchorBefore.id),
      closeTo(anchorBefore.top, 0.5),
    );
  });

  testWidgets('streaming text does not fight an active reader drag', (
    WidgetTester tester,
  ) async {
    final key = GlobalKey<_HistoryHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _HistoryHarness(
          key: key,
          initiallyLoadingHistory: false,
          messageCount: 40,
        ),
      ),
    );
    await tester.pump();

    final scrollable = find.byType(Scrollable).first;
    final position = tester.state<ScrollableState>(scrollable).position;
    key.currentState!.appendStreamingText(30);
    await tester.pump();
    position.jumpTo(40);
    await tester.pump();

    final gesture = await tester.startGesture(tester.getCenter(scrollable));
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();
    final pixelsDuringDrag = position.pixels;

    key.currentState!.appendStreamingText(30);
    await tester.pump();

    expect(position.pixels, closeTo(pixelsDuringDrag, 0.5));

    await gesture.up();
    await tester.pumpAndSettle();
    final anchorBefore = _topVisibleMessage(tester);

    key.currentState!.appendStreamingText(30);
    await tester.pump();
    await tester.pump();

    expect(
      _messageTop(tester, anchorBefore.id),
      closeTo(anchorBefore.top, 0.5),
    );
  });

  testWidgets('expanding an image card never changes the reader offset', (
    WidgetTester tester,
  ) async {
    final key = GlobalKey<_HistoryHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _HistoryHarness(
          key: key,
          initiallyLoadingHistory: false,
          messageCount: 40,
        ),
      ),
    );
    await tester.pump();

    key.currentState!.appendPendingImageCard();
    await tester.pump();
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(25);
    await tester.pump();
    final pixelsBefore = position.pixels;

    await tester.tap(find.byType(ToolOutputBlock));
    await tester.pump();
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(ToolOutputBlock),
        matching: find.byIcon(Icons.expand_less),
      ),
      findsOneWidget,
    );
    expect(position.pixels, closeTo(pixelsBefore, 0.5));
  });

  testWidgets('returning to a session does not restore an expanded image', (
    WidgetTester tester,
  ) async {
    final key = GlobalKey<_HistoryHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _HistoryHarness(
          key: key,
          initiallyLoadingHistory: false,
          messageCount: 4,
        ),
      ),
    );
    await tester.pump();

    key.currentState!.appendPendingImageCard();
    await tester.pump();
    await tester.tap(find.byType(ToolOutputBlock));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(ToolOutputBlock),
        matching: find.byIcon(Icons.expand_less),
      ),
      findsOneWidget,
    );

    key.currentState!.switchSession();
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(ToolOutputBlock),
        matching: find.byIcon(Icons.expand_more),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ToolOutputBlock),
        matching: find.byIcon(Icons.expand_less),
      ),
      findsNothing,
    );
  });

  testWidgets('streaming chat keeps an opaque viewport with isolated rows', (
    WidgetTester tester,
  ) async {
    final key = GlobalKey<_HistoryHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _HistoryHarness(
          key: key,
          initiallyLoadingHistory: false,
          messageCount: 40,
        ),
      ),
    );
    await tester.pump();

    ColoredBox surface() => tester.widget<ColoredBox>(
      find.byKey(const ValueKey('chat-scroll-surface')),
    );
    ListView messageList() =>
        tester.widget<ListView>(find.byType(ListView).first);

    expect(surface().color.a, 1.0);
    expect(
      (messageList().childrenDelegate as SliverChildBuilderDelegate)
          .addRepaintBoundaries,
      isTrue,
    );

    key.currentState!.appendStreamingText(40);
    await tester.pump();
    key.currentState!.switchSession();
    await tester.pump();

    expect(surface().color.a, 1.0);
    expect(find.byKey(const ValueKey('chat-surface')), findsOneWidget);
  });

  testWidgets('live insertions retain stable sliver row ownership', (
    WidgetTester tester,
  ) async {
    final key = GlobalKey<_HistoryHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _HistoryHarness(
          key: key,
          initiallyLoadingHistory: false,
          messageCount: 8,
        ),
      ),
    );
    await tester.pump();

    final retainedMessage = key.currentState!.messages[5];
    final retainedKey = ValueKey<String>(
      'message-row:text:${retainedMessage.id}::',
    );
    final delegate =
        tester.widget<ListView>(find.byType(ListView).first).childrenDelegate
            as SliverChildBuilderDelegate;
    expect(delegate.findChildIndexCallback, isNotNull);
    expect(delegate.findChildIndexCallback!(retainedKey), 2);

    key.currentState!.insertRecoveredToolRows(beforeIndex: 6);
    await tester.pump();

    final updatedDelegate =
        tester.widget<ListView>(find.byType(ListView).first).childrenDelegate
            as SliverChildBuilderDelegate;
    expect(updatedDelegate.findChildIndexCallback!(retainedKey), 4);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is MessageBubble && widget.message.id == retainedMessage.id,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('app resume releases a pointer-blocking scroll activity', (
    WidgetTester tester,
  ) async {
    final key = GlobalKey<_HistoryHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _HistoryHarness(
          key: key,
          initiallyLoadingHistory: false,
          messageCount: 80,
        ),
      ),
    );
    key.currentState!.appendPendingImageCard();
    await tester.pump();

    final list = find.byType(ListView).first;
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(position.minScrollExtent);
    final drivenScroll = position.animateTo(
      position.maxScrollExtent,
      duration: const Duration(seconds: 10),
      curve: Curves.linear,
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(position.isScrollingNotifier.value, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await drivenScroll;

    final beforeDrag = position.pixels;
    await tester.drag(list, const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(beforeDrag));

    position.jumpTo(position.minScrollExtent);
    await tester.pump();
    await tester.tap(find.byType(ToolOutputBlock));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(ToolOutputBlock),
        matching: find.byIcon(Icons.expand_less),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

({String id, double top}) _topVisibleMessage(WidgetTester tester) {
  ({String id, double top})? best;
  for (final bubble in tester.widgetList<MessageBubble>(
    find.byType(MessageBubble),
  )) {
    final finder = find.byWidgetPredicate(
      (widget) =>
          widget is MessageBubble && widget.message.id == bubble.message.id,
    );
    final top = tester.getTopLeft(finder).dy;
    final bottom = tester.getBottomLeft(finder).dy;
    if (bottom <= 0 || top >= 600) continue;
    if (best == null || top < best.top) {
      best = (id: bubble.message.id, top: top);
    }
  }
  return best!;
}

double _messageTop(WidgetTester tester, String id) {
  final finder = find.byWidgetPredicate(
    (widget) => widget is MessageBubble && widget.message.id == id,
  );
  return tester.getTopLeft(finder).dy;
}

class _HistoryHarness extends StatefulWidget {
  const _HistoryHarness({
    super.key,
    required this.initiallyLoadingHistory,
    required this.messageCount,
  });

  final bool initiallyLoadingHistory;
  final int messageCount;

  @override
  State<_HistoryHarness> createState() => _HistoryHarnessState();
}

class _HistoryHarnessState extends State<_HistoryHarness> {
  late bool isLoadingHistory;
  bool isLoadingMore = false;
  bool hasMoreHistory = true;
  int loadMoreCalls = 0;
  int historyWindowRevision = 0;
  String sessionStorageKey = 'server:session-1';
  late List<ChatMessage> messages;

  @override
  void initState() {
    super.initState();
    isLoadingHistory = widget.initiallyLoadingHistory;
    messages = List.generate(widget.messageCount, _message);
  }

  ChatMessage _message(int index) => ChatMessage(
    id: 'message-$index',
    sender: MessageSender.assistant,
    type: MessageType.text,
    timestamp: DateTime(2026, 1, 1).add(Duration(seconds: index)),
    textContent: 'History response $index',
  );

  void finishInitialLoad() {
    setState(() => isLoadingHistory = false);
  }

  void _loadMore() {
    if (isLoadingMore) return;
    setState(() {
      isLoadingMore = true;
      loadMoreCalls++;
    });
  }

  void completeLoad({required int prependCount}) {
    setState(() {
      messages = [
        ...List.generate(
          prependCount,
          (index) => _message(-prependCount + index),
        ),
        ...messages,
      ];
      isLoadingMore = false;
      hasMoreHistory = false;
    });
  }

  void replaceHistoryWindow({required int messageCount}) {
    setState(() {
      messages = List.generate(messageCount, _message);
      historyWindowRevision++;
      hasMoreHistory = true;
      isLoadingMore = false;
    });
  }

  void appendStreamingText(int lineCount) {
    final previous = messages.last;
    setState(() {
      messages = [
        ...messages.take(messages.length - 1),
        ChatMessage(
          id: previous.id,
          sender: previous.sender,
          type: previous.type,
          timestamp: previous.timestamp,
          textContent:
              '${previous.textContent}\n${List.generate(lineCount, (index) => 'Streaming line $index').join('\n')}',
          streamId: 'streaming-tail',
          revision: previous.revision + 1,
        ),
      ];
    });
  }

  void appendPendingImageCard() {
    final image =
        ChatMessage.toolCall(
            tool: 'Read',
            input: const {'file_path': '/tmp/pending-image.png'},
            toolUseId: 'pending-image',
          )
          ..toolOutput = 'Image loaded'
          ..toolImageFilePath = '/tmp/pending-image.png';
    setState(() => messages = [...messages, image]);
  }

  void insertRecoveredToolRows({required int beforeIndex}) {
    final call =
        ChatMessage.toolCall(
            tool: 'ViewImage',
            input: const {'path': '/tmp/recovered.png'},
            toolUseId: 'recovered-image',
          )
          ..toolOutput = 'Image viewed'
          ..toolImageFilePath = '/tmp/recovered.png';
    final result = ChatMessage(
      id: 'recovered-result',
      sender: MessageSender.assistant,
      type: MessageType.toolResult,
      timestamp: DateTime(2026, 1, 1, 0, 1),
      textContent: '',
      toolUseId: 'recovered-result',
      toolName: 'Read',
      toolOutput: 'Recovered output',
    );
    setState(() {
      messages = [
        ...messages.take(beforeIndex),
        call,
        result,
        ...messages.skip(beforeIndex),
      ];
    });
  }

  void switchSession() {
    setState(() => sessionStorageKey = 'server:session-2');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ChatView(
        messages: messages,
        sessionStorageKey: sessionStorageKey,
        isProcessing: false,
        isLoadingHistory: isLoadingHistory,
        isLoadingMore: isLoadingMore,
        hasMoreHistory: hasMoreHistory,
        historyWindowRevision: historyWindowRevision,
        todos: const [],
        onAnswer: (_, __) {},
        onSecureInputSubmit: (_, __) {},
        onSecureInputUseStored: (_, SecretMetadata __) {},
        onSecureInputCancel: (_) {},
        onLoadMore: _loadMore,
      ),
    );
  }
}
