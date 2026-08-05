import 'package:flutter_test/flutter_test.dart';

import 'package:app/models/message.dart';

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
}
