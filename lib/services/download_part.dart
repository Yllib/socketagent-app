import 'dart:convert';
import 'dart:io';

class DownloadIncomplete implements Exception {
  @override
  String toString() => 'Download ended before all bytes arrived';
}

/// A contiguous prefix on disk and the identity it belongs to. Callers serialize
/// operations per transfer. Only flushed bytes count as received or acknowledged.
class DownloadPart {
  DownloadPart(this.file, {Map<String, dynamic>? metadata})
    : metadata = metadata ?? {};

  final File file;
  Map<String, dynamic> metadata;
  Future<void> _savePending = Future<void>.value();
  File get manifest => File('${file.path}.json');
  String? get version => metadata['version'] as String?;
  int? get total => (metadata['total'] as num?)?.toInt();
  Future<int> get length async => await file.exists() ? file.length() : 0;

  Future<void> load() async {
    if (await manifest.exists()) {
      try {
        metadata = {
          ...metadata,
          ...Map<String, dynamic>.from(
            jsonDecode(await manifest.readAsString()) as Map,
          ),
        };
      } on FormatException {
        /* A missing identity forces a safe fresh response. */
      }
    }
  }

  Future<void> save() {
    final json = jsonEncode(metadata);
    final result = _savePending.then((_) async {
      await file.parent.create(recursive: true);
      final pending = File('${manifest.path}.new');
      await pending.writeAsString(json, flush: true);
      await pending.rename(manifest.path);
    });
    _savePending = result.catchError((Object _) {});
    return result;
  }

  Future<void> begin({
    required int offset,
    required int? size,
    required String? identity,
  }) async {
    final saved = await length;
    if (offset < 0 || (size != null && (size < 0 || offset > size))) {
      throw const FormatException('Invalid download size or offset');
    }
    if (offset > 0 &&
        (offset != saved || identity == null || identity != version)) {
      throw const FormatException('File identity or resume offset changed');
    }
    if (offset == 0) {
      // Invalidate the old identity before truncating. A crash at either point
      // must never leave old bytes labelled as the new source revision.
      metadata.remove('version');
      await save();
      await file.writeAsBytes(const [], flush: true);
    }
    metadata['version'] = identity;
    metadata['total'] = size;
    metadata['state'] = 'active';
    await save();
  }

  Future<int> append(int offset, List<int> bytes) async {
    final saved = await length;
    if (offset > saved || offset < 0) {
      throw const FormatException('Gap in download');
    }
    final overlap = saved - offset;
    if (overlap >= bytes.length) return saved;
    final data = bytes.sublist(overlap);
    if (total != null && saved + data.length > total!) {
      throw const FormatException('Download exceeds expected size');
    }
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.writeFrom(data);
      await handle.flush();
    } finally {
      await handle.close();
    }
    return saved + data.length;
  }

  Future<void> verifyComplete([int? expected]) async {
    final size = expected ?? total;
    if (size != null && await length != size) {
      throw DownloadIncomplete();
    }
  }

  Future<void> discard() async {
    if (await file.exists()) await file.delete();
    if (await manifest.exists()) await manifest.delete();
  }
}
