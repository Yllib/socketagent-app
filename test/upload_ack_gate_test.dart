import 'dart:async';

import 'package:app/services/upload_ack_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'upload gate blocks at the configured outstanding chunk limit',
    () async {
      final gate = UploadAckGate(
        enabled: true,
        maxOutstandingChunks: 2,
        ackTimeout: const Duration(seconds: 1),
      );

      var released = false;
      final wait = gate.waitForWindow(2).then((_) => released = true);
      await Future<void>.delayed(Duration.zero);
      expect(released, isFalse);

      gate.noteAck(1);
      await wait;
      expect(released, isTrue);
      gate.dispose();
    },
  );

  test('disabled upload gate never blocks legacy servers', () async {
    final gate = UploadAckGate(enabled: false);
    await gate.waitForWindow(1000).timeout(const Duration(milliseconds: 100));
    gate.dispose();
  });

  test('upload gate fails a stalled acknowledged transfer', () async {
    final gate = UploadAckGate(
      enabled: true,
      maxOutstandingChunks: 1,
      ackTimeout: const Duration(milliseconds: 20),
    );

    await expectLater(gate.waitForWindow(1), throwsA(isA<TimeoutException>()));
    gate.dispose();
  });
}
