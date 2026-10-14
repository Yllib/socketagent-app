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

  test('reads format 1, writes 2 and refuses a newer one', () {
    final old = AccountVault.fromJson({'v': 1, 'updatedAt': 3});
    expect(old.updatedAt, 3);
    expect(old.toJson()['v'], 2);
    expect(
      () => AccountVault.fromJson({'v': 3}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Update the app'),
        ),
      ),
    );
    expect(() => AccountVault.fromJson({'v': 'x'}), throwsFormatException);
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
