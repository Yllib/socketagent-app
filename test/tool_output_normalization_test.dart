import 'dart:convert';

import 'package:app/widgets/tool_output_block.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extracts readable text from Codex dynamic exec content items', () {
    final raw = jsonEncode([
      {
        'type': 'input_text',
        'text': 'Script completed\nWall time 0.4 seconds\nOutput:\n',
      },
      {
        'type': 'input_text',
        'text': jsonEncode({
          'chunk_id': '77b278',
          'wall_time_seconds': 0.4,
          'exit_code': 0,
          'output': '15 files changed, 291 insertions(+), 75 deletions(-)',
        }),
      },
    ]);

    expect(
      normalizeStructuredToolOutput(raw),
      'Script completed\nWall time 0.4 seconds\nOutput:\n'
      '15 files changed, 291 insertions(+), 75 deletions(-)',
    );
  });

  test('preserves ordinary JSON tool output', () {
    const raw = '{"status":"ok","output":"user data"}';
    expect(normalizeStructuredToolOutput(raw), raw);
  });
}
