import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/session_identity_remap.dart';

void main() {
  test('moves local session identity state to a replacement id', () {
    final pinned = {'old'};
    final draft = {'old': 'unfinished thought'};

    expect(moveSessionSetMember(pinned, 'old', 'new'), isTrue);
    expect(moveSessionMapEntry(draft, 'old', 'new'), isTrue);
    expect(pinned, {'new'});
    expect(draft, {'new': 'unfinished thought'});
  });

  test('keeps an existing destination value when aliases converge', () {
    final values = {'old': 'stale', 'new': 'current'};

    expect(moveSessionMapEntry(values, 'old', 'new'), isTrue);
    expect(values, {'new': 'current'});
  });

  test('keeps a named session title across replacement events', () {
    expect(replacementSessionTitle('Socketagent', 'new prompt'), 'Socketagent');
    expect(replacementSessionTitle('Untitled', 'new prompt'), 'new prompt');
  });
}
