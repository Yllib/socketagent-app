import 'package:app/models/computer_access.dart';
import 'package:app/models/device_registry.dart';
import 'package:app/screens/settings/ai_connector_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final card = {
    'type': 'computer_access_request',
    'requestId': 'req1',
    'sessionId': 'connector-abc',
    'kind': 'approval',
    'source': {'name': 'Desktop', 'publicKey': 'B'},
    'target': {'name': 'Desktop', 'publicKey': 'B'},
    'action': 'run_command',
    'summary': 'uname -a',
    'challengeId': 'c1',
    'digest': 'abc',
    'expiresAt': 1760300000000,
    'client': {'name': 'Claude', 'publicKey': 'K'},
    'approvalKey': 'K',
  };

  test('a connector card names the client and seals its key', () {
    final request = ComputerAccessRequest.fromJson(card)!;
    expect(request.fromConnector, isTrue);
    expect(request.askerLabel, 'Claude (AI connector)');
    // The source computer is also the target, so the approval must carry
    // the client's key, not the computer's.
    expect(
      request.approvalPayload(scope: 'once', sourceKey: 'B')['sourceKey'],
      'K',
    );
    expect(
      ComputerAccessRequest.fromJson(request.toJson())!.toJson(),
      request.toJson(),
    );
    final plain = ComputerAccessRequest.fromJson(
      {...card}
        ..remove('client')
        ..remove('approvalKey'),
    )!;
    expect(plain.fromConnector, isFalse);
    expect(plain.askerLabel, 'Desktop');
    expect(
      plain.approvalPayload(scope: 'once', sourceKey: 'B')['sourceKey'],
      'B',
    );
    expect(plain.toJson().containsKey('client'), isFalse);
  });

  test('a device list keeps AI clients apart from phones and computers', () {
    final registry = DeviceRegistry.fromJson({
      'mode': 'enforced',
      'self': 'me',
      'devices': [
        {
          'publicKey': 'me',
          'kind': 'device',
          'name': 'Pixel',
          'platform': 'android',
        },
        {
          'publicKey': 'K',
          'kind': 'connector',
          'name': 'Claude',
          'platform': 'connector',
          'via': 'connector',
          'access': {'read': true, 'agents': true, 'commands': false},
          'confirm': 'never',
        },
        {
          'publicKey': 'C',
          'kind': 'computer',
          'name': 'Laptop',
          'platform': 'computer',
        },
      ],
    });
    expect(registry.phones.map((d) => d.name), ['Pixel']);
    expect(registry.computers.map((d) => d.name), ['Laptop']);
    final client = registry.connectors.single;
    expect(client.isConnector, isTrue);
    expect(client.hasAccess, isTrue);
    expect(client.access?.label, 'read, agents');
    expect(client.confirm, LinkConfirm.never);
  });

  test('sign-in and seen times tell AI client rows apart', () {
    final now = DateTime(2026, 10, 28, 9, 5);
    expect(deviceTimeLabel(DateTime(2026, 10, 28, 4, 27), now), '04:27');
    expect(
      deviceTimeLabel(DateTime(2026, 10, 27, 23, 59), now),
      '2026-10-27 23:59',
    );
  });

  test('an ai_connector_status reply parses', () {
    final status = AiConnectorStatus.fromJson({
      'type': 'ai_connector_status',
      'enabled': true,
      'publicUrl': 'https://agent.example.com',
      'port': 8086,
      'listening': true,
      'mcpUrl': 'https://agent.example.com/mcp',
      'clients': 1,
      'pendingSignIns': 0,
    })!;
    expect(status.listening, isTrue);
    expect(status.mcpUrl, 'https://agent.example.com/mcp');
    expect(status.error, '');
    expect(AiConnectorStatus.fromJson({'type': 'device_list_result'}), isNull);
  });
}
