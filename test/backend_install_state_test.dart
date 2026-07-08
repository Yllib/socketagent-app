import 'package:app/services/chat_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts Codex authCode progress field', () {
    final state = BackendInstallState(
      backend: 'codex',
      requestId: 'test',
      operation: 'auth',
    );

    state.apply({
      'backend': 'codex',
      'operation': 'auth',
      'phase': 'auth',
      'status': 'running',
      'message':
          'Open the OpenAI Codex device page and enter the one-time code.',
      'authUrl': 'https://auth.openai.com/codex/device',
      'authCode': 'USKH-199UY',
    });

    expect(state.authUrl, 'https://auth.openai.com/codex/device');
    expect(state.authCode, 'USKH-199UY');
  });

  test('parses Codex output code without consuming the next line', () {
    final state = BackendInstallState(
      backend: 'codex',
      requestId: 'test',
      operation: 'auth',
    );

    state.apply({
      'backend': 'codex',
      'operation': 'auth',
      'phase': 'auth',
      'status': 'running',
      'output': '''
Welcome to Codex [v0.142.3]
OpenAI's command-line coding agent

Follow these steps to sign in with ChatGPT using device code authorization:

1. Open this link in your browser and sign in to your account
   https://auth.openai.com/codex/device

2. Enter this one-time code (expires in 15 minutes)
   USKH-199UY
Device codes are a common phishing target.
Never share this code.
''',
    });

    expect(state.authUrl, 'https://auth.openai.com/codex/device');
    expect(state.authCode, 'USKH-199UY');
  });

  test('rejects instructional false-positive device code text', () {
    final state = BackendInstallState(
      backend: 'codex',
      requestId: 'test',
      operation: 'auth',
    );

    state.apply({
      'backend': 'codex',
      'operation': 'auth',
      'phase': 'auth',
      'status': 'running',
      'output': '''
Open the OpenAI Codex device page and enter the one-time code.
Waiting for device code...
''',
    });

    expect(state.authCode, isNull);
  });

  test('does not parse hyphenated prose before one-time marker', () {
    final state = BackendInstallState(
      backend: 'codex',
      requestId: 'test',
      operation: 'auth',
    );

    state.apply({
      'backend': 'codex',
      'operation': 'auth',
      'phase': 'auth',
      'status': 'running',
      'output': '''
Welcome to Codex [v0.142.3]
OpenAI's command-line coding agent

Follow these steps to sign in with ChatGPT using device code authorization:
''',
    });

    expect(state.authCode, isNull);
  });
}
