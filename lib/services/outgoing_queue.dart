import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

import '../models/composer_attachment.dart';
import '../models/traced_error.dart';
import 'secure_storage_service.dart';

/// A secret attached to a queued message. The value lives in secure storage
/// until the computer saves it; [saved] then holds the computer's reference
/// and the value is deleted.
class QueuedSecret {
  QueuedSecret({
    required this.id,
    required this.label,
    required this.scope,
    required this.envHint,
    this.saved,
    this.value,
  });

  /// Stable across retries, so the computer can tell a retry from a new save.
  final String id;
  final String label;
  final String scope;
  final String envHint;
  SecretMetadata? saved;

  /// Only set between composing and staging. Never written to the outbox.
  String? value;

  Map<String, Object> toJson() => {
    'id': id,
    'label': label,
    'scope': scope,
    'envHint': envHint,
    if (saved case final saved?) 'saved': saved.toJson(),
  };

  factory QueuedSecret.fromJson(Map<String, dynamic> value) => QueuedSecret(
    id: value['id'] as String,
    label: value['label'] as String,
    scope: value['scope'] as String,
    envHint: value['envHint'] as String,
    saved: value['saved'] is Map
        ? SecretMetadata.fromJson(
            Map<String, dynamic>.from(value['saved'] as Map),
          )
        : null,
  );
}

class OutgoingRequest {
  OutgoingRequest({
    required this.id,
    required this.serverId,
    required this.payload,
    required this.displayText,
    required this.createdAt,
    this.files = const [],
    this.secrets = const [],
    this.failure,
  });
  final String id;
  final String serverId;
  final Map<String, dynamic> payload;
  final String displayText;
  final DateTime createdAt;
  final List<Map<String, dynamic>> files;
  final List<QueuedSecret> secrets;

  /// Why this request stopped retrying. It waits for the user once set.
  TracedError? failure;
  String? get error => failure?.message;

  Map<String, dynamic> toJson() => {
    'id': id,
    'serverId': serverId,
    'payload': payload,
    'displayText': displayText,
    'createdAt': createdAt.toIso8601String(),
    'files': files,
    if (secrets.isNotEmpty)
      'secrets': [for (final secret in secrets) secret.toJson()],
    if (failure case final failure?) ...{
      'error': failure.message,
      'failure': failure.toJson(),
    },
  };
  factory OutgoingRequest.fromJson(Map<String, dynamic> value) =>
      OutgoingRequest(
        id: value['id'] as String,
        serverId: value['serverId'] as String,
        payload: Map<String, dynamic>.from(value['payload'] as Map),
        displayText: value['displayText'] as String,
        createdAt: DateTime.parse(value['createdAt'] as String),
        files: (value['files'] as List)
            .map((f) => Map<String, dynamic>.from(f as Map))
            .toList(),
        secrets: [
          for (final secret in value['secrets'] as List? ?? const [])
            QueuedSecret.fromJson(Map<String, dynamic>.from(secret as Map)),
        ],
        failure:
            TracedError.fromJson(value['failure']) ??
            switch (value['error']) {
              // Records from before errors carried IDs.
              final String message => TracedError(
                kind: 'delivery_failed',
                message: message,
              ),
              _ => null,
            },
      );
}

/// The record is committed before any network write. Files are copied into
/// app storage so deleting a picker temporary file cannot break a queued send.
class OutgoingQueue {
  OutgoingQueue({Directory? directory, SecureStorageService? secretStore})
    : _directory = directory,
      _secretStore = secretStore ?? SecureStorageService();
  Directory? _directory;
  final SecureStorageService _secretStore;
  Future<void> _writes = Future.value();
  Future<Directory> _root() async {
    final directory = _directory ??= Directory(
      '${(await getApplicationSupportDirectory()).path}/outgoing-v1',
    );
    await directory.create(recursive: true);
    return directory;
  }

  String _name(String id) =>
      base64Url.encode(utf8.encode(id)).replaceAll('=', '');
  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _writes.then((_) => operation());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<List<OutgoingRequest>> load() => _serial(() async {
    final root = await _root();
    final requests = <OutgoingRequest>[];
    await for (final file in root.list()) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      requests.add(
        OutgoingRequest.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>,
        ),
      );
    }
    requests.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return requests;
  });
  Future<void> stage(OutgoingRequest request) => _serial(() async {
    final root = await _root();
    final attachments = Directory('${root.path}/${_name(request.id)}');
    if (request.files.isNotEmpty) await attachments.create(recursive: true);
    for (var i = 0; i < request.files.length; i++) {
      final item = request.files[i];
      final copy = await File(
        item['path'] as String,
      ).copy('${attachments.path}/$i');
      item['path'] = copy.path;
    }
    // Values go to secure storage first, so a record on disk always has its
    // values available. A stage that fails leaves nothing behind.
    final written = <String>[];
    try {
      for (final secret in request.secrets) {
        final value = secret.value;
        if (value == null) continue;
        final key = _secretKey(request.id, secret);
        await _secretStore.setOutgoingSecret(key, value);
        written.add(key);
      }
      await _write(root, request.id, jsonEncode(request.toJson()));
    } catch (_) {
      for (final key in written) {
        await _secretStore.deleteOutgoingSecret(key);
      }
      if (await attachments.exists()) await attachments.delete(recursive: true);
      rethrow;
    }
    for (final secret in request.secrets) {
      secret.value = null;
    }
  });

  String _secretKey(String requestId, QueuedSecret secret) =>
      '${_name(requestId)}:${secret.id}';

  /// The queued value of [secret], or null when it is gone.
  Future<String?> secretValue(String requestId, QueuedSecret secret) =>
      _secretStore.getOutgoingSecret(_secretKey(requestId, secret));

  /// Deletes a value the computer has saved.
  Future<void> forgetSecretValue(String requestId, QueuedSecret secret) =>
      _secretStore.deleteOutgoingSecret(_secretKey(requestId, secret));
  Future<void> save(OutgoingRequest request) {
    final encoded = jsonEncode(request.toJson());
    return _serial(() async => _write(await _root(), request.id, encoded));
  }

  Future<void> _write(Directory root, String id, String encoded) async {
    final file = File('${root.path}/${_name(id)}.json');
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(encoded, flush: true);
    await temporary.rename(file.path);
  }

  Future<void> remove(String id) => _serial(() async {
    final root = await _root();
    final file = File('${root.path}/${_name(id)}.json');
    if (await file.exists()) {
      final request = OutgoingRequest.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
      for (final secret in request.secrets) {
        await _secretStore.deleteOutgoingSecret(_secretKey(id, secret));
      }
      await file.delete();
    }
    final attachments = Directory('${root.path}/${_name(id)}');
    if (await attachments.exists()) await attachments.delete(recursive: true);
  });
  Future<void> flush() => _writes;
}
