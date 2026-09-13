import 'package:app/services/session_panel_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'every panel supports persistent hide and restore independently',
    () async {
      final panels = SessionPanelPreferences(
        await SharedPreferences.getInstance(),
      );
      for (final panel in SessionPanel.values) {
        await panels.setHidden('server', 'session', panel, true);
        expect(panels.isHidden('server', 'session', panel), isTrue);
        expect(panels.isHidden('server', 'other', panel), isFalse);
        await panels.setHidden('server', 'session', panel, false);
        expect(panels.isHidden('server', 'session', panel), isFalse);
      }
    },
  );

  test(
    'visibility persists and is isolated by computer, session and panel',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final panels = SessionPanelPreferences(preferences);
      await panels.setHidden('server', 'chat', SessionPanel.browser, true);
      final restored = SessionPanelPreferences(preferences);
      expect(restored.isHidden('server', 'chat', SessionPanel.browser), isTrue);
      expect(restored.isHidden('other', 'chat', SessionPanel.browser), isFalse);
      expect(
        restored.isHidden('server', 'other', SessionPanel.browser),
        isFalse,
      );
      expect(
        restored.isHidden('server', 'chat', SessionPanel.codexPlan),
        isFalse,
      );
      await restored.setHidden('server', 'chat', SessionPanel.browser, false);
      expect(panels.isHidden('server', 'chat', SessionPanel.browser), isFalse);
    },
  );

  test('missing identities cannot save global dismissals', () async {
    final panels = SessionPanelPreferences(
      await SharedPreferences.getInstance(),
    );
    expect(
      await panels.setHidden(null, 'chat', SessionPanel.codexPlan, true),
      isFalse,
    );
    expect(panels.isHidden(null, 'chat', SessionPanel.codexPlan), isFalse);
  });

  test('delimiter characters in identities do not collide', () async {
    final panels = SessionPanelPreferences(
      await SharedPreferences.getInstance(),
    );
    await panels.setHidden('a:b', 'c', SessionPanel.codexPlan, true);
    expect(panels.isHidden('a', 'b:c', SessionPanel.codexPlan), isFalse);
  });
}
