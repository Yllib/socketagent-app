import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import '../models/inline_chat_media.dart';
import 'chat_provider.dart';

/// Cache by owning computer, never by whichever computer is currently selected.
class ChatImageLoader {
  static final shared = ChatImageLoader();
  static const maxImageBytes = 20 * 1024 * 1024;
  final _cache = <String, Uint8List>{};
  final _pending = <String, Future<Uint8List>>{};
  var _cacheBytes = 0;

  Future<Uint8List> load(
    ChatImageSource source,
    String? serverId,
    ChatProvider? provider,
  ) {
    final key = '$serverId:${source.source}';
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return Future.value(cached);
    }
    return _pending.putIfAbsent(key, () async {
      try {
        final bytes = await _fetch(source, serverId, provider);
        if (bytes.isEmpty || bytes.length > maxImageBytes) {
          throw const FormatException(
            'Image preview must be between 1 byte and 20 MB.',
          );
        }
        _cache[key] = bytes;
        _cacheBytes += bytes.length;
        while (_cacheBytes > 48 * 1024 * 1024 && _cache.isNotEmpty) {
          _cacheBytes -= _cache.remove(_cache.keys.first)!.length;
        }
        return bytes;
      } finally {
        _pending.remove(key);
      }
    });
  }

  Future<Uint8List> _fetch(
    ChatImageSource source,
    String? serverId,
    ChatProvider? provider,
  ) async {
    if (serverId == null || provider == null) {
      throw StateError('The computer for this image is unavailable.');
    }
    final data = await provider.fetchFileManagerFileBase64(
      path: source.source,
      fileName: source.fileName,
      serverId: serverId,
    );
    if (data == null) throw StateError('The computer did not return an image.');
    if (data.length > ((maxImageBytes + 2) ~/ 3) * 4) {
      throw const FormatException('Image exceeds 20 MB.');
    }
    return base64Decode(data);
  }

  static Future<bool> save(ChatImageSource source, Uint8List bytes) async {
    final name = source.fileName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final target = await FilePicker.platform.saveFile(
      dialogTitle: 'Save image',
      fileName: name,
      bytes: bytes,
    );
    if (target == null) return false;
    // Mobile's document picker writes the bytes; desktop returns the chosen path.
    if (!Platform.isAndroid && !Platform.isIOS) {
      await File(target).writeAsBytes(bytes, flush: true);
    }
    return true;
  }
}
