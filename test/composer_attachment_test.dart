import 'package:app/models/composer_attachment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes common photo attachment extensions', () {
    expect(PendingFileAttachment.looksLikeImage('photo.JPG'), isTrue);
    expect(PendingFileAttachment.looksLikeImage('capture.heic'), isTrue);
    expect(PendingFileAttachment.looksLikeImage('notes.txt'), isFalse);
  });

  test('parses metadata without a stored value', () {
    final metadata = SecretMetadata.fromJson({
      'secretId': 'sec_123',
      'label': 'DESKTOP_PASSWORD',
      'scope': 'session',
      'filePath': '/secure/session/DESKTOP_PASSWORD_sec_123',
      'envHint': 'DESKTOP_PASSWORD',
      'createdAt': '2026-07-15T12:00:00.000Z',
      'updatedAt': '2026-07-15T13:00:00.000Z',
    });

    expect(metadata.secretId, 'sec_123');
    expect(metadata.scope, 'session');
    expect(metadata.updatedAt, DateTime.utc(2026, 7, 15, 13));
  });

  test('queued secret value can be erased after storage or removal', () {
    final attachment = PendingSecretAttachment.newValue(
      label: 'TOKEN',
      value: 'top-secret',
      scope: 'project',
      envHint: 'TOKEN',
    );

    expect(attachment.needsStorage, isTrue);
    attachment.clearValue();
    expect(attachment.value, isEmpty);
  });

  test('stored secret attachment contains metadata only', () {
    final metadata = SecretMetadata.fromJson({
      'secretId': 'sec_456',
      'label': 'TOKEN',
      'scope': 'global',
      'filePath': '/secure/global/TOKEN_sec_456',
      'envHint': 'TOKEN',
      'createdAt': '2026-07-15T12:00:00.000Z',
    });
    final attachment = PendingSecretAttachment.stored(metadata);

    expect(attachment.needsStorage, isFalse);
    expect(attachment.value, isEmpty);
    expect(attachment.metadata, same(metadata));
  });
}
