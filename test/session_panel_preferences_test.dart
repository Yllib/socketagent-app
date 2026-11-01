import 'package:app/services/session_panel_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const shown = ['plan-1'];

  test('every panel hides and restores independently', () async {
    final panels = SessionPanelPreferences(
      await SharedPreferences.getInstance(),
    );
    for (final panel in SessionPanel.values) {
      await panels.setHidden('server', 'session', panel, true, content: shown);
      expect(panels.isHidden('server', 'session', panel, shown), isTrue);
      expect(panels.isHidden('server', 'other', panel, shown), isFalse);
      await panels.setHidden('server', 'session', panel, false);
      expect(panels.isHidden('server', 'session', panel, shown), isFalse);
    }
  });

  test('a hidden panel comes back when it shows something new', () async {
    final panels = SessionPanelPreferences(
      await SharedPreferences.getInstance(),
    );
    await panels.setHidden(
      'server',
      'chat',
      SessionPanel.activity,
      true,
      content: ['agent-a', 'agent-b'],
    );
    // Items finishing and leaving keep it hidden.
    expect(
      panels.isHidden('server', 'chat', SessionPanel.activity, ['agent-b']),
      isTrue,
    );
    // A new item brings it back.
    expect(
      panels.isHidden('server', 'chat', SessionPanel.activity, [
        'agent-b',
        'agent-c',
      ]),
      isFalse,
    );
  });

  test('hides saved before content was recorded no longer apply', () async {
    SharedPreferences.setMockInitialValues({
      'hidden_session_panel_["server","chat","browser"]': true,
    });
    final panels = SessionPanelPreferences(
      await SharedPreferences.getInstance(),
    );
    expect(
      panels.isHidden('server', 'chat', SessionPanel.browser, ['b']),
      isFalse,
    );
  });

  test('visibility persists and is isolated by computer and panel', () async {
    final preferences = await SharedPreferences.getInstance();
    final panels = SessionPanelPreferences(preferences);
    await panels.setHidden(
      'server',
      'chat',
      SessionPanel.browser,
      true,
      content: shown,
    );
    final restored = SessionPanelPreferences(preferences);
    expect(
      restored.isHidden('server', 'chat', SessionPanel.browser, shown),
      isTrue,
    );
    expect(
      restored.isHidden('other', 'chat', SessionPanel.browser, shown),
      isFalse,
    );
    expect(
      restored.isHidden('server', 'chat', SessionPanel.codexPlan, shown),
      isFalse,
    );
  });

  test('missing identities cannot save global dismissals', () async {
    final panels = SessionPanelPreferences(
      await SharedPreferences.getInstance(),
    );
    expect(
      await panels.setHidden(null, 'chat', SessionPanel.codexPlan, true),
      isFalse,
    );
    expect(panels.isHidden(null, 'chat', SessionPanel.codexPlan, []), isFalse);
  });

  test('delimiter characters in identities do not collide', () async {
    final panels = SessionPanelPreferences(
      await SharedPreferences.getInstance(),
    );
    await panels.setHidden(
      'a:b',
      'c',
      SessionPanel.codexPlan,
      true,
      content: shown,
    );
    expect(panels.isHidden('a', 'b:c', SessionPanel.codexPlan, shown), isFalse);
  });
}
