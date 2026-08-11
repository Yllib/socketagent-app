import 'package:app/models/message.dart';
import 'package:app/widgets/bash_command_view.dart';
import 'package:app/widgets/tool_output_block.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('removes a routine bash login wrapper', () {
    expect(
      stripRoutineShellWrapper(
        "/bin/bash -lc 'rg --files | grep \"socket agent\"'",
      ),
      'rg --files | grep "socket agent"',
    );
  });

  test('tokenizes commands, flags, strings, and pipeline commands', () {
    final tokens = tokenizeShellCommand(
      'rg --hidden "hello world" lib | grep -v test',
    );

    expect(
      tokens
          .where((token) => token.kind == ShellTokenKind.command)
          .map((token) => token.text),
      ['rg', 'grep'],
    );
    expect(
      tokens
          .where((token) => token.kind == ShellTokenKind.flag)
          .map((token) => token.text),
      ['--hidden', '-v'],
    );
    expect(
      tokens.where((token) => token.kind == ShellTokenKind.string).single.text,
      '"hello world"',
    );
  });

  test('does not split operators contained inside quotes', () {
    final tokens = tokenizeShellCommand("printf '%s && %s' one two && echo ok");
    expect(
      tokens
          .where((token) => token.kind == ShellTokenKind.operator)
          .map((token) => token.text),
      ['&&'],
    );
  });

  test('finds wrapper commands and commands in an SSH remote script', () {
    final tokens = tokenizeShellCommand(
      'timeout 12 sshpass -f /tmp/password ssh -o ConnectTimeout=4 '
      'nas@10.10.20.3 "python3 -m esptool version 2>&1 || '
      'command -v esptool || true; ls -l /srv/builds"',
    );

    expect(
      tokens
          .where((token) => token.kind == ShellTokenKind.command)
          .map((token) => token.text),
      ['timeout', 'sshpass', 'ssh', 'python3', 'command', 'true', 'ls'],
    );
  });

  test('provides built-in help for timeout', () {
    final info = commandInfoFor('timeout');
    expect(info.name, 'timeout');
    expect(info.summary, contains('time limit'));
  });

  testWidgets('expanded Bash card highlights commands and opens command help', (
    tester,
  ) async {
    final message = ChatMessage.toolCall(
      tool: 'Bash',
      input: {'command': "/bin/bash -lc 'rg --files | grep \"socket agent\"'"},
      toolUseId: 'bash-test',
    )..toolOutput = 'done';

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(body: ToolOutputBlock(message: message, expanded: true)),
      ),
    );

    final selectable = tester.widget<SelectableText>(
      find.byKey(const ValueKey<String>('bash-highlighted-command')),
    );
    final plainText = selectable.textSpan!.toPlainText();
    expect(plainText, isNot(contains('/bin/bash -lc')));
    expect(plainText, contains('rg --files'));

    final rgSpan = selectable.textSpan!.children!
        .whereType<TextSpan>()
        .firstWhere((span) => span.text == 'rg');
    expect(rgSpan.recognizer, isA<TapGestureRecognizer>());
    (rgSpan.recognizer! as TapGestureRecognizer).onTap!();
    await tester.pumpAndSettle();

    expect(find.text('rg (ripgrep)'), findsOneWidget);
    expect(find.textContaining('Recursively searches files'), findsOneWidget);
  });
}
