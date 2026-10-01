import 'dart:async';
import '../models/server_config.dart';
import 'session_teleport.dart';

class TransferHistory {
  const TransferHistory({this.jobs = const [], this.problems = const []});

  final List<Map<String, dynamic>> jobs;
  final List<String> problems;
}

/// Queries computers independently so one failed connection cannot hide results.
Future<TransferHistory> loadTransferHistory({
  required List<ServerConfig> servers,
  required bool Function(String) isConnected,
  required bool Function(String) isSupported,
  required TransferRequest request,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final configs = List<ServerConfig>.of(servers);
  final results = await Future.wait(
    configs.map((server) async {
      if (!isConnected(server.id)) {
        return const TransferHistory();
      }
      if (!isSupported(server.id)) {
        return TransferHistory(
          problems: ['${server.name}: Server update required'],
        );
      }
      try {
        final reply = await request(server.id, {
          'type': 'session_transfer_job',
          'action': 'list',
        }).timeout(timeout);
        if (reply['ok'] != true || reply['jobs'] is! List) {
          return TransferHistory(
            problems: ['${server.name}: Could not load transfers'],
          );
        }
        final records = <Map<String, dynamic>>[];
        for (final raw in reply['jobs'] as List) {
          final job = Map<String, dynamic>.from(raw as Map);
          if (job['role'] == 'destination') continue;
          final destination = job['role'] == 'local'
              ? server
              : configs
                    .where((s) => s.serverPubkey == job['peerPublicKey'])
                    .firstOrNull;
          records.add({
            ...job,
            'serverId': server.id,
            'serverName': server.name,
            'destinationServerId': destination?.id,
            'destinationServerName': destination?.name,
          });
        }
        return TransferHistory(jobs: records);
      } on TimeoutException {
        return TransferHistory(problems: ['${server.name}: No response']);
      } catch (_) {
        return TransferHistory(
          problems: ['${server.name}: Could not load transfers'],
        );
      }
    }),
  );
  return TransferHistory(
    jobs: results.expand((r) => r.jobs).toList(),
    problems: results.expand((r) => r.problems).toList(),
  );
}
