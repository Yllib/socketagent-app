import 'package:app/models/computer_access.dart';
import 'package:app/models/device_registry.dart';
import 'package:app/models/message.dart';
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
}
