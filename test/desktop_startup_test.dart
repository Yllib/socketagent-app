import 'dart:async';
import 'package:app/widgets/desktop_startup.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('com.socketagent.app/desktop_window');
  testWidgets('window controls work while startup services are still loading', (
    tester,
  ) async {
    final ready = Completer<Widget>();
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(DesktopStartup(initialize: () => ready.future));
    expect(find.text('Opening SocketAgent…'), findsOneWidget);
    await tester.tap(find.byTooltip('Minimize'));
    await tester.tap(find.byTooltip('Maximize'));
    await tester.pump();
    expect(calls, ['minimize', 'toggleMaximize']);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    ready.complete(const MaterialApp(home: Text('Ready')));
    await tester.pumpAndSettle();
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Opening SocketAgent…'), findsNothing);
  });

  testWidgets('failed initialization has a working retry', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      DesktopStartup(
        initialize: () async {
          if (++attempts == 1) throw StateError('test startup failure');
          return const MaterialApp(home: Text('Recovered'));
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not open SocketAgent'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Recovered'), findsOneWidget);
  });
}
