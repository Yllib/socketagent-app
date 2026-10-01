import 'dart:async';
import 'package:app/models/server_config.dart';
import 'package:app/services/transfer_history.dart';
import 'package:app/widgets/transfer_history_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ServerConfig server(String id) => ServerConfig(
  id: id,
  name: id,
  host: '',
  port: 8085,
  token: '',
  serverPubkey: id,
);

Widget dialog(Future<TransferHistory> Function() load) => MaterialApp(
  home: TransferHistoryDialog(
    load: load,
    itemBuilder: (_, job) => Text(job['id'] as String),
  ),
);

void main() {
  test(
    'keeps successful history and failures while skipping offline computers',
    () async {
      final queried = <String>[];
      final result = await loadTransferHistory(
        servers: [
          'good',
          'slow',
          'error',
          'offline',
          'old',
          'bad',
        ].map(server).toList(),
        isConnected: (id) => id != 'offline',
        isSupported: (id) => id != 'old',
        timeout: const Duration(milliseconds: 10),
        request: (id, message) async {
          queried.add(id);
          expect(message, {'type': 'session_transfer_job', 'action': 'list'});
          if (id == 'slow') return Completer<Map<String, dynamic>>().future;
          if (id == 'error') return {'ok': false, 'error': 'failure'};
          if (id == 'bad') return {'ok': true, 'jobs': 'invalid'};
          return {
            'ok': true,
            'jobs': [
              {'id': 'local', 'role': 'local'},
              {'id': 'outgoing', 'role': 'source', 'peerPublicKey': 'old'},
              {'id': 'incoming', 'role': 'destination'},
            ],
          };
        },
      );
      expect(queried, ['good', 'slow', 'error', 'bad']);
      expect(result.jobs.map((j) => j['id']), ['local', 'outgoing']);
      expect(result.jobs.map((j) => j['destinationServerId']), ['good', 'old']);
      expect(result.problems, [
        'slow: No response',
        'error: Could not load transfers',
        'old: Server update required',
        'bad: Could not load transfers',
      ]);
    },
  );

  testWidgets('error stops loading and Retry displays transfers', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      dialog(() {
        attempts++;
        if (attempts == 1) throw StateError('failed');
        return Future.value(
          const TransferHistory(
            jobs: [
              {'id': 'Restored transfer'},
            ],
          ),
        );
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('Loading transfers…'), findsNothing);
    expect(find.text('Could not load transfers. Try again.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Restored transfer'), findsOneWidget);
    expect(find.text('Could not load transfers. Try again.'), findsNothing);
  });

  testWidgets('hung loader is bounded and empty history is explicit', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      dialog(() {
        attempts++;
        return attempts == 1
            ? Completer<TransferHistory>().future
            : Future.value(const TransferHistory());
      }),
    );
    expect(find.text('Loading transfers…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 21));
    await tester.pumpAndSettle();
    expect(find.text('Loading transfers…'), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No transfers on connected computers.'), findsOneWidget);
  });

  testWidgets('partial results remain visible alongside server failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      dialog(
        () async => const TransferHistory(
          jobs: [
            {'id': 'Finished transfer'},
          ],
          problems: ['Laptop: No response'],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Finished transfer'), findsOneWidget);
    expect(find.text('Laptop: No response'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
