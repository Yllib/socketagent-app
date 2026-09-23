import 'dart:convert';
import 'package:app/models/inline_chat_media.dart';
import 'package:app/services/chat_image_loader.dart';
import 'package:app/services/chat_provider.dart';
import 'package:flutter_test/flutter_test.dart';

class _Files implements ChatProvider {
  final calls = <String?>[];
  bool fail = false;

  @override
  Future<String?> fetchFileManagerFileBase64({
    required String path,
    required String fileName,
    String? serverId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add(serverId);
    if (fail) throw StateError('Disconnected');
    return base64Encode(utf8.encode(serverId!));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'file previews deduplicate but never share bytes between computers',
    () async {
      final loader = ChatImageLoader();
      final files = _Files();
      final image = ChatImageSource.parse(
        'socketagent://image?id=12345678-1234-4123-8123-123456789012',
      );
      final results = await Future.wait([
        loader.load(image, 'computer-a', files),
        loader.load(image, 'computer-a', files),
        loader.load(image, 'computer-b', files),
      ]);
      expect(results.map(utf8.decode), [
        'computer-a',
        'computer-a',
        'computer-b',
      ]);
      expect(files.calls, ['computer-a', 'computer-b']);
      await loader.load(image, 'computer-a', files);
      expect(files.calls, hasLength(2));
      await expectLater(loader.load(image, null, files), throwsStateError);
    },
  );

  test('failed preview can be fetched again after reconnect', () async {
    final loader = ChatImageLoader();
    final files = _Files()..fail = true;
    final image = ChatImageSource.parse(
      'socketagent://image?id=12345678-1234-4123-8123-123456789012',
    );
    await expectLater(loader.load(image, 'computer', files), throwsStateError);
    files.fail = false;
    expect(
      utf8.decode(await loader.load(image, 'computer', files)),
      'computer',
    );
    expect(files.calls, hasLength(2));
  });
}
