import 'package:app/models/message.dart';
import 'package:app/util/format.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> listEntry({String? lifetime, String? expiresAt}) => {
  'id': 's1',
  'title': 'Look into the flaky test',
  'cwd': '/home/billy/project',
  'createdAt': '2026-10-28T10:00:00.000Z',
  'lastActive': '2026-10-28T11:00:00.000Z',
  'messagePreview': 'done',
  'lifetime': ?lifetime,
  'expiresAt': ?expiresAt,
};

void main() {
  test('a session list entry from an older server is permanent', () {
    final session = Session.fromJson(listEntry());
    expect(session.isFleeting, isFalse);
    expect(session.expiresAt, isNull);
    expect(
      Session.fromJson(listEntry(lifetime: 'permanent')).isFleeting,
      isFalse,
    );
  });

  test(
    'a fleeting entry carries its deadline through the cache round trip',
    () {
      final session = Session.fromJson(
        listEntry(lifetime: 'fleeting', expiresAt: '2026-10-28T17:00:00.000Z'),
      );
      expect(session.isFleeting, isTrue);
      expect(session.expiresAt, DateTime.parse('2026-10-28T17:00:00.000Z'));

      final cached = Session.fromJson(session.toJson());
      expect(cached.isFleeting, isTrue);
      expect(cached.expiresAt, session.expiresAt);

      // A running fleeting session has no deadline but is still fleeting.
      final running = Session.fromJson(listEntry(lifetime: 'fleeting'));
      expect(running.isFleeting, isTrue);
      expect(running.expiresAt, isNull);
    },
  );

  test('make permanent drops the lifetime and the deadline locally', () {
    final session = Session.fromJson(
      listEntry(lifetime: 'fleeting', expiresAt: '2026-10-28T17:00:00.000Z'),
    );
    final kept = session.copyWith(lifetime: 'permanent');
    expect(kept.isFleeting, isFalse);
    expect(kept.expiresAt, isNull);
    expect(kept.title, session.title);
  });

  test('time left reads in the units a minute ticker can show', () {
    expect(formatTimeLeft(const Duration(seconds: 20)), '< 1m');
    expect(formatTimeLeft(const Duration(minutes: 48)), '48m');
    expect(formatTimeLeft(const Duration(hours: 5, minutes: 12)), '5h 12m');
    expect(formatTimeLeft(const Duration(hours: 6)), '6h');
    expect(formatTimeLeft(const Duration(minutes: -5)), '< 1m');
  });
}
