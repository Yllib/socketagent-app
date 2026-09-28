import 'dart:isolate';
import '../models/message.dart';
import '../models/server_config.dart';

Future<List<Session>> loadSessionList(
  List<dynamic> entries, {
  ServerConfig? server,
  String? serverId,
  Map<String, SessionRunStats?> previousRunStats = const {},
  bool cached = false,
}) => Isolate.run(() {
  final sessions = entries.whereType<Map>().map((entry) {
    final session =
        Session.fromJson(
          Map<String, dynamic>.from(entry),
          previousRunStats: previousRunStats[entry['id']],
        ).withServer(
          serverId: serverId ?? server?.id ?? '',
          serverName: server?.name ?? '',
          serverColor: server?.colorValue,
        );
    return cached ? session.copyWith(running: false) : session;
  }).toList();
  sessions.sort((a, b) => b.lastActive.compareTo(a.lastActive));
  return sessions;
});
