import 'dart:io';

import 'package:app/models/composer_attachment.dart';
import 'package:app/models/computer_access.dart';
import 'package:app/models/device_registry.dart';
import 'package:app/ui_a/data.dart';
import 'package:app/ui_a/theme.dart';
import 'package:flutter/services.dart';

/// Fixed "now" for every render, so clocks and ages are stable.
final fakeNow = DateTime(2026, 10, 31, 14, 30);

DateTime ago({int h = 0, int m = 0, int s = 0}) =>
    fakeNow.subtract(Duration(hours: h, minutes: m, seconds: s));

/// [TowerData] with a believable fleet: four computers, a dozen sessions,
/// one open session mid-run. Scenes mutate the public fields.
class FakeTowerData extends TowerData {
  FakeTowerData() {
    messages = releaseTranscript();
  }

  final List<String> actions = [];

  @override
  List<TowerComputer> computers = const [
    TowerComputer(
      id: 'mac',
      name: 'mac-mini',
      status: ConnectionStatus.connected,
      color: 0xFF2EC4B6,
      relay: true,
      pushRegistered: true,
    ),
    TowerComputer(
      id: 'win',
      name: 'win-desk',
      status: ConnectionStatus.connected,
      color: 0xFFFF9F1C,
      pushRegistered: true,
    ),
    TowerComputer(
      id: 'nas',
      name: 'nas',
      status: ConnectionStatus.disconnected,
      color: 0xFF9B5DE5,
      expectedOnline: true,
    ),
    TowerComputer(
      id: 'fam',
      name: 'family-pc',
      status: ConnectionStatus.connecting,
      color: 0xFFF15BB5,
    ),
  ];

  static Session _s(
    String id,
    String title,
    String server,
    String backend, {
    String cwd = '/home/billy/agents/socketagent-app',
    required DateTime last,
    String preview = '',
    int turns = 12,
    DateTime? running,
    DateTime? finished,
    String? parent,
    String? lifetime,
    DateTime? expires,
    String? scheduled,
  }) {
    final names = {
      'mac': 'mac-mini',
      'win': 'win-desk',
      'nas': 'nas',
      'fam': 'family-pc',
    };
    final colors = {
      'mac': 0xFF2EC4B6,
      'win': 0xFFFF9F1C,
      'nas': 0xFF9B5DE5,
      'fam': 0xFFF15BB5,
    };
    return Session(
      id: id,
      title: title,
      cwd: cwd,
      createdAt: last.subtract(const Duration(days: 1)),
      lastActive: last,
      messagePreview: preview,
      turnCount: turns,
      serverId: server,
      serverName: names[server]!,
      serverColor: colors[server],
      backend: backend,
      delegatedBySessionId: parent,
      lifetime: lifetime,
      expiresAt: expires,
      scheduledTaskId: scheduled,
      runStats: SessionRunStats(
        current: running == null
            ? null
            : SessionRunCurrent(runId: 'r', startedAt: running),
        completedCount: 41,
        totalDurationMs: 41 * 190000,
        averageDurationMs: 190000,
        longestDurationMs: 3900000,
        shortestDurationMs: 4000,
        lastCompletedAt: finished,
        recentRuns: [
          for (var i = 0; i < 36; i++)
            SessionRunRecord(
              runId: 'r$i',
              runNumber: i + 6,
              startedAt: ago(h: 40 - i),
              finishedAt: ago(h: 40 - i, m: -3),
              durationMs:
                  [
                    42000,
                    180000,
                    9000,
                    610000,
                    75000,
                    1200000,
                    30000,
                    260000,
                  ][i % 8] +
                  i * 1500,
              outcome: i == 9 ? 'failed' : (i == 22 ? 'stopped' : 'completed'),
            ),
        ],
      ),
    );
  }

  @override
  List<Session> sessions = [
    _s(
      'rel',
      'Release v1.0.299 to Play',
      'mac',
      'codex',
      last: ago(m: 0),
      running: ago(m: 4, s: 12),
      preview: 'Building the release bundle and running widget tests',
    ),
    _s(
      'relay',
      'Fix relay reconnect storm',
      'win',
      'codex',
      cwd: 'C:/Users/billy/agents/socketagent',
      last: ago(m: 1),
      running: ago(m: 18, s: 40),
      preview: 'Two agents checking the backoff patch',
    ),
    _s(
      'relay-child',
      'Verify backoff on win-desk',
      'win',
      'claude',
      cwd: 'C:/Users/billy/agents/socketagent',
      last: ago(m: 2),
      running: ago(m: 6, s: 3),
      parent: 'relay',
      lifetime: 'fleeting',
      turns: 1,
    ),
    _s(
      'inv',
      'Invoice export for October',
      'mac',
      'claude',
      cwd: '/Users/billy/work/books',
      last: ago(m: 12),
      finished: ago(m: 12),
      preview: 'Exported 214 invoices to october.csv and sent the file',
    ),
    _s(
      'notif',
      'Group finish notifications',
      'win',
      'codex',
      last: ago(h: 1, m: 5),
      finished: ago(h: 1, m: 5),
      preview: 'Grouped alerts land; summary shows 3 sessions',
    ),
    _s(
      'health',
      'Nightly health check',
      'mac',
      'codex',
      cwd: '/home/billy/agents/socketagent',
      last: ago(h: 2),
      finished: ago(h: 2),
      scheduled: 't1',
      preview: 'All 5 computers healthy. nas expected online but offline',
    ),
    _s(
      'server',
      'SocketAgent server',
      'mac',
      'codex',
      cwd: '/home/billy/agents/socketagent/server',
      last: ago(h: 5),
      finished: ago(h: 30),
    ),
    _s(
      'ui',
      'UI revamp brief',
      'mac',
      'claude',
      last: ago(h: 6),
      finished: ago(h: 30),
    ),
    _s(
      'play',
      'Play Console listing copy',
      'win',
      'claude',
      last: ago(h: 9),
      finished: ago(h: 30),
    ),
    _s(
      'nasbk',
      'nas backup rotation',
      'nas',
      'codex',
      cwd: '/srv/backup',
      last: ago(h: 26),
      finished: ago(h: 30),
    ),
    _s(
      'fam',
      'Printer driver on family PC',
      'fam',
      'claude',
      cwd: 'C:/Users/mom',
      last: ago(h: 30),
      finished: ago(h: 31),
    ),
    _s(
      'kokoro',
      'Kokoro voice model sizes',
      'mac',
      'codex',
      last: ago(h: 52),
      finished: ago(h: 60),
    ),
    _s(
      'scan',
      'QR pairing on Windows',
      'win',
      'codex',
      last: ago(h: 80),
      finished: ago(h: 90),
    ),
  ];

  final Set<String> pinned = {'server'};
  final Set<String> muted = {'health'};
  final Set<String> unread = {'inv', 'notif', 'health'};

  @override
  Live liveOf(Session session) {
    if (session.id == openSessionId && session.serverId == openServerId) {
      return processing ? Live.running : Live.idle;
    }
    return session.runStats?.current != null ? Live.running : Live.idle;
  }

  @override
  DateTime? runStartedAt(Session session) =>
      session.runStats?.current?.startedAt;
  @override
  bool hasUnread(Session session) => unread.contains(session.id);
  @override
  bool isPinned(Session session) => pinned.contains(session.id);
  @override
  bool isMuted(Session session) => muted.contains(session.id);
  @override
  void togglePin(Session session) => actions.add('pin ${session.id}');
  @override
  void toggleMute(Session session) => actions.add('mute ${session.id}');

  @override
  List<PendingDevice> pendingDevices = const [];
  @override
  Future<void> approveDevice(PendingDevice device) async =>
      actions.add('approve device');
  @override
  Future<void> denyDevice(PendingDevice device) async =>
      actions.add('deny device');

  @override
  List<Map<String, dynamic>> scheduledTasks = [
    {
      'id': 't1',
      'name': 'Nightly health check',
      'status': 'pending',
      'recurrence': 'daily',
      'runCount': 112,
      'lastRunAt': '2026-10-31T06:00:00Z',
    },
    {
      'id': 't2',
      'name': 'Retry Play upload after rate limit',
      'status': 'completed',
      'recurrence': 'once',
      'runCount': 1,
      'lastRunAt': '2026-10-30T22:10:00Z',
      'lastReadAt': '2026-10-30T23:00:00Z',
    },
  ];
  @override
  int get unreadScheduledTaskCount => 1;
  @override
  void runScheduledTask(String taskId) => actions.add('run $taskId');
  @override
  void markScheduledTaskRead(String taskId) => actions.add('read $taskId');

  @override
  String? openSessionId = 'rel';
  @override
  String? openServerId = 'mac';
  @override
  bool isDraftSession = false;
  @override
  String? get openTitle => openSession?.title;
  @override
  String? get openCwd => openSession?.cwd;
  @override
  String? get openBackend => openSession?.backend;
  @override
  bool openOffline = false;
  @override
  late List<ChatMessage> messages;
  bool processing = true;
  @override
  bool get isProcessing => processing;
  @override
  bool isCompacting = false;
  @override
  DateTime? get openRunStartedAt => ago(m: 4, s: 12);
  @override
  bool hasMoreHistory = true;
  @override
  bool isLoadingHistory = false;
  @override
  void loadMoreHistory() => actions.add('more');
  @override
  List<String> promptSuggestions = const [];
  @override
  List<Map<String, dynamic>> slashCommands = const [
    {
      'name': 'compact',
      'description': 'Summarize the conversation',
      'kind': 'command',
    },
    {
      'name': 'review',
      'description': 'Review uncommitted changes',
      'kind': 'command',
    },
    {'name': 'release', 'description': 'Cut a release build', 'kind': 'skill'},
  ];

  @override
  Map<String, Map<String, dynamic>> tasks = {
    'a1': {
      '_kind': 'subagent',
      'description': 'Check Play Console for the 1.0.298 review status',
      'subagentType': 'explorer',
      'status': 'running',
      'lastToolName': 'BrowserSession',
      'startedAt': ago(m: 2, s: 30).toIso8601String(),
    },
    'b1': {
      '_kind': 'bash',
      'summary': 'flutter build appbundle --release',
      'status': 'running',
      'startedAt': ago(m: 3, s: 2).toIso8601String(),
    },
    'm1': {
      '_kind': 'bash',
      'isMonitor': true,
      'summary': 'Watch CI run 8812',
      'status': 'running',
      'startedAt': ago(m: 11).toIso8601String(),
    },
    'a0': {
      '_kind': 'subagent',
      'description': 'Summarize changelog since 1.0.290',
      'subagentType': 'worker',
      'status': 'completed',
    },
  };
  @override
  List<Map<String, dynamic>> todos = const [
    {'content': 'Bump version to 1.0.299', 'status': 'completed'},
    {'content': 'Run widget tests', 'status': 'completed'},
    {
      'content': 'Build release bundle',
      'activeForm': 'Building release bundle',
      'status': 'in_progress',
    },
    {'content': 'Upload to internal track', 'status': 'pending'},
    {'content': 'Post release notes', 'status': 'pending'},
  ];
  @override
  Map<String, dynamic>? contextUsage = {
    'totalTokens': 148200,
    'maxTokens': 258000,
    'categories': [
      {'name': 'System prompt', 'tokens': 9100},
      {'name': 'Tools', 'tokens': 14800},
      {'name': 'Memory files', 'tokens': 6200},
      {'name': 'Skills', 'tokens': 2300},
      {'name': 'Messages', 'tokens': 115800},
      {'name': 'Free space', 'tokens': 109800},
    ],
  };
  @override
  bool condensedTools = true;
  @override
  void setCondensedTools(bool value) => condensedTools = value;

  @override
  String? permissionMode = 'bypassPermissions';
  @override
  String? model = 'gpt-5.5-codex';
  @override
  String effort = 'high';
  @override
  List<Map<String, dynamic>> models = const [
    {'value': 'gpt-5.5-codex', 'displayName': 'gpt-5.5-codex'},
    {'value': 'gpt-5.5', 'displayName': 'gpt-5.5'},
  ];
  @override
  List<String> effortLevels = const ['low', 'medium', 'high', 'xhigh'];
  @override
  void setModel(String model) => actions.add('model $model');
  @override
  void setEffort(String effort) => actions.add('effort $effort');
  @override
  void setPermissionMode(String mode) => actions.add('mode $mode');

  @override
  void open(Session session) {
    openSessionId = session.id;
    openServerId = session.serverId;
    actions.add('open ${session.id}');
    notifyListeners();
  }

  @override
  void closeOpen() => actions.add('close');
  @override
  void startDraft({
    required String serverId,
    required String backend,
    String? cwd,
    bool fleeting = false,
  }) => actions.add('draft $serverId $backend');
  @override
  Future<bool> send(String text, {Priority? priority}) async {
    actions.add('send ${priority?.name ?? '-'} $text');
    return true;
  }

  @override
  String? retract(String messageId) => null;
  @override
  Future<void> stop() async => actions.add('stop');
  @override
  void interrupt() => actions.add('interrupt');
  @override
  void stopTask(String taskId) => actions.add('stop task $taskId');
  @override
  void backgroundTask(String toolUseId) => actions.add('bg $toolUseId');
  @override
  bool get canBackgroundTasks => false;
  @override
  void dismissTask(String id, String kind) => actions.add('dismiss $id');
  @override
  void requestFullOutput(ChatMessage message) => actions.add('full');
  @override
  void compact() => actions.add('compact');

  String draftText = '';
  @override
  String draft() => draftText;
  @override
  void saveDraft(String text) {}
  @override
  List<PendingFileAttachment> fileAttachments = [];
  @override
  List<PendingSecretAttachment> secretAttachments = [];
  @override
  Future<void> pickFiles({bool images = false}) async {}
  @override
  void removeFile(String id) {}
  @override
  void removeSecret(String id) {}

  @override
  Future<void> answerQuestion(
    String questionId,
    Map<String, String> answers,
  ) async => actions.add('answer $questionId ${answers.values.join('|')}');
  @override
  void submitSecret(String requestId, String value) =>
      actions.add('secret $requestId');
  @override
  void cancelSecret(String requestId) => actions.add('cancel secret');
  @override
  void useStoredSecret(String requestId, SecretMetadata secret) =>
      actions.add('stored ${secret.label}');
  @override
  List<SecretMetadata> storedSecrets = [
    SecretMetadata(
      secretId: 's1',
      label: 'Play service account',
      scope: 'project',
      filePath: '',
      envHint: 'PLAY_SERVICE_JSON',
      createdAt: DateTime(2026, 8, 30),
    ),
  ];
  @override
  Future<void> answerAccess(
    String requestId,
    String decision, {
    ComputerAccess? access,
  }) async => actions.add('access $decision');

  @override
  void rename(Session session, String title) {}
  @override
  void archive(Session session) {}
  @override
  void delete(Session session) => actions.add('delete ${session.id}');
  @override
  void makePermanent(Session session) {}

  @override
  List<String> backendsFor(String serverId) => const ['codex', 'claude'];
  @override
  List<String> recentFolders(String serverId) => const [
    '/home/billy/agents/socketagent-app',
    '/home/billy/agents/socketagent/server',
    '/Users/billy/work/books',
  ];
  @override
  void refreshFolders(String serverId) {}
  @override
  String defaultFolder(String serverId) => '/home/billy/agents';
}

ChatMessage _tool(
  String id,
  String name,
  Map<String, dynamic> input, {
  String? output,
  bool running = false,
  double secs = 0,
  required DateTime at,
}) => ChatMessage(
  id: 'tool_$id',
  sender: MessageSender.assistant,
  type: MessageType.toolCall,
  timestamp: at,
  toolName: name,
  toolInput: input,
  toolUseId: id,
  toolOutput: output,
  toolStreaming: running,
  toolElapsedSeconds: secs,
);

ChatMessage _text(String id, MessageSender who, String text, DateTime at) =>
    ChatMessage(
      id: id,
      sender: who,
      type: MessageType.text,
      timestamp: at,
      textContent: text,
    );

/// The open session mid-run: an earlier exchange, a finished run, a new
/// prompt and a stretch of tool work still going.
List<ChatMessage> releaseTranscript() => [
  _text(
    'u1',
    MessageSender.user,
    'what changed since 1.0.298? keep it short',
    ago(m: 40),
  ),
  ChatMessage(
      id: 'th1',
      sender: MessageSender.assistant,
      type: MessageType.thinking,
      timestamp: ago(m: 40),
      textContent: '**Scanning the log** for commits after the 1.0.298 tag.',
    )
    ..thinkingTokens = 812
    ..thinkingDurationMs = 4100,
  _tool(
    't1',
    'exec_command',
    {'command': 'git log --oneline v1.0.298..HEAD'},
    output:
        '6204313 Add an interface switch\n483a364 Sign in to MCP servers\n5ef0d90 Merge Codex commands',
    secs: 0.4,
    at: ago(m: 39, s: 50),
  ),
  _text(
    'a1',
    MessageSender.assistant,
    'Three changes since **1.0.298**:\n\n- An interface switch to try redesigns side by side\n- MCP server sign-in from the servers screen\n- Codex slash commands merged into the picker',
    ago(m: 39, s: 40),
  ),
  ChatMessage.runBoundary({
    'entryId': 'rb1',
    'runId': 'r40',
    'runNumber': 40,
    'runDurationMs': 22000,
    'runOutcome': 'completed',
    'runFinishedAt': ago(m: 39, s: 38).toIso8601String(),
  }),
  _text(
    'u2',
    MessageSender.user,
    'ship it. bump to 1.0.299, run the widget tests, build the bundle and push to internal. ping me if Play complains',
    ago(m: 4, s: 14),
  ),
  ChatMessage.codexPlan(
    turnId: 'turn9',
    explanation: '',
    steps: [
      {'step': 'Bump version to 1.0.299', 'status': 'completed'},
      {'step': 'Run widget tests', 'status': 'completed'},
      {'step': 'Build release bundle', 'status': 'in_progress'},
      {'step': 'Upload to internal track', 'status': 'pending'},
    ],
  ),
  _tool(
    't2',
    'apply_patch',
    {
      'input':
          '*** Begin Patch\n*** Update File: pubspec.yaml\n-version: 1.0.298+300\n+version: 1.0.299+301\n*** End Patch',
    },
    output: 'Success',
    secs: 0.1,
    at: ago(m: 4),
  ),
  _tool(
    't3',
    'exec_command',
    {'command': 'rg -n "1.0.298" CHANGELOG.md lib/config'},
    output: 'CHANGELOG.md:3:## 1.0.298',
    secs: 0.2,
    at: ago(m: 3, s: 58),
  ),
  _tool(
    't4',
    'apply_patch',
    {
      'input':
          '*** Begin Patch\n*** Update File: CHANGELOG.md\n+## 1.0.299\n+- Interface switch\n+- MCP sign-in\n+- Codex slash commands\n*** End Patch',
    },
    output: 'Success',
    secs: 0.1,
    at: ago(m: 3, s: 50),
  ),
  ChatMessage(
      id: 'th2',
      sender: MessageSender.assistant,
      type: MessageType.thinking,
      timestamp: ago(m: 3, s: 45),
    )
    ..thinkingTokens = 1240
    ..thinkingDurationMs = 6300,
  _tool(
    't5',
    'exec_command',
    {'command': 'flutter test test/widget', 'description': 'widget tests'},
    output: '00:41 +412: All tests passed!',
    secs: 41,
    at: ago(m: 3, s: 40),
  ),
  _tool(
    't6',
    'exec_command',
    {'command': 'flutter analyze'},
    output:
        'error • Undefined name \'kReleaseTrack\' • lib/config/app_distribution.dart:41:9\nExit code 1',
    secs: 9,
    at: ago(m: 3, s: 20),
  ),
  _tool(
    't7',
    'apply_patch',
    {
      'input':
          '*** Begin Patch\n*** Update File: lib/config/app_distribution.dart\n-  kReleaseTrack,\n+  releaseTrack,\n*** End Patch',
    },
    output: 'Success',
    secs: 0.1,
    at: ago(m: 3, s: 10),
  ),
  _text(
    'a2',
    MessageSender.assistant,
    'Tests pass. Fixed a stale `kReleaseTrack` reference that `flutter analyze` caught. Building the bundle now; a helper is checking the Play review queue.',
    ago(m: 3, s: 5),
  ),
  _tool(
    't8',
    'Agent',
    {
      'description': 'Check Play Console review status',
      'subagent_type': 'explorer',
    },
    running: true,
    at: ago(m: 2, s: 30),
  ),
  _tool(
    't9',
    'exec_command',
    {'command': 'flutter build appbundle --release'},
    running: true,
    at: ago(m: 2, s: 2),
  ),
];

/// A pending two-option question, as Codex raises them.
ChatMessage questionCard() => ChatMessage.question(
  questionId: 'q1',
  questions: [
    QuestionItem(
      question:
          'Play flagged the bundle: targetSdk 35 is required. Bump it and rebuild, or upload anyway as a draft?',
      header: 'Play upload',
      options: [
        QuestionOption(
          label: 'Bump and rebuild',
          description: 'Sets targetSdk 35, reruns tests, adds about 6 minutes',
        ),
        QuestionOption(
          label: 'Upload as draft',
          description: 'Saves it in Play; nothing reaches testers',
        ),
      ],
      multiSelect: false,
    ),
  ],
)..timestamp = ago(m: 1, s: 20);

ChatMessage secretCard() => ChatMessage.secureInput(
  requestId: 'sec1',
  label: 'Play upload key password',
  reason: 'Signing the release bundle',
  envHint: 'UPLOAD_KEY_PASSWORD',
  scope: 'project',
)..timestamp = ago(m: 2);

ChatMessage accessCard({
  Duration expiresIn = const Duration(minutes: 9, seconds: 14),
}) => ChatMessage.computerAccess(
  ComputerAccessRequest.fromJson({
    'requestId': 'acc1',
    'sessionId': 'rel',
    'kind': 'approval',
    'source': {'name': 'mac-mini'},
    'target': {'name': 'win-desk', 'publicKey': 'k'},
    'action': 'run_command',
    'summary': r'powershell -c "Get-Service SocketAgent | Restart-Service"',
    'expiresAt': fakeNow.add(expiresIn).millisecondsSinceEpoch,
    'reason': 'Restart the server after installing 1.0.299',
  })!,
)..timestamp = ago(m: 1);

/// Loads Roboto, Material icons and a mono face so tests lay out text like a
/// device does instead of with the wide default test font.
Future<void> loadFonts() async {
  final home = Platform.environment['HOME'];
  final material = '$home/flutter/bin/cache/artifacts/material_fonts';
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      final bytes = File(f).readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  await family('Roboto', [
    for (final w in ['Regular', 'Medium', 'Bold', 'Light', 'Italic'])
      '$material/Roboto-$w.ttf',
  ]);
  await family('MaterialIcons', ['$material/MaterialIcons-Regular.otf']);
  await family(monoFamily, [
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf',
  ]);
}
