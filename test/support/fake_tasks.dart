// Fixed scheduled-task data and a provider that records writes, for the
// Tasks screen, editor and render tests. Shapes follow the server's store:
// raw maps with `_serverId` added, full run histories included.
import 'package:app/models/model_catalog.dart';
import 'dart:async';

import 'package:app/models/message.dart';
import 'package:app/models/scheduled_task_update.dart';
import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/connection_manager.dart';
import 'package:app/services/websocket_service.dart' show ConnectionStatus;

import 'fake_computers.dart';

export 'fake_computers.dart'
    show fakeConfig, mockProviderChannels, unmockProviderChannels;

/// A moment every seed time is relative to, so renders and tests are stable.
final seedNow = DateTime(2026, 10, 31, 14, 30);

String _iso(DateTime t) => t.toUtc().toIso8601String();

const seedPrompt =
    '''Read the overnight inbox and the agent transcripts since the last run.

1. Summarize anything that needs a decision today in three bullets max.
2. For each failed scheduled run, say what failed and whether it needs me.
3. Check the deploy board for anything stuck longer than six hours.

Keep it short. Use NotifyUser only if something is on fire; otherwise stay quiet and leave the digest in the session.''';

const seedResult = '''Digest for Friday morning.

Decisions needed
- The relay certificate expires in nine days. Renewal needs the DNS token you keep offline.
- Two PRs on the app repo wait on your review: 412 (tasks density) and 415 (Codex sign-in retry).

Failed runs
- "Rename photos" failed: Directory not found: /mnt/photos/2026-10. The drive is not mounted on laptop.

Deploy board
- Nothing stuck. Last deploy finished 02:14, 41 seconds.''';

/// Runs for a recurring task: [count] finished runs ending at [lastEnd],
/// spaced by [step], with every seventh one failed.
List<Map<String, dynamic>> seedRuns({
  required int count,
  required DateTime lastEnd,
  required Duration step,
  String sessionPrefix = 'run',
  bool linked = false,
  String latest = seedResult,
}) {
  final runs = <Map<String, dynamic>>[];
  for (var i = 0; i < count; i++) {
    final end = lastEnd.subtract(step * i);
    final failed = i % 7 == 3;
    final start = end.subtract(Duration(minutes: 3 + i % 5, seconds: 12));
    runs.add({
      'startedAt': _iso(start),
      'completedAt': _iso(end),
      'status': failed ? 'failed' : 'completed',
      'trigger': i == 1 ? 'manual' : 'scheduled',
      'sessionId': '$sessionPrefix-$i',
      if (failed)
        'error': 'Agent exited before a final message (exit code 1).'
      else
        'resultSummary': i == 0
            ? latest
            : 'Run ${count - i}: nothing needed attention.',
      if (linked) 'callbackSessionId': 'sess-1',
      if (linked) 'callbackStatus': i == 0 ? 'pending' : 'delivered',
    });
  }
  // Oldest first, as the server stores them.
  return runs.reversed.toList();
}

/// Eight tasks across two computers covering every state the screens show.
List<Map<String, dynamic>> seedTasks() {
  final now = seedNow;
  final tomorrow7 = DateTime(now.year, now.month, now.day + 1, 7);
  return [
    {
      'id': 'digest',
      '_serverId': 'tower',
      'name': 'Morning digest',
      'prompt': seedPrompt,
      'cwd': '/home/billy/agents',
      'backend': 'codex',
      'codexDriver': 'app-server',
      'model': 'gpt-6.1-sol',
      'effort': 'high',
      'permissionMode': 'bypassPermissions',
      'scheduledTime': _iso(tomorrow7),
      'recurrence': {'type': 'daily'},
      'reuseSession': true,
      'notificationMode': 'quiet',
      'status': 'pending',
      'createdAt': _iso(DateTime(2026, 7, 17, 9)),
      'sessionId': 'run-0',
      'resultSummary': seedResult,
      'runCount': 107,
      'lastRunAt': _iso(DateTime(now.year, now.month, now.day, 7, 4)),
      'lastReadAt': _iso(DateTime(now.year, now.month, now.day - 1, 8)),
      'runs': seedRuns(
        count: 107,
        lastEnd: DateTime(now.year, now.month, now.day, 7, 4),
        step: const Duration(days: 1),
      ),
    },
    {
      'id': 'backup',
      '_serverId': 'tower',
      'name': 'Weekly backup check',
      'prompt':
          'Verify last night\'s backup set on the NAS: compare file counts with the manifest and spot-check three random archives.',
      'cwd': '/home/billy/ops',
      'backend': 'claude',
      'effort': 'medium',
      'scheduledTime': _iso(DateTime(2026, 11, 2, 6)),
      'recurrence': {'type': 'weekly'},
      'reuseSession': true,
      'notificationMode': 'completion',
      'status': 'pending',
      'createdAt': _iso(DateTime(2026, 8, 3, 18)),
      'sessionId': 'bk-0',
      'runCount': 17,
      'lastRunAt': _iso(DateTime(2026, 10, 26, 6, 5)),
      'lastReadAt': _iso(DateTime(2026, 10, 26, 9)),
      'runs': seedRuns(
        count: 17,
        lastEnd: DateTime(2026, 10, 26, 6, 5),
        step: const Duration(days: 7),
        sessionPrefix: 'bk',
        latest:
            'Manifest matches: 48,211 files. Spot-checked 3 archives, all open cleanly.',
      ),
    },
    {
      'id': 'triage',
      '_serverId': 'tower',
      'name': 'Inbox triage',
      'prompt': 'Triage new email into folders and flag anything from clients.',
      'cwd': '/home/billy/agents',
      'backend': 'codex',
      'codexDriver': 'app-server',
      'model': 'gpt-5.6-sol',
      'effort': 'high',
      'permissionMode': 'bypassPermissions',
      'scheduledTime': _iso(DateTime(2026, 10, 20, 12)),
      'recurrence': {'type': 'custom', 'intervalMs': 6 * 3600 * 1000},
      'reuseSession': true,
      'notificationMode': 'quiet',
      'status': 'cancelled',
      'createdAt': _iso(DateTime(2026, 8, 20, 11)),
      'sessionId': 'tri-0',
      'runCount': 109,
      'lastRunAt': _iso(DateTime(2026, 10, 20, 6, 2)),
      'lastReadAt': _iso(DateTime(2026, 10, 20, 7)),
      'runs': seedRuns(
        count: 109,
        lastEnd: DateTime(2026, 10, 20, 6, 2),
        step: const Duration(hours: 6),
        sessionPrefix: 'tri',
        latest:
            'Filed 14 messages. Flagged one from Rubano Enterprises about the invoice schedule.',
      ),
    },
    {
      'id': 'smoke',
      '_serverId': 'laptop',
      'name': 'Deploy smoke test',
      'prompt':
          'Hit the staging health endpoints, run the login flow in the browser and report anything that is not a 200.',
      'cwd': '/home/billy/work/web',
      'backend': 'claude',
      'permissionMode': 'acceptEdits',
      'scheduledTime': _iso(now.subtract(const Duration(minutes: 4))),
      'reuseSession': false,
      'notificationMode': 'completion',
      'linkedSessionId': 'sess-1',
      'status': 'running',
      'createdAt': _iso(now.subtract(const Duration(hours: 2))),
      'createdBySessionId': 'sess-1',
      'sessionId': 'smoke-live',
      'runCount': 0,
      'runs': [
        {
          'startedAt': _iso(now.subtract(const Duration(minutes: 4))),
          'status': 'running',
          'trigger': 'scheduled',
          'sessionId': 'smoke-live',
          'callbackSessionId': 'sess-1',
          'callbackStatus': 'pending',
        },
      ],
    },
    {
      'id': 'photos',
      '_serverId': 'laptop',
      'name': 'Rename photos',
      'prompt':
          'Rename every photo in the folder to its EXIF date and move duplicates into _dupes.',
      'cwd': '/mnt/photos/2026-10',
      'backend': 'codex',
      'codexDriver': 'app-server',
      'scheduledTime': _iso(now.subtract(const Duration(hours: 3))),
      'reuseSession': false,
      'notificationMode': 'completion',
      'status': 'failed',
      'createdAt': _iso(now.subtract(const Duration(hours: 5))),
      'error': 'Directory not found: /mnt/photos/2026-10',
      'runCount': 1,
      'lastRunAt': _iso(now.subtract(const Duration(hours: 3))),
      'runs': [
        {
          'startedAt': _iso(now.subtract(const Duration(hours: 3))),
          'completedAt': _iso(now.subtract(const Duration(hours: 3))),
          'status': 'failed',
          'trigger': 'scheduled',
          'error': 'Directory not found: /mnt/photos/2026-10',
        },
      ],
    },
    {
      'id': 'notes',
      '_serverId': 'laptop',
      'name': 'Write release notes',
      'prompt':
          'Draft release notes for 1.0.298 from the commits since the last tag. Group by area, one line each.',
      'cwd': '/home/billy/agents/socketagent-app',
      'backend': 'codex',
      'codexDriver': 'app-server',
      'model': 'gpt-6.1-sol',
      'effort': 'medium',
      'scheduledTime': _iso(DateTime(now.year, now.month, now.day + 1, 9)),
      'reuseSession': false,
      'notificationMode': 'completion',
      'linkedSessionId': 'sess-1',
      'status': 'pending',
      'createdAt': _iso(now.subtract(const Duration(minutes: 40))),
      'createdBySessionId': 'sess-1',
      'runCount': 0,
      'runs': const [],
    },
    {
      'id': 'lint',
      '_serverId': 'laptop',
      'name': 'Nightly lint',
      'prompt':
          'Run the linter and fix anything trivial. Open a PR if there are changes.',
      'cwd': '/home/billy/work/web',
      'backend': 'claude',
      'effort': 'low',
      'permissionMode': 'bypassPermissions',
      'scheduledTime': _iso(DateTime(now.year, now.month, now.day, 2)),
      'reuseSession': false,
      'notificationMode': 'quiet',
      'status': 'completed',
      'createdAt': _iso(DateTime(now.year, now.month, now.day - 1, 22)),
      'sessionId': 'lint-0',
      'resultSummary': 'No lint findings. Nothing to commit.',
      'runCount': 1,
      'lastRunAt': _iso(DateTime(now.year, now.month, now.day, 2, 1)),
      'lastReadAt': _iso(DateTime(now.year, now.month, now.day, 8)),
      'runs': [
        {
          'startedAt': _iso(DateTime(now.year, now.month, now.day, 2)),
          'completedAt': _iso(DateTime(now.year, now.month, now.day, 2, 1)),
          'status': 'completed',
          'trigger': 'scheduled',
          'sessionId': 'lint-0',
          'resultSummary': 'No lint findings. Nothing to commit.',
        },
      ],
    },
    {
      'id': 'pr412',
      '_serverId': 'tower',
      'name': 'Summarize PR 412',
      'prompt': 'Summarize PR 412 and list open review threads.',
      'cwd': '/home/billy/agents/socketagent-app',
      'backend': 'codex',
      'codexDriver': 'app-server',
      'scheduledTime': _iso(DateTime(2026, 10, 28, 16)),
      'reuseSession': false,
      'notificationMode': 'completion',
      'linkedSessionId': 'sess-1',
      'status': 'completed',
      'createdAt': _iso(DateTime(2026, 10, 28, 15)),
      'createdBySessionId': 'sess-1',
      'sessionId': 'pr-0',
      'resultSummary': 'Three open threads, all on the row density change.',
      'runCount': 1,
      'lastRunAt': _iso(DateTime(2026, 10, 28, 16, 2)),
      'lastReadAt': _iso(DateTime(2026, 10, 29, 9)),
      'archivedAt': _iso(DateTime(2026, 10, 29, 9)),
      'runs': [
        {
          'startedAt': _iso(DateTime(2026, 10, 28, 16)),
          'completedAt': _iso(DateTime(2026, 10, 28, 16, 2)),
          'status': 'completed',
          'trigger': 'scheduled',
          'sessionId': 'pr-0',
          'resultSummary': 'Three open threads, all on the row density change.',
          'callbackSessionId': 'sess-1',
          'callbackStatus': 'delivered',
        },
      ],
    },
  ];
}

List<ServerConfig> seedConfigs() => [
  fakeConfig(
    'tower',
    'tower',
    host: '10.0.0.4',
    port: 8787,
    expectedOnline: true,
    colorValue: 0xFF42A5F5,
    defaultCwd: '/home/billy/agents',
  ),
  fakeConfig(
    'laptop',
    'laptop',
    useRelay: true,
    colorValue: 0xFFAB47BC,
    defaultCwd: '/home/billy/work',
  ),
];

List<Session> seedSessions() => [
  Session(
    id: 'sess-1',
    title: 'Release 1.0.298 prep',
    cwd: '/home/billy/agents/socketagent-app',
    createdAt: seedNow.subtract(const Duration(hours: 3)),
    lastActive: seedNow,
    messagePreview: '',
    serverId: 'laptop',
    backend: 'codex',
  ),
  Session(
    id: 'run-0',
    title: 'Morning digest',
    cwd: '/home/billy/agents',
    createdAt: seedNow,
    lastActive: seedNow,
    messagePreview: '',
    serverId: 'tower',
    backend: 'codex',
    scheduledTaskId: 'digest',
  ),
];

/// A provider over fixed tasks that records every scheduled-task write and
/// applies the local effects the real one would, so the screens can be
/// driven end to end without a socket.
class FakeTasksProvider extends ChatProvider {
  FakeTasksProvider({
    List<Map<String, dynamic>>? tasks,
    List<ServerConfig>? configs,
    Map<String, ConnectionStatus>? statuses,
    List<Session>? fakeSessions,
    this.backends = const {
      'tower': ['claude', 'codex'],
      'laptop': ['claude', 'codex'],
    },
    this.recentCwds = const {
      'tower': ['/home/billy/agents', '/home/billy/ops'],
      'laptop': ['/home/billy/work/web'],
    },
    this.folderExists = true,
  }) : tasks = tasks ?? seedTasks(),
       configs = configs ?? seedConfigs(),
       fakeSessions = fakeSessions ?? seedSessions(),
       fakeConnMgr = FakeConnectionManager(
         statuses ??
             const {
               'tower': ConnectionStatus.connected,
               'laptop': ConnectionStatus.disconnected,
             },
       );

  List<Map<String, dynamic>> tasks;
  final List<ServerConfig> configs;
  final List<Session> fakeSessions;
  final FakeConnectionManager fakeConnMgr;
  final Map<String, List<String>> backends;
  final Map<String, List<String>> recentCwds;
  bool folderExists;

  /// Every write, as `(method, arguments)`.
  final List<(String, Map<String, Object?>)> calls = [];
  final Map<String, String> revisions = {};
  final StreamController<ScheduledTaskError> errors =
      StreamController.broadcast();
  int sessionListRequests = 0;

  bool _online(String? serverId) =>
      serverId != null &&
      fakeConnMgr.statusOf(serverId) == ConnectionStatus.connected;

  String? _serverOf(String taskId) =>
      tasks.where((t) => t['id'] == taskId).firstOrNull?['_serverId']
          as String?;

  /// Replaces the list as a `scheduled_task_list` from [serverId] would.
  void receiveList(String serverId, List<Map<String, dynamic>> fresh) {
    tasks = [
      ...tasks.where((t) => t['_serverId'] != serverId),
      for (final t in fresh) {...t, '_serverId': serverId},
    ];
    revisions[serverId] = '${(revisions[serverId]?.length ?? 0) + 1}';
    notifyListeners();
  }

  @override
  List<Map<String, dynamic>> get scheduledTasks => tasks;

  @override
  List<ServerConfig> get serverConfigs => configs;

  @override
  ConnectionManager get connMgr => fakeConnMgr;

  @override
  List<Session> get sessions => fakeSessions;

  /// Codex first when present, as the real provider orders them.
  @override
  List<String> backendsForServer(String? serverId) {
    final raw = backends[serverId] ?? const ['claude'];
    if (!raw.contains('codex')) return raw;
    return ['codex', ...raw.where((b) => b != 'codex')];
  }

  @override
  String preferredBackendForServer(String? serverId) =>
      backendsForServer(serverId).first;

  @override
  List<String> getRecentCwds({String? serverId}) =>
      recentCwds[serverId] ?? const [];

  @override
  void requestRecentCwds({String? serverId}) {}

  /// Model lists by `serverId|backend`, and every catalog request made.
  final Map<String, List<ModelChoice>> catalogs = {};
  final List<String> catalogRequests = [];

  @override
  List<ModelChoice>? modelCatalog(String serverId, String backend) =>
      catalogs['$serverId|$backend'];

  @override
  void requestModelCatalog(String serverId, String backend) {
    catalogRequests.add('$serverId|$backend');
  }

  @override
  void requestScheduledTasks() {}

  @override
  void requestSessionList() {
    sessionListRequests++;
  }

  @override
  Future<bool> checkCwd(String path, {String? serverId}) async => folderExists;

  @override
  Stream<ScheduledTaskError> get scheduledTaskErrors => errors.stream;

  /// Stands in for the computers' `scheduled_task_save_result` replies.
  final StreamController<ScheduledTaskSaveResult> saveResults =
      StreamController.broadcast(sync: true);

  @override
  Stream<ScheduledTaskSaveResult> get scheduledTaskSaveResults =>
      saveResults.stream;

  @override
  String? scheduledTaskRevision(String serverId) => revisions[serverId];

  @override
  bool scheduleTask({
    String? name,
    String? linkedSessionId,
    required String prompt,
    required String cwd,
    required String scheduledTime,
    String? backend,
    String? model,
    String? effort,
    String? permissionMode,
    String? recurrenceType,
    int? customIntervalMs,
    List<int>? daysOfWeek,
    bool reuseSession = false,
    String notificationMode = 'completion',
    String? serverId,
    String? requestId,
  }) {
    calls.add((
      'scheduleTask',
      {
        'name': name,
        'linkedSessionId': linkedSessionId,
        'prompt': prompt,
        'cwd': cwd,
        'scheduledTime': scheduledTime,
        'backend': backend,
        'model': model,
        'effort': effort,
        'permissionMode': permissionMode,
        'recurrenceType': recurrenceType,
        'customIntervalMs': customIntervalMs,
        'daysOfWeek': daysOfWeek,
        'reuseSession': reuseSession,
        'notificationMode': notificationMode,
        'serverId': serverId,
        'requestId': requestId,
      },
    ));
    return _online(serverId);
  }

  @override
  bool updateScheduledTask({
    required String taskId,
    String? name,
    String? prompt,
    String? cwd,
    String? backend,
    String? model,
    String? effort,
    String? permissionMode,
    String? scheduledTime,
    String? recurrenceType,
    int? customIntervalMs,
    List<int>? daysOfWeek,
    bool? reuseSession,
    String? notificationMode,
    String? requestId,
  }) {
    final msg = <String, dynamic>{
      'name': ?name,
      'prompt': ?prompt,
      'cwd': ?cwd,
      'backend': ?backend,
      'model': ?model,
      'effort': ?effort,
      'permissionMode': ?permissionMode,
      'scheduledTime': ?scheduledTime,
      'reuseSession': ?reuseSession,
      'notificationMode': ?notificationMode,
      if (recurrenceType != null)
        'recurrence': recurrenceType == 'once'
            ? null
            : {
                'type': recurrenceType,
                'intervalMs': ?customIntervalMs,
                'daysOfWeek': ?daysOfWeek,
              },
      'requestId': ?requestId,
    };
    calls.add(('updateScheduledTask', {'taskId': taskId, ...msg}));
    final index = tasks.indexWhere((t) => t['id'] == taskId);
    if (index >= 0) {
      tasks[index] = applyScheduledTaskUpdate(tasks[index], msg);
      notifyListeners();
    }
    return _online(_serverOf(taskId));
  }

  /// Full histories a test answers with; see [answerRuns].
  final Map<String, List<Map<String, dynamic>>> fullRuns = {};

  @override
  List<Map<String, dynamic>>? scheduledTaskRuns(
    String serverId,
    String taskId,
  ) => fullRuns[taskId];

  /// Task ids the detail page asked full run histories for. Kept out of
  /// [calls], which records user actions.
  final List<String> runRequests = [];

  @override
  bool requestScheduledTaskRuns(String serverId, String taskId) {
    runRequests.add(taskId);
    return true;
  }

  /// Stands in for a computer's `scheduled_task_runs` reply.
  void answerRuns(String taskId, List<Map<String, dynamic>> runs) {
    fullRuns[taskId] = runs;
    notifyListeners();
  }

  @override
  bool cancelScheduledTask(String taskId) {
    calls.add(('cancelScheduledTask', {'taskId': taskId}));
    return _online(_serverOf(taskId));
  }

  @override
  bool executeScheduledTask(String taskId) {
    calls.add(('executeScheduledTask', {'taskId': taskId}));
    return _online(_serverOf(taskId));
  }

  @override
  bool markScheduledTaskRead(
    String taskId, {
    bool read = true,
    String? serverId,
  }) {
    calls.add(('markScheduledTaskRead', {'taskId': taskId, 'read': read}));
    for (final task in tasks.where((t) => t['id'] == taskId)) {
      if (read) {
        task['lastReadAt'] = _iso(DateTime.now());
      } else {
        task.remove('lastReadAt');
      }
    }
    notifyListeners();
    return _online(_serverOf(taskId));
  }

  @override
  bool archiveScheduledTask(String taskId) {
    calls.add(('archiveScheduledTask', {'taskId': taskId}));
    for (final task in tasks.where((t) => t['id'] == taskId)) {
      task['archivedAt'] = _iso(DateTime.now());
      task['lastReadAt'] = _iso(DateTime.now());
    }
    notifyListeners();
    return _online(_serverOf(taskId));
  }

  @override
  bool restoreScheduledTask(String taskId) {
    calls.add(('restoreScheduledTask', {'taskId': taskId}));
    for (final task in tasks.where((t) => t['id'] == taskId)) {
      task.remove('archivedAt');
    }
    notifyListeners();
    return _online(_serverOf(taskId));
  }

  @override
  bool deleteScheduledTask(String taskId) {
    calls.add(('deleteScheduledTask', {'taskId': taskId}));
    final sent = _online(_serverOf(taskId));
    tasks.removeWhere((t) => t['id'] == taskId);
    notifyListeners();
    return sent;
  }

  @override
  void resumeSession(String sessionId, {String? serverId}) {
    calls.add((
      'resumeSession',
      {'sessionId': sessionId, 'serverId': serverId},
    ));
  }

  @override
  void dispose() {
    unawaited(errors.close());
    unawaited(saveResults.close());
    super.dispose();
  }
}
