import 'package:app/models/file_event_routing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
