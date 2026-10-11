import 'package:app/models/chat_find.dart';
import 'package:app/models/message.dart';
import 'package:app/services/desktop_composer_keys.dart';
import 'package:app/services/desktop_shortcuts.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _message(
  String id,
  String text, {
  MessageSender sender = MessageSender.assistant,
  MessageType type = MessageType.text,
  String? parentToolUseId,
}) => ChatMessage(
  id: id,
  sender: sender,
  type: type,
  timestamp: DateTime(2026),
  textContent: text,
  parentToolUseId: parentToolUseId,
);

void main() {
  test('Ctrl shortcuts map to commands and leave AltGr typing alone', () {
    DesktopShortcut? press(
      LogicalKeyboardKey key, {
      bool control = true,
      bool shift = false,
      bool alt = false,
    }) => desktopShortcutFor(key, control: control, shift: shift, alt: alt);

    expect(press(LogicalKeyboardKey.keyN), DesktopShortcut.newSession);
    expect(press(LogicalKeyboardKey.keyK), DesktopShortcut.switchSession);
    expect(press(LogicalKeyboardKey.keyF), DesktopShortcut.find);
    expect(press(LogicalKeyboardKey.tab), DesktopShortcut.nextSession);
    expect(
      press(LogicalKeyboardKey.tab, shift: true),
      DesktopShortcut.previousSession,
    );
    expect(
      press(LogicalKeyboardKey.equal, shift: true),
      DesktopShortcut.textLarger,
    );
    expect(press(LogicalKeyboardKey.minus), DesktopShortcut.textSmaller);
    expect(press(LogicalKeyboardKey.digit0), DesktopShortcut.textReset);
    expect(press(LogicalKeyboardKey.keyN, control: false), isNull);
    expect(press(LogicalKeyboardKey.keyN, shift: true), isNull);
    expect(press(LogicalKeyboardKey.keyF, alt: true), isNull);
    expect(press(LogicalKeyboardKey.keyV), isNull);
  });

  test('find matches top-level chat text, newest first', () {
    final messages = [
      _message('old', 'Deploy the relay'),
      _message('tool', 'deploy output', type: MessageType.toolResult),
      _message('child', 'deploy from a subagent', parentToolUseId: 'task'),
      _message('new', 'Ready to DEPLOY?', sender: MessageSender.user),
    ];
    expect(findChatMatches(messages, ' deploy ').map((m) => m.id), [
      'new',
      'old',
    ]);
    expect(findChatMatches(messages, '  '), isEmpty);
  });

  test('Up recalls the newest prompt the user sent', () {
    expect(
      lastSentPrompt([
        _message('a', 'first', sender: MessageSender.user),
        _message('b', 'reply'),
        _message('c', 'second', sender: MessageSender.user),
        _message('d', 'reply'),
      ]),
      'second',
    );
    expect(lastSentPrompt([_message('b', 'reply')]), isNull);
  });
}
