import 'dart:async';

/// Bounded application-level send window for file uploads.
///
/// WebSocket/TCP ordering only proves bytes were queued locally. Server
/// acknowledgements prove each chunk was consumed and prevent a file from
/// filling the transport ahead of later interactive traffic.
class UploadAckGate {
  UploadAckGate({
    required this.enabled,
    this.maxOutstandingChunks = 4,
    this.ackTimeout = const Duration(seconds: 30),
  });

  final bool enabled;
  final int maxOutstandingChunks;
  final Duration ackTimeout;

  int _ackedChunks = 0;
  Completer<void>? _changed;
  bool _disposed = false;

  void noteAck(int receivedChunks) {
    if (receivedChunks > _ackedChunks) _ackedChunks = receivedChunks;
    final changed = _changed;
    _changed = null;
    if (changed != null && !changed.isCompleted) changed.complete();
  }

  Future<void> waitForWindow(int sentChunks) async {
    if (!enabled) return;
    while (!_disposed && sentChunks - _ackedChunks >= maxOutstandingChunks) {
      _changed ??= Completer<void>();
      await _changed!.future.timeout(
        ackTimeout,
        onTimeout: () {
          throw TimeoutException(
            'Upload stalled waiting for computer acknowledgement',
          );
        },
      );
    }
  }

  void dispose() {
    _disposed = true;
    final changed = _changed;
    _changed = null;
    if (changed != null && !changed.isCompleted) changed.complete();
  }
}
