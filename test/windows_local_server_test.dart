import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/server_config.dart';
import 'package:app/services/windows_local_server.dart';

void main() {
  final publicKey = base64Encode(List<int>.generate(32, (i) => i));
  test('local discovery preserves quoted credentials and custom port', () {
    final env = WindowsLocalServer.parseEnvironment('''\uFEFF# config
AUTH_TOKEN="test#token=with symbols"
PORT=9005 # custom port
DEFAULT_CWD='C:\\Projects With Spaces'
''');
    final config = WindowsLocalServer.configuration(env, publicKey)!;
    expect(config.host, '127.0.0.1');
    expect(config.port, 9005);
    expect(config.token, 'test#token=with symbols');
    expect(config.defaultCwd, r'C:\Projects With Spaces');
    expect(config.useRelay, isFalse);
    expect(config.serverPubkey, publicKey);
  });
  test('never discovers an unauthenticated or unpinned connection', () {
    expect(WindowsLocalServer.configuration({}, publicKey), isNull);
    expect(
      WindowsLocalServer.configuration({'AUTH_TOKEN': 'test'}, ''),
      isNull,
    );
    expect(
      WindowsLocalServer.configuration({'AUTH_TOKEN': 'test'}, 'invalid'),
      isNull,
    );
    for (final port in ['0', '-1', '65536', 'oops']) {
      expect(
        WindowsLocalServer.configuration({
          'AUTH_TOKEN': 'test',
          'PORT': port,
        }, publicKey),
        isNull,
      );
    }
  });

  group('the owner reads the pairing from the server\'s own files', () {
    final secret = base64Encode(List<int>.generate(32, (i) => i + 1));
    final older = base64Encode(List<int>.generate(32, (i) => i + 2));
    final env = {'AUTH_TOKEN': 'token', 'PAIRING_TOKEN': 'room-id'};
    final state = jsonEncode({
      'version': 2,
      'locked': false,
      'relayKey': 'never read',
      'secrets': [
        {'id': 4, 'secret': secret},
        {'id': 3, 'secret': older, 'retiredAt': '2026-11-01T00:00:00Z'},
      ],
    });

    test('and is on transport v2 from the start', () {
      final config = WindowsLocalServer.configuration(
        env,
        publicKey,
        stateFile: '\uFEFF$state',
      )!;
      expect(config.isV2, isTrue);
      expect(config.pairingSecret, secret);
      expect(config.pairingToken, 'room-id');
      expect(config.host, '127.0.0.1');
      // Still this machine's own entry, with no relay.
      expect(config.isLoopbackOnly, isTrue);
      expect(config.token, 'token');
    });

    test('and keeps the token sign-in when a file is missing or bad', () {
      for (final (environment, file) in [
        (env, null),
        (env, 'not json'),
        (env, jsonEncode({'secrets': <Object>[]})),
        (
          env,
          jsonEncode({
            'secrets': [
              {'secret': 'short'},
            ],
          }),
        ),
        ({'AUTH_TOKEN': 'token'}, state),
      ]) {
        final config = WindowsLocalServer.configuration(
          environment,
          publicKey,
          stateFile: file,
        )!;
        expect(config.isV2, isFalse);
        expect(config.pairingSecret, isEmpty);
        expect(config.pairingToken, isEmpty);
        expect(config.token, 'token');
      }
    });
  });

  test('the machine marker gives a pinned, token-less local server', () {
    final config = WindowsLocalServer.machineConfiguration(
      '\uFEFF${jsonEncode({'directory': r'C:\Users\lanik\socketagent', 'port': 8085, 'task': 'SocketAgentService', 'publicKey': publicKey})}',
    )!;
    expect(config.host, '127.0.0.1');
    expect(config.port, 8085);
    expect(config.token, isEmpty);
    expect(config.serverPubkey, publicKey);
    expect(WindowsLocalServer.machineConfiguration('{"port": 8085}'), isNull);
    expect(
      WindowsLocalServer.machineConfiguration(
        jsonEncode({'port': 8085, 'publicKey': 'short'}),
      ),
      isNull,
    );
    expect(WindowsLocalServer.machineConfiguration('nope'), isNull);
  });

  group('the machine marker is believed', () {
    // What the facts script prints for the folder a full install sets up:
    // the administrators own it, they and SYSTEM have full control, and
    // Users may read.
    const fullInstall = [
      'folder S-1-5-32-544',
      'file S-1-5-32-544',
      'rule Allow 2032127 S-1-5-18',
      'rule Allow 2032127 S-1-5-32-544',
      'rule Allow 1179817 S-1-5-32-545',
      'end',
    ];
    bool trusts(List<String> lines) =>
        WindowsLocalServer.trustsMachineMarker(lines.join('\r\n'));
    List<String> replacing(String line, String by) => [
      for (final l in fullInstall) l == line ? by : l,
    ];

    test('in the folder a full install sets up', () {
      expect(trusts(fullInstall), isTrue);
      // The server runs as SYSTEM or as an administrator.
      expect(trusts(replacing('file S-1-5-32-544', 'file S-1-5-18')), isTrue);
      // A rule that denies takes nothing away from this.
      expect(
        trusts([...fullInstall]..insert(2, 'rule Deny 278 S-1-1-0')),
        isTrue,
      );
    });

    test('only when setup owns the folder and the file', () {
      const user = 'S-1-5-21-1-2-3-1001';
      expect(trusts(replacing('folder S-1-5-32-544', 'folder $user')), isFalse);
      expect(trusts(replacing('file S-1-5-32-544', 'file $user')), isFalse);
      expect(trusts(fullInstall.sublist(1)), isFalse);
    });

    test('only when no other account may write to the folder', () {
      // Users with Modify, as on a folder an ordinary account made.
      expect(
        trusts(
          replacing(
            'rule Allow 1179817 S-1-5-32-545',
            'rule Allow 1245631 S-1-5-32-545',
          ),
        ),
        isFalse,
      );
      // One account allowed to add files, and generic rights nobody reads.
      expect(
        trusts([...fullInstall]..insert(2, 'rule Allow 2 S-1-5-21-1-2-3-1001')),
        isFalse,
      );
      expect(
        trusts([...fullInstall]..insert(2, 'rule Allow -1610612736 S-1-5-11')),
        isFalse,
      );
    });

    test('only when all of it was read', () {
      expect(trusts(fullInstall.sublist(0, fullInstall.length - 1)), isFalse);
      expect(
        trusts([...fullInstall]..insert(2, 'rule Allow S-1-5-18')),
        isFalse,
      );
      expect(trusts(['Get-Acl : Access is denied', ...fullInstall]), isFalse);
      expect(trusts(const []), isFalse);
    });

    test('by a script that quotes the paths it is given', () {
      final script = WindowsLocalServer.machineMarkerFactsScript(
        r"C:\ProgramData\It's",
        r"C:\ProgramData\It's\machine-server.json",
      );
      expect(script, contains(r"-LiteralPath 'C:\ProgramData\It''s'; "));
      expect(script, isNot(contains('"')));
      expect(script, endsWith("; 'end'"));
    });
  });

  test('a marker for a port the owner files name is left out', () {
    final ownKey = base64Encode(List.filled(32, 1));
    final markerKey = base64Encode(List.filled(32, 2));
    final own = WindowsLocalServer.configuration({
      'PORT': '8085',
      'AUTH_TOKEN': 'made-up-owner-token',
    }, ownKey)!;
    ServerConfig marker(int port, String key) =>
        WindowsLocalServer.machineConfiguration(
          jsonEncode({'port': port, 'publicKey': key}),
        )!;

    // Another key on the owner's port never reaches the saved entry.
    expect(WindowsLocalServer.found([own], marker(8085, markerKey)), [own]);
    expect(WindowsLocalServer.found([own], marker(8085, ownKey)), [own]);
    // The machine server of another account, on a port of its own.
    final other = marker(8090, markerKey);
    expect(WindowsLocalServer.found([own], other), [own, other]);
    expect(WindowsLocalServer.found(const [], other), [other]);
    expect(WindowsLocalServer.found([own], null), [own]);
  });

  group('LocalServerPlan', () {
    final key = base64Encode(List<int>.generate(32, (i) => i));
    final oldKey = base64Encode(List<int>.generate(32, (i) => 255 - i));
    final found = WindowsLocalServer.configuration({'AUTH_TOKEN': 'new'}, key)!;
    ServerConfig local(String id, String pubkey) => ServerConfig(
      id: id,
      name: 'This computer',
      host: '127.0.0.1',
      port: 8085,
      token: 'old',
      serverPubkey: pubkey,
    );
    final relay = ServerConfig(
      id: 'desk',
      name: 'Desktop',
      host: '',
      port: 8085,
      token: '',
      useRelay: true,
      relayUrl: 'wss://relay',
      pairingToken: 'p',
      serverPubkey: key,
    );

    test('a computer saved under any route is not added again', () {
      final plan = LocalServerPlan.of([relay], found);
      expect(plan.add, isNull);
      expect(plan.replace, isNull);
      expect(plan.remove, isEmpty);
    });

    test('a stale local entry goes when the computer is already saved', () {
      final plan = LocalServerPlan.of([relay, local('stale', oldKey)], found);
      expect(plan.add, isNull);
      expect(plan.remove, ['stale']);
    });

    test('a stale local entry is updated in place when nothing else is', () {
      final plan = LocalServerPlan.of([local('stale', oldKey)], found);
      expect(plan.replace?.id, 'stale');
      expect(plan.replace?.serverPubkey, key);
      expect(plan.replace?.token, 'new');
      expect(plan.add, isNull);
    });

    test('a new computer is added', () {
      expect(LocalServerPlan.of([], found).add, same(found));
    });

    test('the saved entry takes the pairing the files hold, once', () {
      final secret = base64Encode(List<int>.generate(32, (i) => i + 1));
      final paired = WindowsLocalServer.configuration(
        {'AUTH_TOKEN': 'new', 'PAIRING_TOKEN': 'room-id'},
        key,
        stateFile: jsonEncode({
          'secrets': [
            {'secret': secret},
          ],
        }),
      )!;
      final plan = LocalServerPlan.of([local('mine', key)], paired);
      final update = plan.update!;
      expect(update.id, 'mine');
      expect(update.isV2, isTrue);
      expect(update.pairingSecret, secret);
      expect(update.pairingToken, 'room-id');
      expect(plan.add, isNull);
      expect(plan.replace, isNull);
      // Nothing to do once it is stored, or for a server with no state file.
      expect(LocalServerPlan.of([update], paired).update, isNull);
      expect(LocalServerPlan.of([local('mine', key)], found).update, isNull);
      // The user's own entry for this computer takes it too.
      final named = LocalServerPlan.of([relay, local('mine', key)], paired);
      expect(named.update?.id, 'desk');
      expect(named.update?.pairingSecret, secret);
      expect(named.update?.useRelay, isTrue);
      expect(named.remove, ['mine']);
    });
  });
}
