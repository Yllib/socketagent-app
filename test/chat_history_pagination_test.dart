import 'package:app/models/composer_attachment.dart';
import 'package:app/models/message.dart';
import 'package:app/widgets/chat_view.dart';
import 'package:app/widgets/message_bubble.dart';
import 'package:app/widgets/tool_output_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('notification focus seeks an exact loaded transcript row', (
    WidgetTester tester,
  ) async {
    final key = GlobalKey<_HistoryHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _HistoryHarness(
          key: key,
          initiallyLoadingHistory: false,
          messageCount: 100,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('History response 35'), findsNothing);
    key.currentState!.focusMessage(35);
    await tester.pumpAndSettle();

    expect(find.text('History response 35'), findsOneWidget);
    expect(key.currentState!.targetReached, isTrue);
    expect(key.currentState!.followLatest, isFalse);
  });

  testWidgets('notification focus pages backward until its row is available', (
    WidgetTester tester,
  ) async {
    final key = GlobalKey<_HistoryHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _HistoryHarness(
          key: key,
          initiallyLoadingHistory: false,
          messageCount: 20,
        ),
      ),
    );
    await tester.pump();

    key.currentState!.focusMissingMessage();
    await tester.pump();
    await tester.pump();
    expect(key.currentState!.loadMoreCalls, 1);

    key.currentState!.completeLoadWithTarget(prependCount: 10);
    await tester.pumpAndSettle();

    expect(find.text('Notification completion target'), findsOneWidget);
    expect(key.currentState!.targetReached, isTrue);
  });

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

  testWidgets(
    'prepend preserves the visible row and does not immediately loop',
    (WidgetTester tester) async {
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

      key.currentState!.holdViewport();
      await tester.pump();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      position.jumpTo(position.minScrollExtent + 10);
      await tester.pump();
      await tester.pump();

      expect(key.currentState!.loadMoreCalls, 1);
      final pixelsBefore = position.pixels;
      final anchorBefore = _topVisibleMessage(tester);
      key.currentState!.resetScrollUpdateNotifications();

      key.currentState!.completeLoad(prependCount: 20, hasMoreAfter: true);
      await tester.pumpAndSettle();

      expect(position.pixels, greaterThan(pixelsBefore));
      expect(
        _messageTop(tester, anchorBefore.id),
        closeTo(anchorBefore.top, 0.5),
      );
      expect(key.currentState!.loadMoreCalls, 1);
      expect(key.currentState!.scrollUpdateNotifications, 0);
    },
  );

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

    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
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

    key.currentState!.appendStreamingText(30);
    await tester.pump();
    await tester.pump();
    key.currentState!.holdViewport();
    await tester.pump();
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(position.maxScrollExtent * 0.45);
    await tester.pump();
    final anchorBefore = _topVisibleMessage(tester);
    final pixelsBefore = position.pixels;

    key.currentState!.appendStreamingText(30);
    await tester.pump();
    await tester.pump();

    expect(position.pixels, closeTo(pixelsBefore, 0.5));
    expect(
      _messageTop(tester, anchorBefore.id),
      closeTo(anchorBefore.top, 0.5),
    );
  });

  testWidgets('HOLD preserves screen position across outer layout changes', (
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

    key.currentState!.holdViewport();
    await tester.pump();
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(position.maxScrollExtent * 0.45);
    await tester.pump();
    final pixelsBefore = position.pixels;

    key.currentState!.showOuterBanner();
    await tester.pump();
    await tester.pump();

    expect(position.pixels, closeTo(pixelsBefore, 0.5));
  });

  testWidgets(
    'AUTO off gives an immediate pointer control over entry-time history work',
    (WidgetTester tester) async {
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

      key.currentState!.holdViewport();
      await tester.pump();
      final list = find.byType(ListView).first;
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      position.jumpTo(position.maxScrollExtent * 0.45);
      await tester.pump();

      final gesture = await tester.startGesture(tester.getCenter(list));
      final ownedPixels = position.pixels;
      final anchorBefore = _topVisibleMessage(tester);

      // This is the session-entry race: cached chat is visible, the reader
      // touches it, then delayed older history arrives before drag recognition.
      key.currentState!.completeLoad(prependCount: 20, hasMoreAfter: true);
      await tester.pump();
      await tester.pump();

      expect(key.currentState!.followLatest, isFalse);
      expect(position.pixels, greaterThan(ownedPixels));
      expect(
        _messageTop(tester, anchorBefore.id),
        closeTo(anchorBefore.top, 0.5),
      );

      final anchoredPixels = position.pixels;
      await gesture.moveBy(const Offset(0, 100));
      await tester.pump();
      expect(position.pixels, lessThan(anchoredPixels));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'first entry-time drag cancels AUTO before delayed reconciliation can snap',
    (WidgetTester tester) async {
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

      final list = find.byType(ListView).first;
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(key.currentState!.followLatest, isTrue);
      expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));

      final gesture = await tester.startGesture(tester.getCenter(list));
      key.currentState!.completeLoad(prependCount: 20, hasMoreAfter: true);
      await tester.pump();
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump();

      expect(key.currentState!.followLatest, isFalse);
      expect(position.pixels, lessThan(position.maxScrollExtent));
      final readerPixels = position.pixels;

      await gesture.up();
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(readerPixels, 0.5));
    },
  );

  testWidgets(
    'running session drag stays anchored across streaming and repeated prepends',
    (WidgetTester tester) async {
      final key = GlobalKey<_HistoryHarnessState>();
      await tester.pumpWidget(
        MaterialApp(
          home: _HistoryHarness(
            key: key,
            initiallyLoadingHistory: false,
            messageCount: 120,
          ),
        ),
      );
      key.currentState!.appendStreamingText(20);
      await tester.pump();
      await tester.pump();

      final list = find.byType(ListView).first;
      final gesture = await tester.startGesture(tester.getCenter(list));
      await gesture.moveBy(const Offset(0, 180));
      await tester.pump();
      expect(key.currentState!.followLatest, isFalse);

      var anchor = _topVisibleMessage(tester);
      key.currentState!.appendStreamingText(30);
      key.currentState!.prependHistoryBatch(20);
      await tester.pump();
      await tester.pump();
      expect(_messageTop(tester, anchor.id), closeTo(anchor.top, 0.5));

      await gesture.moveBy(const Offset(0, 70));
      await tester.pump();
      anchor = _topVisibleMessage(tester);
      key.currentState!.appendStreamingText(30);
      key.currentState!.prependHistoryBatch(20);
      await tester.pump();
      await tester.pump();
      expect(_messageTop(tester, anchor.id), closeTo(anchor.top, 0.5));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(key.currentState!.followLatest, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('FOLLOW and HOLD are explicit, deterministic viewport modes', (
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

    key.currentState!.holdViewport();
    await tester.pump();
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(position.maxScrollExtent * 0.45);
    final heldPixels = position.pixels;

    key.currentState!.appendNewResponse('new row while held');
    await tester.pump();
    await tester.pump();
    expect(position.pixels, closeTo(heldPixels, 0.5));

    key.currentState!.followViewport();
    await tester.pump();
    await tester.pump();
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));

    final list = find.byType(ListView).first;
    await tester.drag(list, const Offset(0, 160));
    await tester.pumpAndSettle();
    expect(position.pixels, lessThan(position.maxScrollExtent));
    expect(key.currentState!.followLatest, isFalse);
    final heldAfterManualScroll = position.pixels;

    key.currentState!.appendStreamingText(40);
    await tester.pump();
    await tester.pump();
    expect(position.pixels, closeTo(heldAfterManualScroll, 0.5));

    key.currentState!.isProcessing = false;
    await tester.fling(list, const Offset(0, -1800), 4000);
    await tester.pumpAndSettle();
    expect(key.currentState!.followLatest, isTrue);
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
  });

  testWidgets('FOLLOW tracks same-row streaming growth through completion', (
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
    position.jumpTo(position.maxScrollExtent * 0.4);

    key.currentState!.appendStreamingText(40);
    for (var frame = 0; frame < 14; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));

    position.jumpTo(position.maxScrollExtent * 0.5);
    key.currentState!.finishStreamingText(20);
    for (var frame = 0; frame < 14; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
  });

  testWidgets('FOLLOW settles at the real bottom after a large card batch', (
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
    position.jumpTo(position.maxScrollExtent * 0.35);
    key.currentState!.appendVariableHeightCards(24);
    for (var frame = 0; frame < 16; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is MessageBubble && widget.message.id == 'live-card-23',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'AUTO pins reconciliation and streaming before paint without scroll jumps',
    (WidgetTester tester) async {
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

      key.currentState!.resetScrollUpdateNotifications();
      key.currentState!.enterSessionWithCachedWindow(messageCount: 6);
      await tester.pump();
      key.currentState!.reconcileSessionWindow(messageCount: 140);
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
      expect(find.text('History response 139'), findsOneWidget);
      expect(key.currentState!.scrollUpdateNotifications, 0);

      key.currentState!.appendStreamingText(30);
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
      expect(key.currentState!.scrollUpdateNotifications, 0);
    },
  );

  testWidgets('FOLLOW ignores unrelated rebuilds while the reader is up', (
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
    position.jumpTo(position.maxScrollExtent * 0.45);
    await tester.pump();

    key.currentState!.showOuterBanner();
    await tester.pump();
    await tester.pump();

    expect(position.pixels, lessThan(position.maxScrollExtent));
  });

  testWidgets('FOLLOW reacts to a new prompt but not later history backfill', (
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
    position.jumpTo(position.maxScrollExtent * 0.6);
    await tester.pump();
    key.currentState!.beginHistoryLoad();
    await tester.pump();

    key.currentState!.sendUserPrompt('new local prompt');
    await tester.pump();
    await tester.pump();

    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
    expect(find.text('new local prompt'), findsOneWidget);
    key.currentState!.completeLoad(prependCount: 20);
    await tester.pump();
    await tester.pump();

    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
    expect(tester.takeException(), isNull);
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

    key.currentState!.appendStreamingText(30);
    await tester.pump();
    key.currentState!.holdViewport();
    await tester.pump();
    final scrollable = find.byType(Scrollable).first;
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(position.maxScrollExtent * 0.45);
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
    key.currentState!.holdViewport();
    await tester.pump();
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    final cardTopBefore = tester.getTopLeft(find.byType(ToolOutputBlock)).dy;
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
    expect(
      tester.getTopLeft(find.byType(ToolOutputBlock)).dy,
      closeTo(cardTopBefore, 0.5),
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
    await tester.pump();
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
      'message-row:server:session-1:text:${retainedMessage.id}::',
    );
    final delegate =
        tester.widget<ListView>(find.byType(ListView).first).childrenDelegate
            as SliverChildBuilderDelegate;
    expect(delegate.findChildIndexCallback, isNotNull);
    expect(delegate.findChildIndexCallback!(retainedKey), 6);

    key.currentState!.insertRecoveredToolRows(beforeIndex: 6);
    await tester.pump();

    final updatedDelegate =
        tester.widget<ListView>(find.byType(ListView).first).childrenDelegate
            as SliverChildBuilderDelegate;
    expect(updatedDelegate.findChildIndexCallback!(retainedKey), 6);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is MessageBubble && widget.message.id == retainedMessage.id,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('duplicate event identities cannot corrupt the mounted chat', (
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

    key.currentState!.insertDuplicateIdentityRows();
    await tester.pump();
    await tester.pump();

    expect(find.text('Duplicate row first'), findsOneWidget);
    expect(find.text('Duplicate row second'), findsOneWidget);
    expect(tester.takeException(), isNull);

    key.currentState!.holdViewport();
    await tester.pump();
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    final beforeDrag = position.pixels;
    await tester.drag(find.byType(ListView).first, const Offset(0, 160));
    await tester.pumpAndSettle();
    expect(position.pixels, isNot(closeTo(beforeDrag, 0.5)));
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
    key.currentState!.holdViewport();
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
    final dragDelta = position.pixels <= position.minScrollExtent + 1
        ? -120.0
        : 120.0;
    await tester.drag(list, Offset(0, dragDelta));
    await tester.pump(const Duration(milliseconds: 100));
    expect(position.pixels, isNot(closeTo(beforeDrag, 0.5)));

    position.jumpTo(position.maxScrollExtent);
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
    if (bottom <= 0 || top < 0 || top >= 600) continue;
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
  final GlobalKey<ChatViewState> chatViewKey = GlobalKey();
  late bool isLoadingHistory;
  bool isLoadingMore = false;
  bool hasMoreHistory = true;
  int loadMoreCalls = 0;
  int historyWindowRevision = 0;
  String sessionStorageKey = 'server:session-1';
  String? targetEntryId;
  int? targetSessionSeq;
  bool targetReached = false;
  bool followLatest = true;
  bool isProcessing = false;
  bool outerBannerVisible = false;
  int scrollUpdateNotifications = 0;
  int _nextOlderMessageIndex = -1;
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

  void focusMessage(int index) {
    setState(() {
      messages[index].entryId = 'entry-$index';
      messages[index].sessionSeq = index + 1;
      targetEntryId = 'entry-$index';
      targetSessionSeq = index + 1;
      targetReached = false;
    });
  }

  void focusMissingMessage() {
    setState(() {
      targetEntryId = 'older-completion-entry';
      targetSessionSeq = 1;
      targetReached = false;
    });
  }

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

  void beginHistoryLoad() {
    _loadMore();
  }

  void holdViewport() {
    setState(() => followLatest = false);
  }

  void followViewport() {
    setState(() => followLatest = true);
  }

  void showOuterBanner() {
    setState(() => outerBannerVisible = true);
  }

  void resetScrollUpdateNotifications() {
    scrollUpdateNotifications = 0;
  }

  void enterSessionWithCachedWindow({required int messageCount}) {
    setState(() {
      sessionStorageKey = 'server:reconciling-session';
      messages = List.generate(messageCount, _message);
      historyWindowRevision++;
      hasMoreHistory = true;
      isLoadingMore = false;
    });
  }

  void reconcileSessionWindow({required int messageCount}) {
    setState(() {
      messages = List.generate(messageCount, _message);
      historyWindowRevision++;
      hasMoreHistory = true;
      isLoadingMore = false;
    });
  }

  void sendUserPrompt(String text) {
    setState(() {
      messages = [
        ...messages,
        ChatMessage(
          id: 'local-user-${messages.length}',
          sender: MessageSender.user,
          type: MessageType.text,
          timestamp: DateTime.now(),
          textContent: text,
        ),
      ];
    });
  }

  void appendNewResponse(String text) {
    setState(() {
      messages = [
        ...messages,
        ChatMessage(
          id: 'new-response-${messages.length}',
          sender: MessageSender.assistant,
          type: MessageType.text,
          timestamp: DateTime.now(),
          textContent: text,
        ),
      ];
    });
  }

  void completeLoad({required int prependCount, bool hasMoreAfter = false}) {
    setState(() {
      messages = [
        ...List.generate(
          prependCount,
          (index) => _message(-prependCount + index),
        ),
        ...messages,
      ];
      isLoadingMore = false;
      hasMoreHistory = hasMoreAfter;
    });
  }

  void prependHistoryBatch(int count) {
    final firstIndex = _nextOlderMessageIndex - count + 1;
    final older = List.generate(count, (index) => _message(firstIndex + index));
    _nextOlderMessageIndex = firstIndex - 1;
    setState(() {
      messages = [...older, ...messages];
      historyWindowRevision++;
      hasMoreHistory = true;
      isLoadingMore = false;
    });
  }

  void completeLoadWithTarget({required int prependCount}) {
    final prepended = List.generate(
      prependCount,
      (index) => _message(-prependCount + index),
    );
    prepended[prependCount ~/ 2]
      ..entryId = 'older-completion-entry'
      ..sessionSeq = 1
      ..textContent = 'Notification completion target';
    setState(() {
      messages = [...prepended, ...messages];
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
      isProcessing = true;
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

  void finishStreamingText(int lineCount) {
    final previous = messages.last;
    setState(() {
      isProcessing = false;
      messages = [
        ...messages.take(messages.length - 1),
        ChatMessage(
          id: previous.id,
          sender: previous.sender,
          type: previous.type,
          timestamp: previous.timestamp,
          textContent:
              '${previous.textContent}\n${List.generate(lineCount, (index) => 'Final line $index').join('\n')}',
          streamId: previous.streamId,
          revision: previous.revision + 1,
        ),
      ];
    });
  }

  void appendVariableHeightCards(int count) {
    setState(() {
      isProcessing = true;
      messages = [
        ...messages,
        for (var index = 0; index < count; index++)
          ChatMessage(
            id: 'live-card-$index',
            sender: MessageSender.assistant,
            type: MessageType.text,
            timestamp: DateTime.now().add(Duration(milliseconds: index)),
            textContent: [
              'Live card $index',
              ...List.generate(index % 7, (line) => 'Card detail $line'),
            ].join('\n'),
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

  void insertDuplicateIdentityRows() {
    final timestamp = DateTime(2026, 1, 1, 0, 2);
    setState(() {
      messages = [
        ...messages,
        ChatMessage(
          id: 'duplicate-event',
          sender: MessageSender.assistant,
          type: MessageType.text,
          timestamp: timestamp,
          textContent: 'Duplicate row first',
        ),
        ChatMessage(
          id: 'duplicate-event',
          sender: MessageSender.assistant,
          type: MessageType.text,
          timestamp: timestamp,
          textContent: 'Duplicate row second',
        ),
      ];
    });
  }

  void switchSession() {
    setState(() => sessionStorageKey = 'server:session-2');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          if (outerBannerVisible)
            const SizedBox(
              key: ValueKey('outer-banner'),
              height: 48,
              width: double.infinity,
            ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollUpdateNotification &&
                    notification.dragDetails == null) {
                  scrollUpdateNotifications++;
                }
                return false;
              },
              child: ChatView(
                key: chatViewKey,
                messages: messages,
                sessionStorageKey: sessionStorageKey,
                isProcessing: isProcessing,
                followLatest: followLatest,
                onFollowLatestChanged: (follow) {
                  if (followLatest != follow) {
                    setState(() => followLatest = follow);
                  }
                },
                isLoadingHistory: isLoadingHistory,
                isLoadingMore: isLoadingMore,
                hasMoreHistory: hasMoreHistory,
                historyWindowRevision: historyWindowRevision,
                targetEntryId: targetEntryId,
                targetSessionSeq: targetSessionSeq,
                onTranscriptTargetReached: () {
                  targetReached = true;
                  if (mounted) {
                    setState(() {
                      targetEntryId = null;
                      targetSessionSeq = null;
                    });
                  }
                },
                todos: const [],
                onAnswer: (_, __) {},
                onSecureInputSubmit: (_, __) {},
                onSecureInputUseStored: (_, SecretMetadata __) {},
                onSecureInputCancel: (_) {},
                onLoadMore: _loadMore,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
