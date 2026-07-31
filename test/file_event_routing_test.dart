import 'package:app/models/file_event_routing.dart';
import 'package:app/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('download routing preserves the file owning server', () {
    expect(
      resolveDownloadServerId('server-mac', 'server-active'),
      'server-mac',
    );
    expect(resolveDownloadServerId(null, 'server-active'), 'server-active');
    expect(resolveDownloadServerId('', ''), isNull);
  });

  test('file card requires an explicit matching session', () {
    expect(
      fileEventBelongsToVisibleSession(
        messageSessionId: null,
        activeSessionId: 'session-a',
        messageServerId: 'server-a',
        activeServerId: 'server-a',
      ),
      isFalse,
    );
    expect(
      fileEventBelongsToVisibleSession(
        messageSessionId: 'session-b',
        activeSessionId: 'session-a',
        messageServerId: 'server-a',
        activeServerId: 'server-a',
      ),
      isFalse,
    );
  });

  test('same session id on a different server does not own the card', () {
    expect(
      fileEventBelongsToVisibleSession(
        messageSessionId: 'session-a',
        activeSessionId: 'session-a',
        messageServerId: 'server-b',
        activeServerId: 'server-a',
      ),
      isFalse,
    );
  });

  test('canonical card inherits raw file transport metadata', () {
    final canonical = <String, dynamic>{'file_path': '/tmp/build.apk'};
    mergeSendFileTransportMetadata(canonical, {
      'file_path': '/tmp/build.apk',
      '_file_id': 'file-1',
      '_file_name': 'build.apk',
      '_file_size': 42,
    });

    expect(canonical['_file_id'], 'file-1');
    expect(canonical['_file_name'], 'build.apk');
    expect(canonical['_file_size'], 42);
  });

  test('same-path deliveries bind to separate live cards', () {
    final first = ChatMessage.toolCall(
      tool: 'SendFile',
      input: {'file_path': '/tmp/build.apk', '_file_id': 'delivery-1'},
      toolUseId: 'call-1',
    )..toolStreaming = false;
    final second = ChatMessage.toolCall(
      tool: 'SendFile',
      input: {'file_path': '/tmp/build.apk'},
      toolUseId: 'call-2',
    )..toolStreaming = true;

    expect(
      findSendFileAvailabilityCard(
        [first, second],
        filePath: '/tmp/build.apk',
        fileId: 'delivery-2',
      ),
      1,
    );
    mergeSendFileTransportMetadata(second.toolInput!, {
      '_file_id': 'delivery-2',
    });
    expect(first.toolInput!['_file_id'], 'delivery-1');
    expect(second.toolInput!['_file_id'], 'delivery-2');
  });

  test('completed path-only card cannot steal a later delivery', () {
    final old = ChatMessage.toolCall(
      tool: 'SendFile',
      input: {'file_path': '/tmp/build.apk'},
      toolUseId: 'old-call',
    )..toolStreaming = false;

    expect(
      findSendFileAvailabilityCard(
        [old],
        filePath: '/tmp/build.apk',
        fileId: 'new-delivery',
      ),
      -1,
    );
  });
}
