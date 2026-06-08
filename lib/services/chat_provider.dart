import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/message.dart';
import '../models/archive_entry.dart';
import '../screens/pair_screen.dart' show PairingResult;
import '../models/server_config.dart';
import '../models/raw_event.dart';
import 'websocket_service.dart';
import 'connection_manager.dart';
import 'sherpa_speech_service.dart';
import 'asr_model_manager.dart';
import 'tts_service.dart';
import 'tts_engine.dart';
import 'system_tts_engine.dart';
import 'kokoro_server_engine.dart';
import 'kokoro_device_engine.dart';
import 'kokoro_model_manager.dart';
import 'notification_service.dart';
import 'push_notification_service.dart';
import 'crypto_service.dart';
import 'secure_storage_service.dart';

class ChatProvider extends ChangeNotifier with WidgetsBindingObserver {
  static const String _legacyCancelPrepend =
      '[The user cancelled your previous action. Follow their instructions below.]';

  final ConnectionManager _connMgr = ConnectionManager();

  /// Backwards-compat getter — routes to active server's WebSocketService.
  /// Most existing _ws.send() calls work unchanged through this.
  WebSocketService get _ws => _connMgr.active ?? _fallbackWs;

  /// Dummy WebSocketService for when no server is active (avoids null crashes).
  final WebSocketService _fallbackWs = WebSocketService();
  final AsrModelManager _asrModelManager = AsrModelManager();
  late final SherpaSpeechService _speech = SherpaSpeechService(
    _asrModelManager,
  );
  final TtsService _tts = TtsService();
  final SystemTtsEngine _systemEngine = SystemTtsEngine();
  final KokoroServerEngine _kokoroServerEngine = KokoroServerEngine();
  final KokoroModelManager _kokoroModelManager = KokoroModelManager();
  late KokoroDeviceEngine _kokoroDeviceEngine;
  TtsEngineMode _ttsEngineMode = TtsEngineMode.system;
  late TtsEngine _activeTtsEngine;
  final NotificationService _notifications = NotificationService();
  final CryptoService _crypto = CryptoService();
  final SecureStorageService _secureStorage = SecureStorageService();
  final _subscriptionRequiredController = StreamController<void>.broadcast();

  List<ChatMessage> _messages = [];
  List<Session> _sessions = [];
  List<Map<String, dynamic>> _todos = [];
  List<Map<String, dynamic>> _scheduledTasks = [];
  final Map<String, List<Map<String, dynamic>>> _perServerScheduledTasks = {};
  List<ArchiveEntry> _archives = [];
  final Map<String, List<ArchiveEntry>> _perServerArchives = {};
  Completer<List<ArchiveEntry>>? _archivesCompleter;
  final Map<String, Completer<List<dynamic>>> _archiveHistoryCompleters = {};
  final StreamController<String> _archiveFeedback =
      StreamController.broadcast();
  Map<String, dynamic>? _lastUsage;
  // All file maps keyed on fileId (hash of path+mtime+size from server)
  final Map<String, String> _receivedFiles = {}; // fileId → local path
  final Map<String, String> _serverFiles = {}; // fileId → server path
  final Map<String, String> _serverFileNames = {}; // fileId → display name
  final Set<String> _downloadingFiles = {}; // fileId set
  final Map<String, double> _downloadProgress = {}; // fileId → progress
  final Map<String, double> _lastNotifiedProgress = {}; // throttle UI updates
  final Map<String, IOSink> _activeDownloads = {}; // fileId → write sink
  final Map<String, String> _downloadTempPaths = {}; // fileId → temp path
  final Map<String, BytesBuilder> _fileBytesBuffers = {};
  final Map<String, Completer<String?>> _fileBytesCompleters = {};
  final Map<String, String> _filePathToId = {}; // serverPath → latest fileId
  String? _activeSessionId;
  String? _activeSessionCwd;
  String? _activeSessionTitle;
  final Map<String, List<Map<String, dynamic>>> _skillsByServer = {};
  // Per-session notification toggles
  Set<String> _notifMutedSessions = {};
  // Pinned sessions
  Set<String> _pinnedSessionIds = {};
  // Persistent recent CWDs per server (serverId → ordered list, most recent first)
  final Map<String, List<String>> _recentCwds = {};
  // Backends each server can drive (serverId → ['claude','codex'] or just
  // ['claude']). Populated from the server_capabilities message; UI consults
  // this to gate the codex option in the new-session sheet.
  final Map<String, List<String>> _serverBackends = {};
  final Map<String, String> _serverCodexDrivers = {};
  final Map<String, List<String>> _serverCodexDriversAvailable = {};
  final Map<String, List<Map<String, dynamic>>> _serverCodexCollaborationModes =
      {};
  final Map<String, String> _serverCodexCollaborationMode = {};
  // Backend driving the currently active session ('claude' | 'codex' | null).
  // Surfaced by the chat header so the user knows what they're talking to.
  String? _activeSessionBackend;
  String? _viewingSessionId; // set by HomeScreen when user is on that screen
  bool _appInForeground = true;
  // Per-session input drafts (sessionId → unsent text)
  final Map<String, String> _sessionDrafts = {};
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  bool _isListening = false;
  bool _listeningStartInFlight = false;
  bool _stopListeningAfterStart = false;
  bool _pushToTalk = false;
  bool _isProcessing = false;
  DateTime? _processingSetAt; // when client optimistically set _isProcessing
  bool _isCompacting = false;
  bool _requiresAction = false; // SDK says session needs user input
  String?
  _permissionMode; // 'plan', 'bypassPermissions', 'superYolo', 'default', etc.
  bool _isRateLimited = false;
  double? _rateLimitUtilization;
  bool _isRetrying = false;
  String? _activeHookName;
  List<String> _promptSuggestions = [];
  List<dynamic>? _supportedCommands;
  List<dynamic>? _supportedAgents;
  bool _taskPaneCollapsed = false;
  List<String> _pendingPrepends = [];
  final List<Map<String, String>> _pendingImageLoads =
      []; // {toolUseId, filePath}
  bool _isLoadingHistory = false;
  bool _isLoadingMore = false;
  int _historyOffset = 0; // index of oldest loaded entry (0 = all loaded)
  bool _ttsEnabled = false;
  String _effort = 'high';
  Map<String, dynamic> _thinking = {'type': 'adaptive'};
  List<String> _availableTools = [];
  // Per-session disallowed tools and system prompt caches
  final Map<String, List<String>> _sessionDisallowedTools = {};
  final Map<String, String> _sessionSystemPrompts = {};
  // Background tasks: taskId → {status, summary, outputFile}
  final Map<String, Map<String, dynamic>> _backgroundTasks = {};
  // Subagent tasks: toolUseId → {description, status}
  final Map<String, Map<String, dynamic>> _subagentTasks = {};
  ChatMessage? _currentStreamingMessage;
  ChatMessage? _currentThinkingMessage;
  String? _lastServerStartedAt; // detect server restarts
  Map<String, dynamic>? _contextUsage; // detailed context breakdown from SDK
  // SDK session info
  String? _sessionModel;
  List<Map<String, dynamic>> _supportedModels = [];
  List<Map<String, dynamic>> _mcpServers = [];
  bool _rawMode = false;
  final List<SdkItem> _rawItems = [];
  MessageGroup? _currentMessageGroup;
  ContentBlock? _currentContentBlock;
  Timer? _rawThrottle;

  // File upload state
  String? _pendingAttachmentPath;
  String? _pendingAttachmentName;
  double? _uploadProgress;
  String? _pendingUploadId;
  Completer<String>? _uploadCompleter;
  // Per-upload state used to drive UI progress, gate the chunk send-loop on
  // server acks (backpressure), and detect stalled uploads.
  final Map<String, _UploadState> _uploadStates = {};

  // Settings
  String _serverHost = '';
  int _serverPort = 8085;
  String _authToken = '';
  String _defaultCwd = '';
  bool _autoVoiceOnAssist = true;
  bool _colorfulCards = false;

  // Multi-server
  List<ServerConfig> _serverConfigs = [];
  // Per-server session lists, merged into _sessions
  final Map<String, List<Session>> _perServerSessions = {};
  // Per-server installed plugin names (from status_sync)
  final Map<String, List<String>> _serverPlugins = {};

  // Subscription
  String _subscriberEmail = '';
  String _subscriberToken = ''; // HMAC-signed token from relay
  bool _subscriptionActive = false;
  bool _subscriptionChecked = false;
  String _subscriptionStatus = ''; // "active", "trialing", "owner"
  DateTime? _trialEnd;
  DateTime? _periodEnd;
  bool _cancelAtPeriodEnd = false;

  final Completer<void> _settingsLoaded = Completer<void>();
  Completer<bool>? _pendingCwdCheck;
  Completer<Map<String, dynamic>>? _pendingDirList;
  Completer<List<Map<String, dynamic>>>? _pendingSdkSessions;
  String? _pendingSdkSessionsServerId;
  int _sdkSessionsRequestSeq = 0;
  Completer<Map<String, dynamic>>? _pendingVersionCheck;
  Completer<Map<String, dynamic>>? _pendingForceUpdate;

  StreamSubscription? _messageSub;
  StreamSubscription? _statusSub;
  StreamSubscription? _speechResultSub;
  StreamSubscription? _speechStatusSub;

  List<ChatMessage> get messages => _messages;
  List<Session> get sessions => _sessions;
  List<Map<String, dynamic>> get todos => _todos;
  List<Map<String, dynamic>> get scheduledTasks => _scheduledTasks;
  List<ArchiveEntry> get archives => _archives;
  Stream<String> get archiveFeedback => _archiveFeedback.stream;
  Map<String, dynamic>? get lastUsage => _lastUsage;
  String? get activeSessionId => _activeSessionId;
  String? get activeSessionCwd => _activeSessionCwd;
  String? get activeSessionTitle => _activeSessionTitle;

  // Session notifications
  bool isNotifEnabled(String sessionId) =>
      !_notifMutedSessions.contains(sessionId);

  void toggleSessionNotifications(String sessionId) {
    if (_notifMutedSessions.contains(sessionId)) {
      _notifMutedSessions.remove(sessionId);
    } else {
      _notifMutedSessions.add(sessionId);
    }
    SharedPreferences.getInstance().then((prefs) {
      prefs.setStringList('notif_muted_sessions', _notifMutedSessions.toList());
    });
    notifyListeners();
  }

  // Session pinning
  bool isSessionPinned(String sessionId) =>
      _pinnedSessionIds.contains(sessionId);

  List<Session> get pinnedSessions =>
      _sessions.where((s) => _pinnedSessionIds.contains(s.id)).toList();

  List<Session> get unpinnedSessions =>
      _sessions.where((s) => !_pinnedSessionIds.contains(s.id)).toList();

  void toggleSessionPin(String sessionId) {
    if (_pinnedSessionIds.contains(sessionId)) {
      _pinnedSessionIds.remove(sessionId);
    } else {
      _pinnedSessionIds.add(sessionId);
    }
    SharedPreferences.getInstance().then((prefs) {
      prefs.setStringList('pinned_sessions', _pinnedSessionIds.toList());
    });
    notifyListeners();
  }

  void setViewingSession(String? sessionId) {
    _viewingSessionId = sessionId;
  }

  /// Get recent CWDs (server-side, keyed by serverId).
  List<String> getRecentCwds({String? serverId}) {
    final key = serverId ?? '';
    return _recentCwds[key] ?? [];
  }

  /// Request recent CWDs from a server.
  void requestRecentCwds({String? serverId}) {
    if (serverId != null) {
      _connMgr.sendToServer(serverId, {'type': 'get_recent_cwds'});
    } else {
      _connMgr.sendToAll({'type': 'get_recent_cwds'});
    }
  }

  /// Record a CWD as recently used (sends to server for persistence).
  void addRecentCwd(String path, {String? serverId}) {
    final sid = serverId ?? _connMgr.activeServerId;
    if (sid != null) {
      _connMgr.sendToServer(sid, {'type': 'add_recent_cwd', 'cwd': path});
    }
    // Optimistic local update
    final key = sid ?? '';
    final list = _recentCwds[key] ?? [];
    list.remove(path);
    list.insert(0, path);
    if (list.length > 20) list.removeLast();
    _recentCwds[key] = list;
    notifyListeners();
  }

  /// Remove a CWD from the recent list (sends to server for persistence).
  void removeRecentCwd(String path, {String? serverId}) {
    final sid = serverId ?? _connMgr.activeServerId;
    if (sid != null) {
      _connMgr.sendToServer(sid, {'type': 'remove_recent_cwd', 'cwd': path});
    }
    // Optimistic local update
    final key = sid ?? '';
    _recentCwds[key]?.remove(path);
    notifyListeners();
  }

  void _maybeNotify({required String title, required String body}) {
    final sessionId = _activeSessionId;
    if (sessionId == null) return;
    if (_notifMutedSessions.contains(sessionId)) return;
    if (_viewingSessionId == sessionId && _appInForeground) return;

    final notifId = sessionId.hashCode & 0x7FFFFFFF;
    _notifications.showInstant(
      id: notifId,
      title: title,
      body: body,
      payload: 'session_$sessionId',
    );
  }

  String _sessionTitle() {
    for (final s in _sessions) {
      if (s.id == _activeSessionId) {
        return s.title.isNotEmpty ? s.title : s.cwd;
      }
    }
    return 'Session';
  }

  /// Save a draft for the current session (persists to disk).
  void saveDraft(String text, [String? sessionId]) {
    final id = sessionId ?? _activeSessionId;
    if (id != null) {
      if (text.isEmpty) {
        _sessionDrafts.remove(id);
      } else {
        _sessionDrafts[id] = text;
      }
      _persistDrafts();
    }
  }

  /// Get the saved draft for a session (or current session).
  String getDraft([String? sessionId]) {
    return _sessionDrafts[sessionId ?? _activeSessionId ?? ''] ?? '';
  }

  void _persistDrafts() {
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('session_drafts', jsonEncode(_sessionDrafts));
    });
  }

  Future<void> _loadDrafts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('session_drafts');
    if (raw != null) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in map.entries) {
          _sessionDrafts[e.key] = e.value as String;
        }
      } catch (_) {}
    }
  }

  ConnectionStatus get connectionStatus => _connectionStatus;
  bool get isListening => _isListening;
  bool get pushToTalk => _pushToTalk;
  set pushToTalk(bool v) {
    _pushToTalk = v;
    SharedPreferences.getInstance().then((p) => p.setBool('push_to_talk', v));
    notifyListeners();
  }

  bool get isProcessing => _isProcessing;
  bool get isCompacting => _isCompacting;
  bool get requiresAction => _requiresAction;
  String? get permissionMode => _permissionMode;
  bool get isPlanMode => _permissionMode == 'plan';
  bool get isRateLimited => _isRateLimited;
  double? get rateLimitUtilization => _rateLimitUtilization;
  bool get isRetrying => _isRetrying;
  String? get activeHookName => _activeHookName;
  List<String> serverPlugins(String serverId) => _serverPlugins[serverId] ?? [];
  Map<String, dynamic>? get contextUsage => _contextUsage;
  List<String> get promptSuggestions => _promptSuggestions;
  List<dynamic>? get supportedCommands => _supportedCommands;
  List<dynamic>? get supportedAgents => _supportedAgents;
  String get codexCollaborationMode {
    final serverId = _connMgr.activeServerId ?? _serverConfigs.firstOrNull?.id;
    if (serverId == null) return 'default';
    return _serverCodexCollaborationMode[serverId] ?? 'default';
  }

  List<Map<String, dynamic>> get codexCollaborationModes {
    final serverId = _connMgr.activeServerId ?? _serverConfigs.firstOrNull?.id;
    if (serverId == null) {
      return const [
        {'id': 'default', 'name': 'Default'},
      ];
    }
    return _serverCodexCollaborationModes[serverId] ??
        const [
          {'id': 'default', 'name': 'Default'},
        ];
  }

  String _cleanSlashName(String value) {
    final trimmed = value.trim();
    if (trimmed.length >= 2) {
      final first = trimmed[0];
      final last = trimmed[trimmed.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        return trimmed.substring(1, trimmed.length - 1);
      }
    }
    return trimmed;
  }

  List<Map<String, dynamic>> get slashCommands {
    if (_activeSessionBackend == 'codex') {
      final serverId = _connMgr.activeServerId;
      if (serverId == null) return const [];
      final skills = _skillsByServer[serverId] ?? const [];
      final commands = skills
          .where(
            (skill) =>
                skill['agent'] == 'codex' &&
                skill['format'] == 'skill' &&
                (skill['name'] as String? ?? '').isNotEmpty,
          )
          .map((skill) {
            final cleanName = _cleanSlashName(skill['name'] as String? ?? '');
            return {
              ...skill,
              'name': cleanName,
              'kind': 'skill',
              'agent': 'codex',
            };
          })
          .toList();
      commands.sort(
        (a, b) =>
            (a['name'] as String? ?? '').compareTo(b['name'] as String? ?? ''),
      );
      return commands;
    }

    final commands = _supportedCommands ?? const [];
    return commands
        .map((cmd) {
          if (cmd is Map) {
            final mapped = Map<String, dynamic>.from(cmd);
            return {
              ...mapped,
              'name': _cleanSlashName((mapped['name'] ?? '').toString()),
              'kind': 'command',
              'agent': 'claude',
            };
          }
          return {
            'name': _cleanSlashName(cmd.toString()),
            'description': '',
            'kind': 'command',
            'agent': 'claude',
          };
        })
        .where((cmd) => (cmd['name'] as String? ?? '').isNotEmpty)
        .toList();
  }

  bool get taskPaneCollapsed => _taskPaneCollapsed;
  set taskPaneCollapsed(bool v) {
    _taskPaneCollapsed = v;
    notifyListeners();
  }

  void clearPromptSuggestions() {
    _promptSuggestions = [];
    notifyListeners();
  }

  bool get isLoadingHistory => _isLoadingHistory;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMoreHistory => _historyOffset > 0;
  bool get rawMode => _rawMode;
  List<SdkItem> get rawItems => _rawItems;
  bool get ttsEnabled => _ttsEnabled;
  String get effort => _effort;
  Map<String, dynamic> get thinking => _thinking;
  Map<String, Map<String, dynamic>> get backgroundTasks => _backgroundTasks;
  Map<String, Map<String, dynamic>> get subagentTasks => _subagentTasks;

  /// Active tasks for the bottom pane: bg tasks + non-dismissed subagents
  Map<String, Map<String, dynamic>> get activePaneTasks {
    final combined = <String, Map<String, dynamic>>{};
    for (final e in _backgroundTasks.entries) {
      combined[e.key] = {...e.value, '_kind': 'bash'};
    }
    for (final e in _subagentTasks.entries) {
      if (e.value['dismissed'] == true) continue;
      combined[e.key] = {...e.value, '_kind': 'subagent'};
    }
    return combined;
  }

  void dismissSubagent(String toolUseId) {
    if (_subagentTasks.containsKey(toolUseId)) {
      _subagentTasks[toolUseId]!['dismissed'] = true;
      _saveDismissedSubagents();
      notifyListeners();
    }
  }

  void _saveDismissedSubagents() {
    if (_activeSessionId == null) return;
    final ids = _subagentTasks.entries
        .where((e) => e.value['dismissed'] == true)
        .map((e) => e.key)
        .toList();
    SharedPreferences.getInstance().then((prefs) {
      prefs.setStringList('dismissed_subagents_$_activeSessionId', ids);
    });
  }

  void _loadDismissedSubagents() {
    if (_activeSessionId == null) return;
    SharedPreferences.getInstance().then((prefs) {
      final ids =
          prefs.getStringList('dismissed_subagents_$_activeSessionId') ?? [];
      for (final id in ids) {
        if (_subagentTasks.containsKey(id)) {
          _subagentTasks[id]!['dismissed'] = true;
        }
      }
      if (ids.isNotEmpty) notifyListeners();
    });
  }

  /// Messages filtered for main chat: excludes subagent children
  List<ChatMessage> get filteredMessages {
    final visible = _messages.where((m) {
      if (m.parentToolUseId == null) return true;
      // Keep if parent is not a tracked subagent (could be other nesting)
      return !_subagentTasks.containsKey(m.parentToolUseId);
    }).toList();

    // Pending injected prompts are a live queue affordance, not settled
    // transcript position. Keep them visually pinned to the bottom until the
    // server confirms the agent received them; then they fall back into the
    // normal message order used by history.
    final queued = visible
        .where(
          (m) =>
              m.sender == MessageSender.user &&
              m.isPending &&
              m.injectionPriority != null,
        )
        .toList();
    if (queued.isEmpty) return visible;

    return [...visible.where((m) => !queued.contains(m)), ...queued];
  }

  /// Get child messages for a subagent by its toolUseId
  List<ChatMessage> getSubagentChildren(String toolUseId) {
    return _messages.where((m) => m.parentToolUseId == toolUseId).toList();
  }

  bool get hasAttachment => _pendingAttachmentPath != null;
  String? get pendingAttachmentName => _pendingAttachmentName;
  double? get uploadProgress => _uploadProgress;
  List<TtsVoice> get ttsVoices => _tts.availableVoices;
  TtsVoice? get selectedTtsVoice => _tts.selectedVoice;
  TtsEngineMode get ttsEngineMode => _ttsEngineMode;
  TtsEngine get activeTtsEngine => _activeTtsEngine;
  KokoroModelManager get kokoroModelManager => _kokoroModelManager;
  KokoroDeviceEngine get kokoroDeviceEngine => _kokoroDeviceEngine;
  List<TtsEngineVoice> get ttsEngineVoices => _activeTtsEngine.availableVoices;
  TtsEngineVoice? get selectedTtsEngineVoice => _activeTtsEngine.selectedVoice;
  String get serverHost => _serverHost;
  int get serverPort => _serverPort;
  String get authToken => _authToken;
  String get defaultCwd => _defaultCwd;
  bool get autoVoiceOnAssist => _autoVoiceOnAssist;
  bool get colorfulCards => _colorfulCards;
  WebSocketService get ws => _ws;
  ConnectionManager get connMgr => _connMgr;
  List<ServerConfig> get serverConfigs => _serverConfigs;
  String? get activeServerId => _connMgr.activeServerId;

  Future<String?> fetchServerFileBase64(
    String filePath, {
    String? serverId,
  }) async {
    if (filePath.isEmpty) return null;
    final fileId =
        'bytes_${DateTime.now().microsecondsSinceEpoch}_${filePath.hashCode}';
    final completer = Completer<String?>();
    _fileBytesCompleters[fileId] = completer;
    _fileBytesBuffers[fileId] = BytesBuilder(copy: false);

    final request = {
      'type': 'request_file',
      'filePath': filePath,
      'fileId': fileId,
    };
    if (serverId != null && serverId.isNotEmpty) {
      _connMgr.sendToServer(serverId, request);
    } else {
      _connMgr.send(request);
    }

    return completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _fileBytesCompleters.remove(fileId);
        _fileBytesBuffers.remove(fileId);
        return null;
      },
    );
  }

  SherpaSpeechService get speech => _speech;
  AsrModelManager get asrModelManager => _asrModelManager;
  CryptoService get crypto => _crypto;
  ConnectionMode get connectionMode => _ws.mode;
  Future<void> get settingsReady => _settingsLoaded.future;
  String get subscriberEmail => _subscriberEmail;
  String get subscriberToken => _subscriberToken;
  bool get subscriptionActive => _subscriptionActive;
  bool get subscriptionChecked => _subscriptionChecked;
  String get subscriptionStatus => _subscriptionStatus;
  DateTime? get trialEnd => _trialEnd;
  DateTime? get periodEnd => _periodEnd;
  bool get cancelAtPeriodEnd => _cancelAtPeriodEnd;
  Stream<void> get onSubscriptionRequired =>
      _subscriptionRequiredController.stream;
  String? get sessionModel => _sessionModel;
  List<Map<String, dynamic>> get supportedModels => _supportedModels;
  List<String> get availableTools => _availableTools;
  List<Map<String, dynamic>> get mcpServers => _mcpServers;

  ChatProvider() {
    _activeTtsEngine = _systemEngine;
    _kokoroDeviceEngine = KokoroDeviceEngine(_kokoroModelManager);
    _kokoroServerEngine.sendToServer = (msg) => _connMgr.send(msg);
    WidgetsBinding.instance.addObserver(this);
    PushNotificationService.onTokenRefresh = _registerPushNotifications;
    _loadSettings();
    _setupListeners();
  }

  @override
  void notifyListeners() {
    _keepPendingInjectedMessagesAtEnd();
    super.notifyListeners();
  }

  void _keepPendingInjectedMessagesAtEnd() {
    final pending = _messages
        .where(
          (m) =>
              m.sender == MessageSender.user &&
              m.isPending &&
              m.injectionPriority != null,
        )
        .toList();
    if (pending.isEmpty) return;

    final pendingIds = pending.map((m) => m.id).toSet();
    _messages.removeWhere((m) => pendingIds.contains(m.id));
    _messages.addAll(pending);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInForeground = state == AppLifecycleState.resumed;
  }

  /// Migrate sensitive credentials from SharedPreferences to SecureStorage (one-time)
  Future<void> _migrateToSecureStorage() async {
    final migrated = await _secureStorage.isMigrated();
    if (migrated) return;

    final prefs = await SharedPreferences.getInstance();

    // Migrate auth token
    final authToken = prefs.getString('auth_token');
    if (authToken != null && authToken.isNotEmpty) {
      await _secureStorage.setAuthToken(authToken);
    }

    // Migrate subscriber credentials
    final subscriberToken = prefs.getString('subscriber_token');
    if (subscriberToken != null && subscriberToken.isNotEmpty) {
      await _secureStorage.setSubscriberToken(subscriberToken);
    }
    final subscriberEmail = prefs.getString('subscriber_email');
    if (subscriberEmail != null && subscriberEmail.isNotEmpty) {
      await _secureStorage.setSubscriberEmail(subscriberEmail);
    }

    // Migrate server configs (contains auth tokens, pairing tokens, server pubkeys)
    final configsJson = prefs.getString('server_configs');
    if (configsJson != null && configsJson.isNotEmpty) {
      await _secureStorage.setServerConfigs(configsJson);
    }

    // Mark migration complete
    await _secureStorage.markMigrationComplete();

    // Clean up old plaintext credentials from SharedPreferences
    await prefs.remove('auth_token');
    await prefs.remove('subscriber_token');
    await prefs.remove('subscriber_email');
    await prefs.remove('server_configs');
  }

  Future<void> _loadSettings() async {
    // First-time migration from SharedPreferences to SecureStorage
    await _migrateToSecureStorage();

    final prefs = await SharedPreferences.getInstance();
    _serverHost = prefs.getString('server_host') ?? '';
    _serverPort = prefs.getInt('server_port') ?? 8085;
    _defaultCwd = prefs.getString('default_cwd') ?? '';
    _autoVoiceOnAssist = prefs.getBool('auto_voice_on_assist') ?? true;
    _pushToTalk = prefs.getBool('push_to_talk') ?? false;
    _colorfulCards = prefs.getBool('colorful_cards') ?? false;

    // Load sensitive credentials from SecureStorage
    _authToken = await _secureStorage.getAuthToken() ?? '';
    _subscriberEmail = await _secureStorage.getSubscriberEmail() ?? '';
    _subscriberToken = await _secureStorage.getSubscriberToken() ?? '';

    // Load multi-server configs (or migrate from single-server)
    final configsJson = await _secureStorage.getServerConfigs();
    if (configsJson != null) {
      try {
        final list = jsonDecode(configsJson) as List;
        _serverConfigs = list
            .map((j) => ServerConfig.fromJson(j as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _serverConfigs = [];
      }
      // Migrate old relay URLs to wss://
      bool relayMigrated = false;
      _serverConfigs = _serverConfigs.map((c) {
        if (c.relayUrl == 'ws://jarofdirt.info:9988') {
          relayMigrated = true;
          return c.copyWith(relayUrl: 'wss://relay.jarofdirt.info');
        }
        return c;
      }).toList();
      if (relayMigrated) await _saveServerConfigs();
    }
    // Migrate old single-server config if no multi-server configs exist
    if (_serverConfigs.isEmpty && _serverHost.isNotEmpty) {
      // Migrate global relay pairing data into the server config
      final relayUrl = prefs.getString('relay_url') ?? '';
      final pairingToken = prefs.getString('pairing_token') ?? '';
      final serverPubkey = prefs.getString('server_pubkey') ?? '';
      final useRelay = prefs.getBool('use_relay') ?? false;
      final migrated = ServerConfig(
        id: ServerConfig.generateId(),
        name: 'Server',
        host: _serverHost,
        port: _serverPort,
        token: _authToken,
        useRelay: useRelay,
        relayUrl: relayUrl,
        pairingToken: pairingToken,
        serverPubkey: serverPubkey,
      );
      _serverConfigs = [migrated];
      await _saveServerConfigs();
    }

    // Initialize ConnectionManager with server configs (per-server relay)
    _connMgr.setSubscriberToken(_subscriberToken);
    await _connMgr.setServers(_serverConfigs);
    await _registerPushNotifications();
    _lastServerStartedAt = prefs.getString('server_started_at');
    _notifMutedSessions = (prefs.getStringList('notif_muted_sessions') ?? [])
        .toSet();
    _pinnedSessionIds = (prefs.getStringList('pinned_sessions') ?? []).toSet();
    // Recent CWDs are now server-side — loaded via get_recent_cwds on connect
    _ttsEnabled = prefs.getBool('tts_enabled') ?? false;
    _effort = prefs.getString('effort') ?? 'high';
    final savedThinking = prefs.getString('thinking');
    if (savedThinking != null) {
      try {
        _thinking = Map<String, dynamic>.from(jsonDecode(savedThinking) as Map);
      } catch (_) {}
    }
    // Eagerly initialize STT so model is loaded before user presses mic
    _speech.initialize();
    // Always eagerly initialize TTS so it's warm before any speak message arrives
    final savedVoice = prefs.getString('tts_voice');
    await _tts.initialize();
    if (savedVoice != null) {
      await _tts.restoreVoice(savedVoice);
    }
    // Restore TTS engine mode
    final savedEngine = prefs.getString('tts_engine_mode');
    if (savedEngine != null) {
      try {
        _ttsEngineMode = TtsEngineMode.values.firstWhere(
          (e) => e.name == savedEngine,
        );
      } catch (_) {}
    }
    switch (_ttsEngineMode) {
      case TtsEngineMode.system:
        _activeTtsEngine = _systemEngine;
        break;
      case TtsEngineMode.kokoroServer:
        _activeTtsEngine = _kokoroServerEngine;
        break;
      case TtsEngineMode.kokoroDevice:
        _activeTtsEngine = _kokoroDeviceEngine;
        break;
    }
    // Restore Kokoro voice
    final savedKokoroVoice = prefs.getString('kokoro_voice');
    if (savedKokoroVoice != null) {
      _kokoroServerEngine.restoreVoice(savedKokoroVoice);
      _kokoroDeviceEngine.restoreVoice(savedKokoroVoice);
    }
    await _loadDrafts();
    _settingsLoaded.complete();
    notifyListeners();
  }

  Future<void> saveSettings({
    required String host,
    required int port,
    required String token,
    required String cwd,
    required bool autoVoice,
  }) async {
    _serverHost = host;
    _serverPort = port;
    _authToken = token;
    _defaultCwd = cwd;
    _autoVoiceOnAssist = autoVoice;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_host', host);
    await prefs.setInt('server_port', port);
    await _secureStorage.setAuthToken(token); // SecureStorage for auth token
    await prefs.setString('default_cwd', cwd);
    await prefs.setBool('auto_voice_on_assist', autoVoice);
    notifyListeners();
  }

  Future<void> setAutoVoiceOnAssist(bool value) async {
    _autoVoiceOnAssist = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_voice_on_assist', value);
    notifyListeners();
  }

  // ── Multi-server CRUD ──

  Future<void> _saveServerConfigs() async {
    final json = jsonEncode(_serverConfigs.map((c) => c.toJson()).toList());
    await _secureStorage.setServerConfigs(json);
  }

  Future<void> _registerPushNotifications() async {
    await PushNotificationService().registerWithRelays(
      configs: _serverConfigs,
      subscriberToken: _subscriberToken,
    );
  }

  Future<void> addServer(ServerConfig config) async {
    _serverConfigs.add(config);
    await _saveServerConfigs();
    await _connMgr.setServers(_serverConfigs);
    await _registerPushNotifications();
    // Connect the new server
    final ws = _connMgr.getConnection(config.id);
    ws?.connect();
    notifyListeners();
  }

  /// Create a new server from a QR pairing result and connect via relay.
  Future<void> addServerFromPairing(PairingResult result) async {
    final config = ServerConfig(
      id: ServerConfig.generateId(),
      name: 'My Server',
      host: '',
      port: 8085,
      token: '',
      useRelay: true,
      sortOrder: _serverConfigs.length,
      relayUrl: result.relayUrl,
      pairingToken: result.pairingToken,
      serverPubkey: result.serverPubkey,
    );
    await addServer(config);
    await _connMgr.configureServerRelay(
      config.id,
      relayUrl: result.relayUrl,
      pairingToken: result.pairingToken,
      serverPubkey: result.serverPubkey,
    );
  }

  Future<void> updateServer(ServerConfig config) async {
    final idx = _serverConfigs.indexWhere((c) => c.id == config.id);
    if (idx >= 0) {
      _serverConfigs[idx] = config;
    } else {
      _serverConfigs.add(config);
    }
    await _saveServerConfigs();
    // Disconnect and reconfigure
    final ws = _connMgr.getConnection(config.id);
    ws?.disconnect();
    await _connMgr.setServers(_serverConfigs);
    await _registerPushNotifications();
    _connMgr.getConnection(config.id)?.connect();
    notifyListeners();
  }

  Future<void> removeServer(String serverId) async {
    _serverConfigs.removeWhere((c) => c.id == serverId);
    _perServerSessions.remove(serverId);
    await _saveServerConfigs();
    await _connMgr.setServers(_serverConfigs);
    await _registerPushNotifications();
    _rebuildSessionList();
    notifyListeners();
  }

  void _rebuildSessionList() {
    _sessions = _perServerSessions.values.expand((list) => list).toList()
      ..sort((a, b) => b.lastActive.compareTo(a.lastActive));
  }

  /// Export all server configs as compact maps for QR transfer.
  List<Map<String, dynamic>> exportServerConfigs() {
    return _serverConfigs.map((c) => c.toJson()).toList();
  }

  /// Import server configs from compact maps (from QR decode).
  /// Returns the number of servers imported (skips duplicates).
  Future<int> importServerConfigs(List<Map<String, dynamic>> configs) async {
    int imported = 0;
    for (final m in configs) {
      final name = m['name'] as String? ?? 'Imported';
      final host = m['host'] as String? ?? '';
      final pairingToken = m['pairingToken'] as String? ?? '';

      // Skip duplicates: matching name+host or name+pairingToken
      final isDuplicate = _serverConfigs.any(
        (existing) =>
            existing.name == name &&
            ((host.isNotEmpty && existing.host == host) ||
                (pairingToken.isNotEmpty &&
                    existing.pairingToken == pairingToken)),
      );
      if (isDuplicate) continue;

      final config = ServerConfig(
        id: ServerConfig.generateId(),
        name: name,
        host: host,
        port: m['port'] as int? ?? 8085,
        token: m['token'] as String? ?? '',
        useRelay: m['useRelay'] as bool? ?? false,
        sortOrder: _serverConfigs.length,
        relayUrl: m['relayUrl'] as String? ?? '',
        pairingToken: pairingToken,
        serverPubkey: m['serverPubkey'] as String? ?? '',
        defaultCwd: m['defaultCwd'] as String? ?? '',
        colorValue: m['colorValue'] as int?,
      );
      await addServer(config);
      imported++;
    }
    return imported;
  }

  /// Update a server's relay pairing data and reconnect via relay.
  Future<void> pairServerRelay(
    String serverId, {
    required String relayUrl,
    required String pairingToken,
    required String serverPubkey,
  }) async {
    final idx = _serverConfigs.indexWhere((c) => c.id == serverId);
    if (idx < 0) return;
    _serverConfigs[idx] = _serverConfigs[idx].copyWith(
      useRelay: true,
      relayUrl: relayUrl,
      pairingToken: pairingToken,
      serverPubkey: serverPubkey,
    );
    await _saveServerConfigs();
    // Disconnect and reconnect with relay
    final ws = _connMgr.getConnection(serverId);
    ws?.disconnect();
    await _connMgr.configureServerRelay(
      serverId,
      relayUrl: relayUrl,
      pairingToken: pairingToken,
      serverPubkey: serverPubkey,
    );
    await _registerPushNotifications();
    ws?.connect();
    notifyListeners();
  }

  void _setupListeners() {
    _statusSub = _connMgr.statusStream.listen((update) {
      // Update overall connection status — connected if ANY server is connected
      if (_connMgr.anyConnected) {
        _connectionStatus = ConnectionStatus.connected;
      } else {
        // Use the status of the active server, or the update's status
        _connectionStatus = update.status;
      }
      notifyListeners();
      // Auto-sync state on every (re)connect for this server
      if (update.status == ConnectionStatus.connected) {
        _syncStateToServer(serverId: update.serverId);
      }
    });

    _messageSub = _connMgr.messages.listen((serverMsg) {
      _handleServerMessage(serverMsg.data, serverMsg.serverId);
    });

    _speechResultSub = _speech.onResult.listen((text) {
      // Speech results are handled by the UI text controller
    });

    _speechStatusSub = _speech.onListeningStatus.listen((listening) {
      _isListening = listening;
      notifyListeners();
    });
  }

  /// Sync preferences and resume active session after (re)connect.
  /// If [serverId] is given, syncs only to that server; otherwise syncs to active.
  void _syncStateToServer({String? serverId}) {
    void sendTo(Map<String, dynamic> msg) {
      if (serverId != null) {
        _connMgr.sendToServer(serverId, msg);
      } else {
        _connMgr.send(msg);
      }
    }

    if (_ttsEnabled) {
      sendTo({'type': 'set_tts', 'enabled': true});
    }
    // Sync TTS engine mode
    final engineStr = _ttsEngineMode == TtsEngineMode.kokoroServer
        ? 'kokoro_server'
        : _ttsEngineMode == TtsEngineMode.kokoroDevice
        ? 'kokoro_device'
        : 'system';
    sendTo({
      'type': 'set_tts_engine',
      'engine': engineStr,
      'voice': _kokoroServerEngine.selectedVoice?.id ?? 'af_heart',
    });
    sendTo({'type': 'set_effort', 'effort': _effort});
    sendTo({'type': 'set_thinking', 'thinking': _thinking});

    // Send per-session disallowed tools and system prompt if we have an active session
    if (_activeSessionId != null) {
      final dt = _sessionDisallowedTools[_activeSessionId!];
      if (dt != null && dt.isNotEmpty) {
        sendTo({'type': 'set_disallowed_tools', 'tools': dt});
      }
      final sp = getEffectiveSystemPrompt(_activeSessionId!);
      if (sp.isNotEmpty) {
        sendTo({'type': 'set_system_prompt', 'prompt': sp});
      }
    }

    // Request session list from this server (or all if no serverId)
    if (serverId != null) {
      _connMgr.sendToServer(serverId, {'type': 'get_server_settings'});
      _connMgr.sendToServer(serverId, {'type': 'list_sessions'});
      _connMgr.sendToServer(serverId, {'type': 'list_scheduled_tasks'});
      if (serverId == _connMgr.activeServerId) {
        _connMgr.sendToServer(serverId, {'type': 'skills_list'});
      }
    } else {
      requestServerSettings();
      requestSessionList();
      requestScheduledTasks();
      requestActiveSkills();
    }

    // Resume active session only on the server that owns it
    if (_activeSessionId != null &&
        serverId != null &&
        serverId == _connMgr.activeServerId) {
      _connMgr.sendToServer(serverId, {
        'type': 'resume_session',
        'sessionId': _activeSessionId,
      });
    }
  }

  /// Switch connection mode for a specific server (or first relay server).
  Future<void> setConnectionMode(
    ConnectionMode mode, {
    String? serverId,
  }) async {
    if (serverId != null) {
      final ws = _connMgr.getConnection(serverId);
      ws?.setMode(mode);
      final idx = _serverConfigs.indexWhere((c) => c.id == serverId);
      if (idx >= 0) {
        _serverConfigs[idx] = _serverConfigs[idx].copyWith(
          useRelay: mode == ConnectionMode.relay,
        );
        await _saveServerConfigs();
      }
    } else {
      // Legacy: find first relay server
      for (final config in _serverConfigs) {
        if (config.useRelay || config.isRelayPaired) {
          final ws = _connMgr.getConnection(config.id);
          ws?.setMode(mode);
          break;
        }
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('use_relay', mode == ConnectionMode.relay);
    }
    connectToServer();
    notifyListeners();
  }

  /// Reload relay config for a specific server after pairing.
  Future<void> reloadRelayConfig({
    bool switchToRelay = true,
    String? serverId,
  }) async {
    if (serverId != null) {
      // Per-server relay — config is in the ServerConfig
      final idx = _serverConfigs.indexWhere((c) => c.id == serverId);
      if (idx >= 0) {
        final config = _serverConfigs[idx];
        if (config.isRelayPaired) {
          await _connMgr.configureServerRelay(
            serverId,
            relayUrl: config.relayUrl,
            pairingToken: config.pairingToken,
            serverPubkey: config.serverPubkey,
          );
          if (switchToRelay) {
            final updated = config.copyWith(useRelay: true);
            _serverConfigs[idx] = updated;
            await _saveServerConfigs();
          }
        }
      }
      return;
    }
    // Legacy: reload from shared prefs (for backwards compat)
    final prefs = await SharedPreferences.getInstance();
    final relayUrl = prefs.getString('relay_url');
    final pairingToken = prefs.getString('pairing_token');
    final serverPubkey = prefs.getString('server_pubkey');
    if (relayUrl != null && pairingToken != null && serverPubkey != null) {
      // Apply to the first server that uses relay, or the first server
      final target = _serverConfigs.firstWhere(
        (c) => c.useRelay,
        orElse: () => _serverConfigs.first,
      );
      final updated = target.copyWith(
        useRelay: switchToRelay,
        relayUrl: relayUrl,
        pairingToken: pairingToken,
        serverPubkey: serverPubkey,
      );
      final idx = _serverConfigs.indexWhere((c) => c.id == target.id);
      if (idx >= 0) _serverConfigs[idx] = updated;
      await _saveServerConfigs();
      await _connMgr.setServers(_serverConfigs);
    }
  }

  Future<void> connectToServer() async {
    await _settingsLoaded.future;
    _connMgr.connectAll();
  }

  /// Derive HTTP URL from relay WebSocket URL
  String? _relayHttpUrl() {
    // Try legacy shared prefs key first
    final legacyUrl = _cachedPrefs?.getString('relay_url');
    if (legacyUrl != null && legacyUrl.isNotEmpty) {
      return legacyUrl
          .replaceFirst('wss://', 'https://')
          .replaceFirst('ws://', 'http://');
    }
    // Fall back to first relay server's URL from multi-server configs
    for (final config in _serverConfigs) {
      if (config.relayUrl.isNotEmpty) {
        return config.relayUrl
            .replaceFirst('wss://', 'https://')
            .replaceFirst('ws://', 'http://');
      }
    }
    return null;
  }

  SharedPreferences? _cachedPrefs;

  /// Check subscription status via relay HTTP API (uses signed token)
  Future<bool> checkSubscriptionStatus() async {
    if (_subscriberToken.isEmpty) {
      _subscriptionActive = false;
      _subscriptionChecked = true;
      notifyListeners();
      return false;
    }

    final prefs = await SharedPreferences.getInstance();
    _cachedPrefs = prefs;
    final httpUrl = _relayHttpUrl();
    if (httpUrl == null) {
      _subscriptionChecked = true;
      notifyListeners();
      return false;
    }

    try {
      final uri = Uri.parse(
        '$httpUrl/api/subscription-status?token=${Uri.encodeComponent(_subscriberToken)}',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _subscriptionActive = data['active'] == true;
        if (_subscriptionActive) {
          _subscriptionStatus = data['status'] as String? ?? '';
          _trialEnd = data['trialEnd'] != null
              ? DateTime.fromMillisecondsSinceEpoch(data['trialEnd'] as int)
              : null;
          _periodEnd = data['periodEnd'] != null
              ? DateTime.fromMillisecondsSinceEpoch(data['periodEnd'] as int)
              : null;
          _cancelAtPeriodEnd = data['cancelAtPeriodEnd'] == true;
        } else {
          _subscriptionStatus = '';
          _trialEnd = null;
          _periodEnd = null;
          _cancelAtPeriodEnd = false;
        }
      } else {
        _subscriptionActive = false;
        _subscriptionStatus = '';
        _trialEnd = null;
        _periodEnd = null;
        _cancelAtPeriodEnd = false;
      }
    } catch (e) {
      _subscriptionActive = false;
      _subscriptionStatus = '';
      _trialEnd = null;
      _periodEnd = null;
      _cancelAtPeriodEnd = false;
    }

    _subscriptionChecked = true;
    notifyListeners();
    return _subscriptionActive;
  }

  /// Create a Stripe Checkout Session (or get owner bypass token).
  /// Returns a Map with either {url: checkoutUrl} or {ownerBypass: true, token: signedToken}.
  Future<Map<String, dynamic>?> createCheckoutSession(String email) async {
    final prefs = await SharedPreferences.getInstance();
    _cachedPrefs = prefs;
    final httpUrl = _relayHttpUrl();
    if (httpUrl == null) return null;

    try {
      final uri = Uri.parse('$httpUrl/api/checkout');
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'email': email.trim()}),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      // Return server error so the UI can display it
      try {
        final errBody = jsonDecode(response.body) as Map<String, dynamic>;
        return {
          'error': errBody['error'] ?? 'Server error (${response.statusCode})',
        };
      } catch (_) {
        return {'error': 'Server error (${response.statusCode})'};
      }
    } catch (e) {
      debugPrint('[Subscription] Checkout error: $e');
    }
    return null;
  }

  /// Verify a completed Stripe Checkout Session and get signed token
  Future<bool> verifyCheckoutSession(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    _cachedPrefs = prefs;
    final httpUrl = _relayHttpUrl();
    if (httpUrl == null) return false;

    try {
      final uri = Uri.parse('$httpUrl/api/verify-session');
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'sessionId': sessionId}),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final token = data['token'] as String?;
        final email = data['email'] as String? ?? '';
        if (token != null && token.isNotEmpty) {
          await saveSubscriberToken(token, email);
          return true;
        }
      }
    } catch (e) {
      debugPrint('[Subscription] Verify error: $e');
    }
    return false;
  }

  /// Get Stripe billing portal URL for subscription management
  Future<String?> getBillingPortalUrl() async {
    if (_subscriberEmail.isEmpty) return null;
    final httpUrl = _relayHttpUrl();
    if (httpUrl == null) return null;

    try {
      final uri = Uri.parse('$httpUrl/api/billing-portal');
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'email': _subscriberEmail}),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['url'] as String?;
      }
    } catch (e) {
      debugPrint('[Subscription] Billing portal error: $e');
    }
    return null;
  }

  /// Save subscriber token and email
  Future<void> saveSubscriberToken(String token, [String email = '']) async {
    _subscriberToken = token;
    if (email.isNotEmpty) _subscriberEmail = email;
    await _secureStorage.setSubscriberToken(token);
    if (email.isNotEmpty) await _secureStorage.setSubscriberEmail(email);
    // Update subscriber token on all relay connections
    _connMgr.setSubscriberToken(_subscriberToken);
    await _connMgr.setServers(_serverConfigs);
    await _registerPushNotifications();
    _subscriptionActive = true;
    _subscriptionChecked = true;
    notifyListeners();
  }

  /// Clear subscriber token (sign out)
  Future<void> clearSubscriberToken() async {
    _subscriberToken = '';
    _subscriberEmail = '';
    _subscriptionActive = false;
    _subscriptionChecked = false;
    await _secureStorage.deleteSubscriberToken();
    await _secureStorage.deleteSubscriberEmail();
    // Update subscriber token on all relay connections
    _connMgr.setSubscriberToken('');
    await _connMgr.setServers(_serverConfigs);
    notifyListeners();
  }

  /// Mark subscription as active
  void setSubscriptionActive(bool active) {
    _subscriptionActive = active;
    _subscriptionChecked = true;
    notifyListeners();
  }

  void disconnect() {
    _connMgr.disconnectAll();
  }

  void toggleRawMode() {
    _rawMode = !_rawMode;
    notifyListeners();
  }

  void clearRawEvents() {
    _rawItems.clear();
    _currentMessageGroup = null;
    _currentContentBlock = null;
    notifyListeners();
  }

  void _processRawEvent(Map<String, dynamic> msg) {
    final sdkType = msg['sdkType'] as String? ?? '';
    final event = msg['event'] as Map<String, dynamic>?;
    final eventType = event?['type'] as String? ?? '';

    if (sdkType == 'stream_event') {
      switch (eventType) {
        case 'message_start':
          final message = event?['message'] as Map<String, dynamic>? ?? {};
          final usage = message['usage'] as Map<String, dynamic>?;
          final group = MessageGroup(
            timestamp: DateTime.now(),
            model: message['model'] as String?,
            inputUsage: usage,
          );
          _currentMessageGroup = group;
          _currentContentBlock = null;
          _addRawItem(SdkItem.message(group));
          break;

        case 'content_block_start':
          final cb = event?['content_block'] as Map<String, dynamic>? ?? {};
          final block = ContentBlock(
            index: (event?['index'] as num?)?.toInt() ?? 0,
            blockType: cb['type'] as String? ?? 'unknown',
            toolName: cb['name'] as String?,
            toolUseId: cb['id'] as String?,
          );
          _currentContentBlock = block;
          _currentMessageGroup?.contentBlocks.add(block);
          break;

        case 'content_block_delta':
          if (_currentContentBlock != null) {
            final delta = event?['delta'] as Map<String, dynamic>? ?? {};
            final deltaType = delta['type'] as String? ?? '';
            if (deltaType == 'text_delta') {
              _currentContentBlock!.accumulatedText +=
                  delta['text'] as String? ?? '';
            } else if (deltaType == 'input_json_delta') {
              _currentContentBlock!.accumulatedText +=
                  delta['partial_json'] as String? ?? '';
            } else if (deltaType == 'thinking_delta') {
              _currentContentBlock!.accumulatedText +=
                  delta['thinking'] as String? ?? '';
            }
            _currentContentBlock!.deltaCount++;
          }
          break;

        case 'content_block_stop':
          if (_currentContentBlock != null) {
            _currentContentBlock!.complete = true;
            _currentContentBlock = null;
          }
          break;

        case 'message_delta':
          if (_currentMessageGroup != null) {
            final usage = event?['usage'] as Map<String, dynamic>?;
            final delta = event?['delta'] as Map<String, dynamic>? ?? {};
            _currentMessageGroup!.outputTokens =
                (usage?['output_tokens'] as num?)?.toInt();
            _currentMessageGroup!.stopReason = delta['stop_reason'] as String?;
          }
          break;

        case 'message_stop':
          if (_currentMessageGroup != null) {
            _currentMessageGroup!.complete = true;
            _currentMessageGroup = null;
            _currentContentBlock = null;
          }
          break;
      }
    } else if (sdkType == 'system') {
      _addRawItem(
        SdkItem.system(
          timestamp: DateTime.now(),
          subtype: msg['subtype'] as String?,
          sessionId: msg['sessionId'] as String?,
          status: msg['status'] as String?,
          compactMetadata: msg['compactMetadata'] is Map
              ? Map<String, dynamic>.from(msg['compactMetadata'])
              : null,
          taskId: msg['taskId'] as String?,
          summary: msg['summary'] as String?,
          trigger: msg['trigger'] as String?,
          rawData: msg,
        ),
      );
    } else if (sdkType == 'tool_progress') {
      _addRawItem(
        SdkItem.toolProgress(
          timestamp: DateTime.now(),
          toolName: msg['toolName'] as String?,
          toolUseId: msg['toolUseId'] as String?,
          elapsed: (msg['elapsed'] as num?)?.toDouble(),
          rawData: msg,
        ),
      );
    } else if (sdkType == 'result') {
      _addRawItem(
        SdkItem.result(
          timestamp: DateTime.now(),
          cost: (msg['cost'] as num?)?.toDouble(),
          numTurns: (msg['numTurns'] as num?)?.toInt(),
          durationMs: (msg['durationMs'] as num?)?.toInt(),
          isError: msg['isError'] as bool?,
          modelUsage: msg['modelUsage'] as Map<String, dynamic>?,
          rawData: msg,
        ),
      );
    } else if (sdkType == 'codex_app_server') {
      final method = msg['method'] as String? ?? 'codex';
      final params = msg['params'];
      _addRawItem(
        SdkItem.standalone(
          timestamp:
              DateTime.tryParse(msg['ts'] as String? ?? '') ?? DateTime.now(),
          role: method,
          blocks: [
            {
              'type': params == null ? 'event' : 'json',
              'text': params == null
                  ? method
                  : const JsonEncoder.withIndent('  ').convert(params),
            },
          ],
          rawData: msg,
        ),
      );
    } else if (sdkType == 'assistant') {
      // Redundant — message card already has streamed content blocks.
    } else if (sdkType == 'user') {
      // User events carry tool results — match to the message that has
      // the corresponding tool_use block (by tool_use_id)
      final blocks = (msg['blocks'] as List?)
          ?.map((b) => Map<String, dynamic>.from(b as Map))
          .toList();
      if (blocks != null) {
        // Collect tool_use_ids from these results
        final resultIds = blocks
            .where(
              (b) => b['type'] == 'tool_result' && b['tool_use_id'] != null,
            )
            .map((b) => b['tool_use_id'] as String)
            .toSet();

        // Search backwards for the message group with matching tool_use blocks
        for (int i = _rawItems.length - 1; i >= 0; i--) {
          final item = _rawItems[i];
          if (item.itemType == SdkItemType.message &&
              item.messageGroup != null) {
            final g = item.messageGroup!;
            final hasMatch = g.contentBlocks.any(
              (cb) =>
                  cb.blockType == 'tool_use' &&
                  cb.toolUseId != null &&
                  resultIds.contains(cb.toolUseId),
            );
            if (hasMatch) {
              g.toolResults = [...?g.toolResults, ...blocks];
              break;
            }
          }
        }
      }
    }

    // Throttle UI rebuilds to ~10/sec when in raw mode
    if (_rawMode) {
      _rawThrottle ??= Timer(const Duration(milliseconds: 100), () {
        _rawThrottle = null;
        notifyListeners();
      });
    }
  }

  void _addRawItem(SdkItem item) {
    _rawItems.add(item);
    if (_rawItems.length > 300) {
      _rawItems.removeRange(0, _rawItems.length - 300);
      if (_currentMessageGroup != null) {
        final found = _rawItems.any(
          (i) => i.messageGroup == _currentMessageGroup,
        );
        if (!found) {
          _currentMessageGroup = null;
          _currentContentBlock = null;
        }
      }
    }
  }

  void _restoreSdkEvents(List events) {
    _rawItems.clear();
    _currentMessageGroup = null;
    _currentContentBlock = null;

    MessageGroup? currentGroup;

    for (final raw in events) {
      if (raw is! Map) continue;
      final e = Map<String, dynamic>.from(raw);
      final sdkType = e['sdkType'] as String? ?? '';
      final ts = DateTime.tryParse(e['ts'] as String? ?? '') ?? DateTime.now();

      switch (sdkType) {
        case 'message_start':
          currentGroup = MessageGroup(
            timestamp: ts,
            model: e['model'] as String?,
            inputUsage: e['usage'] as Map<String, dynamic>?,
          );
          _rawItems.add(SdkItem.message(currentGroup));
          break;
        case 'content_block':
          if (currentGroup != null) {
            currentGroup.contentBlocks.add(
              ContentBlock(
                index: (e['blockIndex'] as num?)?.toInt() ?? 0,
                blockType: e['blockType'] as String? ?? 'unknown',
                toolName: e['toolName'] as String?,
                toolUseId: e['toolUseId'] as String?,
                accumulatedText: e['text'] as String? ?? '',
                deltaCount: (e['deltaCount'] as num?)?.toInt() ?? 0,
                complete: true,
              ),
            );
          }
          break;
        case 'message_delta':
          if (currentGroup != null) {
            currentGroup.outputTokens =
                (e['usage'] as Map?)?['output_tokens'] as int?;
            currentGroup.stopReason = e['stopReason'] as String?;
          }
          break;
        case 'message_stop':
          if (currentGroup != null) {
            currentGroup.complete = true;
            currentGroup = null;
          }
          break;
        case 'system':
          _rawItems.add(
            SdkItem.system(
              timestamp: ts,
              subtype: e['subtype'] as String?,
              sessionId: e['sessionId'] as String?,
              status: e['status'] as String?,
              compactMetadata: e['compactMetadata'] is Map
                  ? Map<String, dynamic>.from(e['compactMetadata'])
                  : null,
              taskId: e['taskId'] as String?,
              summary: e['summary'] as String?,
              trigger: e['trigger'] as String?,
              rawData: e,
            ),
          );
          break;
        case 'tool_progress':
          _rawItems.add(
            SdkItem.toolProgress(
              timestamp: ts,
              toolName: e['toolName'] as String?,
              toolUseId: e['toolUseId'] as String?,
              elapsed: (e['elapsed'] as num?)?.toDouble(),
              rawData: e,
            ),
          );
          break;
        case 'assistant':
          // Redundant — message card already has streamed content blocks
          break;
        case 'user':
          // Tool results — match by tool_use_id to the message that requested them
          final userBlocks = (e['blocks'] as List?)
              ?.map((b) => Map<String, dynamic>.from(b as Map))
              .toList();
          if (userBlocks != null) {
            final resultIds = userBlocks
                .where(
                  (b) => b['type'] == 'tool_result' && b['tool_use_id'] != null,
                )
                .map((b) => b['tool_use_id'] as String)
                .toSet();
            for (int i = _rawItems.length - 1; i >= 0; i--) {
              final item = _rawItems[i];
              if (item.itemType == SdkItemType.message &&
                  item.messageGroup != null) {
                final g = item.messageGroup!;
                final hasMatch = g.contentBlocks.any(
                  (cb) =>
                      cb.blockType == 'tool_use' &&
                      cb.toolUseId != null &&
                      resultIds.contains(cb.toolUseId),
                );
                if (hasMatch) {
                  g.toolResults = [...?g.toolResults, ...userBlocks];
                  break;
                }
              }
            }
          }
          break;
        case 'result':
          _rawItems.add(
            SdkItem.result(
              timestamp: ts,
              cost: (e['cost'] as num?)?.toDouble(),
              numTurns: (e['numTurns'] as num?)?.toInt(),
              durationMs: (e['durationMs'] as num?)?.toInt(),
              isError: e['isError'] as bool?,
              modelUsage: e['modelUsage'] as Map<String, dynamic>?,
              rawData: e,
            ),
          );
          break;
        case 'codex_app_server':
          final method = e['method'] as String? ?? 'codex';
          final params = e['params'];
          _rawItems.add(
            SdkItem.standalone(
              timestamp: ts,
              role: method,
              blocks: [
                {
                  'type': params == null ? 'event' : 'json',
                  'text': params == null
                      ? method
                      : const JsonEncoder.withIndent('  ').convert(params),
                },
              ],
              rawData: e,
            ),
          );
          break;
      }
    }
    if (_rawItems.length > 300) {
      _rawItems.removeRange(0, _rawItems.length - 300);
    }
    notifyListeners();
  }

  void _handleServerMessage(Map<String, dynamic> msg, [String? serverId]) {
    final type = msg['type'] as String?;
    if (type == null) return;

    // Messages that should be processed from ANY server
    const globalTypes = {
      'session_list',
      'status_sync',
      'subscription_required',
      'directory_listing',
      'cwd_check',
      'sdk_session_list',
      'active_subagents',
      'version_info',
      'update_result',
      'recent_cwds',
      'archive_list',
      'archive_history',
      'archive_restored',
      'archive_restore_failed',
      'archive_deleted',
      'server_capabilities',
      'server_settings',
      'file_data',
      'file_chunk',
      'file_complete',
    };

    // Route: only process non-global messages from the active server
    if (!globalTypes.contains(type) &&
        serverId != null &&
        _connMgr.activeServerId != null &&
        serverId != _connMgr.activeServerId) {
      return;
    }

    // Visible chat state is single-session. If a long-running session emits
    // messages after the user has opened another session, do not append those
    // events to the current chat; they will be restored from that session's
    // persisted history when the user opens it again.
    final messageSessionId = msg['sessionId'] as String?;
    if (!globalTypes.contains(type) &&
        messageSessionId != null &&
        messageSessionId.isNotEmpty) {
      if (_activeSessionId == null) {
        if (type != 'session_created') return;
      } else if (messageSessionId != _activeSessionId) {
        return;
      }
    }

    // Capture SDK events for raw debug mode (coalesced)
    if (type == 'sdk_event') {
      _processRawEvent(msg);
      return; // Don't process sdk_event further — it's debug-only
    }

    switch (type) {
      case 'text':
        _handleTextMessage(msg);
        break;
      case 'thinking':
        _handleThinkingMessage(msg);
        break;
      case 'tool_call':
        _handleToolCall(msg);
        break;
      case 'tool_result':
        _handleToolResult(msg);
        break;
      case 'tool_result_chunk':
        _handleToolResultChunk(msg);
        break;
      case 'tool_image':
        _handleToolImage(msg);
        break;
      case 'codex_plan':
        _handleCodexPlan(msg);
        break;
      case 'tool_progress':
        _handleToolProgress(msg);
        break;
      case 'tool_stderr':
        _handleToolStderr(msg);
        break;
      case 'question':
        _handleQuestion(msg);
        break;
      case 'result':
        _handleResult(msg);
        break;
      case 'subagent_result':
        _handleSubagentResult(msg);
        break;
      case 'active_subagents':
        _handleActiveSubagents(msg);
        break;
      case 'session_created':
        _handleSessionCreated(msg);
        break;
      case 'session_history':
        _handleSessionHistory(msg);
        break;
      case 'session_list':
        _handleSessionList(msg, serverId);
        break;
      case 'server_capabilities':
        {
          final raw = msg['backends'];
          final backends = (raw is List)
              ? raw.whereType<String>().toList()
              : <String>['claude'];
          if (serverId != null) {
            _serverBackends[serverId] = backends;
            _captureCodexDriverSettings(msg, serverId);
            notifyListeners();
          }
          break;
        }
      case 'server_settings':
        {
          if (serverId != null) {
            _captureCodexDriverSettings(msg, serverId);
            notifyListeners();
          }
          break;
        }
      case 'codex_collaboration_modes':
        {
          final key = serverId ?? _connMgr.activeServerId;
          if (key != null) {
            final modes =
                (msg['modes'] as List?)
                    ?.whereType<Map>()
                    .map((m) => Map<String, dynamic>.from(m))
                    .toList() ??
                const <Map<String, dynamic>>[
                  {'id': 'default', 'name': 'Default'},
                ];
            _serverCodexCollaborationModes[key] = modes;
            final currentMode = msg['currentMode'] as String?;
            if (currentMode != null && currentMode.isNotEmpty) {
              _serverCodexCollaborationMode[key] = currentMode;
            }
            notifyListeners();
          }
          break;
        }
      case 'codex_collaboration_mode_changed':
        {
          final key = serverId ?? _connMgr.activeServerId;
          final mode = msg['mode'] as String? ?? 'default';
          if (key != null) _serverCodexCollaborationMode[key] = mode;
          _messages.add(
            ChatMessage(
              id: 'codex_mode_${DateTime.now().microsecondsSinceEpoch}',
              sender: MessageSender.system,
              type: MessageType.taskNotification,
              timestamp: DateTime.now(),
              textContent: 'Codex collaboration mode set to $mode',
              toolName: 'codex_mode',
            ),
          );
          notifyListeners();
          break;
        }
      case 'usage_restore':
        if (msg['usage'] != null) {
          _lastUsage = Map<String, dynamic>.from(msg['usage'] as Map);
          notifyListeners();
        }
        break;
      case 'usage_update':
        // Mid-query usage update from message_start and message_delta events
        _lastUsage ??= <String, dynamic>{};
        _lastUsage!['inputTokens'] = msg['inputTokens'] ?? 0;
        _lastUsage!['outputTokens'] = msg['outputTokens'] ?? 0;
        _lastUsage!['cacheReadTokens'] = msg['cacheReadTokens'] ?? 0;
        _lastUsage!['cacheCreateTokens'] = msg['cacheCreateTokens'] ?? 0;
        if ((msg['contextWindow'] as num?)?.toInt() != null &&
            (msg['contextWindow'] as num).toInt() > 0) {
          _lastUsage!['contextWindow'] = msg['contextWindow'];
        }
        notifyListeners();
        break;
      case 'speak':
        final text = msg['text'] as String? ?? '';
        if (_ttsEnabled && text.isNotEmpty) {
          if (_ttsEngineMode == TtsEngineMode.kokoroServer) {
            // Don't speak locally — audio will arrive via tts_audio message
          } else if (_ttsEngineMode == TtsEngineMode.kokoroDevice) {
            _kokoroDeviceEngine.speak(text);
          } else {
            _tts.speak(text);
          }
        }
        if (text.isNotEmpty) {
          final messageSessionId = msg['sessionId'] as String? ?? '';
          final belongsToActiveSession =
              messageSessionId.isEmpty ||
              _activeSessionId == null ||
              messageSessionId == _activeSessionId;
          if (belongsToActiveSession) {
            final hasVisibleCard = _messages.any(
              (m) =>
                  m.type == MessageType.toolCall &&
                  m.toolName == 'Speak' &&
                  m.toolInput?['text'] == text,
            );
            if (!hasVisibleCard) {
              _messages.add(
                ChatMessage.toolCall(
                  tool: 'Speak',
                  input: {'text': text},
                  toolUseId: 'speak_${DateTime.now().microsecondsSinceEpoch}',
                ),
              );
              notifyListeners();
            }
          }
        }
        break;
      case 'tts_audio':
        final audioData = msg['audioData'] as String? ?? '';
        if (_ttsEnabled &&
            audioData.isNotEmpty &&
            _ttsEngineMode == TtsEngineMode.kokoroServer) {
          _kokoroServerEngine.playAudioData(audioData);
        }
        break;
      case 'file':
        _handleFileMessage(msg);
        break;
      case 'file_data':
        _handleFileData(msg);
        break;
      case 'file_chunk':
        _handleFileChunk(msg);
        break;
      case 'file_complete':
        _handleFileComplete(msg);
        break;
      case 'todos':
        final rawTodos = msg['todos'] as List?;
        if (rawTodos != null) {
          final newTodos = rawTodos
              .map((t) => Map<String, dynamic>.from(t as Map))
              .toList();
          // Skip if identical to current state (prevents spurious cards on reconnect/re-send)
          if (_todosEqual(_todos, newTodos)) break;
          final diff = _computeTodoDiff(_todos, newTodos);
          _todos = newTodos;
          if (diff.isNotEmpty) {
            _messages.add(
              ChatMessage(
                id: 'todo_update_${DateTime.now().microsecondsSinceEpoch}',
                sender: MessageSender.system,
                type: MessageType.taskNotification,
                timestamp: DateTime.now(),
                textContent: diff,
                toolName: 'todos_updated',
              ),
            );
          }
          notifyListeners();
        }
        break;
      case 'sdk_event_history':
        _restoreSdkEvents(msg['events'] as List? ?? []);
        break;
      case 'cwd_check':
        final exists = msg['exists'] == true;
        _pendingCwdCheck?.complete(exists);
        _pendingCwdCheck = null;
        break;
      case 'directory_listing':
        _pendingDirList?.complete(Map<String, dynamic>.from(msg));
        _pendingDirList = null;
        break;
      case 'recent_cwds':
        final cwds = (msg['cwds'] as List?)?.cast<String>() ?? [];
        final key = serverId ?? '';
        _recentCwds[key] = cwds;
        notifyListeners();
        break;
      case 'sdk_session_list':
        // Only accept response from the server we sent the request to
        if (_pendingSdkSessionsServerId != null &&
            serverId != null &&
            serverId != _pendingSdkSessionsServerId) {
          break;
        }
        final sessions =
            (msg['sessions'] as List?)
                ?.map((e) => Map<String, dynamic>.from(e as Map))
                .toList() ??
            <Map<String, dynamic>>[];
        _pendingSdkSessions?.complete(sessions);
        _pendingSdkSessions = null;
        _pendingSdkSessionsServerId = null;
        break;
      case 'version_info':
        _pendingVersionCheck?.complete(Map<String, dynamic>.from(msg));
        _pendingVersionCheck = null;
        break;
      case 'update_result':
        _pendingForceUpdate?.complete(Map<String, dynamic>.from(msg));
        _pendingForceUpdate = null;
        break;
      case 'compacting':
        _isCompacting = msg['active'] == true;
        notifyListeners();
        break;
      case 'rate_limit_event':
        final rlStatus = msg['status'] as String? ?? 'allowed';
        _isRateLimited =
            rlStatus == 'rejected' || rlStatus == 'allowed_warning';
        _rateLimitUtilization = (msg['utilization'] as num?)?.toDouble();
        notifyListeners();
        break;
      case 'api_retry':
        _isRetrying = true;
        notifyListeners();
        Future.delayed(const Duration(seconds: 10), () {
          if (_isRetrying) {
            _isRetrying = false;
            notifyListeners();
          }
        });
        break;
      case 'task_started':
        // Register monitor-spawned tasks in the background tasks pane
        final tsTaskType = msg['taskType'] as String?;
        if (tsTaskType == 'monitor') {
          final tsTaskId = msg['taskId'] as String? ?? '';
          final tsDesc = msg['description'] as String? ?? 'Monitored process';
          final tsToolUseId = msg['toolUseId'] as String?;
          _backgroundTasks[tsTaskId] = {
            'status': 'running',
            'summary': tsDesc,
            'isMonitor': true,
            if (tsToolUseId != null) 'originToolUseId': tsToolUseId,
          };
          notifyListeners();
        }
        break;
      case 'bg_task_progress':
        // Update subagent with progress summary if available
        final progressToolId = msg['toolUseId'] as String?;
        final progressSummary = msg['summary'] as String?;
        if (progressToolId != null &&
            _subagentTasks.containsKey(progressToolId)) {
          if (progressSummary != null)
            _subagentTasks[progressToolId]!['progressSummary'] =
                progressSummary;
          final lastTool = msg['lastToolName'] as String?;
          if (lastTool != null)
            _subagentTasks[progressToolId]!['lastToolName'] = lastTool;
          notifyListeners();
        }
        break;
      case 'hook_started':
        _activeHookName = msg['hookName'] as String?;
        notifyListeners();
        break;
      case 'hook_progress':
        // Hook is still running — keep indicator active
        break;
      case 'hook_response':
        _activeHookName = null;
        notifyListeners();
        break;
      case 'local_command_output':
        final cmdContent = msg['content'] as String? ?? '';
        if (cmdContent.isNotEmpty) {
          _messages.add(
            ChatMessage(
              id: 'cmd_${DateTime.now().microsecondsSinceEpoch}',
              sender: MessageSender.system,
              type: MessageType.text,
              timestamp: DateTime.now(),
              textContent: cmdContent,
            ),
          );
          notifyListeners();
        }
        break;
      case 'prompt_suggestion':
        final suggestion = msg['suggestion'] as String? ?? '';
        if (suggestion.isNotEmpty) {
          _promptSuggestions = [suggestion];
          notifyListeners();
        }
        break;
      case 'session_lifecycle':
        final lcEvent = msg['event'] as String? ?? '';
        final lcModel = msg['model'] as String?;
        if (lcEvent == 'start' && lcModel != null && lcModel.isNotEmpty) {
          _sessionModel = lcModel;
        }
        // Show as a subtle system notification in chat
        final lcReason = msg['reason'] as String? ?? '';
        String lcText;
        if (lcEvent == 'start') {
          lcText =
              'Session started${lcModel != null && lcModel.isNotEmpty ? ' ($lcModel)' : ''}';
        } else {
          lcText = 'Session ended${lcReason.isNotEmpty ? ' ($lcReason)' : ''}';
        }
        _messages.add(
          ChatMessage(
            id: 'lifecycle_${DateTime.now().microsecondsSinceEpoch}',
            sender: MessageSender.system,
            type: MessageType.taskNotification,
            timestamp: DateTime.now(),
            textContent: lcText,
            toolName: lcEvent == 'start' ? 'session_start' : 'session_end',
          ),
        );
        notifyListeners();
        break;
      case 'task_completed_hook':
        final hookTaskId = msg['taskId'] as String? ?? '';
        final hookTeammate = msg['teammateName'] as String? ?? '';
        final hookSubject = msg['subject'] as String? ?? '';
        // Try to match to a tracked subagent by taskId or teammateName
        bool matched = false;
        if (hookTaskId.isNotEmpty && _subagentTasks.containsKey(hookTaskId)) {
          _subagentTasks[hookTaskId]!['status'] = 'completed';
          matched = true;
        }
        // If not matched by taskId, try matching by teammate name in description
        if (!matched && hookTeammate.isNotEmpty) {
          for (final entry in _subagentTasks.entries) {
            if (entry.value['status'] == 'running' &&
                (entry.value['description'] as String? ?? '').contains(
                  hookTeammate,
                )) {
              entry.value['status'] = 'completed';
              matched = true;
              break;
            }
          }
        }
        // Show a notification if we have a subject
        if (hookSubject.isNotEmpty) {
          _messages.add(
            ChatMessage(
              id: 'task_hook_${DateTime.now().microsecondsSinceEpoch}',
              sender: MessageSender.system,
              type: MessageType.taskNotification,
              timestamp: DateTime.now(),
              textContent: hookSubject,
              toolName: 'completed',
            ),
          );
        }
        notifyListeners();
        break;
      case 'session_state_changed':
        final sessionState = msg['state'] as String? ?? 'idle';
        _requiresAction = sessionState == 'requires_action';
        // Use SDK state as authoritative source for running status
        if (sessionState == 'running') {
          _isProcessing = true;
          _processingSetAt = null; // server confirmed
        } else if (sessionState == 'idle') {
          _isProcessing = false;
          _processingSetAt = null;
          _currentStreamingMessage = null;
        }
        // requires_action keeps _isProcessing true (still mid-query)
        notifyListeners();
        break;
      case 'cwd_changed':
        final newCwd = msg['newCwd'] as String? ?? '';
        if (newCwd.isNotEmpty) {
          _activeSessionCwd = newCwd;
          // Update the session in the session list too
          final idx = _sessions.indexWhere((s) => s.id == _activeSessionId);
          if (idx >= 0) {
            final old = _sessions[idx];
            _sessions[idx] = Session(
              id: old.id,
              title: old.title,
              cwd: newCwd,
              createdAt: old.createdAt,
              lastActive: old.lastActive,
              messagePreview: old.messagePreview,
              running: old.running,
              serverId: old.serverId,
              serverName: old.serverName,
              serverColor: old.serverColor,
            );
          }
          notifyListeners();
        }
        break;
      case 'context_usage':
        _contextUsage = Map<String, dynamic>.from(msg);
        notifyListeners();
        break;
      case 'codex_compact_result':
        _messages.add(
          ChatMessage(
            id: 'codex_compact_${DateTime.now().microsecondsSinceEpoch}',
            sender: MessageSender.system,
            type: MessageType.taskNotification,
            timestamp: DateTime.now(),
            textContent: msg['success'] == true
                ? 'Codex thread compaction started'
                : 'Codex compaction failed: ${msg['error'] ?? 'unknown error'}',
            toolName: msg['success'] == true ? 'success' : 'failed',
          ),
        );
        notifyListeners();
        break;
      case 'codex_rollback_result':
        final turns = (msg['numTurns'] as num?)?.toInt() ?? 1;
        _messages.add(
          ChatMessage(
            id: 'codex_rollback_${DateTime.now().microsecondsSinceEpoch}',
            sender: MessageSender.system,
            type: MessageType.taskNotification,
            timestamp: DateTime.now(),
            textContent: msg['success'] == true
                ? 'Rolled back $turns Codex turn${turns == 1 ? '' : 's'}'
                : 'Codex rollback failed: ${msg['error'] ?? 'unknown error'}',
            toolName: msg['success'] == true ? 'success' : 'failed',
          ),
        );
        notifyListeners();
        break;
      case 'task_created_hook':
        final createdTaskId = msg['taskId'] as String? ?? '';
        final createdSubject = msg['subject'] as String? ?? '';
        final createdTeammate = msg['teammateName'] as String? ?? '';
        if (createdTaskId.isNotEmpty) {
          _subagentTasks[createdTaskId] = {
            'description': createdSubject,
            'prompt': '',
            'subagentType': createdTeammate,
            'status': 'running',
            'toolUseId': createdTaskId,
          };
        }
        notifyListeners();
        break;
      case 'injection_ack':
        // Server confirmed the injected message was processed by the SDK
        final ackMsgId = msg['messageId'] as String? ?? '';
        if (ackMsgId.isNotEmpty) {
          final idx = _messages.indexWhere(
            (m) => m.id == ackMsgId && m.isPending,
          );
          if (idx >= 0) {
            _messages[idx].isPending = false;
            _messages[idx].injectionPriority = null;
            notifyListeners();
          }
        } else {
          // No messageId — promote the oldest pending message
          final idx = _messages.indexWhere((m) => m.isPending);
          if (idx >= 0) {
            _messages[idx].isPending = false;
            _messages[idx].injectionPriority = null;
            notifyListeners();
          }
        }
        break;
      case 'supported_commands':
        _supportedCommands = msg['commands'] as List<dynamic>?;
        notifyListeners();
        break;
      case 'supported_agents':
        _supportedAgents = msg['agents'] as List<dynamic>?;
        notifyListeners();
        break;
      case 'skills_list':
        if (serverId != null) {
          _skillsByServer[serverId] = (msg['skills'] as List? ?? [])
              .map((skill) => Map<String, dynamic>.from(skill as Map))
              .toList();
          notifyListeners();
        }
        break;
      case 'permission_mode_changed':
        final mode = msg['permissionMode'] as String?;
        if (mode != null && mode.isNotEmpty && mode != _permissionMode) {
          _permissionMode = mode;
          _messages.add(_permissionModeMessage(mode));
        } else {
          _permissionMode = mode;
        }
        notifyListeners();
        break;
      case 'status':
        _isProcessing = msg['running'] == true;
        if (!_isProcessing) {
          _isCompacting = false;
          _currentStreamingMessage = null;
        } else {
          // Restore compacting state on resume (server sends compacting: true if active)
          if (msg['compacting'] == true) {
            _isCompacting = true;
          }
        }
        // Restore permission mode (e.g., plan mode) on session resume
        final resumePermMode = msg['permissionMode'] as String?;
        if (resumePermMode != null) {
          _permissionMode = resumePermMode;
        }
        // Restore spinner on the active tool call after session resume
        if (_isProcessing) {
          final activeToolUseId = msg['activeToolUseId'] as String?;
          if (activeToolUseId != null) {
            final idx = _messages.lastIndexWhere(
              (m) =>
                  m.type == MessageType.toolCall &&
                  m.toolUseId == activeToolUseId,
            );
            if (idx >= 0) {
              _messages[idx].toolStreaming = true;
            }
          }
        }
        // Detect server restart
        final startedAt = msg['serverStartedAt'] as String?;
        if (startedAt != null &&
            _lastServerStartedAt != null &&
            startedAt != _lastServerStartedAt) {
          final pid = msg['serverPid'] ?? '';
          _messages.add(
            ChatMessage(
              id: 'restart_${DateTime.now().microsecondsSinceEpoch}',
              sender: MessageSender.system,
              type: MessageType.taskNotification,
              timestamp: DateTime.now(),
              textContent: 'Server restarted (PID $pid)',
              toolName: 'restarted',
            ),
          );
        }
        if (startedAt != null) {
          _lastServerStartedAt = startedAt;
          SharedPreferences.getInstance().then(
            (p) => p.setString('server_started_at', startedAt),
          );
        }
        notifyListeners();
        break;
      case 'status_sync':
        // Capture per-server plugin list from ALL servers (needed for server settings)
        if (serverId != null) {
          final pluginsList = msg['plugins'] as List?;
          if (pluginsList != null) {
            _serverPlugins[serverId] = pluginsList
                .map((e) => e.toString())
                .toList();
          }
        }
        // Only process remaining status_sync fields from the active server
        if (serverId != null && serverId != _connMgr.activeServerId) break;
        // Check if THIS session is running, not just any session
        final runningSessions = (msg['runningSessions'] as List?)
            ?.map((e) => e.toString())
            .toSet();
        bool serverSaysRunning;
        if (runningSessions != null) {
          // Modern server sends a per-session list. Our session is running
          // iff it's in the list. If we don't have a session id yet (e.g.,
          // brand-new codex session before thread.started fires), it can't
          // be in the list, so we are NOT running — falling back to the
          // global msg['running'] would wrongly inherit another session's
          // running state and trip the "queued:next" UI on the first send.
          serverSaysRunning =
              _activeSessionId != null &&
              runningSessions.contains(_activeSessionId);
        } else {
          // Pre-runningSessions servers: best effort with the global flag.
          serverSaysRunning = msg['running'] == true;
        }
        // Don't let status_sync clear processing during the grace period after
        // sendPrompt() — the server may not have started the SDK query yet.
        if (!serverSaysRunning && _isProcessing && _processingSetAt != null) {
          final elapsed = DateTime.now().difference(_processingSetAt!);
          if (elapsed.inSeconds < 15) {
            // Keep _isProcessing true — server hasn't caught up yet
          } else {
            _isProcessing = false;
            _processingSetAt = null;
          }
        } else {
          _isProcessing = serverSaysRunning;
          if (serverSaysRunning) _processingSetAt = null; // server confirmed
        }
        if (!_isProcessing) {
          _isCompacting = false;
          _currentStreamingMessage = null;
        } else {
          // Check if our active session is compacting
          final compactingSessions = (msg['compactingSessions'] as List?)
              ?.map((e) => e.toString())
              .toSet();
          if (compactingSessions != null && _activeSessionId != null) {
            _isCompacting = compactingSessions.contains(_activeSessionId);
          }
        }
        // Reconcile background tasks — remove any not reported by server
        final serverTaskIds =
            (msg['backgroundTaskIds'] as List?)
                ?.map((e) => e.toString())
                .toSet() ??
            <String>{};
        _backgroundTasks.removeWhere((id, _) => !serverTaskIds.contains(id));
        // Update session model from heartbeat
        final sessionModels = msg['sessionModels'] as Map<String, dynamic>?;
        if (sessionModels != null && _activeSessionId != null) {
          final model = sessionModels[_activeSessionId] as String?;
          if (model != null) _sessionModel = model;
        }
        notifyListeners();
        break;
      case 'error':
        _messages.add(ChatMessage.error(msg['message'] ?? 'Unknown error'));
        _isProcessing = false;
        notifyListeners();
        break;
      case 'claude_auth':
        // Expire all previous auth cards — only the latest is valid
        for (final m in _messages) {
          if (m.type == MessageType.claudeAuth && !m.answered) {
            m.expired = true;
          }
        }
        _messages.add(
          ChatMessage(
            id: 'claude_auth_${DateTime.now().microsecondsSinceEpoch}',
            sender: MessageSender.system,
            type: MessageType.claudeAuth,
            timestamp: DateTime.now(),
            textContent: msg['url'] as String? ?? '',
            authRequestId: serverId,
          ),
        );
        _isProcessing = false;
        notifyListeners();
        break;
      case 'claude_auth_result':
        final success = msg['success'] == true;
        _messages.add(
          ChatMessage(
            id: 'claude_auth_result_${DateTime.now().microsecondsSinceEpoch}',
            sender: MessageSender.system,
            type: MessageType.taskNotification,
            timestamp: DateTime.now(),
            textContent: success
                ? 'Authentication successful. You can send your message again.'
                : 'Authentication failed.',
            toolName: success ? 'success' : 'failed',
          ),
        );
        notifyListeners();
        break;
      case 'archive_list':
        final serverConfig = serverId != null
            ? _serverConfigs.where((c) => c.id == serverId).firstOrNull
            : null;
        final archives = (msg['archives'] as List? ?? [])
            .map(
              (a) => ArchiveEntry.fromJson(Map<String, dynamic>.from(a as Map))
                  .withServer(
                    serverId: serverId ?? '',
                    serverName: serverConfig?.name ?? '',
                    serverColor: serverConfig?.colorValue,
                  ),
            )
            .toList();
        if (serverId != null) {
          _perServerArchives[serverId] = archives;
          _archives = _perServerArchives.values
              .expand((items) => items)
              .toList();
        } else {
          _archives = archives;
        }
        _archivesCompleter?.complete(_archives);
        _archivesCompleter = null;
        notifyListeners();
        break;
      case 'archive_history':
        final sid = msg['sid'] as String? ?? '';
        final ts = msg['ts'] as String? ?? '';
        final messages = (msg['messages'] as List? ?? []).cast<dynamic>();
        _archiveHistoryCompleters
            .remove('${serverId ?? ''}_${sid}_$ts')
            ?.complete(messages);
        _archiveHistoryCompleters.remove('${sid}_$ts')?.complete(messages);
        break;
      case 'archive_restored':
        _archiveFeedback.add(
          'Restored "${(msg['session'] as Map?)?['title'] ?? 'session'}"',
        );
        requestSessionList();
        fetchArchives();
        break;
      case 'archive_restore_failed':
        _archiveFeedback.add(
          'Restore failed: ${msg['reason'] ?? 'unknown error'}',
        );
        fetchArchives();
        break;
      case 'archive_deleted':
        _archiveFeedback.add('Archive deleted');
        break;
      case 'context_cleared':
        final clearedId = msg['sessionId'] as String?;
        if (clearedId == _activeSessionId) {
          _messages.clear();
          _todos.clear();
          _currentStreamingMessage = null;
          _lastUsage = null;
        }
        // Refresh session list to show updated preview
        requestSessionList();
        notifyListeners();
        break;
      case 'reminder':
        _handleReminder(msg);
        break;
      case 'scheduled_task_list':
        final tasks = (msg['tasks'] as List? ?? [])
            .map(
              (t) =>
                  Map<String, dynamic>.from(t as Map)
                    ..['_serverId'] = serverId ?? '',
            )
            .toList();
        if (serverId != null) {
          _perServerScheduledTasks[serverId] = tasks;
          _scheduledTasks = _perServerScheduledTasks.values
              .expand((items) => items)
              .toList();
        } else {
          _scheduledTasks = tasks;
        }
        notifyListeners();
        break;
      case 'scheduled_task_update':
        final task = Map<String, dynamic>.from(msg['task'] as Map)
          ..['_serverId'] = serverId ?? '';
        if (serverId != null) {
          final serverTasks = _perServerScheduledTasks.putIfAbsent(
            serverId,
            () => [],
          );
          final idx = serverTasks.indexWhere((t) => t['id'] == task['id']);
          if (idx >= 0) {
            serverTasks[idx] = task;
          } else {
            serverTasks.add(task);
          }
          _scheduledTasks = _perServerScheduledTasks.values
              .expand((items) => items)
              .toList();
        } else {
          final idx = _scheduledTasks.indexWhere((t) => t['id'] == task['id']);
          if (idx >= 0) {
            _scheduledTasks[idx] = task;
          } else {
            _scheduledTasks.add(task);
          }
        }
        notifyListeners();
        break;
      case 'scheduled_task_notification':
        final title = msg['title'] as String? ?? 'Scheduled Task';
        final status = msg['status'] as String? ?? '';
        final isManual = status == 'manual';
        final isLifecycleStart =
            status == 'started' ||
            status == 'running' ||
            (!isManual && title.toLowerCase().contains('started'));
        if (isLifecycleStart) {
          break;
        }
        final body = msg['body'] as String? ?? '';
        final sid = msg['sessionId'] as String? ?? '';
        _notifications.showInstant(
          id: title.hashCode & 0x7FFFFFFF,
          title: title,
          body: body,
          payload: sid.isNotEmpty
              ? 'session:${Uri.encodeComponent(sid)}'
                    '${serverId != null ? ':${Uri.encodeComponent(serverId)}' : ''}'
              : null,
        );
        break;
      case 'upload_complete':
        final uploadId = msg['uploadId'] as String?;
        final serverPath = msg['serverPath'] as String?;
        if (uploadId == _pendingUploadId && serverPath != null) {
          _uploadCompleter?.complete(serverPath);
          _uploadCompleter = null;
        }
        if (uploadId != null) {
          _uploadStates.remove(uploadId)?.dispose();
        }
        break;
      case 'upload_progress':
        {
          final uploadId = msg['uploadId'] as String?;
          final received = (msg['bytesReceived'] as num?)?.toInt() ?? 0;
          final total = (msg['totalBytes'] as num?)?.toInt() ?? 0;
          final receivedChunks = (msg['receivedChunks'] as num?)?.toInt() ?? 0;
          if (uploadId == null || total <= 0) break;
          final state = _uploadStates[uploadId];
          if (state != null) {
            debugPrint(
              '[Upload] ack: chunks=$receivedChunks bytes=$received/$total',
            );
            state.target.uploadProgress = (received / total).clamp(0.0, 1.0);
            state.noteAck(receivedChunks);
            notifyListeners();
          }
          break;
        }
      case 'compact_boundary':
        _currentStreamingMessage = null;
        final trigger = msg['trigger'] as String? ?? 'auto';
        final preTokens = (msg['preTokens'] as num?)?.toInt() ?? 0;
        _messages.add(
          ChatMessage.compactBoundary(trigger: trigger, preTokens: preTokens),
        );
        notifyListeners();
        break;
      case 'bash_backgrounded':
        _handleBashBackgrounded(msg);
        break;
      case 'task_notification':
        _handleTaskNotification(msg);
        break;
      case 'session_forked':
        final newId = msg['newSessionId'] as String?;
        if (newId != null && newId.isNotEmpty) {
          _activeSessionId = newId;
          notifyListeners();
          requestSessionList();
        }
        break;
      case 'outlook_auth':
        _handleOutlookAuth(msg);
        break;
      case 'ibs_auth':
        _handleIBSAuth(msg);
        break;
      case 'ibs_auth_result':
        _handleIBSAuthResult(msg);
        break;
      case 'outlook_auth_result':
        _handleOutlookAuthResult(msg);
        break;
      case 'tool_summary':
        _handleToolSummary(msg);
        break;
      case 'session_init':
        _handleSessionInit(msg);
        break;
      case 'supported_models':
        _handleSupportedModels(msg);
        break;
      case 'mcp_status':
        _handleMcpStatus(msg);
        break;
      case 'elicitation_url':
        _handleElicitationUrl(msg);
        break;
      case 'monitor_started':
        _handleMonitorStarted(msg);
        break;
      case 'monitor_output':
        _handleMonitorOutput(msg);
        break;
      case 'files_persisted':
        // Log but don't surface to user — file persistence is server-internal
        break;
      case 'auth_status':
        _handleAuthStatus(msg);
        break;
      case 'rewind_result':
        _handleRewindResult(msg);
        break;
      case 'rewind_conversation_result':
        _handleRewindConversationResult(msg);
        break;
      case 'branch_result':
        _handleBranchResult(msg);
        break;
      case 'user_message_uuid':
        _handleUserMessageUuid(msg);
        break;
      case 'question_answered':
        final answeredQId = msg['questionId'] as String? ?? '';
        if (answeredQId.isNotEmpty) {
          final idx = _messages.indexWhere(
            (m) =>
                m.questionId == answeredQId && m.type == MessageType.question,
          );
          if (idx >= 0) {
            _messages[idx].answered = true;
            notifyListeners();
          }
        }
        break;
      case 'subscription_required':
        _subscriptionActive = false;
        _subscriptionChecked = true;
        _subscriptionRequiredController.add(null);
        notifyListeners();
        break;
    }
  }

  void _handleOutlookAuth(Map<String, dynamic> msg) {
    _currentStreamingMessage = null;
    final authRequestId = msg['authRequestId'] as String? ?? '';
    if (authRequestId.isEmpty) return;

    _messages.add(ChatMessage.outlookAuth(authRequestId: authRequestId));
    notifyListeners();
  }

  /// Submit outlook auth tokens as an answer (reuses the answer WebSocket flow)
  void submitOutlookAuth(String authRequestId, Map<String, String> answers) {
    // Mark the card as completed
    final idx = _messages.indexWhere(
      (m) =>
          m.type == MessageType.outlookAuth && m.authRequestId == authRequestId,
    );
    if (idx >= 0) {
      _messages[idx].answered = true;
    }
    _ws.sendAnswer(authRequestId, answers);
    notifyListeners();
  }

  void _handleOutlookAuthResult(Map<String, dynamic> msg) {
    final success = msg['success'] as bool? ?? false;
    final message =
        msg['message'] as String? ??
        (success ? 'Outlook auth completed' : 'Outlook auth failed');
    _messages.add(
      ChatMessage(
        id: 'outlook_auth_result_${DateTime.now().microsecondsSinceEpoch}',
        sender: MessageSender.system,
        type: MessageType.taskNotification,
        timestamp: DateTime.now(),
        textContent: message,
        toolName: success ? 'outlook_auth_success' : 'outlook_auth_failure',
      ),
    );
    notifyListeners();
  }

  void _handleElicitationUrl(Map<String, dynamic> msg) {
    _currentStreamingMessage = null;
    final questionId = msg['questionId'] as String? ?? '';
    final mcpServerName = msg['mcpServerName'] as String? ?? 'MCP Server';
    final message = msg['message'] as String? ?? '';
    final url = msg['url'] as String? ?? '';
    if (questionId.isEmpty || url.isEmpty) return;

    _messages.add(
      ChatMessage.elicitationUrl(
        questionId: questionId,
        mcpServerName: mcpServerName,
        message: message,
        url: url,
      ),
    );
    notifyListeners();
  }

  void _handleIBSAuth(Map<String, dynamic> msg) {
    _currentStreamingMessage = null;
    final authRequestId = msg['authRequestId'] as String? ?? '';
    if (authRequestId.isEmpty) return;

    _messages.add(ChatMessage.ibsAuth(authRequestId: authRequestId));
    notifyListeners();
  }

  /// Submit IBS auth cookies as an answer (reuses the answer WebSocket flow)
  void submitIBSAuth(String authRequestId, Map<String, String> answers) {
    // Mark the card as completed
    final idx = _messages.indexWhere(
      (m) => m.type == MessageType.ibsAuth && m.authRequestId == authRequestId,
    );
    if (idx >= 0) {
      _messages[idx].answered = true;
    }
    _ws.sendAnswer(authRequestId, answers);
    notifyListeners();
  }

  void _handleIBSAuthResult(Map<String, dynamic> msg) {
    final success = msg['success'] as bool? ?? false;
    final message =
        msg['message'] as String? ??
        (success ? 'IBS auth completed' : 'IBS auth failed');
    _messages.add(
      ChatMessage(
        id: 'ibs_auth_result_${DateTime.now().microsecondsSinceEpoch}',
        sender: MessageSender.system,
        type: MessageType.taskNotification,
        timestamp: DateTime.now(),
        textContent: message,
        toolName: success ? 'ibs_auth_success' : 'ibs_auth_failure',
      ),
    );
    notifyListeners();
  }

  // Regex to match <task-notification>...</task-notification> blocks
  static final _taskNotifRegex = RegExp(
    r'<task-notification>\s*'
    r'<task-id>(.*?)</task-id>\s*'
    r'<output-file>(.*?)</output-file>\s*'
    r'<status>(.*?)</status>\s*'
    r'<summary>(.*?)</summary>\s*'
    r'</task-notification>',
    dotAll: true,
  );
  // Regex to match system-injected XML blocks that should not appear in chat
  static final _systemReminderRegex = RegExp(
    r'<system-reminder>.*?</system-reminder>'
    r'|<local-command-caveat>.*?</local-command-caveat>'
    r'|<command-name>.*?</command-name>'
    r'|<command-message>.*?</command-message>'
    r'|<command-args>.*?</command-args>'
    r'|<local-command-stdout>.*?</local-command-stdout>',
    dotAll: true,
  );

  void _handleTextMessage(Map<String, dynamic> msg) {
    _closeThinkingMessage();
    _processingSetAt = null; // server confirmed processing
    final content = msg['content'] as String? ?? '';

    if (_currentStreamingMessage == null ||
        _currentStreamingMessage!.type != MessageType.text ||
        _currentStreamingMessage!.sender != MessageSender.assistant) {
      _currentStreamingMessage = ChatMessage.assistantText(
        msg['sessionId'] ?? '',
      );
      // Forward SDK hierarchy fields
      _currentStreamingMessage!.parentToolUseId =
          msg['parentToolUseId'] as String?;
      _currentStreamingMessage!.uuid = msg['uuid'] as String?;
      // Don't add to _messages yet — wait until there's visible content
    }

    _currentStreamingMessage!.textContent += content;

    // Extract task notifications and create notification messages
    final rawText = _currentStreamingMessage!.textContent;
    final notifMatches = _taskNotifRegex.allMatches(rawText).toList();
    if (notifMatches.isNotEmpty) {
      var cleaned = rawText;
      for (final match in notifMatches) {
        cleaned = cleaned.replaceFirst(match.group(0)!, '');
        final taskId = match.group(1)?.trim() ?? '';
        final status = match.group(3)?.trim() ?? '';
        final summary = match.group(4)?.trim() ?? '';
        // Add as a system notification message (avoid duplicates)
        final notifId = 'task_notif_$taskId';
        if (!_messages.any((m) => m.id == notifId)) {
          _messages.add(
            ChatMessage(
              id: notifId,
              sender: MessageSender.system,
              type: MessageType.taskNotification,
              timestamp: DateTime.now(),
              textContent: summary,
              toolName: status, // reuse toolName to store status
            ),
          );
        }
      }
      _currentStreamingMessage!.textContent = cleaned;
    }

    // Strip system-reminder blocks
    _currentStreamingMessage!.textContent = _currentStreamingMessage!
        .textContent
        .replaceAll(_systemReminderRegex, '');

    // Only add to the message list once there's visible content
    if (_currentStreamingMessage!.textContent.trim().isNotEmpty &&
        !_messages.contains(_currentStreamingMessage)) {
      _messages.add(_currentStreamingMessage!);
    }

    notifyListeners();
  }

  void _closeThinkingMessage() {
    if (_currentThinkingMessage != null) {
      _currentThinkingMessage!.toolStreaming = false;
      _currentThinkingMessage = null;
    }
  }

  void _handleThinkingMessage(Map<String, dynamic> msg) {
    _processingSetAt = null; // server confirmed processing
    final content = msg['content'] as String? ?? '';
    if (_currentThinkingMessage == null) {
      _currentThinkingMessage = ChatMessage.thinking();
      _currentThinkingMessage!.parentToolUseId =
          msg['parentToolUseId'] as String?;
      _currentThinkingMessage!.uuid = msg['uuid'] as String?;
      _messages.add(_currentThinkingMessage!);
    }
    _currentThinkingMessage!.textContent += content;
    _currentThinkingMessage!.toolStreaming = true;
    notifyListeners();
  }

  void _handleToolCall(Map<String, dynamic> msg) {
    _currentStreamingMessage = null;
    _closeThinkingMessage();
    _processingSetAt = null; // server confirmed processing

    final rawTool = msg['tool'] ?? 'Unknown';
    final tool = (rawTool as String).replaceFirst('mcp__app__', '');
    final input = Map<String, dynamic>.from(
      (msg['input'] as Map<String, dynamic>?) ?? {},
    );

    // Enrich TaskOutput with the original task's description
    if (tool == 'TaskOutput') {
      final taskId = input['task_id'] as String?;
      if (taskId != null) {
        // Find the original backgrounded Bash command by matching task_id in output
        for (final m in _messages.reversed) {
          if (m.type == MessageType.toolCall &&
              m.isBackgrounded &&
              m.toolUseId == taskId) {
            final desc = m.toolInput?['description'] as String?;
            if (desc != null) input['_taskDescription'] = desc;
            break;
          }
        }
      }
    }

    final toolUseId = msg['toolUseId'] as String? ?? '';
    final toolMsg = ChatMessage.toolCall(
      tool: tool,
      input: input,
      toolUseId: toolUseId,
    );
    toolMsg.toolStreaming = true; // tool is actively running
    toolMsg.parentToolUseId = msg['parentToolUseId'] as String?;
    toolMsg.uuid = msg['uuid'] as String?;
    _messages.add(toolMsg);

    // Track Task/Agent tool calls as subagent tasks
    if (tool == 'Task' || tool == 'Agent') {
      final desc = input['description'] as String? ?? 'Sub agent task';
      _subagentTasks[toolUseId] = {
        'description': desc,
        'prompt': input['prompt'] as String? ?? '',
        'subagentType': input['subagent_type'] as String? ?? '',
        'status': 'running',
        'toolUseId': toolUseId,
      };
    }
    notifyListeners();
  }

  void _handleToolResult(Map<String, dynamic> msg) {
    final toolUseId = msg['toolUseId'] as String? ?? '';
    final output = msg['output'] as String? ?? '';

    // Skip TodoWrite boilerplate results
    if (output.startsWith('Todos have been modified successfully')) return;

    final toolCallIdx = _messages.lastIndexWhere(
      (m) => m.type == MessageType.toolCall && m.toolUseId == toolUseId,
    );

    if (toolCallIdx >= 0) {
      // Don't overwrite streamed output for backgrounded bash commands
      if (_messages[toolCallIdx].isBackgrounded) {
        // Keep existing streamed output, keep streaming
        return;
      }
      _messages[toolCallIdx].toolOutput = output;
      _messages[toolCallIdx].toolStreaming = false;

      // Mark subagent task as completed
      if (_subagentTasks.containsKey(toolUseId)) {
        _subagentTasks[toolUseId]!['status'] = 'completed';
      }
    } else if (output.trim().isNotEmpty) {
      _messages.add(
        ChatMessage.toolResult(toolUseId: toolUseId, output: output),
      );
    }
    notifyListeners();
  }

  /// Handle streaming tool result chunk (progressive output rendering)
  void _handleToolResultChunk(Map<String, dynamic> msg) {
    final toolUseId = msg['toolUseId'] as String? ?? '';
    final content = msg['content'] as String? ?? '';
    final done = msg['done'] == true;
    final chunkIndex = msg['chunkIndex'] as int? ?? 0;

    final toolCallIdx = _messages.lastIndexWhere(
      (m) => m.type == MessageType.toolCall && m.toolUseId == toolUseId,
    );

    if (toolCallIdx >= 0) {
      if (_messages[toolCallIdx].isBackgrounded) return;
      // First chunk: clear any stderr output that accumulated while tool was running
      if (chunkIndex == 0) {
        _messages[toolCallIdx].toolOutput = '';
      }
      _messages[toolCallIdx].toolOutput =
          (_messages[toolCallIdx].toolOutput ?? '') + content;
      _messages[toolCallIdx].toolStreaming = !done;

      // Mark subagent task as completed when final chunk arrives
      if (done && _subagentTasks.containsKey(toolUseId)) {
        _subagentTasks[toolUseId]!['status'] = 'completed';
      }
    }
    notifyListeners();
  }

  /// Handle tool_image — attach inline image data to matching tool_call message
  void _handleToolImage(Map<String, dynamic> msg) {
    final toolUseId = msg['toolUseId'] as String? ?? '';
    final imageData = msg['imageData'] as String? ?? '';
    final mimeType = msg['mimeType'] as String? ?? 'image/png';
    final filePath = msg['filePath'] as String? ?? '';

    if (imageData.isEmpty) return;

    final idx = _messages.lastIndexWhere(
      (m) => m.type == MessageType.toolCall && m.toolUseId == toolUseId,
    );
    if (idx >= 0) {
      _messages[idx].toolImageData = imageData;
      _messages[idx].toolImageMimeType = mimeType;
      _messages[idx].toolImageFilePath = filePath;
      notifyListeners();
    }
  }

  void _handleCodexPlan(Map<String, dynamic> msg) {
    final turnId = msg['turnId'] as String? ?? '';
    final explanation = msg['explanation'] as String? ?? '';
    final rawSteps = msg['plan'] as List? ?? const [];
    final steps = rawSteps
        .whereType<Map>()
        .map((step) => Map<String, dynamic>.from(step))
        .toList();
    if (steps.isEmpty && explanation.trim().isEmpty) return;

    final planMessage = ChatMessage.codexPlan(
      turnId: turnId,
      explanation: explanation,
      steps: steps,
    );
    final idx = _messages.lastIndexWhere(
      (m) => m.type == MessageType.codexPlan && m.toolUseId == turnId,
    );
    if (idx >= 0) {
      _messages[idx] = planMessage;
    } else {
      _messages.add(planMessage);
    }
    notifyListeners();
  }

  /// Handle tool progress (elapsed time while tool runs)
  void _handleToolProgress(Map<String, dynamic> msg) {
    final toolUseId = msg['toolUseId'] as String? ?? '';
    final elapsed = (msg['elapsedSeconds'] as num?)?.toDouble() ?? 0.0;

    final toolCallIdx = _messages.lastIndexWhere(
      (m) => m.type == MessageType.toolCall && m.toolUseId == toolUseId,
    );

    if (toolCallIdx >= 0) {
      _messages[toolCallIdx].toolElapsedSeconds = elapsed;
      // Ensure tool is marked as streaming (defensive fix for reconnects)
      if (!_messages[toolCallIdx].toolStreaming) {
        _messages[toolCallIdx].toolStreaming = true;
      }
      notifyListeners();
    }
  }

  /// Handle streaming bash output — append to the targeted or most recent running tool card
  void _handleToolStderr(Map<String, dynamic> msg) {
    final content = msg['content'] as String? ?? '';
    if (content.isEmpty) return;
    final targetToolUseId = msg['toolUseId'] as String?;

    // If toolUseId specified, route directly to that card (background tasks)
    if (targetToolUseId != null && targetToolUseId.isNotEmpty) {
      for (int i = _messages.length - 1; i >= 0; i--) {
        final m = _messages[i];
        if (m.type == MessageType.toolCall && m.toolUseId == targetToolUseId) {
          m.toolOutput = (m.toolOutput ?? '') + content;
          m.toolStreaming = true;
          notifyListeners();
          return;
        }
      }
    }

    // Find the most recent tool_call that is still streaming (no tool_result yet)
    for (int i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.type == MessageType.toolCall) {
        // Check if a tool_result exists for this tool call
        final hasResult = _messages.any(
          (r) => r.type == MessageType.toolResult && r.toolUseId == m.toolUseId,
        );
        if (!hasResult) {
          m.toolOutput = (m.toolOutput ?? '') + content;
          m.toolStreaming = true;
          notifyListeners();
          return;
        }
      }
    }
  }

  /// Handle bash command moved to background (timeout)
  void _handleBashBackgrounded(Map<String, dynamic> msg) {
    final toolUseId = msg['toolUseId'] as String? ?? '';
    final taskId = msg['taskId'] as String? ?? '';

    // Find the tool card and extract command info, then mark as backgrounded
    String summary = 'Bash command (backgrounded)';
    for (int i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.type == MessageType.toolCall && m.toolUseId == toolUseId) {
        m.isBackgrounded = true;
        m.backgroundTaskId = taskId;
        m.toolStreaming = true; // keep streaming
        // Pull description or command for the pane summary
        final desc = m.toolInput?['description'] as String?;
        final cmd = m.toolInput?['command'] as String?;
        if (desc != null && desc.isNotEmpty) {
          summary = desc;
        } else if (cmd != null && cmd.isNotEmpty) {
          // Take first segment before && or ;
          summary = cmd.split(RegExp(r'\s*&&\s*|\s*;\s*')).first;
        }
        break;
      }
    }

    // Add to background tasks bar
    _backgroundTasks[taskId] = {
      'status': 'running',
      'summary': summary,
      'originToolUseId': toolUseId,
    };
    notifyListeners();
  }

  void _handleQuestion(Map<String, dynamic> msg) {
    _currentStreamingMessage = null;

    final questionId = msg['questionId'] as String? ?? '';

    // Deduplicate: if this question already exists (e.g. restored from history,
    // then re-sent by server on reconnect), just ensure it's marked unanswered
    final existingIdx = _messages.indexWhere(
      (m) => m.questionId == questionId && m.type == MessageType.question,
    );
    if (existingIdx >= 0) {
      _messages[existingIdx].answered = false;
      notifyListeners();
      return;
    }

    final rawQuestions = msg['questions'] as List? ?? [];
    final questions = rawQuestions
        .map((q) => QuestionItem.fromJson(q as Map<String, dynamic>))
        .toList();

    // Extract email preview if present
    Map<String, String>? emailPreview;
    if (msg['emailPreview'] != null) {
      final ep = msg['emailPreview'] as Map<String, dynamic>;
      emailPreview = {
        'to': ep['to'] as String? ?? '',
        'subject': ep['subject'] as String? ?? '',
        'body': ep['body'] as String? ?? '',
        if (ep['cc'] != null) 'cc': ep['cc'] as String,
        if (ep['attachment'] != null) 'attachment': ep['attachment'] as String,
        if (ep['scheduledTime'] != null)
          'scheduledTime': ep['scheduledTime'] as String,
      };
    }

    _messages.add(
      ChatMessage.question(
        questionId: questionId,
        questions: questions,
        emailPreview: emailPreview,
      ),
    );
    // Use the first question's text as notification body
    String questionBody = 'Your agent needs your input';
    if (questions.isNotEmpty) {
      final qText = questions[0].question;
      if (qText.isNotEmpty) {
        questionBody = qText.length > 200
            ? '${qText.substring(0, 200)}...'
            : qText;
      }
    }
    _maybeNotify(title: _sessionTitle(), body: questionBody);
    notifyListeners();
  }

  void _handleResult(Map<String, dynamic> msg) {
    _currentStreamingMessage = null;
    _closeThinkingMessage();
    _isProcessing = false;
    _isCompacting = false;
    _isRateLimited = false;
    _isRetrying = false;
    // Upload-only pending bubbles can settle on result. Queued injection
    // bubbles wait for injection_ack so they can still be pulled back before
    // the server actually starts that queued turn.
    for (final m in _messages) {
      if (m.isPending && m.injectionPriority == null) {
        m.isPending = false;
      }
    }
    // Use the last assistant text message as notification body
    String notifBody = 'Query complete';
    for (int i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.type == MessageType.text && m.sender == MessageSender.assistant) {
        final text = m.textContent.trim();
        if (text.isNotEmpty) {
          notifBody = text.length > 200 ? '${text.substring(0, 200)}...' : text;
          break;
        }
      }
    }
    _maybeNotify(title: _sessionTitle(), body: notifBody);
    if (msg['usage'] != null) {
      _lastUsage = Map<String, dynamic>.from(msg['usage'] as Map);
      _lastUsage!['costUsd'] = msg['costUsd'];
      _lastUsage!['numTurns'] = msg['numTurns'];
      if (msg['stopReason'] != null)
        _lastUsage!['stopReason'] = msg['stopReason'];
      if (msg['resultSubtype'] != null)
        _lastUsage!['resultSubtype'] = msg['resultSubtype'];
      if (msg['errors'] != null) _lastUsage!['errors'] = msg['errors'];
      if (msg['durationApiMs'] != null)
        _lastUsage!['durationApiMs'] = msg['durationApiMs'];
      if (msg['permissionDenials'] != null)
        _lastUsage!['permissionDenials'] = msg['permissionDenials'];
      if (msg['totalUsage'] != null)
        _lastUsage!['totalUsage'] = Map<String, dynamic>.from(
          msg['totalUsage'] as Map,
        );
    }
    // Show error message for failed queries
    final subtype = msg['resultSubtype'] as String?;
    if (subtype != null && subtype.startsWith('error_')) {
      final errors = (msg['errors'] as List?)?.cast<String>() ?? [];
      final errorText = errors.isNotEmpty
          ? errors.join('\n')
          : subtype.replaceAll('_', ' ');
      _messages.add(ChatMessage.error(errorText));
    }
    // Mark any tool calls that never got a result so spinners stop
    for (final m in _messages) {
      if (m.type == MessageType.toolCall) {
        if (m.toolOutput == null) m.toolOutput = '';
        m.toolStreaming = false;
      }
    }
    // Clear completed background tasks
    _backgroundTasks.removeWhere(
      (_, t) =>
          t['status'] == 'completed' ||
          t['status'] == 'failed' ||
          t['status'] == 'stopped',
    );
    // Mark any still-running subagents as completed (query is done)
    for (final entry in _subagentTasks.values) {
      if (entry['status'] == 'running') entry['status'] = 'completed';
    }
    notifyListeners();
  }

  void _handleSubagentResult(Map<String, dynamic> msg) {
    final parentToolUseId = msg['parentToolUseId'] as String? ?? '';
    // Mark the subagent task as completed
    if (_subagentTasks.containsKey(parentToolUseId)) {
      _subagentTasks[parentToolUseId]!['status'] = 'completed';
      if (msg['durationMs'] != null) {
        _subagentTasks[parentToolUseId]!['durationMs'] = msg['durationMs'];
      }
      if (msg['numTurns'] != null) {
        _subagentTasks[parentToolUseId]!['numTurns'] = msg['numTurns'];
      }
    }
    notifyListeners();
  }

  /// Handle active_subagents message sent on session resume.
  /// Creates synthetic Task tool_call messages and subagent tracking entries
  /// for subagents that are currently running but whose start may not be in
  /// the loaded history page.
  void _handleActiveSubagents(Map<String, dynamic> msg) {
    final tasks = msg['tasks'] as List<dynamic>? ?? [];
    for (final task in tasks) {
      final t = task as Map<String, dynamic>;
      final toolUseId = t['toolUseId'] as String? ?? '';
      final description = t['description'] as String? ?? 'Sub agent task';
      final subagentType = t['subagentType'] as String? ?? '';
      if (toolUseId.isEmpty) continue;

      // Add to subagent tracking if not already there
      if (!_subagentTasks.containsKey(toolUseId)) {
        _subagentTasks[toolUseId] = {
          'description': description,
          'prompt': '',
          'subagentType': subagentType,
          'status': 'running',
          'toolUseId': toolUseId,
        };
      }

      // If the Task tool_call message isn't in _messages, create a synthetic one
      final hasToolCall = _messages.any(
        (m) => m.type == MessageType.toolCall && m.toolUseId == toolUseId,
      );
      if (!hasToolCall) {
        final syntheticMsg = ChatMessage.toolCall(
          tool: 'Agent',
          input: {'description': description, 'subagent_type': subagentType},
          toolUseId: toolUseId,
        );
        syntheticMsg.toolStreaming = true;
        _messages.add(syntheticMsg);
      }
    }
    if (tasks.isNotEmpty) notifyListeners();
  }

  Future<void> _handleReminder(Map<String, dynamic> msg) async {
    final title = msg['title'] as String? ?? 'Reminder';
    final body = msg['body'] as String? ?? '';
    final scheduledTimeStr = msg['scheduledTime'] as String? ?? '';
    final notificationId = msg['notificationId'] as int? ?? 0;

    final scheduledTime = DateTime.tryParse(scheduledTimeStr);
    if (scheduledTime == null) {
      debugPrint('[Reminder] Invalid scheduled time: $scheduledTimeStr');
      return;
    }

    await _notifications.scheduleReminder(
      id: notificationId,
      title: title,
      body: body,
      scheduledTime: scheduledTime,
    );
  }

  void _handleTaskNotification(Map<String, dynamic> msg) {
    final taskId = msg['taskId'] as String? ?? '';
    final status = msg['status'] as String? ?? 'completed';
    final summary = msg['summary'] as String? ?? '';
    final outputFile = msg['outputFile'] as String?;
    final originToolUseId = msg['originToolUseId'] as String?;

    // Update background tasks map
    if (status == 'completed' || status == 'failed' || status == 'stopped') {
      _backgroundTasks.remove(taskId);
      // Also remove by originToolUseId (started uses toolUseId, completed uses agentId)
      if (originToolUseId != null) {
        _backgroundTasks.remove(originToolUseId);
      }
      // Stop streaming on any backgrounded tool card associated with this task
      for (final m in _messages) {
        if (m.isBackgrounded &&
            (m.backgroundTaskId == taskId ||
                (originToolUseId != null && m.toolUseId == originToolUseId))) {
          m.toolStreaming = false;
        }
      }
    } else {
      // For "started" notifications, try to find the originating tool card for better info
      String enrichedSummary = summary;
      String? resolvedOriginToolUseId = originToolUseId;
      if (resolvedOriginToolUseId == null) {
        // The taskId might be the toolUseId of the Bash call
        for (final m in _messages.reversed) {
          if (m.type == MessageType.toolCall && m.toolUseId == taskId) {
            resolvedOriginToolUseId = taskId;
            final desc = m.toolInput?['description'] as String?;
            final cmd = m.toolInput?['command'] as String?;
            if (desc != null && desc.isNotEmpty) {
              enrichedSummary = desc;
            } else if (cmd != null && cmd.isNotEmpty) {
              enrichedSummary = cmd.split(RegExp(r'\s*&&\s*|\s*;\s*')).first;
            }
            break;
          }
        }
      }
      _backgroundTasks[taskId] = {
        'status': status,
        'summary': enrichedSummary,
        'outputFile': outputFile,
        if (resolvedOriginToolUseId != null)
          'originToolUseId': resolvedOriginToolUseId,
      };
    }

    // Add a notification card to chat log
    final notifId = 'task_notif_${DateTime.now().microsecondsSinceEpoch}';
    final notifMsg = ChatMessage(
      id: notifId,
      sender: MessageSender.system,
      type: MessageType.taskNotification,
      timestamp: DateTime.now(),
      textContent: summary,
      toolName: status,
      toolOutput: outputFile,
      toolUseId: taskId,
    );
    // Link to original bash card so completion card can show its content
    notifMsg.parentToolUseId = originToolUseId;
    _messages.add(notifMsg);
    notifyListeners();
  }

  void _handleMonitorStarted(Map<String, dynamic> msg) {
    final taskId = msg['taskId'] as String? ?? '';
    final description = msg['description'] as String? ?? 'Monitored process';
    final monitoring = msg['monitoring'] as bool? ?? false;

    if (monitoring) {
      // Add or update in background tasks
      _backgroundTasks[taskId] = {
        ..._backgroundTasks[taskId] ?? {},
        'status': 'running',
        'summary': description,
        'isMonitor': true,
      };
    } else {
      // Monitoring stopped — remove from background tasks
      _backgroundTasks.remove(taskId);
    }
    notifyListeners();
  }

  void _handleMonitorOutput(Map<String, dynamic> msg) {
    final taskId = msg['taskId'] as String? ?? '';
    final content = msg['content'] as String? ?? '';
    if (content.isEmpty) return;

    // Find existing monitor output card for this taskId and append, or create new one
    final desc = _backgroundTasks[taskId]?['summary'] as String? ?? 'Monitor';
    ChatMessage? existing;
    for (int i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.type == MessageType.monitorOutput && m.toolUseId == taskId) {
        existing = m;
        break;
      }
    }

    if (existing != null) {
      // Append new output to existing card
      existing.toolOutput = (existing.toolOutput ?? '') + '\n' + content;
      existing.textContent = desc;
    } else {
      // Create a new monitor output card
      _messages.add(
        ChatMessage(
          id: 'monitor_${taskId}_${DateTime.now().microsecondsSinceEpoch}',
          sender: MessageSender.system,
          type: MessageType.monitorOutput,
          timestamp: DateTime.now(),
          textContent: desc,
          toolUseId: taskId,
          toolOutput: content,
        ),
      );
    }
    notifyListeners();
  }

  void _handleToolSummary(Map<String, dynamic> msg) {
    _currentStreamingMessage = null;
    _closeThinkingMessage();
    final summary = msg['summary'] as String? ?? '';
    final precedingIds =
        (msg['precedingToolUseIds'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        [];
    final parentToolUseId = msg['parentToolUseId'] as String?;
    final uuid = msg['uuid'] as String?;
    _messages.add(
      ChatMessage.toolSummary(
        summary: summary,
        precedingToolUseIds: precedingIds,
        parentToolUseId: parentToolUseId,
        uuid: uuid,
      ),
    );
    notifyListeners();
  }

  void _handleSessionInit(Map<String, dynamic> msg) {
    _sessionModel = msg['model'] as String?;
    // Track permission mode for UI theming (plan mode)
    final perm = msg['permissionMode'] as String?;
    if (perm != null) {
      _permissionMode = perm;
    }
    // Capture available tools list for the blocked tools picker
    final tools = msg['tools'] as List?;
    if (tools != null) {
      _availableTools =
          tools
              .map((t) {
                if (t is Map) return t['name']?.toString() ?? t.toString();
                return t.toString();
              })
              .where((n) => n.isNotEmpty)
              .toList()
            ..sort();
    }
    notifyListeners();
  }

  void _handleSupportedModels(Map<String, dynamic> msg) {
    final models = msg['models'] as List?;
    if (models != null) {
      _supportedModels = models
          .map(
            (m) => m is Map
                ? Map<String, dynamic>.from(m)
                : <String, dynamic>{'id': m.toString()},
          )
          .toList();
      notifyListeners();
    }
  }

  void _handleMcpStatus(Map<String, dynamic> msg) {
    final servers = msg['servers'] as List?;
    if (servers != null) {
      _mcpServers = servers
          .map((s) => Map<String, dynamic>.from(s as Map))
          .toList();
      notifyListeners();
    }
  }

  void _handleAuthStatus(Map<String, dynamic> msg) {
    final isAuthenticating = msg['isAuthenticating'] == true;
    final output = (msg['output'] as List?)?.cast<String>() ?? [];
    final error = msg['error'] as String?;

    // Extract URL from output lines
    String? url;
    for (final line in output) {
      final match = RegExp(r'https?://\S+').firstMatch(line);
      if (match != null) {
        url = match.group(0);
        break;
      }
    }

    if (url != null) {
      // Show the login URL as a tappable text message
      _messages.add(
        ChatMessage(
          id: 'auth_status_${DateTime.now().microsecondsSinceEpoch}',
          sender: MessageSender.assistant,
          type: MessageType.text,
          timestamp: DateTime.now(),
          textContent:
              'Claude login required. Open this link to authenticate:\n\n$url',
        ),
      );
    } else if (isAuthenticating) {
      _messages.add(
        ChatMessage(
          id: 'auth_status_${DateTime.now().microsecondsSinceEpoch}',
          sender: MessageSender.system,
          type: MessageType.taskNotification,
          timestamp: DateTime.now(),
          textContent: error ?? 'Authenticating with Claude...',
          toolName: error != null ? 'failed' : 'info',
        ),
      );
    }
    notifyListeners();
  }

  void _handleRewindResult(Map<String, dynamic> msg) {
    final success = msg['success'] == true;
    final filesChanged = (msg['filesChanged'] as List?)?.length ?? 0;
    final error = msg['error'] as String?;
    final text = success
        ? 'Reverted $filesChanged file${filesChanged != 1 ? 's' : ''}'
        : 'Rewind failed: ${error ?? 'unknown error'}';
    _messages.add(
      ChatMessage(
        id: 'rewind_${DateTime.now().microsecondsSinceEpoch}',
        sender: MessageSender.system,
        type: MessageType.taskNotification,
        timestamp: DateTime.now(),
        textContent: text,
        toolName: success ? 'success' : 'failed',
      ),
    );
    notifyListeners();
  }

  void setModel(String? model) {
    _ws.sendSetModel(model);
    if (model != null) _sessionModel = model;
    notifyListeners();
  }

  void setPermissionMode(String mode) {
    _ws.sendSetPermissionMode(mode);
    if (_permissionMode != mode) {
      _permissionMode = mode;
      _messages.add(_permissionModeMessage(mode));
    } else {
      _permissionMode = mode;
    }
    notifyListeners();
  }

  ChatMessage _permissionModeMessage(String mode) {
    return ChatMessage(
      id: 'permission_${DateTime.now().microsecondsSinceEpoch}',
      sender: MessageSender.system,
      type: MessageType.taskNotification,
      timestamp: DateTime.now(),
      textContent: 'Permission mode changed to ${_permissionModeLabel(mode)}',
      toolName: 'permission_mode',
    );
  }

  String _permissionModeLabel(String mode) {
    switch (mode) {
      case 'superYolo':
        return 'Super Yolo';
      case 'bypassPermissions':
        return 'Yolo';
      case 'default':
        return 'Ask';
      case 'auto':
        return 'Smart Auto';
      case 'acceptEdits':
        return 'Auto-Edit';
      case 'plan':
        return 'Plan';
      default:
        return mode;
    }
  }

  void requestMcpStatus() {
    _ws.sendMcpStatus();
  }

  void reconnectMcpServer(String serverName) {
    _ws.sendMcpReconnect(serverName);
  }

  void toggleMcpServer(String serverName, bool enabled) {
    _ws.sendMcpToggle(serverName, enabled);
  }

  void rewindToMessage(String uuid) {
    _ws.sendRewind(uuid);
  }

  void rewindConversation(String uuid, {bool rewindFiles = true}) {
    _ws.sendRewindConversation(uuid, rewindFiles: rewindFiles);
  }

  void branchFromMessage(String uuid) {
    final sessionId = _activeSessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    _ws.sendBranchFromMessage(sessionId, uuid);
  }

  void _handleRewindConversationResult(Map<String, dynamic> msg) {
    final success = msg['success'] == true;
    final dryRun = msg['dryRun'] == true;
    final error = msg['error'] as String?;
    final messagesRemoved = (msg['messagesRemoved'] as num?)?.toInt() ?? 0;

    if (dryRun) return; // dry-run previews are not shown as messages

    if (success) {
      // Truncate local messages at the rewind point
      final uuid = msg['userMessageUuid'] as String?;
      if (uuid != null) {
        final idx = _messages.indexWhere((m) => m.uuid == uuid);
        if (idx >= 0) {
          _messages.removeRange(idx + 1, _messages.length);
        }
      }
      _isProcessing = false;
      _currentStreamingMessage = null;
      _messages.add(
        ChatMessage(
          id: 'rewind_conv_${DateTime.now().microsecondsSinceEpoch}',
          sender: MessageSender.system,
          type: MessageType.taskNotification,
          timestamp: DateTime.now(),
          textContent:
              'Conversation rewound ($messagesRemoved messages removed)',
          toolName: 'success',
        ),
      );
    } else {
      _messages.add(
        ChatMessage(
          id: 'rewind_conv_${DateTime.now().microsecondsSinceEpoch}',
          sender: MessageSender.system,
          type: MessageType.taskNotification,
          timestamp: DateTime.now(),
          textContent:
              'Conversation rewind failed: ${error ?? 'unknown error'}',
          toolName: 'failed',
        ),
      );
    }
    notifyListeners();
  }

  void _handleBranchResult(Map<String, dynamic> msg) {
    final success = msg['success'] == true;
    final newSessionId = msg['newSessionId'] as String?;
    final error = msg['error'] as String?;

    if (success && newSessionId != null && newSessionId.isNotEmpty) {
      _activeSessionId = newSessionId;
      _isProcessing = false;
      _currentStreamingMessage = null;
      notifyListeners();
      requestSessionList();
    } else {
      _messages.add(
        ChatMessage(
          id: 'branch_${DateTime.now().microsecondsSinceEpoch}',
          sender: MessageSender.system,
          type: MessageType.taskNotification,
          timestamp: DateTime.now(),
          textContent: 'Branch failed: ${error ?? 'unknown error'}',
          toolName: 'failed',
        ),
      );
      notifyListeners();
    }
  }

  void _handleUserMessageUuid(Map<String, dynamic> msg) {
    final uuid = msg['uuid'] as String?;
    if (uuid == null || uuid.isEmpty) return;
    // Find the most recent user text message without a UUID and assign it
    for (int i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.sender == MessageSender.user &&
          (m.type == MessageType.text ||
              m.type == MessageType.skillInvocation) &&
          m.uuid == null) {
        m.uuid = uuid;
        notifyListeners();
        return;
      }
    }
  }

  void interruptQuery() {
    _ws.sendInterrupt();
  }

  ChatMessage _buildUserDisplayMessage(String text) {
    final skillMessage = _buildSkillInvocationMessage(text);
    return skillMessage ?? ChatMessage.userText(text);
  }

  ChatMessage? _buildSkillInvocationMessage(String text) {
    if (_activeSessionBackend != 'codex') return null;
    final match = RegExp(
      r'''^/(?:"([^"]+)"|'([^']+)'|([^\s]+))(?:\s+([\s\S]*))?$''',
    ).firstMatch(text.trim());
    if (match == null) return null;

    final rawName = match.group(1) ?? match.group(2) ?? match.group(3) ?? '';
    final name = _cleanSlashName(rawName);
    if (name.isEmpty) return null;
    final args = (match.group(4) ?? '').trim();
    final command = slashCommands.where((candidate) {
      return _cleanSlashName((candidate['name'] ?? '').toString()) == name;
    }).firstOrNull;

    return ChatMessage.skillInvocation(
      name: name,
      args: args,
      description: (command?['description'] ?? '').toString(),
      body: (command?['body'] ?? '').toString(),
    );
  }

  void _handleSessionCreated(Map<String, dynamic> msg) {
    final sessionId = msg['sessionId'] as String?;
    if (sessionId != null && sessionId.isNotEmpty) {
      _activeSessionId = sessionId;
      _loadPrepends();
    }
    _activeSessionCwd = msg['cwd'] as String?;
    _activeSessionTitle = msg['title'] as String?;
    // Server echoes the backend on the second session_created (the one with
    // the real id). Capture it so the chat header label is right immediately.
    final backend = msg['backend'] as String?;
    if (backend != null) _activeSessionBackend = backend;
    final permissionMode = msg['permissionMode'] as String?;
    if (permissionMode != null) _permissionMode = permissionMode;
    if (_activeSessionBackend == 'codex') requestActiveSkills();
    notifyListeners();
  }

  void _handleSessionHistory(Map<String, dynamic> msg) {
    final rawMessages = msg['messages'] as List? ?? [];
    final offset = (msg['offset'] as num?)?.toInt() ?? 0;
    final isAppend = msg['append'] == true;
    final isPrepend = _isLoadingMore && _messages.isNotEmpty;

    // Silently restore todos from session_history (server includes current state)
    final rawTodos = msg['todos'] as List?;
    if (rawTodos != null) {
      _todos = rawTodos
          .map((t) => Map<String, dynamic>.from(t as Map))
          .toList();
    }

    // Restore prompt suggestion tied to this session
    final suggestion = msg['promptSuggestion'] as String?;
    if (suggestion != null && suggestion.isNotEmpty) {
      _promptSuggestions = [suggestion];
    }

    final loaded = <ChatMessage>[];
    var _historyPrevTodos = <Map<String, dynamic>>[];

    for (final entry in rawMessages) {
      final role = entry['role'] as String? ?? '';
      final content = entry['content'] as String? ?? '';

      switch (role) {
        case 'user':
          var userText = content;

          // Strip cancel prefix and show a cancel indicator
          final cancelMatch = RegExp(
            r'^\[The user cancelled your previous action\. Follow their instructions below\.\][\s]*',
          ).firstMatch(userText);
          if (cancelMatch != null) {
            userText = userText.substring(cancelMatch.end);
            loaded.add(
              ChatMessage(
                id: 'cancel_${DateTime.now().microsecondsSinceEpoch}_$offset',
                sender: MessageSender.system,
                type: MessageType.taskNotification,
                timestamp: DateTime.now(),
                textContent: 'Action cancelled',
                toolName: 'cancelled',
              ),
            );
          }

          // Strip [System: ...] messages (e.g. restart continuation prompts) — hide entirely
          final systemMatch = RegExp(
            r'^\[System: [^\]]*\][\s]*',
          ).firstMatch(userText);
          if (systemMatch != null) {
            userText = userText.substring(systemMatch.end);
            if (userText.trim().isEmpty) break; // nothing left to show
          }

          // Strip todo dismiss prefix and show a dismiss indicator
          final todoDismissMatch = RegExp(
            r'^\[The user dismissed the task list\..*?\][\s]*',
          ).firstMatch(userText);
          if (todoDismissMatch != null) {
            userText = userText.substring(todoDismissMatch.end);
            loaded.add(
              ChatMessage(
                id: 'todo_dismiss_${DateTime.now().microsecondsSinceEpoch}_$offset',
                sender: MessageSender.system,
                type: MessageType.taskNotification,
                timestamp: DateTime.now(),
                textContent: 'Task list dismissed',
                toolName: 'dismissed',
              ),
            );
          }

          // Strip file attachment prefix and show an upload indicator
          final attachMatch = RegExp(
            r'^\[Attached file: (.+?)\]\n?',
          ).firstMatch(userText);
          if (attachMatch != null) {
            final filePath = attachMatch.group(1)!;
            final fileName = filePath.split('/').last;
            userText = userText.substring(attachMatch.end);
            loaded.add(
              ChatMessage(
                id: 'upload_${DateTime.now().microsecondsSinceEpoch}_$offset',
                sender: MessageSender.system,
                type: MessageType.taskNotification,
                timestamp: DateTime.now(),
                textContent: 'Uploaded: $fileName',
                toolName: 'uploaded',
              ),
            );
          }

          // Strip monitor injection messages — these are displayed as MonitorCards via monitor_output
          if (userText.startsWith('[Monitor: ')) break;

          // Strip system XML tags from user messages (e.g. /exit command output)
          userText = userText.replaceAll(_systemReminderRegex, '').trim();

          if (userText.trim().isNotEmpty) {
            final userMsg = _buildUserDisplayMessage(userText);
            // Restore uuid directly from history entry (for rewind support)
            userMsg.uuid = entry['uuid'] as String?;
            loaded.add(userMsg);
          }
          break;
        case 'assistant':
          if (content.isNotEmpty) {
            // Detect tool summary from history
            if (entry['toolSummary'] == true) {
              final precedingIds =
                  (entry['precedingToolUseIds'] as List?)
                      ?.map((e) => e.toString())
                      .toList() ??
                  [];
              loaded.add(
                ChatMessage.toolSummary(
                  summary: content,
                  precedingToolUseIds: precedingIds,
                  uuid: entry['uuid'] as String?,
                ),
              );
              break;
            }
            // Detect thinking blocks from history
            if (entry['thinking'] == true) {
              final m = ChatMessage.thinking();
              m.textContent = content;
              m.uuid = entry['uuid'] as String?;
              loaded.add(m);
              break;
            }
            // Detect compact boundary markers from history
            final compactMatch = RegExp(
              r'^\[compact_boundary:(\d+):(\w+)\]$',
            ).firstMatch(content);
            if (compactMatch != null) {
              final preTokens = int.tryParse(compactMatch.group(1)!) ?? 0;
              final trigger = compactMatch.group(2) ?? 'auto';
              loaded.add(
                ChatMessage.compactBoundary(
                  trigger: trigger,
                  preTokens: preTokens,
                ),
              );
              break;
            }
            // Detect session lifecycle markers from history
            final lifecycleMatch = RegExp(
              r'^\[session_lifecycle:(start|end):([^\]]+)\]$',
            ).firstMatch(content);
            if (lifecycleMatch != null) {
              final lcEvent = lifecycleMatch.group(1)!;
              final lcDetail = lifecycleMatch.group(2)!;
              String lcText;
              if (lcEvent == 'start') {
                // Detail format: "source:model" or just "source"
                final parts = lcDetail.split(':');
                final model = parts.length > 1
                    ? parts.sublist(1).join(':')
                    : null;
                lcText =
                    'Session started${model != null && model.isNotEmpty ? ' ($model)' : ''}';
              } else {
                lcText =
                    'Session ended${lcDetail.isNotEmpty ? ' ($lcDetail)' : ''}';
              }
              loaded.add(
                ChatMessage(
                  id: 'lifecycle_hist_${DateTime.now().microsecondsSinceEpoch}_$offset',
                  sender: MessageSender.system,
                  type: MessageType.taskNotification,
                  timestamp: DateTime.now(),
                  textContent: lcText,
                  toolName: lcEvent == 'start'
                      ? 'session_start'
                      : 'session_end',
                ),
              );
              break;
            }
            // Detect CWD change markers from history — update session CWD silently
            final cwdMatch = RegExp(
              r'^\[cwd_changed:(.+)\]$',
            ).firstMatch(content);
            if (cwdMatch != null) {
              _activeSessionCwd = cwdMatch.group(1);
              break; // Don't render a chat message for CWD changes
            }
            // Detect task status notifications from history
            final taskMatch = RegExp(
              r'^\[Task (\w+)\] (.*)$',
            ).firstMatch(content);
            if (taskMatch != null) {
              final status = taskMatch.group(1) ?? 'completed';
              final summary = taskMatch.group(2) ?? '';
              loaded.add(
                ChatMessage(
                  id: 'task_hist_${DateTime.now().microsecondsSinceEpoch}_$offset',
                  sender: MessageSender.system,
                  type: MessageType.taskNotification,
                  timestamp: DateTime.now(),
                  textContent: summary,
                  toolName: status,
                ),
              );
              break;
            }
            // Detect IBS auth card from history — load as NOT answered;
            // a subsequent ibs_auth_result entry will mark it answered
            final ibsAuthMatch = RegExp(
              r'^\[ibs_auth:(.+)\]$',
            ).firstMatch(content);
            if (ibsAuthMatch != null) {
              final authRequestId = ibsAuthMatch.group(1) ?? '';
              loaded.add(ChatMessage.ibsAuth(authRequestId: authRequestId));
              break;
            }
            // Detect IBS auth result from history — mark the matching card answered
            final ibsResultMatch = RegExp(
              r'^\[ibs_auth_result:(success|failure):(\d+):(.+)\]$',
            ).firstMatch(content);
            if (ibsResultMatch != null) {
              final success = ibsResultMatch.group(1) == 'success';
              final message = ibsResultMatch.group(3) ?? '';
              // Find the most recent unanswered IBS auth card and mark it done
              for (int i = loaded.length - 1; i >= 0; i--) {
                if (loaded[i].type == MessageType.ibsAuth &&
                    !loaded[i].answered) {
                  loaded[i].answered = true;
                  break;
                }
              }
              loaded.add(
                ChatMessage(
                  id: 'ibs_result_${DateTime.now().microsecondsSinceEpoch}_$offset',
                  sender: MessageSender.system,
                  type: MessageType.taskNotification,
                  timestamp: DateTime.now(),
                  textContent: message,
                  toolName: success ? 'ibs_auth_success' : 'ibs_auth_failure',
                ),
              );
              break;
            }
            // Detect Claude auth card from history
            final claudeAuthMatch = RegExp(
              r'^\[claude_auth:(.+)\]$',
            ).firstMatch(content);
            if (claudeAuthMatch != null) {
              // Expire all previous auth cards — only the latest is valid
              for (final m in loaded) {
                if (m.type == MessageType.claudeAuth && !m.answered) {
                  m.expired = true;
                }
              }
              final url = claudeAuthMatch.group(1) ?? '';
              loaded.add(
                ChatMessage(
                  id: 'claude_auth_hist_${DateTime.now().microsecondsSinceEpoch}_$offset',
                  sender: MessageSender.system,
                  type: MessageType.claudeAuth,
                  timestamp: DateTime.now(),
                  textContent: url,
                ),
              );
              break;
            }
            // Detect Claude auth result from history
            final claudeAuthResultMatch = RegExp(
              r'^\[claude_auth_result:(success|failure)\]$',
            ).firstMatch(content);
            if (claudeAuthResultMatch != null) {
              final success = claudeAuthResultMatch.group(1) == 'success';
              // Mark previous claude_auth card as submitted
              for (int i = loaded.length - 1; i >= 0; i--) {
                if (loaded[i].type == MessageType.claudeAuth) {
                  loaded[i].answered = true;
                  break;
                }
              }
              loaded.add(
                ChatMessage(
                  id: 'claude_auth_result_hist_${DateTime.now().microsecondsSinceEpoch}_$offset',
                  sender: MessageSender.system,
                  type: MessageType.taskNotification,
                  timestamp: DateTime.now(),
                  textContent: success
                      ? 'Authentication successful. You can send your message again.'
                      : 'Authentication failed.',
                  toolName: success ? 'success' : 'failed',
                ),
              );
              break;
            }
            // Detect Outlook auth card from history
            final outlookAuthMatch = RegExp(
              r'^\[outlook_auth:(.+)\]$',
            ).firstMatch(content);
            if (outlookAuthMatch != null) {
              final authRequestId = outlookAuthMatch.group(1) ?? '';
              loaded.add(ChatMessage.outlookAuth(authRequestId: authRequestId));
              break;
            }
            // Detect Outlook auth result from history
            final outlookResultMatch = RegExp(
              r'^\[outlook_auth_result:(success|failure):(.+)\]$',
            ).firstMatch(content);
            if (outlookResultMatch != null) {
              final success = outlookResultMatch.group(1) == 'success';
              final message = outlookResultMatch.group(2) ?? '';
              for (int i = loaded.length - 1; i >= 0; i--) {
                if (loaded[i].type == MessageType.outlookAuth &&
                    !loaded[i].answered) {
                  loaded[i].answered = true;
                  break;
                }
              }
              loaded.add(
                ChatMessage(
                  id: 'outlook_result_${DateTime.now().microsecondsSinceEpoch}_$offset',
                  sender: MessageSender.system,
                  type: MessageType.taskNotification,
                  timestamp: DateTime.now(),
                  textContent: message,
                  toolName: success
                      ? 'outlook_auth_success'
                      : 'outlook_auth_failure',
                ),
              );
              break;
            }
            // Detect server restart initiated from history
            final restartMatch = RegExp(
              r'^\[Server restart .*\]$',
            ).firstMatch(content);
            if (restartMatch != null) {
              loaded.add(
                ChatMessage(
                  id: 'restart_hist_${DateTime.now().microsecondsSinceEpoch}_$offset',
                  sender: MessageSender.system,
                  type: MessageType.taskNotification,
                  timestamp: DateTime.now(),
                  textContent: content.substring(1, content.length - 1),
                  toolName: 'restarted',
                ),
              );
              break;
            }
            // Strip system XML from history text
            var cleaned = content
                .replaceAll(_systemReminderRegex, '')
                .replaceAll(_taskNotifRegex, '')
                .trim();
            if (cleaned.isNotEmpty) {
              final m = ChatMessage.assistantText('');
              m.textContent = cleaned;
              m.uuid = entry['uuid'] as String?;
              loaded.add(m);
            }
          }
          break;
        case 'notification':
          if (content.isNotEmpty) {
            final status = entry['status'] as String? ?? 'info';
            final originToolUseId = entry['originToolUseId'] as String?;
            final notifMsg = ChatMessage(
              id: 'notif_${DateTime.now().microsecondsSinceEpoch}_$offset',
              sender: MessageSender.system,
              type: MessageType.taskNotification,
              timestamp: DateTime.now(),
              textContent: content,
              toolName: status,
            );
            notifMsg.parentToolUseId = originToolUseId;
            loaded.add(notifMsg);
          }
          break;
        case 'permission_mode':
          final mode = entry['permissionMode'] as String?;
          if (mode != null && mode.isNotEmpty) {
            _permissionMode = mode;
            loaded.add(_permissionModeMessage(mode));
          }
          break;
        case 'monitor':
          // Restore monitor output cards from history
          if (content.isNotEmpty) {
            final monitorTaskId = entry['taskId'] as String? ?? '';
            final monitorDesc = entry['description'] as String? ?? 'Monitor';
            // Accumulate into an existing monitor card for this taskId, or create new
            ChatMessage? existingMonitor;
            for (int i = loaded.length - 1; i >= 0; i--) {
              if (loaded[i].type == MessageType.monitorOutput &&
                  loaded[i].toolUseId == monitorTaskId) {
                existingMonitor = loaded[i];
                break;
              }
            }
            if (existingMonitor != null) {
              existingMonitor.toolOutput =
                  (existingMonitor.toolOutput ?? '') + '\n' + content;
            } else {
              loaded.add(
                ChatMessage(
                  id: 'monitor_${monitorTaskId}_${DateTime.now().microsecondsSinceEpoch}_$offset',
                  sender: MessageSender.system,
                  type: MessageType.monitorOutput,
                  timestamp: DateTime.now(),
                  textContent: monitorDesc,
                  toolUseId: monitorTaskId,
                  toolOutput: content,
                ),
              );
            }
          }
          break;
        case 'user_uuid':
          // Retroactively assign UUID to the most recent user message
          final userUuid = content;
          if (userUuid.isNotEmpty) {
            for (int i = loaded.length - 1; i >= 0; i--) {
              if (loaded[i].sender == MessageSender.user &&
                  loaded[i].type == MessageType.text &&
                  loaded[i].uuid == null) {
                loaded[i].uuid = userUuid;
                break;
              }
            }
          }
          break;
        case 'tool_call':
          final toolName = (entry['toolName'] as String? ?? 'Tool')
              .replaceFirst('mcp__app__', '');
          final toolInput = (entry['toolInput'] as Map<String, dynamic>?) ?? {};
          final toolCallMsg = ChatMessage.toolCall(
            tool: toolName,
            input: toolInput,
            toolUseId: entry['toolUseId'] as String? ?? '',
          );
          toolCallMsg.uuid = entry['uuid'] as String?;
          toolCallMsg.parentToolUseId = entry['parentToolUseId'] as String?;
          loaded.add(toolCallMsg);
          // Restore server file references for SendFile tool calls
          if (toolName == 'SendFile') {
            final filePath = toolInput['file_path'] as String? ?? '';
            if (filePath.isNotEmpty) {
              final fileName = filePath.split('/').last;
              // Use filePath as a fallback fileId for history entries (no hash available)
              final fileId = _filePathToId[filePath] ?? filePath;
              _serverFiles[fileId] = filePath;
              _serverFileNames[fileId] = fileName;
              _filePathToId[filePath] = fileId;
            }
          }
          break;
        case 'tool_result':
          final toolUseId = entry['toolUseId'] as String? ?? '';
          final output = entry['toolOutput'] as String? ?? '';
          // Skip TodoWrite boilerplate results
          if (output.startsWith('Todos have been modified successfully')) break;
          final idx = loaded.lastIndexWhere(
            (m) => m.type == MessageType.toolCall && m.toolUseId == toolUseId,
          );
          if (idx >= 0) {
            loaded[idx].toolOutput = output;
            loaded[idx].toolStreaming = false;
          } else if (output.trim().isNotEmpty) {
            loaded.add(
              ChatMessage.toolResult(toolUseId: toolUseId, output: output),
            );
          }
          break;
        case 'tool_image':
          // Attach image to matching tool_call — request file from server
          final imgToolUseId = entry['toolUseId'] as String? ?? '';
          final imgFilePath = entry['filePath'] as String? ?? '';
          final imgMimeType = entry['mimeType'] as String? ?? 'image/png';
          if (imgFilePath.isNotEmpty && imgToolUseId.isNotEmpty) {
            final idx = loaded.lastIndexWhere(
              (m) =>
                  m.type == MessageType.toolCall && m.toolUseId == imgToolUseId,
            );
            if (idx >= 0) {
              loaded[idx].toolImageFilePath = imgFilePath;
              loaded[idx].toolImageMimeType = imgMimeType;
              // Image data will be fetched after history is loaded
              _pendingImageLoads.add({
                'toolUseId': imgToolUseId,
                'filePath': imgFilePath,
              });
            }
          }
          break;
        case 'codex_plan':
          final turnId = entry['toolUseId'] as String? ?? '';
          final input = (entry['toolInput'] as Map<String, dynamic>?) ?? {};
          final explanation =
              input['explanation'] as String? ??
              entry['content'] as String? ??
              '';
          final rawSteps = input['steps'] as List? ?? const [];
          final steps = rawSteps
              .whereType<Map>()
              .map((step) => Map<String, dynamic>.from(step))
              .toList();
          if (steps.isNotEmpty || explanation.trim().isNotEmpty) {
            final planMessage = ChatMessage.codexPlan(
              turnId: turnId,
              explanation: explanation,
              steps: steps,
            );
            final idx = loaded.lastIndexWhere(
              (m) => m.type == MessageType.codexPlan && m.toolUseId == turnId,
            );
            if (idx >= 0) {
              loaded[idx] = planMessage;
            } else {
              loaded.add(planMessage);
            }
          }
          break;
        case 'todos_update':
          // Legacy: old history entries had inline todos diffs — skip them.
          // Current state is restored via the 'todos' field on session_history.
          try {
            _historyPrevTodos = (jsonDecode(content) as List)
                .map((t) => Map<String, dynamic>.from(t as Map))
                .toList();
          } catch (_) {}
          break;
        case 'question':
          final questionId = entry['questionId'] as String? ?? '';
          final rawQuestions = entry['questions'] as List? ?? [];
          final questions = rawQuestions
              .map((q) => QuestionItem.fromJson(q as Map<String, dynamic>))
              .toList();
          final answered = entry['answered'] as bool? ?? false;
          Map<String, String>? emailPreview;
          if (entry['emailPreview'] != null) {
            final ep = entry['emailPreview'] as Map<String, dynamic>;
            emailPreview = ep.map((k, v) => MapEntry(k, v.toString()));
          }
          final qMsg = ChatMessage.question(
            questionId: questionId,
            questions: questions,
            emailPreview: emailPreview,
          );
          qMsg.answered = answered;
          loaded.add(qMsg);
          break;
        case 'elicitation_url':
          final elicitQId = entry['questionId'] as String? ?? '';
          final elicitServer =
              entry['mcpServerName'] as String? ?? 'MCP Server';
          final elicitMessage = entry['content'] as String? ?? '';
          final elicitUrl = entry['url'] as String? ?? '';
          final elicitAnswered = entry['answered'] as bool? ?? false;
          if (elicitQId.isNotEmpty && elicitUrl.isNotEmpty) {
            final eMsg = ChatMessage.elicitationUrl(
              questionId: elicitQId,
              mcpServerName: elicitServer,
              message: elicitMessage,
              url: elicitUrl,
            );
            eMsg.answered = elicitAnswered;
            loaded.add(eMsg);
          }
          break;
      }
    }

    // Clear orphaned tool calls that never got a result (e.g. server was
    // killed mid-query). Without this they'd show as blank spinning cards.
    for (final m in loaded) {
      if (m.type == MessageType.toolCall && m.toolOutput == null) {
        m.toolOutput = '';
      }
    }

    _historyOffset = offset;

    if (isAppend) {
      // Append missed messages (e.g., from server downtime recovery)
      // Deduplicate: skip user messages whose text already exists in recent messages
      final deduped = <ChatMessage>[];
      for (final msg in loaded) {
        if (msg.sender == MessageSender.user && msg.type == MessageType.text) {
          final isDupe = _messages.reversed
              .take(20)
              .any(
                (m) =>
                    m.sender == MessageSender.user &&
                    m.type == MessageType.text &&
                    m.textContent == msg.textContent,
              );
          if (isDupe) continue;
        }
        deduped.add(msg);
      }
      _messages = [..._messages, ...deduped];
    } else if (isPrepend) {
      // Prepend older messages before existing ones
      _messages = [...loaded, ..._messages];
      _isLoadingMore = false;
    } else {
      // Initial load — replace
      final localOnlyCards = _messages.where((m) {
        if (m.type != MessageType.toolCall || m.toolUseId == null) return false;
        final isLocalOnly =
            m.toolUseId!.startsWith('file_') ||
            m.toolUseId!.startsWith('speak_');
        if (!isLocalOnly) return false;
        return !loaded.any(
          (l) =>
              l.type == MessageType.toolCall &&
              l.toolName == m.toolName &&
              l.toolInput.toString() == m.toolInput.toString(),
        );
      }).toList();
      _messages = [...loaded, ...localOnlyCards];
      _backgroundTasks.clear();
      _subagentTasks.clear();
      _isLoadingHistory = false;
    }
    // Fallback: if server didn't include 'todos' field (old server compat),
    // sync _todos from the last todos_update in history for dedup.
    if (rawTodos == null && _historyPrevTodos.isNotEmpty) {
      _todos = _historyPrevTodos;
    }
    // Rebuild subagent tasks from loaded messages (for expandable Task cards)
    for (final m in _messages) {
      if (m.type == MessageType.toolCall &&
          (m.toolName == 'Task' || m.toolName == 'Agent') &&
          m.toolUseId != null) {
        final desc = m.toolInput?['description'] as String? ?? 'Sub agent task';
        final hasResult = m.toolOutput != null;
        _subagentTasks[m.toolUseId!] = {
          'description': desc,
          'prompt': m.toolInput?['prompt'] as String? ?? '',
          'subagentType': m.toolInput?['subagent_type'] as String? ?? '',
          'status': hasResult ? 'completed' : 'running',
          'toolUseId': m.toolUseId!,
        };
      }
    }
    _loadDismissedSubagents();
    notifyListeners();

    // Fetch pending image data from server for history tool_image entries.
    if (_pendingImageLoads.isNotEmpty) {
      _fetchPendingImages();
    }
  }

  /// Fetch image files from the server for tool_image history entries
  Future<void> _fetchPendingImages() async {
    final loads = List<Map<String, String>>.from(_pendingImageLoads);
    _pendingImageLoads.clear();

    for (final load in loads) {
      final toolUseId = load['toolUseId'] ?? '';
      final filePath = load['filePath'] ?? '';
      if (toolUseId.isEmpty || filePath.isEmpty) continue;

      try {
        final base64Data = await fetchServerFileBase64(filePath);
        if (base64Data == null || base64Data.isEmpty) continue;

        final idx = _messages.lastIndexWhere(
          (m) => m.type == MessageType.toolCall && m.toolUseId == toolUseId,
        );
        if (idx >= 0) {
          _messages[idx].toolImageData = base64Data;
          notifyListeners();
        }
      } catch (e) {
        // Image no longer available — leave toolImageData null, widget will show placeholder
        debugPrint('Failed to load image for $toolUseId: $e');
      }
    }
  }

  void _handleSessionList(Map<String, dynamic> msg, [String? serverId]) {
    final rawSessions = msg['sessions'] as List? ?? [];
    // Find server config for tagging
    final serverConfig = serverId != null
        ? _serverConfigs.where((c) => c.id == serverId).firstOrNull
        : null;
    final sessions = rawSessions
        .map(
          (s) => Session.fromJson(s as Map<String, dynamic>).withServer(
            serverId: serverId ?? '',
            serverName: serverConfig?.name ?? '',
            serverColor: serverConfig?.colorValue,
          ),
        )
        .toList();

    if (serverId != null) {
      // Store per-server and rebuild merged list
      _perServerSessions[serverId] = sessions;
      _rebuildSessionList();
    } else {
      // Legacy single-server path
      _sessions = sessions;
    }
    notifyListeners();
  }

  Future<void> sendPrompt(String text, {String? priority}) async {
    if (text.trim().isEmpty && _pendingAttachmentPath == null) return;

    // Snapshot attachment fields up front so we can clear the input chip
    // immediately while we still have the path to actually upload from.
    final attachPath = _pendingAttachmentPath;
    final attachName = _pendingAttachmentName;
    final hasAttachmentForSend = attachPath != null;

    // Show the user's message immediately (original text only)
    final displayText = text.trim().isEmpty
        ? '📎 ${attachName ?? "file"}'
        : text;
    final userMsg = _buildUserDisplayMessage(displayText);
    // Mark as pending if injecting with non-immediate priority OR if we're
    // about to spend time uploading. The bubble renders pending state with
    // reduced opacity + a progress indicator while the file streams up.
    if (priority != null && _isProcessing) {
      userMsg.isPending = true;
      userMsg.injectionPriority = priority;
    }
    if (hasAttachmentForSend) {
      userMsg.isPending = true;
      userMsg.uploadProgress = 0.0;
      userMsg.uploadFileName = attachName;
    }
    _messages.add(userMsg);
    // Don't null _currentStreamingMessage here — if Claude is mid-stream,
    // let it keep appending to the existing message at its current position
    // (before the user message). It gets cleared by _handleResult when the
    // turn ends, so the response to the injected message starts fresh.
    _isProcessing = true;
    _processingSetAt = DateTime.now();
    _promptSuggestions = [];

    // Drop the input-area chip now — the file is committed to this bubble.
    // Progress now lives on the bubble itself.
    if (hasAttachmentForSend) {
      _pendingAttachmentPath = null;
      _pendingAttachmentName = null;
      _uploadProgress = null;
      _pendingUploadId = null;
    }
    notifyListeners();

    String prompt = text;

    if (hasAttachmentForSend) {
      try {
        final serverPath = await _uploadFromPath(
          path: attachPath,
          name: attachName ?? 'file',
          progressTarget: userMsg,
        );
        prompt = '[Attached file: $serverPath]\n$prompt';
        // Inline an "Uploaded: filename" card just above the user bubble so
        // the chat shows the file inline (matching what history-restore
        // produces from the saved `[Attached file: ...]` prefix).
        final fileName = serverPath.split('/').last;
        final uploadCard = ChatMessage(
          id: 'upload_${DateTime.now().microsecondsSinceEpoch}',
          sender: MessageSender.system,
          type: MessageType.taskNotification,
          timestamp: DateTime.now(),
          textContent: 'Uploaded: $fileName',
          toolName: 'uploaded',
        );
        final idx = _messages.indexOf(userMsg);
        if (idx >= 0) {
          _messages.insert(idx, uploadCard);
        } else {
          _messages.add(uploadCard);
        }
      } catch (e) {
        userMsg.isPending = false;
        userMsg.uploadProgress = null;
        _messages.add(ChatMessage.error('Upload failed: $e'));
        _isProcessing = false;
        notifyListeners();
        return;
      }
      userMsg.uploadProgress = null;
    }

    _dropLegacyCancelPrepends();
    if (_pendingPrepends.isNotEmpty) {
      final prefix = _pendingPrepends.join('\n');
      prompt = '$prefix\n$prompt';
      _clearPrepends();
    }

    _ws.sendPrompt(
      prompt,
      sessionId: _activeSessionId,
      priority: priority,
      messageId: userMsg.id,
      cwd: _activeSessionId == null ? _activeSessionCwd : null,
    );

    // Upload + dispatch done — bubble is officially "sent" now (unless it's
    // queued behind a running query, in which case keep the pending state).
    if (hasAttachmentForSend && userMsg.injectionPriority == null) {
      userMsg.isPending = false;
    }
    notifyListeners();
  }

  String? retractQueuedMessage(String messageId) {
    final idx = _messages.indexWhere(
      (m) =>
          m.id == messageId &&
          m.sender == MessageSender.user &&
          m.isPending &&
          m.injectionPriority != null,
    );
    if (idx < 0) return null;

    final text = _messages[idx].textContent;
    _messages.removeAt(idx);
    _ws.sendRetractQueuedPrompt(messageId);
    notifyListeners();
    return text;
  }

  Future<void> pickFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result != null && result.files.single.path != null) {
      _pendingAttachmentPath = result.files.single.path!;
      _pendingAttachmentName = result.files.single.name;
      notifyListeners();
    }
  }

  void removeAttachment() {
    _pendingAttachmentPath = null;
    _pendingAttachmentName = null;
    _uploadProgress = null;
    _pendingUploadId = null;
    notifyListeners();
  }

  Future<String> _uploadFromPath({
    required String path,
    required String name,
    required ChatMessage progressTarget,
  }) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    final binary = _ws.serverSupportsBinary;
    // 1MB binary chunks: small enough to not blow up the OS TCP buffer on
    // cellular, big enough that NaCl/JSON overhead per chunk stays a small
    // fraction. 512KB on the legacy base64 path keeps the relay's 16MB
    // payload limit comfortably out of reach.
    final chunkSize = binary ? 1 * 1024 * 1024 : 512 * 1024;
    final totalChunks = (bytes.length / chunkSize)
        .ceil()
        .clamp(1, double.infinity)
        .toInt();
    final uploadId = DateTime.now().microsecondsSinceEpoch.toString();
    _pendingUploadId = uploadId;
    final completer = Completer<String>();
    _uploadCompleter = completer;

    // No client-side backpressure: fire-and-forget chunks like the original
    // working test that did 130 MB in ~1s on LAN. The stall timer below still
    // catches the case where the server stops emitting progress events.
    final state = _UploadState(
      target: progressTarget,
      onStall: () {
        if (!completer.isCompleted) {
          completer.completeError(
            Exception('Upload stalled — no progress from server for 30s'),
          );
        }
      },
    );
    if (binary) {
      _uploadStates[uploadId] = state;
      state.start();
    }

    _ws.send({
      'type': 'upload_start',
      'uploadId': uploadId,
      'fileName': name,
      'fileSize': bytes.length,
      'totalChunks': totalChunks,
      'chunkSize': chunkSize,
    });

    debugPrint(
      '[Upload] start id=$uploadId chunks=$totalChunks size=${bytes.length} binary=$binary',
    );
    for (var i = 0; i < totalChunks; i++) {
      if (i % 10 == 0 || i == totalChunks - 1) {
        debugPrint('[Upload] sending chunk $i/$totalChunks');
      }

      final start = i * chunkSize;
      final end = (start + chunkSize).clamp(0, bytes.length);
      final chunk = Uint8List.fromList(bytes.sublist(start, end));
      if (binary) {
        _ws.sendUploadChunkBinary(
          uploadId: uploadId,
          chunkIndex: i,
          bytes: chunk,
        );
      } else {
        _ws.send({
          'type': 'upload_chunk',
          'uploadId': uploadId,
          'chunkIndex': i,
          'data': base64Encode(chunk),
        });
        // Legacy fallback: drive spinner from chunk-loop iteration so it's
        // not stuck at 0 when the server isn't emitting progress events.
        progressTarget.uploadProgress = (i + 1) / totalChunks;
        notifyListeners();
      }
    }

    // No wall-clock timeout — completion is gated by server `upload_complete`
    // (success) or the stall detector inside `state` (failure after 30s
    // without a progress event).
    return completer.future;
  }

  void abortQuery() {
    _ws.sendAbort(sessionId: _activeSessionId);
    _currentStreamingMessage = null;
    _closeThinkingMessage();
    _isProcessing = false;
    _isCompacting = false;
    // Stop spinners on any tool cards that never got a result
    for (final m in _messages) {
      if (m.type == MessageType.toolCall && m.toolOutput == null) {
        m.toolOutput = '';
      }
      if (m.type == MessageType.toolCall && m.toolStreaming) {
        m.toolStreaming = false;
      }
    }
    // Show cancel card immediately
    _messages.add(
      ChatMessage(
        id: 'cancel_${DateTime.now().microsecondsSinceEpoch}',
        sender: MessageSender.system,
        type: MessageType.taskNotification,
        timestamp: DateTime.now(),
        textContent: 'Action cancelled',
        toolName: 'cancelled',
      ),
    );
    // Hard stop is handled by the server abort/interrupt path. Do not turn it
    // into a hidden instruction that gets prepended to the next user message.
    _dropLegacyCancelPrepends();
    notifyListeners();
  }

  void submitAuthCode(String code, {String? serverId}) {
    final msg = {
      'type': 'auth_code',
      'code': code,
      'sessionId': _activeSessionId,
    };
    if (serverId != null && serverId.isNotEmpty) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _connMgr.send(msg);
    }
  }

  void answerQuestion(String questionId, Map<String, String> answers) {
    // Check if this is an outlook auth answer
    if (questionId.startsWith('outlook_auth_')) {
      submitOutlookAuth(questionId, answers);
      return;
    }
    // Check if this is an IBS auth answer
    if (questionId.startsWith('ibs_auth_')) {
      submitIBSAuth(questionId, answers);
      return;
    }
    final idx = _messages.indexWhere(
      (m) => m.questionId == questionId && m.type == MessageType.question,
    );
    if (idx >= 0) {
      _messages[idx].answered = true;
    }
    _ws.sendAnswer(questionId, answers);
    notifyListeners();
  }

  /// Clear file attachment state (without notifyListeners)
  void _clearAttachment() {
    _pendingAttachmentPath = null;
    _pendingAttachmentName = null;
    _uploadProgress = null;
    _pendingUploadId = null;
    _uploadCompleter = null;
  }

  /// Clear raw SDK debug state
  void _clearRawState() {
    _rawItems.clear();
    _currentMessageGroup = null;
    _currentContentBlock = null;
    _rawThrottle?.cancel();
    _rawThrottle = null;
  }

  void createNewSession({String? cwd, String? serverId, String? backend}) {
    _messages = [];
    _todos = [];
    _lastUsage = null;
    _activeSessionId = null;
    final effectiveBackend = backend ?? preferredBackendForServer(serverId);
    _activeSessionBackend = effectiveBackend;
    _currentStreamingMessage = null;
    _currentThinkingMessage = null;
    _isProcessing = false;
    _processingSetAt = null;
    _isCompacting = false;
    _permissionMode = null;
    _historyOffset = 0;
    _isLoadingMore = false;
    _sessionModel = null;
    _supportedModels = [];
    _mcpServers = [];
    _subagentTasks.clear();
    _backgroundTasks.clear();
    _pendingPrepends = [];
    _promptSuggestions = [];
    _contextUsage = null;
    _requiresAction = false;
    _pendingImageLoads.clear();
    _clearAttachment();
    _clearRawState();
    // Set active server to the target server
    if (serverId != null) {
      _connMgr.activeServerId = serverId;
    } else if (_connMgr.activeServerId == null && _serverConfigs.isNotEmpty) {
      _connMgr.activeServerId = _serverConfigs.first.id;
    }
    // Use per-server defaultCwd, falling back to global _defaultCwd for primary server.
    // If no default is configured, don't send cwd — server uses its own DEFAULT_CWD from .env.
    String? effectiveCwd = cwd;
    if (effectiveCwd == null) {
      final serverConfig =
          _serverConfigs.where((s) => s.id == serverId).firstOrNull ??
          _serverConfigs.firstOrNull;
      if (serverConfig != null && serverConfig.defaultCwd.isNotEmpty) {
        effectiveCwd = serverConfig.defaultCwd;
      } else if (_defaultCwd.isNotEmpty &&
          (serverId == null ||
              _serverConfigs.length <= 1 ||
              serverId == _serverConfigs.firstOrNull?.id)) {
        effectiveCwd = _defaultCwd; // Legacy global fallback for primary server
      }
    }
    if (effectiveCwd != null) {
      addRecentCwd(effectiveCwd, serverId: serverId);
    }
    final msg = <String, dynamic>{
      'type': 'new_session',
      if (effectiveCwd != null) 'cwd': effectiveCwd,
      'backend': effectiveBackend,
    };
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _connMgr.send(msg);
    }
    notifyListeners();
  }

  /// Backends the given server can drive, ordered by UI preference. Defaults to ['claude'] when the
  /// capability message hasn't arrived yet (older servers won't send it at
  /// all, so legacy claude-only behavior is the safe default).
  List<String> backendsForServer(String? serverId) {
    final effectiveServerId =
        serverId ?? _connMgr.activeServerId ?? _serverConfigs.firstOrNull?.id;
    if (effectiveServerId == null) return const ['claude'];
    final raw = _serverBackends[effectiveServerId] ?? const ['claude'];
    if (!raw.contains('codex')) return raw;
    return ['codex', ...raw.where((b) => b != 'codex')];
  }

  String preferredBackendForServer(String? serverId) {
    final backends = backendsForServer(serverId);
    return backends.firstOrNull ?? 'claude';
  }

  void _captureCodexDriverSettings(Map<String, dynamic> msg, String serverId) {
    final driver = msg['codexDriver'];
    if (driver == 'exec' || driver == 'app-server') {
      _serverCodexDrivers[serverId] = driver as String;
    }

    final rawDrivers = msg['codexDriversAvailable'];
    if (rawDrivers is List) {
      final drivers = rawDrivers
          .whereType<String>()
          .where((d) => d == 'exec' || d == 'app-server')
          .toList();
      _serverCodexDriversAvailable[serverId] = drivers;
    }

    final currentMode = msg['codexCollaborationMode'] as String?;
    if (currentMode != null && currentMode.isNotEmpty) {
      _serverCodexCollaborationMode[serverId] = currentMode;
    }

    final rawModes = msg['codexCollaborationModes'];
    if (rawModes is List) {
      _serverCodexCollaborationModes[serverId] = rawModes
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    }
  }

  String codexDriverForServer(String? serverId) {
    final effectiveServerId =
        serverId ?? _connMgr.activeServerId ?? _serverConfigs.firstOrNull?.id;
    if (effectiveServerId == null) return 'exec';
    return _serverCodexDrivers[effectiveServerId] ?? 'exec';
  }

  List<String> codexDriversAvailableForServer(String? serverId) {
    final effectiveServerId =
        serverId ?? _connMgr.activeServerId ?? _serverConfigs.firstOrNull?.id;
    if (effectiveServerId == null) return const [];
    final known = _serverCodexDriversAvailable[effectiveServerId];
    if (known != null) return known;
    return backendsForServer(effectiveServerId).contains('codex')
        ? const ['exec']
        : const [];
  }

  void requestServerSettings({String? serverId}) {
    if (serverId != null) {
      _connMgr.sendToServer(serverId, {'type': 'get_server_settings'});
    } else {
      _connMgr.sendToAll({'type': 'get_server_settings'});
    }
  }

  void requestActiveSkills() {
    final serverId = _connMgr.activeServerId;
    if (serverId == null) return;
    if (_connMgr.statusOf(serverId) != ConnectionStatus.connected) return;
    _connMgr.sendToServer(serverId, {'type': 'skills_list'});
  }

  void setCodexDriverForServer(String serverId, String driver) {
    if (driver != 'exec' && driver != 'app-server') return;
    _serverCodexDrivers[serverId] = driver;
    _connMgr.sendToServer(serverId, {
      'type': 'set_codex_driver',
      'driver': driver,
    });
    notifyListeners();
  }

  void requestCodexCollaborationModes({String? serverId}) {
    final targetServerId = serverId ?? _connMgr.activeServerId;
    final msg = {'type': 'codex_collaboration_modes'};
    if (targetServerId != null) {
      _connMgr.sendToServer(targetServerId, msg);
    } else {
      _connMgr.send(msg);
    }
  }

  void setCodexCollaborationMode(String mode) {
    final serverId = _connMgr.activeServerId;
    if (serverId != null) {
      _serverCodexCollaborationMode[serverId] = mode;
      _connMgr.sendToServer(serverId, {
        'type': 'set_codex_collaboration_mode',
        'mode': mode,
      });
    } else {
      _ws.send({'type': 'set_codex_collaboration_mode', 'mode': mode});
    }
    notifyListeners();
  }

  String? get activeSessionBackend => _activeSessionBackend;

  void resumeSession(String sessionId) {
    _messages = [];
    _todos = [];
    _lastUsage = null;
    _activeSessionId = sessionId;
    _loadPrepends();
    _currentStreamingMessage = null;
    _currentThinkingMessage = null;
    _isProcessing = false;
    _processingSetAt = null;
    _permissionMode = null;
    _isCompacting = false;
    _isLoadingHistory = true;
    _historyOffset = 0;
    _isLoadingMore = false;
    _sessionModel = null;
    _supportedModels = [];
    _mcpServers = [];
    _subagentTasks.clear();
    _backgroundTasks.clear();
    _promptSuggestions = [];
    _contextUsage = null;
    _requiresAction = false;
    _pendingImageLoads.clear();
    _clearAttachment();
    _clearRawState();
    // Load per-session settings from prefs
    _loadSessionSettings(sessionId);

    // Look up which server owns this session and switch active server
    final session = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (session != null) {
      _activeSessionTitle = session.title;
      _activeSessionCwd = session.cwd;
      _activeSessionBackend = session.backend;
    } else {
      _activeSessionBackend = null; // legacy session without backend tag
    }
    if (session != null && session.serverId.isNotEmpty) {
      _connMgr.activeServerId = session.serverId;
      _connMgr.sendToServer(session.serverId, {
        'type': 'resume_session',
        'sessionId': sessionId,
      });
    } else {
      _ws.sendResumeSession(sessionId);
    }

    // Send per-session settings after resume
    _sendSessionSettings(sessionId);
    if (_activeSessionBackend == 'codex') requestActiveSkills();

    notifyListeners();
  }

  void resumeSessionFromNotification(String sessionId, {String? serverId}) {
    if (serverId != null && serverId.isNotEmpty) {
      _connMgr.activeServerId = serverId;
    }
    resumeSession(sessionId);
  }

  void _loadSessionSettings(String sessionId) {
    SharedPreferences.getInstance().then((prefs) {
      final dt = prefs.getStringList('disallowed_tools_$sessionId');
      if (dt != null) _sessionDisallowedTools[sessionId] = dt;
      final sp = prefs.getString('system_prompt_$sessionId');
      if (sp != null) _sessionSystemPrompts[sessionId] = sp;
    });
  }

  void _sendSessionSettings(String sessionId) {
    final dt = _sessionDisallowedTools[sessionId];
    if (dt != null && dt.isNotEmpty) {
      _connMgr.send({'type': 'set_disallowed_tools', 'tools': dt});
    }
    final sp = getEffectiveSystemPrompt(sessionId);
    if (sp.isNotEmpty) {
      _connMgr.send({'type': 'set_system_prompt', 'prompt': sp});
    }
  }

  void loadMoreHistory() {
    if (_isLoadingMore || _historyOffset <= 0 || _activeSessionId == null)
      return;
    _isLoadingMore = true;
    final limit = 50;
    final newOffset = (_historyOffset - limit).clamp(0, _historyOffset);
    _ws.send({
      'type': 'load_more_history',
      'sessionId': _activeSessionId,
      'offset': newOffset,
      'limit': _historyOffset - newOffset,
    });
    notifyListeners();
  }

  /// Check if a path exists on the server. Returns true if it exists.
  Future<bool> checkCwd(String path, {String? serverId}) async {
    _pendingCwdCheck = Completer<bool>();
    final msg = {'type': 'check_cwd', 'path': path};
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _ws.send(msg);
    }
    return _pendingCwdCheck!.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
  }

  /// Ask the server to create a directory. Returns true if successful.
  Future<bool> createCwd(String path, {String? serverId}) async {
    _pendingCwdCheck = Completer<bool>();
    final msg = {'type': 'create_cwd', 'path': path};
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _ws.send(msg);
    }
    return _pendingCwdCheck!.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
  }

  /// List subdirectories of a path on a specific server.
  /// Returns {path: resolvedPath, directories: [name, ...], error?: string}.
  Future<Map<String, dynamic>> listDirectory(
    String dirPath, {
    String? serverId,
  }) async {
    _pendingDirList = Completer<Map<String, dynamic>>();
    final msg = {'type': 'list_directory', 'path': dirPath};
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _ws.send(msg);
    }
    return _pendingDirList!.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => {
        'path': dirPath,
        'directories': <String>[],
        'error': 'Timeout',
      },
    );
  }

  /// Request SDK sessions for a given CWD from the server.
  Future<List<Map<String, dynamic>>> requestSdkSessions(
    String cwd, {
    String? serverId,
  }) async {
    final seq = ++_sdkSessionsRequestSeq;
    _pendingSdkSessions = Completer<List<Map<String, dynamic>>>();
    _pendingSdkSessionsServerId = serverId;
    final msg = {'type': 'list_sdk_sessions', 'cwd': cwd};
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _ws.send(msg);
    }
    final result = await _pendingSdkSessions!.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => <Map<String, dynamic>>[],
    );
    // Ignore stale results if a newer request was made
    if (seq != _sdkSessionsRequestSeq) return <Map<String, dynamic>>[];
    return result;
  }

  /// Check server version and available updates.
  Future<Map<String, dynamic>> requestVersionCheck({String? serverId}) async {
    _pendingVersionCheck = Completer<Map<String, dynamic>>();
    final msg = {'type': 'version_check'};
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _ws.send(msg);
    }
    return _pendingVersionCheck!.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => <String, dynamic>{
        'error': 'Timed out checking for updates',
      },
    );
  }

  /// Force server to pull updates, compile, and restart.
  Future<Map<String, dynamic>> requestForceUpdate({String? serverId}) async {
    _pendingForceUpdate = Completer<Map<String, dynamic>>();
    final msg = {'type': 'force_update', 'forceRestart': true};
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _ws.send(msg);
    }
    return _pendingForceUpdate!.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () => <String, dynamic>{
        'success': false,
        'error': 'Timed out waiting for update',
      },
    );
  }

  /// Resume an SDK-only session (not yet in SocketAgent store).
  void resumeSdkSession(
    String sessionId,
    String cwd, {
    String? serverId,
    String? backend,
  }) {
    _messages = [];
    _todos = [];
    _lastUsage = null;
    _activeSessionId = sessionId;
    _isLoadingHistory = true;
    _isProcessing = false;
    _isCompacting = false;
    _currentStreamingMessage = null;
    _promptSuggestions = [];
    _contextUsage = null;
    _requiresAction = false;
    // Track the backend immediately so chat-header [CODEX] flag is right
    // before session_created comes back; falls through to whatever the
    // server confirms on the SessionInfo write-through.
    _activeSessionBackend = backend;

    final msg = {
      'type': 'resume_session',
      'sessionId': sessionId,
      'cwd': cwd,
      if (backend != null) 'backend': backend,
    };
    if (serverId != null) {
      _connMgr.activeServerId = serverId;
      _connMgr.sendToServer(serverId, msg);
    } else {
      _connMgr.send(msg);
    }
    if (_activeSessionBackend == 'codex') requestActiveSkills();
    notifyListeners();
  }

  void requestSessionList() {
    _connMgr.sendToAll({'type': 'list_sessions'});
    _connMgr.sendToAll({'type': 'get_recent_cwds'});
    _connMgr.sendToAll({'type': 'get_server_settings'});
  }

  void requestScheduledTasks() {
    _connMgr.sendToAll({'type': 'list_scheduled_tasks'});
  }

  String? _serverIdForScheduledTask(String taskId) {
    final task = _scheduledTasks.where((t) => t['id'] == taskId).firstOrNull;
    final serverId = task?['_serverId'] as String?;
    return serverId != null && serverId.isNotEmpty ? serverId : null;
  }

  void scheduleTask({
    required String prompt,
    required String cwd,
    required String scheduledTime,
    String? backend,
    String? recurrenceType,
    int? customIntervalMs,
    bool reuseSession = false,
    String notificationMode = 'completion',
    String? serverId,
  }) {
    final msg = <String, dynamic>{
      'type': 'schedule_task',
      'prompt': prompt,
      'cwd': cwd,
      'backend': backend ?? preferredBackendForServer(serverId),
      'scheduledTime': scheduledTime,
      'reuseSession': reuseSession,
      'notificationMode': notificationMode,
    };
    if (recurrenceType != null && recurrenceType != 'once') {
      msg['recurrence'] = <String, dynamic>{
        'type': recurrenceType,
        if (recurrenceType == 'custom' && customIntervalMs != null)
          'intervalMs': customIntervalMs,
      };
    }
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _connMgr.send(msg);
    }
  }

  void updateScheduledTask({
    required String taskId,
    String? prompt,
    String? cwd,
    String? backend,
    String? scheduledTime,
    String? recurrenceType,
    int? customIntervalMs,
    bool? reuseSession,
    String? notificationMode,
  }) {
    final msg = <String, dynamic>{
      'type': 'update_scheduled_task',
      'taskId': taskId,
    };
    if (prompt != null) msg['prompt'] = prompt;
    if (cwd != null) msg['cwd'] = cwd;
    if (backend != null) msg['backend'] = backend;
    if (scheduledTime != null) msg['scheduledTime'] = scheduledTime;
    if (reuseSession != null) msg['reuseSession'] = reuseSession;
    if (notificationMode != null) msg['notificationMode'] = notificationMode;
    if (recurrenceType != null) {
      if (recurrenceType == 'once') {
        msg['recurrence'] = null;
      } else {
        msg['recurrence'] = <String, dynamic>{
          'type': recurrenceType,
          if (recurrenceType == 'custom' && customIntervalMs != null)
            'intervalMs': customIntervalMs,
        };
      }
    }
    final serverId = _serverIdForScheduledTask(taskId);
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _connMgr.send(msg);
    }
  }

  void cancelScheduledTask(String taskId) {
    final msg = {'type': 'cancel_scheduled_task', 'taskId': taskId};
    final serverId = _serverIdForScheduledTask(taskId);
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _connMgr.send(msg);
    }
  }

  void executeScheduledTask(String taskId) {
    final msg = {'type': 'execute_scheduled_task', 'taskId': taskId};
    final serverId = _serverIdForScheduledTask(taskId);
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _connMgr.send(msg);
    }
  }

  void deleteScheduledTask(String taskId) {
    final serverId = _serverIdForScheduledTask(taskId);
    _scheduledTasks.removeWhere((t) => t['id'] == taskId);
    for (final tasks in _perServerScheduledTasks.values) {
      tasks.removeWhere((t) => t['id'] == taskId);
    }
    final msg = {'type': 'delete_scheduled_task', 'taskId': taskId};
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _connMgr.send(msg);
    }
    notifyListeners();
  }

  void deleteSession(String sessionId) {
    final session = _sessions.where((s) => s.id == sessionId).firstOrNull;
    _sessions.removeWhere((s) => s.id == sessionId);
    // Also remove from per-server cache
    if (session != null && session.serverId.isNotEmpty) {
      _perServerSessions[session.serverId]?.removeWhere(
        (s) => s.id == sessionId,
      );
      _connMgr.sendToServer(session.serverId, {
        'type': 'delete_session',
        'sessionId': sessionId,
      });
    } else {
      _ws.sendDeleteSession(sessionId);
    }
    notifyListeners();
  }

  void archiveSession(String sessionId) {
    final session = _sessions.where((s) => s.id == sessionId).firstOrNull;
    _sessions.removeWhere((s) => s.id == sessionId);
    if (session != null && session.serverId.isNotEmpty) {
      _perServerSessions[session.serverId]?.removeWhere(
        (s) => s.id == sessionId,
      );
      _connMgr.sendToServer(session.serverId, {
        'type': 'archive_session',
        'sessionId': sessionId,
      });
    } else {
      _ws.sendArchiveSession(sessionId);
    }
    notifyListeners();
  }

  void renameSession(String sessionId, String title) {
    // Optimistically update local state
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx >= 0) {
      final s = _sessions[idx];
      _sessions[idx] = Session(
        id: s.id,
        title: title,
        cwd: s.cwd,
        createdAt: s.createdAt,
        lastActive: s.lastActive,
        messagePreview: s.messagePreview,
        running: s.running,
        serverId: s.serverId,
        serverName: s.serverName,
        serverColor: s.serverColor,
      );
    }
    // Update active session title if renaming the current session
    if (_activeSessionId == sessionId) {
      _activeSessionTitle = title;
    }
    // Send to server
    final session = idx >= 0 ? _sessions[idx] : null;
    if (session != null && session.serverId.isNotEmpty) {
      _connMgr.sendToServer(session.serverId, {
        'type': 'rename_session',
        'sessionId': sessionId,
        'title': title,
      });
    } else {
      _ws.send({
        'type': 'rename_session',
        'sessionId': sessionId,
        'title': title,
      });
    }
    notifyListeners();
  }

  void clearSessionContext(String sessionId) {
    final session = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (session != null && session.serverId.isNotEmpty) {
      _connMgr.sendToServer(session.serverId, {
        'type': 'clear_context',
        'sessionId': sessionId,
      });
    } else {
      _ws.sendClearContext(sessionId);
    }
    // If this is the active session, clear local messages/todos
    if (_activeSessionId == sessionId) {
      _messages.clear();
      _todos.clear();
      _currentStreamingMessage = null;
      _lastUsage = null;
    }
    notifyListeners();
  }

  void compactCodexThread(String sessionId) {
    final session = _sessions.where((s) => s.id == sessionId).firstOrNull;
    final msg = {'type': 'compact_context', 'sessionId': sessionId};
    if (session != null && session.serverId.isNotEmpty) {
      _connMgr.sendToServer(session.serverId, msg);
    } else {
      _ws.send(msg);
    }
  }

  void rollbackCodexThread(String sessionId, {int numTurns = 1}) {
    final session = _sessions.where((s) => s.id == sessionId).firstOrNull;
    final msg = {
      'type': 'codex_rollback_thread',
      'sessionId': sessionId,
      'numTurns': numTurns,
    };
    if (session != null && session.serverId.isNotEmpty) {
      _connMgr.sendToServer(session.serverId, msg);
    } else {
      _ws.send(msg);
    }
  }

  Future<List<ArchiveEntry>> fetchArchives() {
    _archivesCompleter ??= Completer<List<ArchiveEntry>>();
    _connMgr.sendToAll({'type': 'list_archives'});
    return _archivesCompleter!.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _archivesCompleter = null;
        return _archives;
      },
    );
  }

  String? _serverIdForArchive(String sid, String ts) {
    final archive = _archives
        .where((a) => a.sid == sid && a.ts == ts)
        .firstOrNull;
    return archive != null && archive.serverId.isNotEmpty
        ? archive.serverId
        : null;
  }

  Future<List<dynamic>> fetchArchiveHistory(
    String sid,
    String ts, {
    String? serverId,
  }) {
    final ownerServerId = serverId ?? _serverIdForArchive(sid, ts);
    final key = '${ownerServerId ?? ''}_${sid}_$ts';
    final existing = _archiveHistoryCompleters[key];
    if (existing != null) return existing.future;
    final completer = Completer<List<dynamic>>();
    _archiveHistoryCompleters[key] = completer;
    final msg = {'type': 'get_archive_history', 'sid': sid, 'ts': ts};
    if (ownerServerId != null) {
      _connMgr.sendToServer(ownerServerId, msg);
    } else {
      _ws.sendGetArchiveHistory(sid, ts);
    }
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _archiveHistoryCompleters.remove(key);
        return <dynamic>[];
      },
    );
  }

  void restoreArchive(String sid, String ts, {String? serverId}) {
    final ownerServerId = serverId ?? _serverIdForArchive(sid, ts);
    final msg = {'type': 'restore_archive', 'sid': sid, 'ts': ts};
    if (ownerServerId != null) {
      _connMgr.sendToServer(ownerServerId, msg);
    } else {
      _ws.sendRestoreArchive(sid, ts);
    }
  }

  void deleteArchive(String sid, String ts, {String? serverId}) {
    final ownerServerId = serverId ?? _serverIdForArchive(sid, ts);
    _archives.removeWhere((a) => a.sid == sid && a.ts == ts);
    for (final archives in _perServerArchives.values) {
      archives.removeWhere((a) => a.sid == sid && a.ts == ts);
    }
    notifyListeners();
    final msg = {'type': 'delete_archive', 'sid': sid, 'ts': ts};
    if (ownerServerId != null) {
      _connMgr.sendToServer(ownerServerId, msg);
    } else {
      _ws.sendDeleteArchive(sid, ts);
    }
  }

  void setTtsEnabled(bool enabled) {
    _ttsEnabled = enabled;
    _ws.send({'type': 'set_tts', 'enabled': enabled});
    if (!enabled) {
      _tts.stop();
      _kokoroServerEngine.stop();
      _kokoroDeviceEngine.stop();
    }
    notifyListeners();
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('tts_enabled', enabled);
    });
  }

  void setColorfulCards(bool value) {
    _colorfulCards = value;
    notifyListeners();
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('colorful_cards', value);
    });
  }

  void setEffort(String effort) {
    _effort = effort;
    _ws.send({'type': 'set_effort', 'effort': effort});
    notifyListeners();
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('effort', effort);
    });
  }

  void setThinking(Map<String, dynamic> thinking) {
    _thinking = thinking;
    _ws.send({'type': 'set_thinking', 'thinking': thinking});
    notifyListeners();
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('thinking', jsonEncode(thinking));
    });
  }

  // Per-session disallowed tools
  List<String> getDisallowedTools(String sessionId) {
    return _sessionDisallowedTools[sessionId] ?? [];
  }

  Future<void> setDisallowedTools(String sessionId, List<String> tools) async {
    _sessionDisallowedTools[sessionId] = tools;
    _connMgr.send({'type': 'set_disallowed_tools', 'tools': tools});
    final prefs = await SharedPreferences.getInstance();
    prefs.setStringList('disallowed_tools_$sessionId', tools);
    notifyListeners();
  }

  // Per-session system prompt override
  String getSessionSystemPrompt(String sessionId) {
    return _sessionSystemPrompts[sessionId] ?? '';
  }

  String getEffectiveSystemPrompt(String sessionId) {
    final sessionOverride = _sessionSystemPrompts[sessionId] ?? '';
    if (sessionOverride.isNotEmpty) return sessionOverride;
    // Fall back to server-level default
    final session = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (session != null && session.serverId.isNotEmpty) {
      final config = _serverConfigs
          .where((c) => c.id == session.serverId)
          .firstOrNull;
      if (config != null && config.systemPrompt.isNotEmpty)
        return config.systemPrompt;
    }
    // Single server fallback
    if (_serverConfigs.length == 1 &&
        _serverConfigs.first.systemPrompt.isNotEmpty) {
      return _serverConfigs.first.systemPrompt;
    }
    return '';
  }

  Future<void> setSessionSystemPrompt(String sessionId, String prompt) async {
    _sessionSystemPrompts[sessionId] = prompt;
    final effective = getEffectiveSystemPrompt(sessionId);
    _connMgr.send({'type': 'set_system_prompt', 'prompt': effective});
    final prefs = await SharedPreferences.getInstance();
    if (prompt.isEmpty) {
      prefs.remove('system_prompt_$sessionId');
    } else {
      prefs.setString('system_prompt_$sessionId', prompt);
    }
    notifyListeners();
  }

  void dismissTodos() {
    _todos.clear();
    _messages.add(
      ChatMessage(
        id: 'todo_dismiss_${DateTime.now().microsecondsSinceEpoch}',
        sender: MessageSender.system,
        type: MessageType.taskNotification,
        timestamp: DateTime.now(),
        textContent: 'Task list dismissed',
        toolName: 'dismissed',
      ),
    );
    _addPrepend(
      '[The user dismissed the task list. Clear your todos with the TodoWrite tool (pass an empty array) before starting your next task.]',
    );
    notifyListeners();
  }

  bool _todosEqual(List<Map<String, dynamic>> a, List<Map<String, dynamic>> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i]['content'] != b[i]['content'] ||
          a[i]['status'] != b[i]['status'])
        return false;
    }
    return true;
  }

  String _computeTodoDiff(
    List<Map<String, dynamic>> oldTodos,
    List<Map<String, dynamic>> newTodos,
  ) {
    if (oldTodos.isEmpty && newTodos.isEmpty) return '';
    if (newTodos.isEmpty) return 'Cleared task list';

    // Build lookup of old todos by content
    final oldByContent = <String, String>{};
    for (final t in oldTodos) {
      final content = t['content'] as String? ?? '';
      final status = t['status'] as String? ?? 'pending';
      oldByContent[content] = status;
    }

    final changes = <String>[];

    if (oldTodos.isEmpty) {
      // All new
      for (final t in newTodos) {
        final content = t['content'] as String? ?? '';
        final status = t['status'] as String? ?? 'pending';
        if (status == 'in_progress') {
          changes.add('▶ $content');
        } else if (status == 'completed') {
          changes.add('✓ $content');
        } else {
          changes.add('+ $content');
        }
      }
    } else {
      // Diff
      final newByContent = <String, String>{};
      for (final t in newTodos) {
        final content = t['content'] as String? ?? '';
        final status = t['status'] as String? ?? 'pending';
        newByContent[content] = status;
      }

      // Status changes and new items
      for (final t in newTodos) {
        final content = t['content'] as String? ?? '';
        final newStatus = t['status'] as String? ?? 'pending';
        final oldStatus = oldByContent[content];

        if (oldStatus == null) {
          // New task
          changes.add('+ $content');
        } else if (oldStatus != newStatus) {
          // Status changed
          if (newStatus == 'completed') {
            changes.add('✓ $content');
          } else if (newStatus == 'in_progress') {
            changes.add('▶ $content');
          } else {
            changes.add('○ $content');
          }
        }
      }

      // Removed items
      for (final t in oldTodos) {
        final content = t['content'] as String? ?? '';
        if (!newByContent.containsKey(content)) {
          changes.add('- $content');
        }
      }
    }

    return changes.join('\n');
  }

  void _addPrepend(String text) {
    _pendingPrepends.add(text);
    _savePrepends();
  }

  bool _isLegacyCancelPrepend(String text) {
    return text.trim().startsWith(_legacyCancelPrepend);
  }

  void _dropLegacyCancelPrepends() {
    final before = _pendingPrepends.length;
    _pendingPrepends.removeWhere(_isLegacyCancelPrepend);
    if (_pendingPrepends.length != before) {
      _savePrepends();
    }
  }

  void _savePrepends() {
    if (_activeSessionId == null) return;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setStringList('prepends_$_activeSessionId', _pendingPrepends);
    });
  }

  void _loadPrepends() {
    final sessionId = _activeSessionId;
    if (sessionId == null) {
      _pendingPrepends = [];
      return;
    }
    SharedPreferences.getInstance().then((prefs) {
      if (_activeSessionId != sessionId) return;
      final loaded = prefs.getStringList('prepends_$sessionId') ?? [];
      _pendingPrepends = loaded
          .where((p) => !_isLegacyCancelPrepend(p))
          .toList();
      if (_pendingPrepends.length != loaded.length) {
        if (_pendingPrepends.isEmpty) {
          prefs.remove('prepends_$sessionId');
        } else {
          prefs.setStringList('prepends_$sessionId', _pendingPrepends);
        }
      }
    });
  }

  void _clearPrepends() {
    _pendingPrepends.clear();
    if (_activeSessionId != null) {
      SharedPreferences.getInstance().then((prefs) {
        prefs.remove('prepends_$_activeSessionId');
      });
    }
  }

  void stopTask(String taskId) {
    // Remove from background tasks immediately to prevent duplicate taps
    _backgroundTasks.remove(taskId);
    notifyListeners();
    _ws.sendStopTask(taskId);
  }

  void forkSession(String sessionId) {
    _activeSessionId = null;
    _currentStreamingMessage = null;
    _isProcessing = false;
    _ws.sendForkSession(sessionId);
    notifyListeners();
  }

  Future<void> initTtsVoices() async {
    await _tts.initialize();
    await _kokoroServerEngine.initialize();
    // Always pre-load on-device engine so isolate is warm when needed
    _kokoroDeviceEngine.initialize();
    // Restore saved voice
    final prefs = await SharedPreferences.getInstance();
    final savedVoice = prefs.getString('tts_voice');
    if (savedVoice != null) {
      await _tts.restoreVoice(savedVoice);
    }
    final savedKokoroVoice = prefs.getString('kokoro_voice');
    if (savedKokoroVoice != null) {
      await _kokoroServerEngine.restoreVoice(savedKokoroVoice);
      await _kokoroDeviceEngine.restoreVoice(savedKokoroVoice);
    }
    notifyListeners();
  }

  Future<void> setTtsVoice(TtsVoice voice) async {
    await _tts.setVoice(voice);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tts_voice', voice.name);
  }

  Future<void> previewTtsVoice(TtsVoice voice) async {
    await _tts.setVoice(voice);
    await _tts.speak('Hello, this is a preview of my voice.');
  }

  Future<void> setTtsEngineMode(TtsEngineMode mode) async {
    _ttsEngineMode = mode;
    // Stop any current speech
    _tts.stop();
    _kokoroServerEngine.stop();
    switch (mode) {
      case TtsEngineMode.system:
        _activeTtsEngine = _systemEngine;
        break;
      case TtsEngineMode.kokoroServer:
        _activeTtsEngine = _kokoroServerEngine;
        break;
      case TtsEngineMode.kokoroDevice:
        _activeTtsEngine = _kokoroDeviceEngine;
        _kokoroDeviceEngine.initialize();
        break;
    }
    // Sync to server
    final engineStr = mode == TtsEngineMode.kokoroServer
        ? 'kokoro_server'
        : mode == TtsEngineMode.kokoroDevice
        ? 'kokoro_device'
        : 'system';
    _ws.send({
      'type': 'set_tts_engine',
      'engine': engineStr,
      'voice': _kokoroServerEngine.selectedVoice?.id ?? 'af_heart',
    });
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tts_engine_mode', mode.name);
  }

  Future<void> setKokoroVoice(TtsEngineVoice voice) async {
    await _kokoroServerEngine.setVoice(voice);
    await _kokoroDeviceEngine.setVoice(voice);
    // Sync voice to server
    final engineStr = _ttsEngineMode == TtsEngineMode.kokoroDevice
        ? 'kokoro_device'
        : 'kokoro_server';
    _ws.send({
      'type': 'set_tts_engine',
      'engine': engineStr,
      'voice': voice.id,
    });
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('kokoro_voice', voice.id);
  }

  /// Get a direct server's connection details for HTTP model downloads.
  ({String host, int port, String token})? _getDirectServer() {
    if (_serverHost.isNotEmpty) {
      return (host: _serverHost, port: _serverPort, token: _authToken);
    }
    final direct = _serverConfigs
        .where((c) => !c.useRelay && c.host.isNotEmpty)
        .firstOrNull;
    if (direct != null) {
      return (host: direct.host, port: direct.port, token: direct.token);
    }
    return null;
  }

  Future<void> downloadKokoroModel([
    KokoroModel model = KokoroModel.v019,
  ]) async {
    final server = _getDirectServer();
    if (server == null)
      throw Exception('No direct server configured for model download');
    await _kokoroModelManager.downloadModel(
      serverHost: server.host,
      serverPort: server.port,
      authToken: server.token,
      model: model,
    );
    // After download, initialize/reinitialize the device engine
    await _kokoroDeviceEngine.reinitialize();
    notifyListeners();
  }

  /// Switch the active model version. If already downloaded, just swaps instantly.
  /// If not downloaded yet, downloads first.
  Future<void> setKokoroModel(KokoroModel model) async {
    final installed = await _kokoroModelManager.isModelVersionInstalled(model);
    if (installed) {
      await _kokoroModelManager.setActiveModel(model);
      await _kokoroDeviceEngine.reinitialize();
      notifyListeners();
    } else {
      await downloadKokoroModel(model);
    }
  }

  Future<void> deleteKokoroModel() async {
    _kokoroDeviceEngine.dispose();
    await _kokoroModelManager.deleteModel();
    if (_ttsEngineMode == TtsEngineMode.kokoroDevice) {
      await setTtsEngineMode(TtsEngineMode.system);
    }
    notifyListeners();
  }

  Future<void> deleteKokoroModelVersion(KokoroModel model) async {
    await _kokoroModelManager.deleteModelVersion(model);
    if (await _kokoroModelManager.isModelInstalled()) {
      await _kokoroDeviceEngine.reinitialize();
    } else {
      _kokoroDeviceEngine.dispose();
      if (_ttsEngineMode == TtsEngineMode.kokoroDevice) {
        await setTtsEngineMode(TtsEngineMode.system);
      }
    }
    notifyListeners();
  }

  Future<void> previewKokoroVoice(TtsEngineVoice voice) async {
    if (_ttsEngineMode == TtsEngineMode.kokoroDevice) {
      if (!_kokoroDeviceEngine.isModelLoaded) {
        await _kokoroDeviceEngine.initialize();
      }
      if (!_kokoroDeviceEngine.isModelLoaded) {
        throw Exception(
          'Kokoro on-device model is not loaded. Download it first.',
        );
      }
      await _kokoroDeviceEngine.setVoice(voice);
      await _kokoroDeviceEngine.speak('Hello, this is a preview of my voice.');
    } else if (_ttsEngineMode == TtsEngineMode.kokoroServer) {
      await _kokoroServerEngine.setVoice(voice);
      _ws.send({
        'type': 'request_tts_audio',
        'text': 'Hello, this is a preview of my voice.',
        'voice': voice.id,
        'speed': 1.0,
      });
    } else {
      throw Exception('Voice preview is only available for Kokoro engines.');
    }
  }

  String? _replaySpeakingText;
  String? get replaySpeakingText => _replaySpeakingText;

  Future<void> replaySpeak(String text) async {
    if (text.trim().isEmpty) return;
    _replaySpeakingText = text;
    notifyListeners();
    try {
      if (_ttsEngineMode == TtsEngineMode.kokoroServer) {
        await _kokoroServerEngine.speak(text);
      } else if (_ttsEngineMode == TtsEngineMode.kokoroDevice) {
        await _kokoroDeviceEngine.speak(text);
      } else {
        await _tts.speak(text);
      }
    } finally {
      _replaySpeakingText = null;
      notifyListeners();
    }
  }

  Future<void> stopReplaySpeak() async {
    if (_ttsEngineMode == TtsEngineMode.kokoroDevice) {
      await _kokoroDeviceEngine.stop();
    } else if (_ttsEngineMode == TtsEngineMode.kokoroServer) {
      _kokoroServerEngine.stop();
    } else {
      _tts.stop();
    }
    _replaySpeakingText = null;
    notifyListeners();
  }

  /// Get local path for a downloaded file, or null if not yet downloaded
  /// Get fileId for a server file path (latest)
  String? getFileId(String serverPath) => _filePathToId[serverPath];

  /// Get local path for a downloaded file by fileId
  String? getReceivedFilePath(String fileId) => _receivedFiles[fileId];

  /// Get server path for a file available for download by fileId
  String? getServerFilePath(String fileId) => _serverFiles[fileId];

  /// Whether a file is currently being downloaded by fileId
  bool isDownloading(String fileId) => _downloadingFiles.contains(fileId);

  /// Get download progress for a file (0.0 to 1.0), or null if not downloading
  double? getDownloadProgress(String fileId) => _downloadProgress[fileId];

  /// Handle file metadata from server (no data yet — just registers availability)
  void _handleFileMessage(Map<String, dynamic> msg) {
    final fileId = msg['fileId'] as String? ?? '';
    // Sanitize: strip path separators to prevent directory traversal
    var fileName = msg['fileName'] as String? ?? 'file';
    fileName = fileName.split('/').last.split('\\').last.replaceAll('..', '');
    if (fileName.isEmpty) fileName = 'file';
    final filePath = msg['filePath'] as String? ?? '';
    if (filePath.isNotEmpty && fileId.isNotEmpty) {
      _serverFiles[fileId] = filePath;
      _serverFileNames[fileId] = fileName;
      _filePathToId[filePath] = fileId;
      debugPrint(
        '[File] Available for download: $fileName (id=$fileId, path=$filePath)',
      );
      final messageSessionId = msg['sessionId'] as String? ?? '';
      final belongsToActiveSession =
          messageSessionId.isEmpty ||
          _activeSessionId == null ||
          messageSessionId == _activeSessionId;
      if (!belongsToActiveSession) {
        notifyListeners();
        return;
      }
      final hasVisibleCard = _messages.any(
        (m) =>
            m.type == MessageType.toolCall &&
            m.toolName == 'SendFile' &&
            m.toolInput?['file_path'] == filePath,
      );
      if (!hasVisibleCard) {
        _messages.add(
          ChatMessage.toolCall(
            tool: 'SendFile',
            input: {'file_path': filePath},
            toolUseId: 'file_$fileId',
          ),
        );
      }
      notifyListeners();
    }
  }

  /// Clear received state for a file so it can be re-downloaded
  void clearReceivedFile(String fileId) {
    _receivedFiles.remove(fileId);
    notifyListeners();
  }

  /// Request file data from server (user tapped download).
  /// All app-server file bytes move over the connected socket.
  void requestFile(String fileId) {
    final serverPath = _serverFiles[fileId];
    if (serverPath == null) return;
    _downloadingFiles.add(fileId);
    notifyListeners();
    _ws.send({
      'type': 'request_file',
      'filePath': serverPath,
      'fileId': fileId,
    });
  }

  /// Handle file data response from server (legacy non-chunked)
  Future<void> _handleFileData(Map<String, dynamic> msg) async {
    final fileId =
        msg['fileId'] as String? ?? msg['fileName'] as String? ?? 'file';
    final fileName = msg['fileName'] as String? ?? 'file';
    final base64Data = msg['data'] as String? ?? '';
    final fileSize = msg['fileSize'] as int? ?? 0;

    final byteCompleter = _fileBytesCompleters.remove(fileId);
    if (byteCompleter != null) {
      _fileBytesBuffers.remove(fileId);
      if (!byteCompleter.isCompleted) {
        byteCompleter.complete(base64Data.isEmpty ? null : base64Data);
      }
      return;
    }

    _downloadingFiles.remove(fileId);

    if (base64Data.isEmpty) {
      notifyListeners();
      return;
    }

    try {
      final downloadsDir = Directory('/storage/emulated/0/Download');
      if (!downloadsDir.existsSync()) {
        downloadsDir.createSync(recursive: true);
      }

      var targetFile = File('${downloadsDir.path}/$fileName');
      var counter = 1;
      while (targetFile.existsSync()) {
        final ext = fileName.contains('.')
            ? '.${fileName.split('.').last}'
            : '';
        final base = fileName.contains('.')
            ? fileName.substring(0, fileName.lastIndexOf('.'))
            : fileName;
        targetFile = File('${downloadsDir.path}/$base ($counter)$ext');
        counter++;
      }

      final bytes = base64Decode(base64Data);
      await targetFile.writeAsBytes(bytes);

      _receivedFiles[fileId] = targetFile.path;
      debugPrint(
        '[File] Saved: ${targetFile.path} (${(fileSize / 1024).toStringAsFixed(1)} KB)',
      );
      notifyListeners();
    } catch (e) {
      debugPrint('[File] Error saving file: $e');
      notifyListeners();
    }
  }

  /// Handle a file chunk from the server (chunked transfer)
  void _handleFileChunk(Map<String, dynamic> msg) {
    final fileId =
        msg['fileId'] as String? ?? msg['fileName'] as String? ?? 'file';
    final fileName = msg['fileName'] as String? ?? 'file';
    final chunkIndex = msg['chunkIndex'] as int? ?? 0;
    final totalChunks = msg['totalChunks'] as int? ?? 1;
    final base64Data = msg['data'] as String? ?? '';

    try {
      final bytes = base64Decode(base64Data);
      final byteCompleter = _fileBytesCompleters[fileId];
      if (byteCompleter != null) {
        _fileBytesBuffers[fileId]?.add(bytes);
        return;
      }

      // Open temp file on first chunk
      if (!_activeDownloads.containsKey(fileId)) {
        final safeId = fileId.replaceAll('/', '_').replaceAll(' ', '_');
        final tempPath = '/storage/emulated/0/Download/.$safeId.tmp';
        final tempFile = File(tempPath);
        _activeDownloads[fileId] = tempFile.openWrite();
        _downloadTempPaths[fileId] = tempPath;
        _downloadingFiles.add(fileId);
        debugPrint(
          '[File] Starting chunked download: $fileName (id=$fileId, $totalChunks chunks)',
        );
      }

      _activeDownloads[fileId]!.add(bytes);

      _downloadProgress[fileId] = (chunkIndex + 1) / totalChunks;
      notifyListeners();
    } catch (e) {
      debugPrint(
        '[File] Error handling chunk $chunkIndex/$totalChunks for $fileName: $e',
      );
    }
  }

  /// Handle file transfer complete (chunked transfer)
  Future<void> _handleFileComplete(Map<String, dynamic> msg) async {
    final fileId =
        msg['fileId'] as String? ?? msg['fileName'] as String? ?? 'file';
    final fileName = msg['fileName'] as String? ?? 'file';

    try {
      final byteCompleter = _fileBytesCompleters.remove(fileId);
      if (byteCompleter != null) {
        final bytes = _fileBytesBuffers.remove(fileId)?.takeBytes();
        if (!byteCompleter.isCompleted) {
          byteCompleter.complete(bytes == null ? null : base64Encode(bytes));
        }
        return;
      }

      // Close the temp file
      final sink = _activeDownloads.remove(fileId);
      await sink?.flush();
      await sink?.close();
      _lastNotifiedProgress.remove(fileId);

      final tempPath = _downloadTempPaths.remove(fileId);
      if (tempPath == null) {
        debugPrint('[File] Error: no temp path for $fileId');
        _downloadingFiles.remove(fileId);
        _downloadProgress.remove(fileId);
        notifyListeners();
        return;
      }

      final tempFile = File(tempPath);
      if (!tempFile.existsSync()) {
        debugPrint('[File] Error: temp file missing at $tempPath');
        _downloadingFiles.remove(fileId);
        _downloadProgress.remove(fileId);
        notifyListeners();
        return;
      }

      // Rename temp file to final name (handle duplicates)
      final downloadsDir = Directory('/storage/emulated/0/Download');
      var targetFile = File('${downloadsDir.path}/$fileName');
      var counter = 1;
      while (targetFile.existsSync()) {
        final ext = fileName.contains('.')
            ? '.${fileName.split('.').last}'
            : '';
        final base = fileName.contains('.')
            ? fileName.substring(0, fileName.lastIndexOf('.'))
            : fileName;
        targetFile = File('${downloadsDir.path}/$base ($counter)$ext');
        counter++;
      }

      // Try rename first, fall back to copy+delete
      try {
        await tempFile.rename(targetFile.path);
      } catch (_) {
        await tempFile.copy(targetFile.path);
        await tempFile.delete();
      }

      _receivedFiles[fileId] = targetFile.path;
      _downloadingFiles.remove(fileId);
      _downloadProgress.remove(fileId);
      debugPrint(
        '[File] Chunked download complete: ${targetFile.path} (fileId=$fileId)',
      );
      notifyListeners();
    } catch (e) {
      debugPrint(
        '[File] Error completing download for $fileName (fileId=$fileId): $e',
      );
      _downloadingFiles.remove(fileId);
      _downloadProgress.remove(fileId);
      notifyListeners();
    }
  }

  Future<void> toggleListening({String existingText = ''}) async {
    if (_isListening) {
      await stopListening();
    } else {
      await startListening(existingText: existingText);
    }
  }

  Future<void> startListening({String existingText = ''}) async {
    if (_isListening) return;
    if (_listeningStartInFlight) return;

    _listeningStartInFlight = true;
    _stopListeningAfterStart = false;
    try {
      await _speech.startListening(
        existingText: existingText,
        pushToTalk: _pushToTalk,
      );
    } finally {
      _listeningStartInFlight = false;
    }

    if (_stopListeningAfterStart) {
      _stopListeningAfterStart = false;
      if (_isListening) {
        await _speech.stopListening();
      }
    }
  }

  Future<void> stopListening() async {
    if (_listeningStartInFlight && !_isListening) {
      _stopListeningAfterStart = true;
      return;
    }
    if (!_isListening) return;
    await _speech.stopListening();
  }

  @override
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PushNotificationService.onTokenRefresh = null;
    _messageSub?.cancel();
    _statusSub?.cancel();
    _speechResultSub?.cancel();
    _speechStatusSub?.cancel();
    _connMgr.dispose();
    _speech.dispose();
    _tts.dispose();
    _subscriptionRequiredController.close();
    super.dispose();
  }
}

/// Per-upload runtime state. Tracks how many chunks the server has confirmed
/// receiving (used as a backpressure ack signal in the upload loop) and runs a
/// stall timer that fires the supplied callback if no progress event arrives
/// for 60s.
class _UploadState {
  _UploadState({required this.target, required this.onStall});

  final ChatMessage target;
  final void Function() onStall;

  int chunksAcked = 0;
  Completer<void>? _ackWaiter;
  Timer? _stallTimer;

  static const _stallTimeout = Duration(seconds: 30);

  bool _stalled = false;
  bool get stalled => _stalled;

  void start() => _resetStall();

  void noteAck(int receivedChunks) {
    chunksAcked = receivedChunks;
    _wakeWaiter();
    _resetStall();
  }

  Future<void> waitForAck() {
    if (_stalled) return Future.value();
    _ackWaiter ??= Completer<void>();
    return _ackWaiter!.future;
  }

  void _resetStall() {
    _stallTimer?.cancel();
    _stallTimer = Timer(_stallTimeout, _fireStall);
  }

  void _fireStall() {
    _stalled = true;
    onStall();
    // Critical: also wake any pending waitForAck so the upload loop unblocks
    // and observes the stalled completer instead of sitting forever.
    _wakeWaiter();
  }

  void _wakeWaiter() {
    final waiter = _ackWaiter;
    _ackWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  void dispose() {
    _stallTimer?.cancel();
    _stallTimer = null;
    _wakeWaiter();
  }
}
