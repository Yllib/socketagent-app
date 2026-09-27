import 'dart:io';
import 'package:app/services/outgoing_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'saved prompt and attachment survive restart and deletion of the original',
    () async {
      final dir = await Directory.systemTemp.createTemp('outbox-test-');
      try {
        final source = File('${dir.path}/picked.png');
        await source.writeAsString('snapshot');
        final root = Directory('${dir.path}/queue');
        final queue = OutgoingQueue(directory: root);
        final request = OutgoingRequest(
          id: 'one',
          serverId: 'server-a',
          payload: {
            'type': 'prompt',
            'messageId': 'one',
            'sessionId': 'thread-a',
            'text': 'look',
          },
          displayText: 'look',
          createdAt: DateTime(2026),
          files: [
            {'path': source.path, 'name': 'picked.png'},
          ],
        );
        await queue.stage(request);
        await source.delete();
        final restored = (await OutgoingQueue(directory: root).load()).single;
        expect(restored.payload['messageId'], 'one');
        expect(restored.payload['sessionId'], 'thread-a');
        expect(restored.serverId, 'server-a');
        expect(
          await File(restored.files.single['path'] as String).readAsString(),
          'snapshot',
        );
        restored.files.single['serverPath'] = '/uploads/picked.png';
        await queue.save(restored);
        expect(
          (await OutgoingQueue(
            directory: root,
          ).load()).single.files.single['serverPath'],
          '/uploads/picked.png',
        );
        await queue.remove(restored.id);
        expect(await queue.load(), isEmpty);
        expect(
          await File(restored.files.single['path'] as String).exists(),
          isFalse,
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'receipt removal waits for outstanding writes and cannot resurrect a request',
    () async {
      final root = await Directory.systemTemp.createTemp('outbox-write-test-');
      try {
        final queue = OutgoingQueue(directory: root);
        final request = OutgoingRequest(
          id: 'id',
          serverId: 'server',
          payload: {'type': 'prompt', 'text': 'hello'},
          displayText: 'hello',
          createdAt: DateTime.now(),
        );
        await queue.stage(request);
        final writing = queue.save(request);
        final removing = queue.remove(request.id);
        await Future.wait([writing, removing]);
        expect(await OutgoingQueue(directory: root).load(), isEmpty);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
