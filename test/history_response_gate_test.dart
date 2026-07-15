import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/history_response_gate.dart';

void main() {
  test(
    'rejects an older page from an obsolete request in the same session',
    () {
      final decision = gateSessionHistoryResponse(
        responseSessionId: 'session-1',
        activeSessionId: 'session-1',
        historyKind: 'older',
        requestId: 'old-page',
        expectedInitialRequestId: 'new-snapshot',
        expectedOlderRequestId: null,
        legacyAppend: false,
        legacyLoadingMore: false,
        hasVisibleMessages: true,
      );

      expect(decision.accept, isFalse);
    },
  );

  test('rejects a stale initial snapshot after a newer resume', () {
    final decision = gateSessionHistoryResponse(
      responseSessionId: 'session-1',
      activeSessionId: 'session-1',
      historyKind: 'initial',
      requestId: 'resume-1',
      expectedInitialRequestId: 'resume-2',
      expectedOlderRequestId: null,
      legacyAppend: false,
      legacyLoadingMore: false,
      hasVisibleMessages: true,
    );

    expect(decision.accept, isFalse);
  });

  test('accepts matching initial and older responses with explicit kinds', () {
    final initial = gateSessionHistoryResponse(
      responseSessionId: 'session-1',
      activeSessionId: 'session-1',
      historyKind: 'initial',
      requestId: 'resume-2',
      expectedInitialRequestId: 'resume-2',
      expectedOlderRequestId: 'page-1',
      legacyAppend: false,
      legacyLoadingMore: true,
      hasVisibleMessages: true,
    );
    final older = gateSessionHistoryResponse(
      responseSessionId: 'session-1',
      activeSessionId: 'session-1',
      historyKind: 'older',
      requestId: 'page-1',
      expectedInitialRequestId: null,
      expectedOlderRequestId: 'page-1',
      legacyAppend: false,
      legacyLoadingMore: false,
      hasVisibleMessages: true,
    );

    expect(initial.accept, isTrue);
    expect(initial.kind, SessionHistoryKind.initial);
    expect(older.accept, isTrue);
    expect(older.kind, SessionHistoryKind.older);
  });

  test('accepts live append independently of snapshot request generation', () {
    final decision = gateSessionHistoryResponse(
      responseSessionId: 'session-1',
      activeSessionId: 'session-1',
      historyKind: 'append',
      requestId: null,
      expectedInitialRequestId: 'resume-2',
      expectedOlderRequestId: null,
      legacyAppend: false,
      legacyLoadingMore: false,
      hasVisibleMessages: true,
    );

    expect(decision.accept, isTrue);
    expect(decision.kind, SessionHistoryKind.append);
  });

  test('rejects an unsolicited legacy snapshot over a visible transcript', () {
    final decision = gateSessionHistoryResponse(
      responseSessionId: 'session-1',
      activeSessionId: 'session-1',
      historyKind: null,
      requestId: null,
      expectedInitialRequestId: null,
      expectedOlderRequestId: null,
      legacyAppend: false,
      legacyLoadingMore: false,
      hasVisibleMessages: true,
    );

    expect(decision.accept, isFalse);
  });
}
