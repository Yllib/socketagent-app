import 'dart:math';

/// An error the user saw. Its ID is shown in the app and written to the app's
/// error log, the computer's log, and any report the user sends, so one
/// string finds the same failure everywhere.
class TracedError {
  TracedError({
    required this.kind,
    required this.message,
    this.serverId,
    this.sessionId,
    String? id,
    DateTime? occurredAt,
  }) : id = id ?? newErrorId(),
       occurredAt = occurredAt ?? DateTime.now();

  final String id;

  /// What failed, in snake_case: `secret_store`, `upload`, `server_error`.
  final String kind;
  final String message;
  final String? serverId;
  final String? sessionId;
  final DateTime occurredAt;

  /// Reads a record written by [toJson]. Returns null for anything else.
  static TracedError? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final kind = value['kind'];
    final message = value['message'];
    if (id is! String || kind is! String || message is! String) return null;
    final serverId = value['serverId'];
    final sessionId = value['sessionId'];
    final occurredAt = value['occurredAt'];
    return TracedError(
      id: id,
      kind: kind,
      message: message,
      serverId: serverId is String ? serverId : null,
      sessionId: sessionId is String ? sessionId : null,
      occurredAt: occurredAt is String
          ? DateTime.tryParse(occurredAt)?.toLocal()
          : null,
    );
  }

  Map<String, String> toJson() => {
    'id': id,
    'kind': kind,
    'message': message,
    'occurredAt': occurredAt.toUtc().toIso8601String(),
    'serverId': ?serverId,
    'sessionId': ?sessionId,
  };
}

/// `E-` and eight uppercase hex digits. Short enough to read out loud.
String newErrorId() {
  final random = Random.secure();
  final digits = List.generate(8, (_) => random.nextInt(16).toRadixString(16));
  return 'E-${digits.join().toUpperCase()}';
}
