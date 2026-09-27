import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class OutgoingRequest {
  OutgoingRequest({
    required this.id,
    required this.serverId,
    required this.payload,
    required this.displayText,
    required this.createdAt,
    this.files = const [],
    this.error,
  });
  final String id;
  final String serverId;
  final Map<String, dynamic> payload;
  final String displayText;
  final DateTime createdAt;
  final List<Map<String, dynamic>> files;
  String? error;
  Map<String, dynamic> toJson() => {
    'id': id,
    'serverId': serverId,
    'payload': payload,
    'displayText': displayText,
    'createdAt': createdAt.toIso8601String(),
    'files': files,
    if (error != null) 'error': error,
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
        error: value['error'] as String?,
      );
}

/// The record is committed before any network write. Files are copied into
/// app storage so deleting a picker temporary file cannot break a queued send.
class OutgoingQueue {
  OutgoingQueue({Directory? directory}) : _directory = directory;
  Directory? _directory;
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
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
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
    await _write(root, request.id, jsonEncode(request.toJson()));
  });
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
    if (await file.exists()) await file.delete();
    final attachments = Directory('${root.path}/${_name(id)}');
    if (await attachments.exists()) await attachments.delete(recursive: true);
  });
  Future<void> flush() => _writes;
}
