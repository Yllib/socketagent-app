import 'dart:async';

import 'package:flutter/material.dart';

import 'package:app/models/composer_attachment.dart';
import 'package:app/models/computer_access.dart';
import 'package:app/models/device_registry.dart';
import 'package:app/models/message.dart';
import 'package:app/models/work_review.dart';
import 'package:app/ui_c/state/ui_c_models.dart';
import 'package:app/ui_c/state/ui_c_store.dart';

/// A believable evening on three computers, relative to [now]. Every action
/// records its name so interaction tests can assert what was called.
class FakeUiCStore extends UiCStore {
  FakeUiCStore({DateTime? now, this.openSessionId = 's_tower_1'})
    : now = now ?? DateTime.now();

  final DateTime now;
  String? openSessionId;
  bool isDraft = false;
  final List<String> calls = [];
  bool _condensed = true;
  String _mode = 'bypassPermissions';
  String _model = 'claude-fable-5-1';
  String _effort = 'high';
  final Set<String> _looked = {};
  final List<ActivityItem> _dismissed = [];

  static const tower = 'srv_tower';
  static const laptop = 'srv_laptop';
  static const pi = 'srv_pi';

  DateTime ago({int h = 0, int m = 0, int s = 0}) =>
      now.subtract(Duration(hours: h, minutes: m, seconds: s));

  @override
  List<FleetComputer> get computers => [
    FleetComputer(
      id: tower,
      name: 'Tower',
      color: const Color(0xFFFFB000),
      link: LinkState.connected,
      running: 2,
      waiting: 2,
      expectedOnline: true,
      harnesses: const ['claude', 'codex'],
      version: '1.42.0',
    ),
    FleetComputer(
      id: laptop,
      name: 'Laptop',
      color: const Color(0xFF4FD1FF),
      link: LinkState.connected,
      running: 1,
      waiting: 1,
      harnesses: const ['claude'],
      version: '1.42.0',
      issues: 1,
    ),
    FleetComputer(
      id: pi,
      name: 'Pi',
      color: const Color(0xFF8BE78B),
      link: LinkState.offline,
      running: 0,
      waiting: 0,
      expectedOnline: true,
      harnesses: const ['claude'],
      version: '1.40.2',
    ),
  ];

  Session _session(
    String id,
    String title, {
    required String serverId,
    required String cwd,
    required DateTime lastActive,
    String backend = 'claude',
    bool running = false,
    DateTime? startedAt,
    String preview = '',
    int turns = 12,
    String? delegatedBy,
    String? lifetime,
    String? outcome,
  }) {
    final serverName = switch (serverId) {
      tower => 'Tower',
      laptop => 'Laptop',
      _ => 'Pi',
    };
    return Session(
      id: id,
      title: title,
      cwd: cwd,
      createdAt: lastActive.subtract(const Duration(hours: 5)),
      lastActive: lastActive,
      messagePreview: preview,
      turnCount: turns,
      running: running,
      activeStartedAt: startedAt?.toIso8601String(),
      serverId: serverId,
      serverName: serverName,
      backend: backend,
      delegatedBySessionId: delegatedBy,
      lifetime: lifetime,
      runStats: outcome == null
          ? null
          : SessionRunStats(
              completedCount: 4,
              recentRuns: [
                SessionRunRecord(
                  runId: 'r_$id',
                  runNumber: 4,
                  startedAt: lastActive.subtract(const Duration(minutes: 9)),
                  finishedAt: lastActive,
                  durationMs: 9 * 60 * 1000,
                  outcome: outcome,
                ),
              ],
            ),
    );
  }

  late final List<Session> _sessions = [
    _session(
      's_tower_1',
      'Switchboard interface C',
      serverId: tower,
      cwd: '/home/billy/agents/socketagent-app',
      lastActive: ago(s: 20),
      running: true,
      startedAt: ago(m: 14, s: 12),
      preview: 'Running widget tests for the board screen',
      turns: 38,
    ),
    _session(
      's_tower_2',
      'Rate limit headers for codex',
      serverId: tower,
      cwd: '/home/billy/agents/socketagent',
      lastActive: ago(m: 3),
      backend: 'codex',
      running: true,
      startedAt: ago(m: 41),
      preview: 'Waiting on your answer about the retry policy',
      turns: 21,
    ),
    _session(
      's_tower_3',
      'Review: fleet board tests',
      serverId: tower,
      cwd: '/home/billy/agents/socketagent-app',
      lastActive: ago(m: 11),
      delegatedBy: 's_tower_1',
      lifetime: 'fleeting',
      preview: 'Found two flaky goldens',
      turns: 6,
      outcome: 'completed',
    ),
    _session(
      's_laptop_1',
      'Invoice export job',
      serverId: laptop,
      cwd: '/Users/billy/work/billing',
      lastActive: ago(m: 1),
      running: true,
      startedAt: ago(m: 6),
      preview: 'Needs the Stripe key to continue',
      turns: 9,
    ),
    _session(
      's_laptop_2',
      'Nightly digest',
      serverId: laptop,
      cwd: '/Users/billy/work/digest',
      lastActive: ago(h: 1, m: 20),
      preview: 'Digest sent to 3 recipients',
      turns: 4,
      outcome: 'completed',
    ),
    _session(
      's_tower_4',
      'Protocol doc cleanup',
      serverId: tower,
      cwd: '/home/billy/agents/socketagent/docs',
      lastActive: ago(h: 2, m: 5),
      preview: 'Stopped after the second rewrite',
      turns: 15,
      outcome: 'stopped',
    ),
    _session(
      's_pi_1',
      'Home sensors',
      serverId: pi,
      cwd: '/home/pi/sensors',
      lastActive: ago(h: 9),
      preview: 'Logged 48 readings',
      turns: 3,
    ),
    _session(
      's_tower_5',
      'Font loader for goldens',
      serverId: tower,
      cwd: '/home/billy/agents/socketagent-app',
      lastActive: ago(h: 26),
      preview: 'FontLoader works with local files',
      turns: 7,
      outcome: 'failed',
    ),
  ];

  @override
  List<Session> get sessions => _sessions;

  @override
  SessionLive live(Session session) {
    final waiting = {'s_tower_2', 's_laptop_1'}.contains(session.id);
    final finished = finishedSinceLooked.any((s) => s.id == session.id);
    return SessionLive(
      phase: session.serverId == pi
          ? SessionPhase.offline
          : waiting
          ? SessionPhase.waitingOnUser
          : session.running
          ? SessionPhase.running
          : finished
          ? SessionPhase.unreadFinished
          : SessionPhase.idle,
      startedAt: session.activeStartedAt == null
          ? null
          : DateTime.parse(session.activeStartedAt!),
      pinned: session.id == 's_tower_1',
      muted: session.id == 's_laptop_2',
      children: session.id == 's_tower_1' ? 1 : 0,
      lastFinishedOutcome: session.runStats?.recentRuns.firstOrNull?.outcome,
    );
  }

  @override
  bool get sessionsLoading => false;

  // Messages the open session shows and the inbox draws from.

  ChatMessage _user(String id, String text, DateTime at) => ChatMessage(
    id: id,
    sender: MessageSender.user,
    type: MessageType.text,
    timestamp: at,
    textContent: text,
    delivery: MessageDelivery.received,
  );

  ChatMessage _agent(String id, String text, DateTime at) => ChatMessage(
    id: id,
    sender: MessageSender.assistant,
    type: MessageType.text,
    timestamp: at,
    textContent: text,
  );

  ChatMessage _tool(
    String id,
    String name,
    Map<String, dynamic> input,
    DateTime at, {
    String? output,
    bool streaming = false,
    double elapsed = 0,
    bool background = false,
  }) => ChatMessage(
    id: id,
    sender: MessageSender.assistant,
    type: MessageType.toolCall,
    timestamp: at,
    toolName: name,
    toolInput: input,
    toolUseId: 'tu_$id',
    toolOutput: output,
    toolStreaming: streaming,
    toolElapsedSeconds: elapsed,
    isBackgrounded: background,
    entryId: 'e_$id',
  );

  late final ChatMessage questionMessage = ChatMessage(
    id: 'm_q1',
    sender: MessageSender.assistant,
    type: MessageType.question,
    timestamp: ago(m: 2, s: 40),
    questionId: 'q_retry',
    questions: [
      QuestionItem(
        question: 'Retry 429s with backoff, or surface them to the user?',
        header: 'Rate limits',
        options: [
          QuestionOption(
            label: 'Backoff',
            description: 'Three tries, 2s 8s 30s',
          ),
          QuestionOption(
            label: 'Surface',
            description: 'Fail fast, show the reset time',
          ),
          QuestionOption(label: 'Both', description: 'One retry, then surface'),
        ],
      ),
    ],
    entryId: 'e_q1',
  );

  late final ChatMessage secretMessage = ChatMessage(
    id: 'm_sec1',
    sender: MessageSender.assistant,
    type: MessageType.secureInput,
    timestamp: ago(m: 1, s: 5),
    questionId: 'sec_stripe',
    textContent:
        'The export needs a restricted Stripe key with read access to invoices.',
    toolInput: const {
      'label': 'Stripe restricted key',
      'reason': 'Read invoices for the export',
      'envHint': 'STRIPE_KEY',
      'scope': 'permanent',
      'status': 'pending',
    },
    entryId: 'e_sec1',
  );

  late final ChatMessage accessMessage = ChatMessage(
    id: 'm_acc1',
    sender: MessageSender.assistant,
    type: MessageType.computerAccess,
    timestamp: ago(s: 48),
    toolInput: ComputerAccessRequest(
      requestId: 'acc_1',
      sessionId: 's_tower_1',
      kind: 'approval',
      sourceName: 'Tower',
      sourcePublicKey: 'pk_tower',
      targetName: 'Laptop',
      targetPublicKey: 'pk_laptop',
      action: 'run_command',
      summary: 'flutter test test/ui_c',
      digest: 'd1',
      challengeId: 'c1',
      expiresAt: now.add(const Duration(minutes: 4)).millisecondsSinceEpoch,
    ).toJson(),
    entryId: 'e_acc1',
  );

  late final List<ChatMessage> _messages = [
    ChatMessage(
      id: 'm_rb0',
      sender: MessageSender.system,
      type: MessageType.runBoundary,
      timestamp: ago(h: 1, m: 2),
      textContent: 'completed',
      toolInput: const {'runNumber': 3, 'durationMs': 1260000},
    ),
    _user(
      'm_u1',
      'Build the board screen render test. Phone first, then the desktop workspace. Use the fake store.',
      ago(m: 14, s: 12),
    ),
    ChatMessage(
        id: 'm_th1',
        sender: MessageSender.assistant,
        type: MessageType.thinking,
        timestamp: ago(m: 14, s: 8),
        textContent:
            'The fonts need to load before the first pump or the goldens show boxes.',
      )
      ..thinkingTokens = 812
      ..thinkingDurationMs = 6400,
    _tool(
      'm_t1',
      'Read',
      const {'file_path': 'test/ui_b/support/fake_session.dart'},
      ago(m: 14),
      output: '// 212 lines',
      elapsed: 0.4,
    ),
    _tool(
      'm_t2',
      'Glob',
      const {'pattern': 'test/ui_c/**'},
      ago(m: 13, s: 50),
      output: 'No files found',
      elapsed: 0.2,
    ),
    _tool(
      'm_t3',
      'Write',
      const {'file_path': 'test/ui_c/support/fonts.dart', 'content': '...'},
      ago(m: 13, s: 30),
      output: 'File created',
      elapsed: 0.1,
    ),
    _tool(
      'm_t4',
      'Edit',
      const {
        'file_path': 'lib/ui_c/theme/ui_c_theme.dart',
        'old_string': 'static bool useRemote = true;',
        'new_string':
            'static bool useRemote = true;\n  static const condensedFamily = \'RobotoCondensed\';',
      },
      ago(m: 13),
      output: 'ok',
      elapsed: 0.1,
    ),
    _agent(
      'm_a1',
      'Fonts load from `~/flutter/bin/cache/artifacts/material_fonts`. The condensed family falls back to Roboto when the file is missing, so the test still renders.\n\nNext I will render the board at 412x915 and check the inbox rows.',
      ago(m: 12, s: 30),
    ),
    _tool(
      'm_t5',
      'Bash',
      const {
        'command': '~/flutter/bin/flutter test test/ui_c/render_test.dart',
        'description': 'Run render tests',
      },
      ago(m: 12),
      output: '00:14 +3: All tests passed!',
      elapsed: 14.2,
    ),
    _tool(
      'm_t6',
      'Bash',
      const {'command': 'grep -rn "SectionHead" lib/ui_c | wc -l'},
      ago(m: 11, s: 30),
      output: '17',
      elapsed: 0.1,
    ),
    _tool(
      'm_t7',
      'Agent',
      const {
        'description': 'Review fleet board tests for flakiness',
        'subagent_type': 'claude',
      },
      ago(m: 11),
      output: 'Two goldens depend on the clock. Pin now() in the fake.',
      elapsed: 184,
    ),
    _tool(
      'm_t8',
      'Bash',
      const {
        'command':
            'dart format lib/ui_c test/ui_c && flutter analyze lib/ui_c test/ui_c',
      },
      ago(m: 7),
      output:
          'error • Undefined name \'ago\' • test/ui_c/support/fake_store.dart:41:7',
      elapsed: 3.1,
    ),
    _agent(
      'm_a2',
      'The reviewer found two goldens that depend on the wall clock. I pinned `now` in the fake store so the elapsed labels are stable.\n\n| Screen | Size | Status |\n|---|---|---|\n| Board | 412x915 | passes |\n| Session | 412x915 | passes |\n| Desktop | 1440x900 | rendering |',
      ago(m: 5),
    ),
    accessMessage,
    _tool(
      'm_t9',
      'Bash',
      const {
        'command': '~/flutter/bin/flutter test test/ui_c --update-goldens',
        'description': 'Regenerate goldens',
      },
      ago(s: 31),
      streaming: true,
    ),
  ];

  @override
  List<ChatMessage> get messages {
    return switch (openSessionId) {
      's_tower_2' => [
        _user('m_u9', 'Handle 429s from the Codex API', ago(m: 41)),
        questionMessage,
      ],
      's_laptop_1' => [
        _user('m_u8', 'Export last month\'s invoices to CSV', ago(m: 6)),
        secretMessage,
      ],
      _ => _messages,
    };
  }

  @override
  List<InboxItem> get inbox => [
    InboxItem(
      id: 'q_retry',
      kind: InboxKind.question,
      serverId: tower,
      computerName: 'Tower',
      sessionId: 's_tower_2',
      sessionTitle: 'Rate limit headers for codex',
      title:
          'Rate limits: Retry 429s with backoff, or surface them to the user?',
      since: questionMessage.timestamp,
      message: questionMessage,
      options: const ['Backoff', 'Surface', 'Both'],
    ),
    InboxItem(
      id: 'secret_stripe',
      kind: InboxKind.secret,
      serverId: laptop,
      computerName: 'Laptop',
      sessionId: 's_laptop_1',
      sessionTitle: 'Invoice export job',
      title: 'Secret: Stripe restricted key',
      detail: 'Read invoices for the export',
      since: secretMessage.timestamp,
      message: secretMessage,
    ),
    InboxItem(
      id: 'access_1',
      kind: InboxKind.computerAccess,
      serverId: tower,
      computerName: 'Tower',
      sessionId: 's_tower_1',
      sessionTitle: 'Switchboard interface C',
      title: 'Tower on Laptop: Run a command',
      detail: 'flutter test test/ui_c',
      since: accessMessage.timestamp,
      expiresAt: now.add(const Duration(minutes: 4)),
      message: accessMessage,
      access: ComputerAccessRequest.fromJson(accessMessage.toolInput),
    ),
    InboxItem(
      id: 'device_pixel',
      kind: InboxKind.device,
      serverId: tower,
      computerName: 'Tower',
      sessionId: '',
      sessionTitle: '',
      title: 'Pixel 9 wants to pair',
      detail: 'Code 48 21  android',
      since: ago(m: 9),
      payload: const PendingDevice(
        serverId: tower,
        publicKey: 'pk_pixel',
        name: 'Pixel 9',
        platform: 'android',
        code: '48 21',
      ),
    ),
  ];

  @override
  List<Session> get finishedSinceLooked => _sessions
      .where(
        (s) =>
            {'s_tower_3', 's_laptop_2', 's_tower_4'}.contains(s.id) &&
            !_looked.contains(s.id),
      )
      .toList();

  @override
  int get unreadAutomationResults => 1;
  @override
  int get openReviews => 1;

  @override
  List<WorkReview> get reviews => [
    WorkReview(
      id: 'wr_1',
      roundId: 'round_1',
      serverId: tower,
      sessionId: 's_tower_4',
      title: 'Protocol doc rewrite',
      summary:
          'Two sections rewritten, one deleted. Check the status_sync wording.',
      instructions: '',
      purpose: '',
      authorization: '',
      status: WorkReviewStatus.open,
      items: const [],
      itemCount: 3,
      result: null,
      createdAt: ago(h: 2, m: 10),
      updatedAt: ago(h: 2, m: 5),
    ),
  ];

  @override
  List<Map<String, dynamic>> get scheduledTasks => [
    {
      'id': 'task_digest',
      'serverId': laptop,
      'name': 'Nightly digest',
      'recurrence': {'type': 'daily'},
      'status': 'scheduled',
      'lastRunAt': ago(h: 1, m: 42).toIso8601String(),
      'lastResultSummary': 'Digest sent to 3 recipients',
      'runCount': 31,
      'sessionId': 's_laptop_2',
    },
    {
      'id': 'task_sensors',
      'serverId': pi,
      'name': 'Sensor rollup',
      'recurrence': {'type': 'custom', 'intervalMs': 3600000},
      'status': 'scheduled',
      'lastRunAt': ago(h: 9).toIso8601String(),
      'lastResultSummary': 'Logged 48 readings',
      'runCount': 212,
      'sessionId': 's_pi_1',
      'lastReadAt': now.toIso8601String(),
    },
  ];

  @override
  List<SecretMetadata> get secrets => [
    SecretMetadata(
      secretId: 'sec_gh',
      label: 'GitHub token',
      scope: 'permanent',
      filePath: '/home/billy/.socketagent/secrets/gh',
      envHint: 'GH_TOKEN',
      createdAt: ago(h: 200),
    ),
    SecretMetadata(
      secretId: 'sec_stripe_old',
      label: 'Stripe restricted key',
      scope: 'session',
      filePath: '/Users/billy/.socketagent/secrets/stripe',
      envHint: 'STRIPE_KEY',
      createdAt: ago(h: 30),
    ),
  ];

  // Open session

  Session? get _open =>
      _sessions.where((s) => s.id == openSessionId).firstOrNull;

  @override
  String? get activeSessionId => isDraft ? null : openSessionId;
  @override
  String? get activeServerId => isDraft ? tower : _open?.serverId;
  @override
  String get activeTitle => isDraft ? '' : _open?.title ?? '';
  @override
  String? get activeBackend => isDraft ? 'claude' : _open?.backend;
  @override
  String get activeCwd =>
      isDraft ? '/home/billy/agents/socketagent-app' : _open?.cwd ?? '';
  @override
  bool get isDraftSession => isDraft;
  @override
  bool get activeOffline => _open?.serverId == pi;
  @override
  bool get isProcessing => _open?.running ?? false;
  @override
  bool get isCompacting => false;
  @override
  bool get requiresAction =>
      {'s_tower_2', 's_laptop_1'}.contains(openSessionId) ||
      openSessionId == 's_tower_1';
  @override
  bool get waitingOnAgent => false;
  @override
  DateTime? get runStartedAt => live(_open!).startedAt;
  @override
  bool get historyLoading => false;
  @override
  bool get hasOlderHistory => openSessionId == 's_tower_1';
  @override
  int get olderHistoryCount => 142;
  @override
  String? get historyError => null;
  @override
  String? get permissionMode => _mode;
  @override
  String? get model => _model;
  @override
  List<ModelChoice> get models => [
    ModelChoice(
      id: 'claude-fable-5-1',
      label: 'Fable 5.1',
      current: _model == 'claude-fable-5-1',
    ),
    ModelChoice(
      id: 'claude-opus-5-5',
      label: 'Opus 5.5',
      current: _model == 'claude-opus-5-5',
    ),
    ModelChoice(
      id: 'claude-sonnet-5-5',
      label: 'Sonnet 5.5',
      current: _model == 'claude-sonnet-5-5',
    ),
  ];
  @override
  String get effort => _effort;
  @override
  List<String> get effortLevels => const ['low', 'medium', 'high', 'max'];
  @override
  ContextGauge? get context => const ContextGauge(
    used: 143000,
    total: 200000,
    categories: [
      (name: 'tools', tokens: 61000),
      (name: 'messages', tokens: 58000),
      (name: 'system', tokens: 24000),
    ],
  );
  @override
  List<LimitNotice> get limits => [
    LimitNotice(
      label: '5h',
      percent: 82,
      resetsAt: now.add(const Duration(minutes: 48)),
    ),
    LimitNotice(
      label: 'week',
      percent: 41,
      resetsAt: now.add(const Duration(days: 3)),
    ),
  ];
  @override
  List<String> get promptSuggestions => const [
    'Run the tests',
    'Show me the PNGs',
    'Commit this',
  ];

  @override
  List<ActivityItem> get activity => [
    for (final item in [
      ActivityItem(
        key: 'act_review',
        kind: ActivityKind.delegated,
        title: 'Review: fleet board tests',
        status: ActivityStatus.completed,
        detail: 'Found two flaky goldens',
        startedAt: ago(m: 11),
        canDismiss: true,
        childSessionId: 's_tower_3',
      ),
      ActivityItem(
        key: 'act_goldens',
        kind: ActivityKind.command,
        title: 'flutter test test/ui_c --update-goldens',
        status: ActivityStatus.running,
        lastTool: '00:09 +2 -0: session_render_test.dart',
        startedAt: ago(s: 31),
        canStop: true,
        backgrounded: true,
      ),
      ActivityItem(
        key: 'act_sub',
        kind: ActivityKind.subagent,
        title: 'Explore: how ui_b loads fonts',
        status: ActivityStatus.running,
        lastTool: 'Grep FontLoader',
        startedAt: ago(m: 1, s: 20),
        toolUses: 7,
        tokens: 12400,
        canStop: true,
      ),
    ])
      if (!_dismissed.any((d) => d.key == item.key)) item,
  ];

  @override
  List<PlanStep> get plan => const [
    PlanStep(key: 'p1', text: 'Font loader for tests', status: 'completed'),
    PlanStep(
      key: 'p2',
      text: 'Fake store with three computers',
      status: 'completed',
    ),
    PlanStep(
      key: 'p3',
      text: 'Render board and session at phone size',
      status: 'in_progress',
    ),
    PlanStep(
      key: 'p4',
      text: 'Render the desktop workspace',
      status: 'pending',
    ),
    PlanStep(key: 'p5', text: 'Commit and report', status: 'pending'),
  ];
  @override
  String get planExplanation =>
      'Render tests first so the PNGs guide the design.';
  @override
  bool get condensedTools => _condensed;
  @override
  List<PendingFileAttachment> get pendingFiles => const [];
  @override
  List<PendingSecretAttachment> get pendingSecrets => const [];
  @override
  bool get isListening => false;
  @override
  Stream<String> get dictation => const Stream.empty();
  @override
  String? get focusEntryId => null;
  @override
  bool get canBackground => true;

  @override
  List<({String id, String name})> get projects => const [
    (id: 'proj_app', name: 'SocketAgent app'),
    (id: 'proj_billing', name: 'Billing'),
  ];
  @override
  String? projectOf(Session session) => switch (session.serverId) {
    tower => 'proj_app',
    laptop => 'proj_billing',
    _ => null,
  };
  @override
  List<String> recentFolders(String serverId) => const [
    '/home/billy/agents/socketagent-app',
    '/home/billy/agents/socketagent',
    '/home/billy/ui-revamp',
  ];
  @override
  String defaultFolder(String serverId) => '/home/billy';

  // Actions

  void _record(String name) {
    calls.add(name);
    notifyListeners();
  }

  @override
  void openSession(Session session) {
    openSessionId = session.id;
    isDraft = false;
    _record('openSession ${session.id}');
  }

  @override
  void openSessionById(String sessionId, {String? serverId}) {
    openSessionId = sessionId;
    isDraft = false;
    _record('openSessionById $sessionId');
  }

  @override
  void leaveSession() => calls.add('leaveSession');
  @override
  void newSession({
    String? serverId,
    String? cwd,
    String? backend,
    bool fleeting = false,
  }) {
    isDraft = true;
    _record('newSession $serverId $cwd $backend $fleeting');
  }

  @override
  void refreshSessions() => _record('refreshSessions');
  @override
  void loadOlderHistory() => _record('loadOlderHistory');
  @override
  Future<bool> send(String text, {SendPriority? priority}) async {
    _record('send $text ${priority?.wire}');
    return true;
  }

  @override
  Future<void> stop() async => _record('stop');
  @override
  void interrupt() => _record('interrupt');
  @override
  Future<void> answerQuestion(
    String questionId,
    Map<String, String> answers,
  ) async => _record('answerQuestion $questionId ${answers.values.join('|')}');
  @override
  void submitSecret(String requestId, String value) =>
      _record('submitSecret $requestId ${value.length}');
  @override
  void useStoredSecret(String requestId, SecretMetadata secret) =>
      _record('useStoredSecret $requestId ${secret.secretId}');
  @override
  void cancelSecret(String requestId) => _record('cancelSecret $requestId');
  @override
  Future<void> answerAccess(String requestId, String decision) async =>
      _record('answerAccess $requestId $decision');
  @override
  void stopActivity(ActivityItem item) => _record('stopActivity ${item.key}');
  @override
  void dismissActivity(ActivityItem item) {
    _dismissed.add(item);
    _record('dismissActivity ${item.key}');
  }

  @override
  void backgroundTool(String toolUseId) => _record('backgroundTool $toolUseId');
  @override
  String? retractQueued(String messageId) {
    _record('retractQueued $messageId');
    return null;
  }

  @override
  void dismissPlanStep(String key) => _record('dismissPlanStep $key');
  @override
  void setPermissionMode(String mode) {
    _mode = mode;
    _record('setPermissionMode $mode');
  }

  @override
  void setModel(String id) {
    _model = id;
    _record('setModel $id');
  }

  @override
  void setEffort(String level) {
    _effort = level;
    _record('setEffort $level');
  }

  @override
  void setCondensedTools(bool value) {
    _condensed = value;
    _record('setCondensedTools $value');
  }

  @override
  void togglePin(Session session) => _record('togglePin ${session.id}');
  @override
  void toggleMute(Session session) => _record('toggleMute ${session.id}');
  @override
  void renameSession(Session session, String title) =>
      _record('renameSession ${session.id} $title');
  @override
  void archiveSession(Session session) =>
      _record('archiveSession ${session.id}');
  @override
  void deleteSession(Session session) => _record('deleteSession ${session.id}');
  @override
  void makePermanent(Session session) => _record('makePermanent ${session.id}');
  @override
  void compactContext() => _record('compactContext');
  @override
  void clearContext() => _record('clearContext');
  @override
  void requestFullOutput(ChatMessage message) =>
      _record('requestFullOutput ${message.id}');
  @override
  Future<void> pickFiles({bool imagesOnly = false}) async =>
      _record('pickFiles $imagesOnly');
  @override
  void removeFile(String id) => _record('removeFile $id');
  @override
  void removeSecretAttachment(String id) =>
      _record('removeSecretAttachment $id');
  @override
  void attachSecret(SecretMetadata secret) =>
      _record('attachSecret ${secret.secretId}');
  @override
  Future<void> toggleListening() async => _record('toggleListening');
  @override
  void saveDraft(String text) => calls.add('saveDraft');
  @override
  String draft() => '';
  @override
  void markTaskRead(Map<String, dynamic> task) =>
      _record('markTaskRead ${task['id']}');
  @override
  void clearFocusEntry() {}
  @override
  void markLooked(Session session) {
    _looked.add(session.id);
    _record('markLooked ${session.id}');
  }

  @override
  Future<void> approveDevice(PendingDevice device) async =>
      _record('approveDevice ${device.name}');
  @override
  Future<void> denyDevice(PendingDevice device) async =>
      _record('denyDevice ${device.name}');
}
