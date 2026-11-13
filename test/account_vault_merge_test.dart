import 'package:app/models/account_vault.dart';
import 'package:app/models/server_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  VaultComputer computer(String key, int at, {String name = 'PC'}) =>
      VaultComputer(key: key, updatedAt: at, fields: {'name': name});
  VaultDevice device(String key, int at) =>
      VaultDevice(publicKey: key, name: key, platform: 'android', addedAt: at);

  test('newer write wins per computer and both sides keep their others', () {
    final a = AccountVault(
      computers: [
        computer('x', 10, name: 'old'),
        computer('a', 5),
      ],
    );
    final b = AccountVault(
      computers: [
        computer('x', 20, name: 'new'),
        computer('b', 5),
      ],
    );
    final merged = mergeVaults(a, b);
    expect(merged.computers.map((c) => c.key).toSet(), {'x', 'a', 'b'});
    expect(merged.computers.firstWhere((c) => c.key == 'x').name, 'new');
    expect(
      mergeVaults(b, a).computers.firstWhere((c) => c.key == 'x').name,
      'new',
    );
  });

  test('a tombstone removes an older write and ties, and keeps the stone', () {
    final a = AccountVault(computers: [computer('x', 10)]);
    final b = AccountVault(
      removedComputers: const [VaultTombstone(key: 'x', at: 10)],
    );
    final merged = mergeVaults(a, b);
    expect(merged.computers, isEmpty);
    expect(merged.removedComputers.single.key, 'x');
    final older = AccountVault(computers: [computer('x', 9)]);
    expect(mergeVaults(older, b).computers, isEmpty);
  });

  test('a write after the tombstone brings the computer back', () {
    final a = AccountVault(computers: [computer('x', 11)]);
    final b = AccountVault(
      removedComputers: const [VaultTombstone(key: 'x', at: 10)],
    );
    final merged = mergeVaults(a, b);
    expect(merged.computers.single.key, 'x');
    expect(merged.removedComputers, isEmpty);
  });

  test('devices and revocations merge the same way', () {
    final a = AccountVault(
      devices: [device('p', 1), device('q', 1)],
      revokedDevices: const [VaultTombstone(key: 'q', at: 2)],
    );
    final b = AccountVault(devices: [device('r', 3)]);
    final merged = mergeVaults(a, b);
    expect(merged.devices.map((d) => d.publicKey).toSet(), {'p', 'r'});
    expect(merged.isRevoked('q'), isTrue);
    expect(merged.isRevoked('p'), isFalse);
  });

  test('subscription and vault stamp follow the newer side', () {
    const a = AccountVault(
      updatedAt: 5,
      updatedBy: 'A',
      subscription: VaultSubscription(token: 't1', email: '', updatedAt: 5),
      preferences: {'k': 1},
    );
    const b = AccountVault(
      updatedAt: 9,
      updatedBy: 'B',
      subscription: VaultSubscription(token: 't2', email: 'e', updatedAt: 9),
    );
    final merged = mergeVaults(a, b);
    expect(merged.subscription!.token, 't2');
    expect(merged.updatedBy, 'B');
    expect(merged.preferences, {
      'k': 1,
    }, reason: 'empty newer map does not erase');
    expect(mergeVaults(a, const AccountVault()).subscription!.token, 't1');
  });

  test('vault json round trips with every list', () {
    final vault = AccountVault(
      updatedAt: 7,
      updatedBy: 'Pixel',
      computers: [computer('x', 1)],
      removedComputers: const [VaultTombstone(key: 'y', at: 2)],
      subscription: const VaultSubscription(
        token: 't',
        email: 'e',
        updatedAt: 3,
      ),
      devices: [device('p', 4)],
      revokedDevices: const [VaultTombstone(key: 'q', at: 5)],
      pinnedSessions: const [VaultPin(sessionId: 's', at: 6)],
      unpinnedSessions: const [VaultTombstone(key: 'u', at: 6)],
      projects: const [VaultProject(id: 'p1', name: 'Site', at: 7)],
      removedProjects: const [VaultTombstone(key: 'p0', at: 7)],
      projectMembers: const [
        VaultProjectMember(sessionId: 's', projectId: 'p1', at: 8),
      ],
      removedProjectMembers: const [VaultTombstone(key: 'u', at: 8)],
      preferences: const {'theme': 'dark'},
    );
    final restored = AccountVault.fromJson(vault.toJson());
    expect(restored.toJson(), vault.toJson());
  });

  test('reads formats 1, 2 and 3, writes 3 and refuses a newer one', () {
    for (final format in [1, 2, 3]) {
      final vault = AccountVault.fromJson({'v': format, 'updatedAt': 3});
      expect(vault.updatedAt, 3);
      expect(vault.toJson()['v'], 3);
    }
    expect(
      () => AccountVault.fromJson({'v': 4}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Update the app'),
        ),
      ),
    );
    expect(() => AccountVault.fromJson({'v': 'x'}), throwsFormatException);
    expect(() => AccountVault.fromJson({'v': 0}), throwsFormatException);
  });

  test('a v2 pairing rides in the vault and no entry clears it', () {
    final paired = ServerConfig(
      id: 'srv_1',
      name: 'Desk',
      host: '10.0.0.2',
      port: 8085,
      token: '',
      pairingToken: 'room',
      serverPubkey: 'pub',
      pairingSecret: 'c2VjcmV0',
      transport: 2,
    );
    final stored = AccountVault(
      computers: [VaultComputer.fromConfig(paired, now: 1)],
    );
    final fields = AccountVault.fromJson(stored.toJson()).computers.single;
    expect(fields.fields['pairingSecret'], 'c2VjcmV0');
    expect(fields.fields['transport'], 2);
    final restored = ServerConfig.fromJson({...fields.fields, 'id': 'srv_2'});
    expect(restored.isV2, isTrue);
    expect(restored.pairingSecret, 'c2VjcmV0');

    // A device still on the old transport writes neither field.
    final old = ServerConfig.fromJson(
      paired.toJson()
        ..remove('pairingSecret')
        ..remove('transport'),
    );
    expect(old.isV2, isFalse);
    expect(VaultComputer.sharedFields(old).keys, isNot(contains('transport')));
    expect(
      VaultComputer.sharedFields(old).keys,
      isNot(contains('pairingSecret')),
    );

    // Its entry, or one that says the old transport outright, merges over
    // the paired one without taking the pairing away.
    final merged = ServerConfig.fromJson({
      ...paired.toJson(),
      ...VaultComputer.sharedFields(old),
      'transport': 1,
      'pairingSecret': '',
    }).after(paired);
    expect(merged.isV2, isTrue);
    expect(merged.pairingSecret, 'c2VjcmV0');

    // The room ID and the relay stay with the secret. An entry that brings
    // a secret and a room of its own replaces the pair.
    final relayed = paired.copyWith(relayUrl: 'wss://relay.example');
    final blanked = paired
        .copyWith(pairingToken: '', pairingSecret: '', relayUrl: '')
        .after(relayed);
    expect(blanked.pairingToken, 'room');
    expect(blanked.pairingSecret, 'c2VjcmV0');
    expect(blanked.relayUrl, 'wss://relay.example');
    final halfNew = paired.copyWith(pairingSecret: 'bmV3').after(relayed);
    expect(halfNew.pairingSecret, 'bmV3');
    expect(halfNew.pairingToken, 'room');
    final secretOnly = paired
        .copyWith(pairingToken: '', pairingSecret: 'bmV3')
        .after(relayed);
    expect(secretOnly.pairingSecret, 'c2VjcmV0');
    expect(secretOnly.pairingToken, 'room');
    final renewed = paired
        .copyWith(pairingToken: 'new-room', pairingSecret: 'bmV3')
        .after(relayed);
    expect(renewed.pairingSecret, 'bmV3');
    expect(renewed.pairingToken, 'new-room');

    // A relay named with no pairing does not move a v2 entry off its own.
    // It is taken with a whole pairing, or by an entry that has none.
    const otherRelay = 'wss://other.example';
    final relayOnly = paired.copyWith(pairingSecret: '', relayUrl: otherRelay);
    expect(relayOnly.after(relayed).relayUrl, 'wss://relay.example');
    expect(relayOnly.after(paired).relayUrl, otherRelay);
    expect(
      renewed.copyWith(relayUrl: otherRelay).after(relayed).relayUrl,
      otherRelay,
    );

    // A different key is a different computer and starts without one.
    final other = paired.withComputerKey('other');
    expect(other.isV2, isFalse);
    expect(other.pairingSecret, isEmpty);
  });

  test('fields from a newer build survive a round trip and a merge', () {
    final fromNewer = AccountVault.fromJson({
      'v': 2,
      'updatedAt': 5,
      'folders': ['work'],
    });
    expect(fromNewer.toJson()['folders'], ['work']);
    final local = AccountVault(updatedAt: 9, computers: [computer('x', 9)]);
    final merged = mergeVaults(local, fromNewer);
    expect(merged.toJson()['folders'], ['work']);
    expect(merged.computers.single.key, 'x');
  });

  test('the account PIN the relay names wins, and no clock decides', () {
    VaultAccountPin pin(String id, int setAt) => VaultAccountPin(
      id: id,
      salt: 'salt-$id',
      publicKey: 'key-$id',
      setAt: setAt,
      setBy: 'device',
    );
    final mine = AccountVault(updatedAt: 9, pin: pin('mine', 9));
    final theirs = AccountVault(updatedAt: 5, pin: pin('theirs', 1));

    expect(mergeVaults(mine, theirs, relayPinId: 'mine').pin!.id, 'mine');
    expect(mergeVaults(mine, theirs, relayPinId: 'theirs').pin!.id, 'theirs');
    // Neither matches, or the relay has no record: the relay's copy wins.
    expect(mergeVaults(mine, theirs, relayPinId: 'other').pin!.id, 'theirs');
    expect(mergeVaults(mine, theirs).pin!.id, 'theirs');
    // A vault with no PIN never takes one away.
    expect(mergeVaults(mine, const AccountVault()).pin!.id, 'mine');
    expect(mergeVaults(const AccountVault(), theirs).pin!.id, 'theirs');
    expect(mergeVaults(mine, mine, relayPinId: 'mine').pin!.salt, 'salt-mine');
  });

  test('the account PIN and the repair id survive the stored form', () {
    final vault = AccountVault.fromJson({
      'v': 3,
      'pin': {
        'id': 'i',
        'salt': 's',
        'publicKey': 'k',
        'setAt': 4,
        'setBy': 'd',
      },
      'reset': {'id': 'r'},
    });
    expect(vault.pin!.setBy, 'd');
    expect(vault.resetId, 'r');
    final again = AccountVault.fromJson(vault.toJson());
    expect(again.pin!.publicKey, 'k');
    expect(again.resetId, 'r');
    expect(again.unknownFields, isEmpty);
    // The relay's repair id wins, and a vault without one keeps the other's.
    expect(mergeVaults(const AccountVault(), vault).resetId, 'r');
    expect(mergeVaults(vault, const AccountVault()).resetId, 'r');
    expect(
      mergeVaults(vault, const AccountVault(resetId: 'newer')).resetId,
      'newer',
    );
    // A PIN entry this build cannot read stops the vault being used, so it
    // is never written back without it.
    expect(
      () => AccountVault.fromJson({
        'v': 3,
        'pin': {'id': 'i'},
      }),
      throwsFormatException,
    );
  });

  test('a computer shares every field except the device-local ones', () {
    final config = ServerConfig(
      id: 'srv_1',
      name: 'Desk',
      host: '10.0.0.2',
      port: 8085,
      token: 'tok',
      useRelay: true,
      autoRoute: true,
      sortOrder: 3,
      relayUrl: 'wss://relay',
      pairingToken: 'pair',
      serverPubkey: 'pub',
    );
    final shared = VaultComputer.fromConfig(config, now: 1);
    expect(shared.key, 'pub');
    expect(shared.fields.keys, isNot(contains('id')));
    expect(shared.fields.keys, isNot(contains('useRelay')));
    expect(shared.fields.keys, isNot(contains('sortOrder')));
    expect(shared.fields['token'], 'tok');
    expect(shared.fields['autoRoute'], isTrue);
    final direct = config.copyWith(
      serverPubkey: '',
      useRelay: false,
      autoRoute: false,
    );
    expect(VaultComputer.keyFor(direct), direct.connectionIdentity);
  });
}
