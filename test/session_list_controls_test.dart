import 'package:app/widgets/computer_filter_dialog.dart';
import 'package:app/widgets/session_backend_watermark.dart';
import 'package:app/widgets/session_compaction_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget app(Widget child) => MaterialApp(
  theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: Colors.black),
  home: Scaffold(body: child),
);

Widget notice(int count, {String server = 'a', VoidCallback? onStart}) => app(
  SizedBox(
    width: 300,
    child: SessionCompactionNotice(
      serverId: server,
      sessionId: 'same-session',
      compactions: count,
      onStartFresh: onStart ?? () {},
    ),
  ),
);

void main() {
  testWidgets(
    'computer picker sorts by count, accepts several computers and applies together',
    (tester) async {
      ComputerFilterSelection? result;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<ComputerFilterSelection>(
                  context: context,
                  builder: (_) => const ComputerFilterDialog(
                    selection: ComputerFilterSelection({}, false),
                    computers: [
                      ComputerFilterOption(
                        id: 'few',
                        name: 'Few',
                        sessionCount: 2,
                        connected: false,
                      ),
                      ComputerFilterOption(
                        id: 'many',
                        name: 'Many',
                        sessionCount: 30,
                        connected: true,
                      ),
                      ComputerFilterOption(
                        id: 'middle',
                        name: 'Middle',
                        sessionCount: 10,
                        connected: true,
                      ),
                    ],
                  ),
                );
              },
              child: const Text('Choose'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Many')).dy,
        lessThan(tester.getTopLeft(find.text('Middle')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Middle')).dy,
        lessThan(tester.getTopLeft(find.text('Few')).dy),
      );
      await tester.tap(find.text('Many'));
      await tester.pump();
      await tester.tap(find.text('Middle'));
      await tester.pump();
      expect(result, isNull);
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(result!.ids, {'many', 'middle'});
      expect(result!.includes('many', connected: true), isTrue);
      expect(result!.includes('middle', connected: true), isTrue);
      expect(result!.includes('few', connected: true), isFalse);
      expect(
        const ComputerFilterSelection(
          {},
          true,
        ).includes('few', connected: false),
        isFalse,
      );
    },
  );

  testWidgets(
    'dismissal persists and returns after exactly 15 more compactions',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(notice(38));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Dismiss for 15 more compactions'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Start a new thread'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(notice(52));
      await tester.pumpAndSettle();
      expect(find.textContaining('Start a new thread'), findsNothing);
      await tester.pumpWidget(notice(53));
      await tester.pumpAndSettle();
      expect(find.textContaining('53 compactions.'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss for 15 more compactions'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(notice(67));
      expect(find.textContaining('Start a new thread'), findsNothing);
      await tester.pumpWidget(notice(68));
      expect(find.textContaining('Start a new thread'), findsOneWidget);
    },
  );

  testWidgets('dismissals stay on their computer and reset after rollover', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(notice(38));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Dismiss for 15 more compactions'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(notice(38, server: 'b'));
    await tester.pumpAndSettle();
    expect(find.textContaining('38 compactions.'), findsOneWidget);
    await tester.pumpWidget(notice(11));
    await tester.pumpAndSettle();
    expect(find.textContaining('11 compactions.'), findsOneWidget);
    await tester.pumpWidget(notice(38));
    await tester.pumpAndSettle();
    expect(find.textContaining('38 compactions.'), findsOneWidget);
  });

  testWidgets(
    'notice opens explanation and starts thread without opening the session',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      var starts = 0;
      await tester.pumpWidget(notice(38, onStart: () => starts++));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(SessionCompactionNotice)).height,
        lessThanOrEqualTo(32),
      );
      final help = tester.getCenter(find.byTooltip('More info'));
      final dismiss = tester.getCenter(
        find.byTooltip('Dismiss for 15 more compactions'),
      );
      expect(help.dx, lessThan(dismiss.dx));
      expect(help.dy, dismiss.dy);
      await tester.tap(find.byTooltip('More info'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Remember'), findsOneWidget);
      expect(starts, 0);
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Start a new thread'));
      expect(starts, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('notice changes do not resize or move the watermark', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    for (final compact in [false, true]) {
      for (final width in [320.0, 600.0]) {
        Future<void> pumpRow(bool showNotice) async {
          await tester.pumpWidget(
            app(
              Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: SessionBackendWatermark(
                    backend: 'codex',
                    compact: compact,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: compact ? 56 : 80,
                          child: const Text('Session details'),
                        ),
                        if (showNotice)
                          SessionCompactionNotice(
                            serverId: 'watermark-test',
                            sessionId: 'session',
                            compactions: 38,
                            onStartFresh: () {},
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        await pumpRow(false);
        final mark = tester.getRect(find.byType(Image));
        final row = tester.getSize(find.byType(SessionBackendWatermark));
        await pumpRow(true);
        expect(tester.getRect(find.byType(Image)), mark);
        expect(
          tester.getSize(find.byType(SessionBackendWatermark)).height,
          greaterThan(row.height),
        );
        await tester.tap(find.byTooltip('Dismiss for 15 more compactions'));
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byType(Image)), mark);
        expect(tester.getSize(find.byType(SessionBackendWatermark)), row);
        // Each layout case starts with an undismissed notice.
        SharedPreferences.setMockInitialValues({});
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('watermark preserves session tap and small row layout', (
    tester,
  ) async {
    var opens = 0;
    for (final backend in ['claude', 'codex']) {
      await tester.pumpWidget(
        app(
          SizedBox(
            width: 320,
            child: InkWell(
              onTap: () => opens++,
              child: SessionBackendWatermark(
                backend: backend,
                child: const Padding(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Working on SocketAgent'),
                      Text('Latest response from the agent'),
                      Text('Dev VM · just now'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Working on SocketAgent'));
      expect(tester.takeException(), isNull);
    }
    expect(opens, 2);
  });
}
