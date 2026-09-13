import 'package:shared_preferences/shared_preferences.dart';

/// Keep an ambiguous redemption retryable even after the dialog or app closes.
class CodexResetAttempts {
  final Map<String, Future<Map<String, dynamic>>> _inFlight = {};

  Future<Map<String, dynamic>> run(
    String serverId,
    String proposedId,
    Future<Map<String, dynamic>> Function(String id) send,
  ) {
    final pending = _inFlight[serverId];
    if (pending != null) return pending;
    final future = _run(serverId, proposedId, send);
    _inFlight[serverId] = future;
    return future.whenComplete(() => _inFlight.remove(serverId));
  }

  Future<Map<String, dynamic>> _run(
    String serverId,
    String proposedId,
    Future<Map<String, dynamic>> Function(String id) send,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    final key = 'codex_reset_attempt_${Uri.encodeComponent(serverId)}';
    final attempt = preferences.getString(key) ?? proposedId;
    if (!await preferences.setString(key, attempt)) {
      throw StateError('Could not save the reset request. No reset was sent.');
    }
    final result = await send(attempt);
    if ([
      'reset',
      'alreadyRedeemed',
      'nothingToReset',
      'noCredit',
    ].contains(result['outcome'])) {
      await preferences.remove(key);
    }
    return result;
  }
}
