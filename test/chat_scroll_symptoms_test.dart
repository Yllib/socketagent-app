import 'package:app/models/composer_attachment.dart';
import 'package:app/models/message.dart';
import 'package:app/widgets/chat_view.dart';
import 'package:app/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Two field reports, reproduced as exactly as a widget test allows.
//
// 1. "Stuck at the top": the reader is at the top of the loaded history, a
//    page of older rows lands, and the view does not keep the row the reader
//    was looking at. It ends up back at the top, the load-older trigger fires
//    again, and the transcript pages backwards until history runs out.
// 2. "Jumps around on entry": a cached transcript paints, the reader touches
//    it, and the authoritative history then replaces the window underneath
//    their finger.
void main() {
  testWidgets(
    'a tall page landing while the reader sits at the top holds the row and '
    'does not request the next page',
    (tester) async {
      final key = GlobalKey<_SymptomHarnessState>();
      await tester.pumpWidget(
        MaterialApp(home: _SymptomHarness(key: key, messageCount: 60)),
      );
      await tester.pump();

      // Reader drags to the very top. The drag turns follow off and the
      // trigger asks for the first older page.
      final list = find.byKey(const ValueKey('chat-scroll-surface'));
      await tester.fling(list, const Offset(0, 4000), 8000);
      // The loading bar animates while a page is in flight, so settle by
      // frames rather than pumpAndSettle.
      await _pumpFrames(tester, 40);
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(position.pixels, closeTo(position.minScrollExtent, 0.5));
      expect(key.currentState!.followLatest, isFalse);
      expect(key.currentState!.loadMoreCalls, 1);

      final anchor = _topVisibleMessage(tester);

      // A real page: fifty rows, taller than the viewport and its cache
      // together, so the previously visible rows leave the sliver's cache.
      key.currentState!.completeLoad(prependCount: 50, tall: true);
      await tester.pump();
      expect(
        _messageTop(tester, anchor.id),
        closeTo(anchor.top, 0.5),
        reason: 'first painted frame after the page landed',
      );
      await tester.pumpAndSettle();
      expect(_messageTop(tester, anchor.id), closeTo(anchor.top, 0.5));
      expect(position.pixels, greaterThan(position.minScrollExtent + 1000));
      expect(
        key.currentState!.loadMoreCalls,
        1,
        reason: 'the next page is only wanted once the reader scrolls up',
      );
      expect(tester.takeException(), isNull);

      // Scrolling back to the top asks for exactly one more page, and that
      // page is held in place the same way.
      await tester.fling(list, const Offset(0, 8000), 12000);
      await _pumpFrames(tester, 60);
      expect(position.pixels, closeTo(position.minScrollExtent, 0.5));
      expect(key.currentState!.loadMoreCalls, 2);
      final secondAnchor = _topVisibleMessage(tester);
      key.currentState!.completeLoad(prependCount: 50, tall: true);
      await tester.pumpAndSettle();
      expect(
        _messageTop(tester, secondAnchor.id),
        closeTo(secondAnchor.top, 0.5),
      );
      expect(key.currentState!.loadMoreCalls, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'authoritative history replacing a touched cached window keeps the row '
    'under the finger',
    (tester) async {
      final key = GlobalKey<_SymptomHarnessState>();
      await tester.pumpWidget(
        MaterialApp(home: _SymptomHarness(key: key, messageCount: 80)),
      );
      await tester.pump();

      // Entering a session: a cached tail paints, pinned to the bottom.
      key.currentState!.enterSession(cachedCount: 20);
      await tester.pump();
      await tester.pump();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));

      // The reader starts reading upward before history finishes.
      final list = find.byKey(const ValueKey('chat-scroll-surface'));
      final gesture = await tester.startGesture(tester.getCenter(list));
      await gesture.moveBy(const Offset(0, 90));
      await tester.pump();
      expect(key.currentState!.followLatest, isFalse);
      final anchor = _topVisibleMessage(tester);

      // The server's window arrives: the same tail rows plus a long run of
      // older rows, and the "load earlier" header appears above them.
      key.currentState!.replaceWindow(messageCount: 140, hasMore: true);
      await tester.pump();
      expect(
        _messageTop(tester, anchor.id),
        closeTo(anchor.top, 0.5),
        reason: 'first painted frame after the replacement',
      );

      // The drag continues across the replacement without a jump. Bubbles
      // animate their padding when neighbours change, so settle first.
      await tester.pumpAndSettle();
      final settledTop = _messageTop(tester, anchor.id);
      expect(settledTop, closeTo(anchor.top, 1));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(_messageTop(tester, anchor.id), closeTo(settledTop + 40, 0.5));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_messageTop(tester, anchor.id), closeTo(settledTop + 40, 0.5));
      expect(key.currentState!.followLatest, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a finger resting on a cached window does not stop the replacement from '
    'staying at the bottom',
    (tester) async {
      final key = GlobalKey<_SymptomHarnessState>();
      await tester.pumpWidget(
        MaterialApp(home: _SymptomHarness(key: key, messageCount: 80)),
      );
      await tester.pump();
      key.currentState!.enterSession(cachedCount: 20);
      await tester.pump();
      await tester.pump();

      final list = find.byKey(const ValueKey('chat-scroll-surface'));
      final gesture = await tester.startGesture(tester.getCenter(list));
      key.currentState!.replaceWindow(messageCount: 140, hasMore: true);
      await tester.pump();
      await tester.pump();

      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(key.currentState!.followLatest, isTrue);
      expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
      expect(find.text('History response 139'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pumpFrames(WidgetTester tester, int frames) async {
  for (var frame = 0; frame < frames; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

({String id, double top}) _topVisibleMessage(WidgetTester tester) {
  final viewport = tester.getRect(find.byType(Scrollable).first);
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
    if (bottom <= viewport.top || top >= viewport.bottom) continue;
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

class _SymptomHarness extends StatefulWidget {
  const _SymptomHarness({super.key, required this.messageCount});

  final int messageCount;

  @override
  State<_SymptomHarness> createState() => _SymptomHarnessState();
}

class _SymptomHarnessState extends State<_SymptomHarness> {
  late List<ChatMessage> messages = List.generate(
    widget.messageCount,
    _message,
  );
  String sessionStorageKey = 'server:session-1';
  bool followLatest = true;
  bool isLoadingMore = false;
  bool hasMoreHistory = true;
  int historyWindowRevision = 0;
  int loadMoreCalls = 0;
  int _oldest = 0;

  ChatMessage _message(int index, {bool tall = false}) => ChatMessage(
    id: 'message-$index',
    sender: MessageSender.assistant,
    type: MessageType.text,
    timestamp: DateTime(2026, 1, 1).add(Duration(seconds: index)),
    textContent: List.filled(
      tall ? index.abs() % 5 + 2 : 1,
      'History response $index',
    ).join('\n'),
  );

  void _loadMore() {
    if (isLoadingMore) return;
    setState(() {
      isLoadingMore = true;
      loadMoreCalls++;
    });
  }

  void completeLoad({required int prependCount, bool tall = false}) {
    final older = List.generate(
      prependCount,
      (index) => _message(_oldest - prependCount + index, tall: tall),
    );
    _oldest -= prependCount;
    setState(() {
      messages = [...older, ...messages];
      isLoadingMore = false;
    });
  }

  void enterSession({required int cachedCount}) {
    setState(() {
      sessionStorageKey = 'server:session-2';
      followLatest = true;
      messages = List.generate(
        cachedCount,
        (index) => _message(widget.messageCount - cachedCount + index),
      );
      hasMoreHistory = false;
      isLoadingMore = false;
    });
  }

  void replaceWindow({required int messageCount, required bool hasMore}) {
    setState(() {
      messages = List.generate(messageCount, _message);
      historyWindowRevision++;
      hasMoreHistory = hasMore;
      isLoadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ChatView(
        messages: messages,
        sessionStorageKey: sessionStorageKey,
        isProcessing: false,
        followLatest: followLatest,
        onFollowLatestChanged: (follow) {
          if (followLatest != follow) setState(() => followLatest = follow);
        },
        isLoadingMore: isLoadingMore,
        hasMoreHistory: hasMoreHistory,
        historyWindowRevision: historyWindowRevision,
        todos: const [],
        onAnswer: (_, _) {},
        onSecureInputSubmit: (_, _) {},
        onSecureInputUseStored: (_, SecretMetadata _) {},
        onSecureInputCancel: (_) {},
        onLoadMore: _loadMore,
      ),
    );
  }
}
