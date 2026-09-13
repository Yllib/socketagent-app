import 'dart:async';
import 'package:app/services/codex_reset_attempts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'ambiguous reset survives reopen and successful outcome starts a new attempt',
    () async {
      final seen = <String>[];
      await expectLater(
        CodexResetAttempts().run('server', 'first', (id) async {
          seen.add(id);
          throw StateError('lost reply');
        }),
        throwsStateError,
      );
      await CodexResetAttempts().run('server', 'second', (id) async {
        seen.add(id);
        return {'outcome': 'alreadyRedeemed'};
      });
      await CodexResetAttempts().run('server', 'third', (id) async {
        seen.add(id);
        return {'outcome': 'nothingToReset'};
      });
      expect(seen, ['first', 'first', 'third']);
    },
  );
  test(
    'concurrent clicks share one request and servers retain separate attempts',
    () async {
      final service = CodexResetAttempts();
      final reply = Completer<Map<String, dynamic>>();
      var calls = 0;
      Future<Map<String, dynamic>> send(String id) {
        calls++;
        return reply.future;
      }

      final first = service.run('server', 'one', send);
      final second = service.run('server', 'two', send);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      reply.complete({'outcome': 'reset'});
      await Future.wait([first, second]);
      await service.run('different-server', 'separate', (id) async {
        expect(id, 'separate');
        return {'outcome': 'noCredit'};
      });
    },
  );
}
