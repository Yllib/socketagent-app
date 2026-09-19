import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/backend_warning.dart';

/// A computer's backend health, as the server reports it.
Map<String, dynamic> backend(
  String name,
  String severity, {
  String? kind,
  String? reason,
}) => {
  'backend': name,
  'enabled': true,
  'available': severity == 'ok',
  'severity': severity,
  if (kind != null) 'kind': kind,
  if (reason != null) 'reason': reason,
};

void main() {
  // The complaint this rule exists for: a computer set up for one backend was
  // permanently flagged over the one its owner never intended to configure.
  test('an unsigned backend is not a fault when the other one works', () {
    expect(
      backendWarningFor([
        backend('claude', 'ok'),
        backend('codex', 'error', kind: 'auth', reason: 'Codex is not signed in'),
      ]),
      isNull,
    );
    expect(
      backendWarningFor([
        backend('claude', 'error', kind: 'auth', reason: 'Claude is not signed in'),
        backend('codex', 'ok'),
      ]),
      isNull,
    );
  });

  test('a computer with no way to run a turn is flagged', () {
    final warning = backendWarningFor([
      backend('claude', 'error', kind: 'auth'),
      backend('codex', 'error', kind: 'auth'),
    ]);
    expect(warning, isNotNull);
    expect(warning!['severity'], 'error');
    expect(warning['label'], 'No backend signed in');
    expect(warning['reason'], contains('Neither Claude nor Codex'));
  });

  // A broken install is a fault, not a choice, so the specific reason beats a
  // summary that would blame authentication for it.
  test('a non-auth failure reports itself rather than the summary', () {
    final warning = backendWarningFor([
      backend('claude', 'error', kind: 'install', reason: 'Claude CLI was not found.'),
      backend('codex', 'error', kind: 'auth'),
    ]);
    expect(warning!['reason'], 'Claude CLI was not found.');
  });

  test('a working but degraded backend still gets a nudge', () {
    expect(
      backendWarningFor([
        backend('claude', 'warning', reason: 'Claude is using the system install.'),
        backend('codex', 'ok'),
      ])!['reason'],
      contains('system install'),
    );
  });

  test('all healthy, and no health at all, say nothing', () {
    expect(
      backendWarningFor([backend('claude', 'ok'), backend('codex', 'ok')]),
      isNull,
    );
    expect(backendWarningFor([]), isNull);
  });

  // Servers older than the `kind` field send none, so the rule still has to
  // hold on the signal that matters: whether anything is usable.
  test('a server that sends no kind is still judged on what works', () {
    expect(
      backendWarningFor([backend('claude', 'ok'), backend('codex', 'error')]),
      isNull,
    );
    expect(
      backendWarningFor([backend('claude', 'error'), backend('codex', 'error')]),
      isNotNull,
    );
  });
}
