import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/traced_error.dart';

/// Appends every traced error to `logs/errors.jsonl` in app support. Past
/// 1 MB the file becomes `errors.jsonl.previous`, so the log stays small.
class ErrorLog {
  ErrorLog({Directory? directory}) : _directory = directory;

  static const _maxBytes = 1024 * 1024;

  Directory? _directory;
  Future<void> _writes = Future.value();

  Future<File> _file() async {
    final directory = _directory ??= Directory(
      '${(await getApplicationSupportDirectory()).path}/logs',
    );
    await directory.create(recursive: true);
    return File('${directory.path}/errors.jsonl');
  }

  /// Writes are serialized so concurrent errors never interleave lines.
  Future<void> record(TracedError error) {
    final result = _writes.then((_) async {
      final file = await _file();
      final line = '${jsonEncode(error.toJson())}\n';
      if (await file.exists() &&
          await file.length() + line.length > _maxBytes) {
        await file.rename('${file.path}.previous');
      }
      await file.writeAsString(line, mode: FileMode.append, flush: true);
    });
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
