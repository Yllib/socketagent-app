import 'package:app/models/session_list_filter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('a saved session list filter loads back after a restart', () async {
    SharedPreferences.setMockInitialValues({});
    expect((await SessionListFilter.load()).computerIds, isEmpty);

    await const SessionListFilter(
      computerIds: {'laptop', 'desktop'},
      connectedOnly: true,
      backend: 'codex',
    ).save();
    final saved = await SessionListFilter.load();
    expect(saved.computerIds, {'laptop', 'desktop'});
    expect(saved.connectedOnly, isTrue);
    expect(saved.backend, 'codex');

    await const SessionListFilter().save();
    final cleared = await SessionListFilter.load();
    expect(cleared.computerIds, isEmpty);
    expect(cleared.connectedOnly, isFalse);
    expect(cleared.backend, isNull);
  });
}
