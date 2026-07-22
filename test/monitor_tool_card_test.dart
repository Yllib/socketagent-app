import 'dart:convert';

import 'package:app/models/message.dart';
import 'package:app/widgets/monitor_tool_card.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses Monitor MCP metadata without exposing the JSON envelope', () {
    final message = ChatMessage.toolCall(
      tool: 'Monitor',
      input: {
        'command': '/private/tmp/watch-bandscan61-beta-review.sh',
        'description': 'Watch beta review',
        'timeoutSeconds': 7200,
      },
      toolUseId: 'call-1',
    );
    message.toolOutput = jsonEncode({
      'content': [
        {
          'type': 'text',
          'text':
              'Process started and monitoring enabled. '
              'Task ID: monitor-e48ee422. PID: 35783. '
              'Monitoring timeout: 7200s.',
        },
      ],
      'structuredContent': null,
      '_meta': null,
    });

    final details = MonitorToolDetails.fromMessage(message);
    expect(details.description, 'Watch beta review');
    expect(details.taskId, 'monitor-e48ee422');
    expect(details.pid, '35783');
    expect(details.timeoutSeconds, 7200);
    expect(details.status, 'started');
    expect(details.result, isNot(contains('structuredContent')));
  });
}
