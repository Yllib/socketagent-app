import 'package:flutter_test/flutter_test.dart';

import 'package:app/models/message.dart';
import 'package:app/models/private_integration_auth.dart';

void main() {
  test('Outlook auth card retains only server-supplied allowlist metadata', () {
    final message = ChatMessage.outlookAuth(
      authRequestId: 'outlook_auth_test',
      startUrl: 'https://mail.example.test/mail/inbox',
      captureOrigins: const ['https://mail.example.test'],
    );

    expect(message.authRequestId, 'outlook_auth_test');
    expect(message.authStartUrl, 'https://mail.example.test/mail/inbox');
    expect(message.authCaptureOrigins, const ['https://mail.example.test']);
    expect(message.type, MessageType.outlookAuth);
  });

  test('IBS auth card retains only server-supplied allowlist metadata', () {
    final message = ChatMessage.ibsAuth(
      authRequestId: 'ibs_auth_test',
      startUrl: 'https://ibs.example.test/app/list',
      captureOrigins: const ['https://ibs.example.test'],
    );

    expect(message.authRequestId, 'ibs_auth_test');
    expect(message.authStartUrl, 'https://ibs.example.test/app/list');
    expect(message.authCaptureOrigins, const ['https://ibs.example.test']);
    expect(message.type, MessageType.ibsAuth);
  });

  test('settings auth messages remain routable from the selected server', () {
    expect(
      isDirectPrivateIntegrationAuthMessage(
        'outlook_auth',
        const {'directRequestId': 'settings-request'},
        directAuthRequestIds: const {},
        hasPendingChallenge: false,
        hasPendingOutcome: false,
      ),
      isTrue,
    );
    expect(
      isDirectPrivateIntegrationAuthMessage(
        'outlook_auth_result',
        const {'authRequestId': 'outlook-auth-request'},
        directAuthRequestIds: const {'outlook-auth-request'},
        hasPendingChallenge: false,
        hasPendingOutcome: false,
      ),
      isTrue,
    );
    expect(
      isDirectPrivateIntegrationAuthMessage(
        'ibs_auth_result',
        const {'authRequestId': 'ibs-auth-request'},
        directAuthRequestIds: const {},
        hasPendingChallenge: false,
        hasPendingOutcome: true,
      ),
      isTrue,
    );
  });

  test('session auth cards still follow visible-session routing', () {
    expect(
      isDirectPrivateIntegrationAuthMessage(
        'outlook_auth',
        const {'authRequestId': 'session-request'},
        directAuthRequestIds: const {},
        hasPendingChallenge: false,
        hasPendingOutcome: false,
      ),
      isFalse,
    );
    expect(
      isDirectPrivateIntegrationAuthMessage(
        'outlook_auth_result',
        const {'authRequestId': 'session-request'},
        directAuthRequestIds: const {},
        hasPendingChallenge: false,
        hasPendingOutcome: false,
      ),
      isFalse,
    );
  });

  test(
    'a pending settings request recovers a challenge missing its marker',
    () {
      expect(
        isDirectPrivateIntegrationAuthMessage(
          'outlook_auth',
          const {'authRequestId': 'outlook-auth-request'},
          directAuthRequestIds: const {},
          hasPendingChallenge: true,
          hasPendingOutcome: false,
        ),
        isTrue,
      );
    },
  );
}
