import 'dart:async';
import 'dart:math';

typedef TransferRequest =
    Future<Map<String, dynamic>> Function(
      String serverId,
      Map<String, dynamic> message,
    );

String newTeleportId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// The app authorizes durable jobs and watches them. Session bytes never cross it.
class SessionTeleport {
  SessionTeleport({
    required this.request,
    this.pollInterval = const Duration(seconds: 2),
  });
  final TransferRequest request;
  final Duration pollInterval;

  Future<Map<String, dynamic>?> status(String serverId, String jobId) async {
    final reply = await request(serverId, {
      'type': 'session_transfer_job',
      'action': 'status',
      'jobId': jobId,
    });
    if (reply['ok'] != true) {
      throw StateError(
        reply['error']?.toString() ?? 'Could not read transfer status',
      );
    }
    return reply['job'] is Map
        ? Map<String, dynamic>.from(reply['job'] as Map)
        : null;
  }

  Future<void> start(String serverId, Map<String, dynamic> config) async {
    for (var attempt = 0; ; attempt++) {
      try {
        final reply = await request(serverId, {
          'type': 'session_transfer_job',
          'action': 'start',
          'config': config,
        });
        if (reply['ok'] != true) {
          throw StateError(
            reply['error']?.toString() ?? 'Could not start transfer',
          );
        }
        return;
      } on TimeoutException {
        if (attempt >= 2) rethrow;
        // An acknowledgement can be lost after the server accepted the job.
        // Retrying the same ID is safe and never exports/imports a second copy.
      }
    }
  }

  Future<Map<String, dynamic>?> watch({
    required String serverId,
    required String jobId,
    String? peerServerId,
    required void Function(Map<String, dynamic>) onProgress,
    bool Function()? keepWatching,
  }) async {
    while (keepWatching?.call() ?? true) {
      try {
        final job = await status(serverId, jobId);
        if (job != null) {
          onProgress(job);
          if (job['phase'] == 'completed') return job;
          if (job['phase'] == 'failed') {
            throw StateError(
              job['error']?.toString() ?? 'Transfer paused. Retry to continue.',
            );
          }
        }
      } on TimeoutException {
        onProgress({'phase': 'waiting', 'connectionLost': true});
      }
      if (peerServerId != null) {
        try {
          final peer = await status(peerServerId, jobId);
          if (peer?['phase'] == 'failed') {
            throw StateError(
              peer?['error']?.toString() ??
                  'The destination paused this transfer.',
            );
          }
        } on TimeoutException {
          // The server reconnects independently; keep watching the accepted job.
        }
      }
      await Future<void>.delayed(pollInterval);
    }
    return null;
  }
}
