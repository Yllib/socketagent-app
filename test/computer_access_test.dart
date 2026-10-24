import 'package:app/models/computer_access.dart';
import 'package:app/models/device_registry.dart';
import 'package:app/models/message.dart';
import 'package:app/widgets/computer_access_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final approval = {
    'type': 'computer_access_request',
    'requestId': 'req1',
    'sessionId': 's1',
    'kind': 'approval',
    'source': {'name': 'Dev VM', 'publicKey': 'A'},
    'target': {'name': 'Desktop', 'publicKey': 'B'},
    'action': 'run_command',
    'summary': 'cd ~/proj && npm test',
    'challengeId': 'c1',
    'digest': 'abc',
    'expiresAt': 1760300000000,
  };

  test('an approval card parses and builds the token payload', () {
    final request = ComputerAccessRequest.fromJson(approval)!;
    expect(request.isLink, isFalse);
    expect(request.pending, isTrue);
    expect(request.actionLabel, 'Run a command');
    expect(request.sourcePublicKey, 'A');
    expect(request.approvalPayload(scope: 'chat', sourceKey: 'A'), {
      'digest': 'abc',
      'challengeId': 'c1',
      'scope': 'chat',
      'sourceSessionId': 's1',
      'sourceKey': 'A',
      'expiresAt': 1760300000000,
    });
    expect(
      request.isExpired(DateTime.fromMillisecondsSinceEpoch(1760300000000)),
      isTrue,
    );
    expect(
      request.isExpired(DateTime.fromMillisecondsSinceEpoch(1760299999999)),
      isFalse,
    );
    final card = ChatMessage.computerAccess(request);
    expect(card.type, MessageType.computerAccess);
    expect(card.questionId, 'req1');
    expect(card.answered, isFalse);
    final restored = ComputerAccessRequest.fromJson(card.toolInput)!;
    expect(restored.toJson(), request.toJson());
    expect(restored.withStatus('once').pending, isFalse);
    expect(ComputerAccessRequest.fromJson({'kind': 'link'}), isNull);
  });

  test('a link card carries the access asked for and defaults', () {
    final request = ComputerAccessRequest.fromJson({
      ...approval,
      'kind': 'link',
      'access': {'read': true, 'agents': false, 'commands': false},
      'reason': 'To run the test suite there',
    })!;
    expect(request.isLink, isTrue);
    expect(request.access.label, 'read');
    expect(request.reason, 'To run the test suite there');
    expect(ComputerAccess.fromJson(null).label, 'read, agents, commands');
    // Servers before "ask" send every_time or per_chat.
    expect(LinkConfirm.fromWire('per_chat'), LinkConfirm.ask);
    expect(LinkConfirm.fromWire('every_time'), LinkConfirm.ask);
    expect(LinkConfirm.fromWire('never'), LinkConfirm.never);
  });

  test('a device list keeps pending devices and link grants apart', () {
    final registry = DeviceRegistry.fromJson({
      'mode': 'enforced',
      'self': 'me',
      'devices': [
        {
          'publicKey': 'me',
          'kind': 'device',
          'name': 'Pixel',
          'platform': 'android',
          'via': 'token',
          'online': true,
        },
        {
          'publicKey': 'A',
          'kind': 'computer',
          'name': 'Dev VM',
          'platform': 'computer',
          'via': 'link',
          'access': {'read': true, 'agents': true, 'commands': false},
          'confirm': 'never',
        },
      ],
      'pending': [
        {
          'publicKey': 'new',
          'name': 'Tablet',
          'platform': 'android',
          'code': '000123',
        },
      ],
    }, serverId: 'srv');
    expect(registry.learning, isFalse);
    expect(registry.phones.single.online, isTrue);
    expect(registry.computers.single.access!.label, 'read, agents');
    expect(registry.computers.single.confirm, LinkConfirm.never);
    expect(registry.pending.single.serverId, 'srv');
    expect(registry.pending.single.code, '000123');
  });

  test('a link needs a new ticket inside seven days of expiry', () {
    final now = DateTime(2026, 10, 12);
    ComputerLink link(DateTime? expires) => ComputerLink(
      name: 'Desktop',
      targetPubkey: 'B',
      online: true,
      access: const ComputerAccess(),
      confirm: LinkConfirm.ask,
      ticketExpiresAt: expires,
    );
    expect(link(null).needsTicketRefresh(now), isTrue);
    expect(
      link(now.add(const Duration(days: 6))).needsTicketRefresh(now),
      isTrue,
    );
    expect(
      link(now.add(const Duration(days: 8))).needsTicketRefresh(now),
      isFalse,
    );
  });

  test('a link card knows which box its request needs', () {
    final request = ComputerAccessRequest.fromJson({
      ...approval,
      'kind': 'link',
    })!;
    expect(request.hasAction, isTrue);
    const commandsOnly = ComputerAccess(
      read: false,
      agents: false,
      commands: true,
    );
    const readOnly = ComputerAccess(read: true, agents: false, commands: false);
    expect(request.accessCoversAction(commandsOnly), isTrue);
    expect(request.accessCoversAction(readOnly), isFalse);
    final start = ComputerAccessRequest.fromJson({
      ...approval,
      'kind': 'link',
      'action': 'agent_start',
    })!;
    expect(start.accessCoversAction(commandsOnly), isFalse);
    expect(start.accessCoversAction(const ComputerAccess()), isTrue);
    // A chat approval covers one kind of access, and the card says which.
    expect(request.chatGrantLabel, 'commands');
    expect(start.chatGrantLabel, 'agents');
    final read = ComputerAccessRequest.fromJson({
      ...approval,
      'action': 'transcript_read',
    })!;
    expect(read.chatGrantLabel, 'reads');
  });

  test('a link ends at the next local midnight and says so', () {
    final now = DateTime(2026, 10, 22, 15, 4);
    final midnight = nextLocalMidnight(now);
    expect(midnight, DateTime(2026, 10, 23));
    expect(linkExpiryLabel(midnight, now), 'until midnight');
    expect(linkExpiryLabel(DateTime(2026, 10, 22, 15, 19), now), 'until 15:19');
    expect(
      linkExpiryLabel(DateTime(2026, 10, 25, 9, 0), now),
      'until 2026-10-25 09:00',
    );
    final link = ComputerLink.fromJson({
      'name': 'Arcade',
      'targetPubkey': 'B',
      'expiresAt': midnight.millisecondsSinceEpoch,
    })!;
    expect(link.expiresAt, midnight);
  });

  group('link card buttons', () {
    Future<void> pumpCard(WidgetTester tester, Map<String, Object?> raw) {
      final request = ComputerAccessRequest.fromJson({
        ...raw,
        'expiresAt': DateTime.now()
            .add(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
      })!;
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ComputerAccessCard(
              message: ChatMessage.computerAccess(request),
            ),
          ),
        ),
      );
    }

    testWidgets('a waiting request can be allowed alone', (tester) async {
      await pumpCard(tester, {
        ...approval,
        'kind': 'link',
        'access': {'read': false, 'agents': false, 'commands': true},
        'reason': 'Arcade is not linked to this computer.',
      });
      expect(find.text('cd ~/proj && npm test'), findsOneWidget);
      for (final label in [
        'Allow',
        'Allow for today',
        'Allow permanently',
        'Deny',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
    });

    testWidgets('a plain link request has no one-action button', (
      tester,
    ) async {
      await pumpCard(tester, {
        'requestId': 'req2',
        'sessionId': 's1',
        'kind': 'link',
        'source': {'name': 'Dev VM', 'publicKey': 'A'},
        'target': {'name': 'Desktop', 'publicKey': 'B'},
        'access': {'read': true, 'agents': true, 'commands': true},
      });
      expect(find.text('Allow'), findsNothing);
      expect(find.text('Allow for today'), findsOneWidget);
      expect(find.text('Allow permanently'), findsOneWidget);
    });
  });
}
