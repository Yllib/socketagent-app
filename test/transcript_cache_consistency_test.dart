import 'dart:io';
import 'package:app/services/session_transcript_cache.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final snapshot = <String, dynamic>{
    'offset': 0,
    'total': 2,
    'messages': [
      {
        'sessionSeq': 1,
        'entryId': 'a',
        'revision': 1,
        'role': 'assistant',
        'content': 'first',
      },
      {
        'sessionSeq': 2,
        'entryId': 'b',
        'revision': 1,
        'role': 'user',
        'content': 'second',
      },
    ],
  };
  test(
    'checkpoint digest covers earlier entries and revisions, not only the final cursor',
    () {
      final cache = SessionTranscriptCache();
      final original = cache.historyDigest(snapshot);
      final changed = {
        ...snapshot,
        'messages': [
          {
            ...(snapshot['messages'] as List).first as Map<String, dynamic>,
            'revision': 2,
          },
          (snapshot['messages'] as List).last,
        ],
      };
      expect(cache.resumeCheckpoint(changed), cache.resumeCheckpoint(snapshot));
      expect(cache.historyDigest(changed), isNot(original));
    },
  );
  test(
    'cold disk read cannot resurrect a snapshot invalidated or replaced during the read',
    () async {
      final root = await Directory.systemTemp.createTemp('cache-generation-');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => root.path,
      );
      try {
        await SessionTranscriptCache().save('server', 'thread', snapshot);
        final cold = SessionTranscriptCache();
        final loading = cold.load('server', 'thread');
        await cold.invalidate('server', 'thread');
        expect(await loading, isNull);
        expect(cold.peek('server', 'thread'), isNull);
        await SessionTranscriptCache().save('server', 'thread', snapshot);
        final next = SessionTranscriptCache();
        final old = next.load('server', 'thread');
        final replacement = {
          ...snapshot,
          'messages': [(snapshot['messages'] as List).first],
          'total': 1,
        };
        await next.save('server', 'thread', replacement);
        expect((await old)?['total'], 1);
        expect(
          (await SessionTranscriptCache().load('server', 'thread'))?['total'],
          1,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
