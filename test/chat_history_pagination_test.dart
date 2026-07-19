import 'package:app/models/composer_attachment.dart';
import 'package:app/models/message.dart';
import 'package:app/widgets/chat_view.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ChatView(
        messages: messages,
        isProcessing: false,
        isLoadingHistory: isLoadingHistory,
        isLoadingMore: isLoadingMore,
        hasMoreHistory: hasMoreHistory,
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
