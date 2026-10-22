import 'package:app/models/composer_attachment.dart';
import 'package:app/models/message.dart';
import 'package:app/widgets/chat_scrollbar.dart';
import 'package:app/widgets/chat_view.dart';
import 'package:app/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The chat scrollbar: one thumb, placed by row over the whole conversation,
// steady while rows of varied height build, and draggable through history
// that is not loaded yet.
void main() {
  testWidgets('the chat has exactly one scrollbar, on desktop too', (
    tester,
  ) async {
    final key = GlobalKey<_ScrollbarHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: _ScrollbarHarness(key: key, messageCount: 80),
      ),
    );
    await tester.pump();

    // Desktop's default scroll behavior wraps scroll views in a Scrollbar,
    // which is a RawScrollbar underneath.
    expect(find.byWidgetPredicate((w) => w is RawScrollbar), findsNothing);
    expect(find.byType(ChatScrollbar), findsOneWidget);
    final thumb = _thumbRect(tester);
    final chat = tester.getRect(
      find.byKey(const ValueKey('chat-scroll-surface')),
    );
    expect(thumb.right, chat.right);
    expect(thumb.width, ChatScrollbar.thickness);
    // Pinned to the bottom, so the thumb sits at the end of the track.
    expect(thumb.bottom, closeTo(chat.bottom - ChatScrollbar.margin, 0.5));
  });

  testWidgets(
    'the thumb keeps its length and moves evenly while rows of varied '
    'height build',
    (tester) async {
      final key = GlobalKey<_ScrollbarHarnessState>();
      await tester.pumpWidget(
        MaterialApp(
          home: _ScrollbarHarness(key: key, messageCount: 40, varied: true),
        ),
      );
      await tester.pump();
      final list = find.byKey(const ValueKey('chat-scroll-surface'));
      final chat = tester.getRect(list);
      final track = chat.height - 2 * ChatScrollbar.margin;

      final first = _thumbRect(tester);
      var previous = first;
      expect(first.height, greaterThan(ChatScrollbar.minThumbLength));
      // Scroll up one drag at a time, from the bottom to the top. Every row
      // above the viewport is laid out for the first time on the way, which
      // refines the mean row height the thumb's length comes from: a slow
      // drift of a pixel or two per step, never a jump.
      for (var step = 0; step < 50; step++) {
        await tester.drag(list, const Offset(0, 100));
        await tester.pump();
        final thumb = _thumbRect(tester);
        expect(
          thumb.height,
          closeTo(previous.height, 3),
          reason: 'step $step: thumb length must not jump with layout',
        );
        expect(
          thumb.height,
          closeTo(first.height, first.height * 0.25),
          reason: 'step $step: thumb length must stay near its first value',
        );
        expect(
          thumb.top,
          lessThanOrEqualTo(previous.top + 0.01),
          reason: 'step $step: thumb must not move back down',
        );
        expect(
          previous.top - thumb.top,
          lessThan(track * 0.1),
          reason: 'step $step: a short drag must not jump the thumb',
        );
        previous = thumb;
      }
      expect(previous.top, closeTo(chat.top + ChatScrollbar.margin, 0.5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an older page landing does not move the thumb', (tester) async {
    final key = GlobalKey<_ScrollbarHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _ScrollbarHarness(
          key: key,
          messageCount: 60,
          olderHistoryCount: 50,
        ),
      ),
    );
    await tester.pump();
    final list = find.byKey(const ValueKey('chat-scroll-surface'));
    await tester.fling(list, const Offset(0, 4000), 8000);
    await _pumpFrames(tester, 40);
    expect(key.currentState!.loadMoreCalls, 1);
    final before = _thumbRect(tester);
    final chat = tester.getRect(list);
    // Half the conversation is still unloaded, so the thumb is mid-track.
    expect(before.top, greaterThan(chat.top + chat.height * 0.3));

    key.currentState!.completeLoad(prependCount: 50);
    await tester.pumpAndSettle();
    final after = _thumbRect(tester);
    // The rows that land take the space the header had above row 0, so the
    // row under the viewport's top edge moves by less than one row.
    final oneRow = (chat.height - 2 * ChatScrollbar.margin) / 110;
    expect(after.top, closeTo(before.top, oneRow));
    expect(after.height, closeTo(before.height, 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dragging the thumb moves through the conversation and loads older '
    'history on the way up',
    (tester) async {
      final key = GlobalKey<_ScrollbarHarnessState>();
      await tester.pumpWidget(
        MaterialApp(
          home: _ScrollbarHarness(
            key: key,
            messageCount: 120,
            olderHistoryCount: 100,
          ),
        ),
      );
      await tester.pump();
      final chat = tester.getRect(
        find.byKey(const ValueKey('chat-scroll-surface')),
      );
      final track = chat.height - 2 * ChatScrollbar.margin;
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(key.currentState!.followLatest, isTrue);

      // Up to the middle of the track: row 110 of 220, which is loaded row
      // 10, and the view is no longer following. That close to the top of
      // the loaded rows the next page is requested at once, and its loading
      // bar animates, so settle by frames from here on.
      final start = _thumbRect(tester);
      final gesture = await tester.startGesture(start.center);
      await gesture.moveBy(Offset(0, -(track - start.height) / 2));
      await _pumpFrames(tester, 10);
      expect(key.currentState!.followLatest, isFalse);
      expect(
        _thumbRect(tester).top,
        closeTo(start.top - (track - start.height) / 2, 1),
      );
      expect(_topVisibleMessage(tester), inInclusiveRange(5, 15));
      expect(key.currentState!.loadMoreCalls, 1);

      // On to the top: the view is at the top of what is loaded. The thumb
      // is held above it, so each page that lands asks for the one before,
      // until history runs out.
      await gesture.moveBy(Offset(0, -(track - start.height) / 2));
      await _pumpFrames(tester, 10);
      expect(position.pixels, closeTo(position.minScrollExtent, 0.5));
      key.currentState!.completeLoad(prependCount: 50);
      await _pumpFrames(tester, 10);
      expect(key.currentState!.loadMoreCalls, 2);
      expect(position.pixels, closeTo(position.minScrollExtent, 0.5));
      key.currentState!.completeLoad(prependCount: 50);
      await tester.pumpAndSettle();
      expect(key.currentState!.loadMoreCalls, 2);
      expect(key.currentState!.hasMoreHistory, isFalse);
      expect(position.pixels, closeTo(position.minScrollExtent, 0.5));
      expect(_topVisibleMessage(tester), -100);

      // Back down to the end: following again.
      await gesture.moveBy(Offset(0, track));
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
      expect(key.currentState!.followLatest, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pumpFrames(WidgetTester tester, int frames) async {
  for (var frame = 0; frame < frames; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Rect _thumbRect(WidgetTester tester) {
  final scrollbar = tester.renderObject<RenderChatScrollbar>(
    find.byType(ChatScrollbar),
  );
  final thumb = scrollbar.thumb;
  expect(thumb, isNotNull, reason: 'the thumb is visible');
  return thumb!.rect.shift(scrollbar.localToGlobal(Offset.zero));
}

/// Index of the message whose row is under the viewport's top edge.
int _topVisibleMessage(WidgetTester tester) {
  final viewport = tester.getRect(find.byType(Scrollable).first);
  int? best;
  double? bestTop;
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
    if (bestTop == null || top < bestTop) {
      bestTop = top;
      best = int.parse(bubble.message.id.substring('message-'.length));
    }
  }
  return best!;
}

class _ScrollbarHarness extends StatefulWidget {
  const _ScrollbarHarness({
    super.key,
    required this.messageCount,
    this.olderHistoryCount = 0,
    this.varied = false,
  });

  final int messageCount;
  final int olderHistoryCount;
  final bool varied;

  @override
  State<_ScrollbarHarness> createState() => _ScrollbarHarnessState();
}

class _ScrollbarHarnessState extends State<_ScrollbarHarness> {
  late List<ChatMessage> messages = List.generate(
    widget.messageCount,
    _message,
  );
  late int olderHistoryCount = widget.olderHistoryCount;
  bool get hasMoreHistory => olderHistoryCount > 0;
  bool followLatest = true;
  bool isLoadingMore = false;
  int loadMoreCalls = 0;
  int _oldest = 0;

  ChatMessage _message(int index) => ChatMessage(
    id: 'message-$index',
    sender: MessageSender.assistant,
    type: MessageType.text,
    timestamp: DateTime(2026, 1, 1).add(Duration(seconds: index)),
    textContent: List.filled(
      widget.varied ? index.abs() % 9 + 1 : 1,
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

  void completeLoad({required int prependCount}) {
    final older = List.generate(
      prependCount,
      (index) => _message(_oldest - prependCount + index),
    );
    _oldest -= prependCount;
    setState(() {
      messages = [...older, ...messages];
      olderHistoryCount -= prependCount;
      isLoadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ChatView(
        messages: messages,
        sessionStorageKey: 'server:session-1',
        isProcessing: false,
        followLatest: followLatest,
        onFollowLatestChanged: (follow) {
          if (followLatest != follow) setState(() => followLatest = follow);
        },
        isLoadingMore: isLoadingMore,
        hasMoreHistory: hasMoreHistory,
        olderHistoryCount: olderHistoryCount,
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
