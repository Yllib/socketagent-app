import 'package:app/models/message.dart';
import 'package:app/widgets/monitor_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Monitor output card shows its source and latest output', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'monitor-monitor-1',
      sender: MessageSender.system,
      type: MessageType.monitorOutput,
      timestamp: DateTime.now(),
      textContent: 'APK build',
      toolUseId: 'monitor-1',
      toolOutput: 'Compiling\nBuild complete',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MonitorCard(message: message)),
      ),
    );

    expect(find.text('Monitor output'), findsOneWidget);
    expect(find.text('APK build'), findsOneWidget);
    expect(find.text('Build complete'), findsOneWidget);

    await tester.tap(find.text('Monitor output'));
    await tester.pump();
    expect(find.text('Compiling\nBuild complete'), findsOneWidget);
  });
}
