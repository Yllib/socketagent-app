import 'dart:convert';

import 'package:app/models/server_config.dart';
import 'package:app/screens/connect_computer_screen.dart';
import 'package:app/screens/pair_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wire spec section 6: an `SA3` code is taken whole or refused whole, and
/// never read as an old code.
void main() {
  final key = base64Encode(List.generate(32, (i) => i + 1));
  final secret = base64Encode(List.generate(32, (i) => 255 - i));
  const room = '3f6c1e0a9b7d4c218e550a1b2c3d4e5f';

  String code({
    String prefix = 'SA3',
    String roomId = room,
    String? computerKey,
    String? pairingSecret,
    String port = '8085',
    String hosts = '192.168.1.20,10.0.0.5',
    List<String> more = const [],
  }) => [
    prefix,
    roomId,
    computerKey ?? key,
    pairingSecret ?? secret,
    port,
    hosts,
    ...more,
  ].join('|');

  test('a v2 code pairs the relay and every address on transport v2', () {
    final pairing = parsePairingCode('${code()}\n');
    expect(pairing.pairingToken, room);
    expect(pairing.serverPubkey, key);
    expect(pairing.pairingSecret, secret);
    expect(pairing.relayUrl, defaultRelayUrl);
    expect(pairing.local?.hosts, ['192.168.1.20', '10.0.0.5']);
    expect(pairing.local?.port, 8085);
    // The code carries no AUTH_TOKEN.
    expect(pairing.local?.token, isEmpty);

    final relay = relayCandidate(pairing, 0);
    expect(relay.isV2, isTrue);
    expect(relay.pairingSecret, secret);
    expect(relay.token, isEmpty);
    expect(lanCandidates(pairing, 0).every((c) => c.isV2), isTrue);
  });

  test('hosts may be empty and a seventh part names another relay', () {
    final noHosts = parsePairingCode(code(hosts: ''));
    expect(noHosts.local, isNull);
    expect(noHosts.pairingSecret, secret);

    final ownRelay = parsePairingCode(code(more: ['wss://relay.example']));
    expect(ownRelay.relayUrl, 'wss://relay.example');
  });

  test('an old code still pairs on the old transport', () {
    final old = parsePairingCode('SA|pairing-token|$key|8085|auth|10.0.0.5');
    expect(old.pairingSecret, isEmpty);
    expect(relayCandidate(old, 0).isV2, isFalse);
  });

  test('a v2 code that breaks one rule is refused', () {
    final long = 'r' * 201;
    final urlSafeKey = '${'-_' * 21}-=';
    final broken = {
      'prefix in another case': code(prefix: 'sa3'),
      'five parts': code().split('|').take(5).join('|'),
      'eight parts': code(more: ['wss://relay.example', 'x']),
      'empty room': code(roomId: ''),
      'room over 200 characters': code(roomId: long),
      'room with a space': code(roomId: 'a room'),
      'room outside ASCII': code(roomId: 'café'),
      'key of 31 bytes': code(computerKey: base64Encode(List.filled(31, 7))),
      'key that is not base64': code(computerKey: '${'!' * 43}='),
      'key in the URL-safe alphabet': code(computerKey: urlSafeKey),
      'secret of 33 bytes': code(
        pairingSecret: base64Encode(List.filled(33, 7)),
      ),
      'empty secret': code(pairingSecret: ''),
      'port zero': code(port: '0'),
      'port too high': code(port: '65536'),
      'port with a sign': code(port: '+8085'),
      'port in hex': code(port: '0x1f95'),
      'empty port': code(port: ''),
      'relay without TLS': code(more: ['ws://relay.example']),
      'relay over https': code(more: ['https://relay.example']),
      'relay with no host': code(more: ['wss://']),
    };
    for (final MapEntry(key: rule, value: text) in broken.entries) {
      expect(() => parsePairingCode(text), throwsFormatException, reason: rule);
    }
  });

  test('a pasted v2 code yields its key, like an old one', () {
    expect(ServerConfig.normalizeServerPubkey(code()), key);
    expect(
      ServerConfig.normalizeServerPubkey(code(more: ['wss://relay.example'])),
      key,
    );
  });
}
