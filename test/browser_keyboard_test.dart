import 'package:app/services/browser_keyboard.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

KeyDownEvent _down(
  PhysicalKeyboardKey physical,
  LogicalKeyboardKey logical, [
  String? character,
]) => KeyDownEvent(
  physicalKey: physical,
  logicalKey: logical,
  character: character,
  timeStamp: Duration.zero,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('browserKeyFor', () {
    test('a letter reports its physical code and types itself', () {
      final key = browserKeyFor(
        _down(PhysicalKeyboardKey.keyH, LogicalKeyboardKey.keyH, 'H'),
      );
      expect(key, (code: 'KeyH', key: 'H', text: 'H'));
    });

    test('a control character becomes the shortcut letter', () {
      final key = browserKeyFor(
        _down(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA, '\x01'),
      );
      expect(key, (code: 'KeyA', key: 'a', text: null));
    });

    test('named keys type nothing', () {
      expect(
        browserKeyFor(
          _down(PhysicalKeyboardKey.enter, LogicalKeyboardKey.enter, '\r'),
        ),
        (code: 'Enter', key: 'Enter', text: null),
      );
      expect(
        browserKeyFor(
          _down(PhysicalKeyboardKey.shiftRight, LogicalKeyboardKey.shiftRight),
        ),
        (code: 'ShiftRight', key: 'Shift', text: null),
      );
    });

    test('a phone keyboard Backspace without a physical key still maps', () {
      final key = browserKeyFor(
        _down(
          const PhysicalKeyboardKey(0x1100000000),
          LogicalKeyboardKey.backspace,
        ),
      );
      expect(key, (code: 'Backspace', key: 'Backspace', text: null));
    });

    test('device keys stay with the phone', () {
      expect(
        browserKeyFor(
          _down(
            PhysicalKeyboardKey.audioVolumeUp,
            LogicalKeyboardKey.audioVolumeUp,
          ),
        ),
        isNull,
      );
    });

    test('a release repeats the key it pressed and types nothing', () {
      final key = browserKeyFor(
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.keyH,
          logicalKey: LogicalKeyboardKey.keyH,
          timeStamp: Duration.zero,
        ),
        heldKey: 'H',
      );
      expect(key, (code: 'KeyH', key: 'H', text: null));
    });
  });

  group('imeEdit', () {
    test('typing appends', () {
      expect(imeEdit('ab', 'abc'), (backspaces: 0, typed: 'c'));
    });

    test('an autocorrect rewrites the changed tail', () {
      expect(imeEdit('I teh', 'I the '), (backspaces: 2, typed: 'he '));
    });

    test('deleting an emoji is one Backspace', () {
      expect(imeEdit('a😀', 'a'), (backspaces: 1, typed: ''));
    });

    test('swapping one emoji for another never splits it', () {
      expect(imeEdit('😀', '😃'), (backspaces: 1, typed: '😃'));
    });
  });
}
