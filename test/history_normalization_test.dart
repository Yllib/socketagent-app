import 'package:app/models/history_normalization.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('collapses adjacent synthetic and canonical SendFile pairs', () {
    final normalized = normalizeSendFileHistoryEntries([
      {
        'role': 'tool_call',
        'toolName': 'SendFile',
        'toolUseId': 'exec-1',
        'toolInput': {'file_path': '/tmp/app.apk'},
        'timestamp': '2026-07-15T12:00:00.000Z',
      },
      {
        'role': 'tool_call',
        'toolName': 'SendFile',
        'toolUseId': 'mcp_SendFile_duplicate',
        'toolInput': {'file_path': '/tmp/app.apk'},
        'fileId': 'file-1',
        'fileName': 'app.apk',
        'fileSize': 42,
        'fileVersion': 'v1',
        'fileDeliveryPath': '/data/send-files/file-1/app.apk',
        'timestamp': '2026-07-15T12:00:00.010Z',
      },
      {
        'role': 'tool_result',
        'toolUseId': 'mcp_SendFile_duplicate',
        'toolOutput': 'ready',
      },
      {'role': 'tool_result', 'toolUseId': 'exec-1', 'toolOutput': 'ready'},
    ]);

    expect(normalized, hasLength(2));
    expect(normalized.first['toolUseId'], 'exec-1');
    expect(normalized.first['fileId'], 'file-1');
    expect(
      normalized.first['fileDeliveryPath'],
      '/data/send-files/file-1/app.apk',
    );
    expect(normalized.last['toolUseId'], 'exec-1');
  });

  test('preserves deliberate later sends of the same path', () {
    final normalized = normalizeSendFileHistoryEntries([
      {
        'role': 'tool_call',
        'toolName': 'SendFile',
        'toolUseId': 'exec-1',
        'toolInput': {'file_path': '/tmp/app.apk'},
        'timestamp': '2026-07-15T12:00:00.000Z',
      },
      {'role': 'assistant', 'content': 'later'},
      {
        'role': 'tool_call',
        'toolName': 'SendFile',
        'toolUseId': 'exec-2',
        'toolInput': {'file_path': '/tmp/app.apk'},
        'timestamp': '2026-07-15T12:01:00.000Z',
      },
    ]);

    expect(
      normalized.where((entry) => entry['role'] == 'tool_call'),
      hasLength(2),
    );
  });

  test('removes misclassified known Codex items and their results', () {
    final normalized = normalizeSendFileHistoryEntries([
      {
        'role': 'tool_call',
        'toolName': 'CodexItem',
        'toolUseId': 'msg-1',
        'toolInput': {
          '_codexItemType': 'unrecognized',
          'itemType': 'agentMessage',
        },
      },
      {'role': 'tool_result', 'toolUseId': 'msg-1', 'toolOutput': 'unexpected'},
      {'role': 'assistant', 'content': 'The real message'},
      {
        'role': 'tool_call',
        'toolName': 'CodexItem',
        'toolUseId': 'future-1',
        'toolInput': {
          '_codexItemType': 'unrecognized',
          'itemType': 'futureProtocolItem',
        },
      },
    ]);

    expect(normalized.where((entry) => entry['toolUseId'] == 'msg-1'), isEmpty);
    expect(
      normalized.any((entry) => entry['content'] == 'The real message'),
      isTrue,
    );
    expect(normalized.any((entry) => entry['toolUseId'] == 'future-1'), isTrue);
  });

  test('removes duplicate raw NotifyUser calls but keeps its receipt', () {
    final normalized = normalizeSendFileHistoryEntries([
      {
        'role': 'tool_call',
        'toolName': 'NotifyUser',
        'toolUseId': 'notify-1',
        'toolInput': {'title': 'Alert', 'body': 'Details'},
      },
      {
        'role': 'tool_result',
        'toolUseId': 'notify-1',
        'toolOutput': 'Notification sent',
      },
      {
        'role': 'notification',
        'status': 'manual',
        'content': 'Alert\nDetails',
        'toolInput': {'title': 'Alert', 'body': 'Details'},
      },
    ]);

    expect(
      normalized.any((entry) => entry['toolUseId'] == 'notify-1'),
      isFalse,
    );
    expect(normalized.single['role'], 'notification');
  });
}
