import 'package:flutter_test/flutter_test.dart';
import 'package:app/screens/terminal_screen.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('cursor keys follow application cursor mode', () {
    final terminal = Terminal();
    expect(cursorKeySequence(terminal, 'A', 1), '\x1b[A');

    terminal.write('\x1b[?1h');
    expect(cursorKeySequence(terminal, 'A', 1), '\x1bOA');
    expect(cursorKeySequence(terminal, 'H', 1), '\x1bOH');
    expect(cursorKeySequence(terminal, 'A', 5), '\x1b[1;5A');

    terminal.write('\x1b[?1l');
    expect(cursorKeySequence(terminal, 'F', 1), '\x1b[F');
  });
}
