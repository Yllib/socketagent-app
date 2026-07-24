import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/message.dart';
import '../models/message_reconciliation.dart';
import '../models/file_event_routing.dart';
import '../models/history_normalization.dart';
import '../models/history_response_gate.dart';
import '../models/history_backfill.dart';
import '../models/hard_stop_protocol.dart';
import '../models/composer_attachment.dart';
import '../models/html_plan.dart';
import '../models/archive_entry.dart';
import '../models/file_manager_entry.dart';
import '../screens/pair_screen.dart' show PairingResult;
import '../models/server_config.dart';
import '../models/raw_event.dart';
import '../models/scheduled_task_cache.dart';
import '../models/scheduled_task_update.dart';
import 'websocket_service.dart';
import 'secret_inventory_request_tracker.dart';
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
import 'relay_push_service.dart';
import 'crypto_service.dart';
import 'secure_storage_service.dart';
import 'adb_bridge_service.dart';
import 'tool_event_reconciler.dart';
import 'session_transcript_cache.dart';

const _codexAgentControlTypes = {
  'wait',
  'sendInput',
  'resumeAgent',
  'closeAgent',
};

class SdkSessionPage {
  const SdkSessionPage({
    required this.sessions,
    required this.total,
    required this.hasMore,
  });

  final List<Map<String, dynamic>> sessions;
  final int total;
  final bool hasMore;
}

String _stripTerminalControl(String value) {
  return value
      .replaceAll(
        RegExp(
          r'(?:\x1B\[[0-?]*[ -/]*[@-~]|\x9B[0-?]*[ -/]*[@-~]|\x1B\][^\x07]*(?:\x07|\x1B\\))',
        ),
        '',
      )
      .replaceAll(RegExp(r'\[(?:\d{1,3}(?:;\d{1,3})*)m'), '');
}

Map<String, String> _parseBackendDeviceAuth(String value) {
  final parsed = <String, String>{};
  final text = _stripTerminalControl(value);
  for (final match in RegExp(r'https?://[^\s)]+').allMatches(text)) {
    final candidate = (match.group(0) ?? '').replaceAll(RegExp(r'[,.]+$'), '');
    if (!(candidate.contains('/codex/device') ||
        candidate.contains('device'))) {
      continue;
    }
    parsed['authUrl'] ??= candidate;
    final urlCode = _parseBackendDeviceCodeFromUrl(candidate);
    if (urlCode != null && urlCode.isNotEmpty) {
      parsed['authCode'] ??= urlCode;
    }
  }

  final codeText = text.replaceAll(RegExp(r'https?://[^\s)]+'), ' ');
  final code =
      parsed['authCode'] ?? _parseBackendDeviceCodeAfterOneTime(codeText);

  if (code != null && code.isNotEmpty) {
    parsed['authCode'] = code;
  }
  return parsed;
}

String? _parseBackendDeviceCodeAfterOneTime(String text) {
  final oneTimeRe = RegExp(r'\bone-time\b', caseSensitive: false);
  final hyphenatedRe = RegExp(
    r'\b[A-Z0-9]{4,6}(?:-[A-Z0-9]{4,6})+\b',
    caseSensitive: false,
  );
  for (final marker in oneTimeRe.allMatches(text)) {
    final tail = text.substring(marker.end);
    final match = hyphenatedRe.firstMatch(tail);
    if (match == null) continue;
    final code = _normalizeBackendAuthCodeCandidate(
      match.group(0) ?? '',
      allowCompact: true,
    );
    if (code != null) return code;
  }
  return null;
}

String? _parseBackendDeviceCodeFromUrl(String candidate) {
  final uri = Uri.tryParse(candidate);
  if (uri == null) return null;
  for (final key in [
    'user_code',
    'userCode',
    'code',
    'device_code',
    'deviceCode',
  ]) {
    final value = uri.queryParameters[key];
    if (value == null || value.isEmpty) continue;
    final code = _normalizeBackendAuthCodeCandidate(value, allowCompact: true);
    if (code != null) return code;
  }
  return null;
}

const Set<String> _backendAuthCodeStopWords = {
  'STARTING',
  'AUTHORIZ',
  'AUTHORIZE',
  'AUTHCODE',
  'LOGINING',
  'LOGINCODE',
  'SIGNININ',
  'SIGNINCODE',
  'BROWSER',
  'OPENAI',
  'DEVICE',
  'DEVICECODE',
  'ENTERCODE',
  'TIMECODE',
  'ONETIMECODE',
  'VERIFICATIONCODE',
  'RUNNING',
  'WAITING',
  'PENDING',
  'COMPLETE',
  'CANCELLED',
};

bool _isBackendAuthCodeStopWord(String value) {
  final normalized = value.replaceAll(RegExp(r'[^A-Z0-9]'), '').toUpperCase();
  return _backendAuthCodeStopWords.contains(normalized);
}

String? _normalizeBackendAuthCodeCandidate(
  String value, {
  bool allowCompact = false,
}) {
  final trimmed = value.trim();
  final grouped = RegExp(
    r'^[A-Z0-9]{4}(?:[- \t][A-Z0-9]{4,6}){1,3}$',
    caseSensitive: false,
  ).firstMatch(trimmed)?.group(0);
  if (grouped != null) {
    final normalized = grouped.replaceAll(RegExp(r'[ \t]+'), '-').toUpperCase();
    if (!_isBackendAuthCodeStopWord(normalized) &&
        (allowCompact || RegExp(r'\d').hasMatch(normalized))) {
      return normalized;
    }
  }
  final compact = RegExp(
    r'^[A-Z0-9]{8,9}$',
    caseSensitive: false,
  ).firstMatch(trimmed)?.group(0);
  if (compact != null) {
    final normalized = compact.toUpperCase();
    if (!_isBackendAuthCodeStopWord(normalized) &&
        (allowCompact || RegExp(r'\d').hasMatch(normalized))) {
      return normalized;
    }
  }
  return null;
}

bool _isLocalRelayUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  return host == 'localhost' || host == '127.0.0.1' || host == '::1';
}

String _normalizeRelayUrl(String value) {
  final trimmed = value.trim();
  if (trimmed == 'ws://jarofdirt.info:9988' || _isLocalRelayUrl(trimmed)) {
    return 'wss://relay.jarofdirt.info';
  }
  return trimmed;
}

class BackendInstallState {
  BackendInstallState({
    required this.backend,
    required this.requestId,
    this.operation = 'repair',
    this.phase = 'install',
    this.status = 'running',
    this.message = '',
    this.authUrl,
    this.authCode,
    this.running = true,
    List<String>? output,
  }) : output = output ?? <String>[];

  final String backend;
  final String requestId;
  String operation;
  String phase;
  String status;
  String message;
  String? authUrl;
  String? authCode;
  bool running;
  final List<String> output;
  String _authTextTail = '';

  void apply(Map<String, dynamic> msg) {
    void absorbAuth(String value, {bool accumulate = false}) {
      var source = value;
      if (accumulate) {
        _authTextTail = '$_authTextTail\n$value';
        if (_authTextTail.length > 12000) {
          _authTextTail = _authTextTail.substring(_authTextTail.length - 12000);
        }
        source = _authTextTail;
      }
      final parsed = _parseBackendDeviceAuth(source);
      final parsedUrl = parsed['authUrl'];
      if (parsedUrl != null && parsedUrl.isNotEmpty) {
        authUrl = parsedUrl;
      }
      final parsedCode = parsed['authCode'];
      if (parsedCode != null && parsedCode.isNotEmpty) {
        authCode = parsedCode;
      }
    }

    operation = msg['operation'] as String? ?? operation;
    phase = msg['phase'] as String? ?? phase;
    status = msg['status'] as String? ?? status;
    final rawMessage = msg['message'] as String?;
    if (rawMessage != null) {
      message = _stripTerminalControl(rawMessage).trimRight();
      absorbAuth(message, accumulate: true);
    }
    final rawAuthUrl = msg['authUrl'] as String?;
    if (rawAuthUrl != null) {
      authUrl = _stripTerminalControl(rawAuthUrl).trim();
    }
    final rawAuthCode = msg['authCode'] as String?;
    if (rawAuthCode != null) {
      final normalizedAuthCode = _normalizeBackendAuthCodeCandidate(
        _stripTerminalControl(rawAuthCode),
        allowCompact: true,
      );
      if (normalizedAuthCode != null) {
        authCode = normalizedAuthCode;
      } else {
        authCode = null;
      }
    }

    final rawOutput = msg['output'] as String?;
    if (rawOutput != null && rawOutput.trim().isNotEmpty) {
      final cleanOutput = _stripTerminalControl(
        rawOutput,
      ).replaceAll('\r\n', '\n');
      absorbAuth(cleanOutput, accumulate: true);
      final lines = const LineSplitter()
          .convert(cleanOutput)
          .map((line) => line.trimRight())
          .where((line) => line.trim().isNotEmpty);
      output.addAll(lines);
      if (output.length > 120) {
        output.removeRange(0, output.length - 120);
      }
    }

    running =
        status == 'running' ||
        !(status == 'failed' || status == 'cancelled' || phase == 'probe');

    if (authCode != null &&
        _normalizeBackendAuthCodeCandidate(authCode!, allowCompact: true) ==
            null) {
      authCode = null;
    }
  }
}

class _RunningSessionInfo {
  const _RunningSessionInfo({
    required this.sessionId,
    required this.serverId,
    required this.serverName,
    required this.title,
    this.startedAt,
    this.compacting = false,
    this.suppressOngoingNotification = false,
  });

  final String sessionId;
  final String serverId;
  final String serverName;
  final String title;
  final DateTime? startedAt;
  final bool compacting;
  final bool suppressOngoingNotification;
}

class _DownloadProgressNotification {
  const _DownloadProgressNotification({
    required this.fileId,
    required this.fileName,
    required this.progress,
  });

  final String fileId;
  final String fileName;
  final double? progress;
}

class _PhoneAdbFileTransfer {
  _PhoneAdbFileTransfer({
    required this.path,
    required this.sink,
    required this.completer,
    required this.expectedSize,
  });

  final String path;
  final IOSink sink;
  final Completer<String> completer;
  final int expectedSize;
  int receivedBytes = 0;
}

class _PendingHardStop {
  _PendingHardStop({
    required this.requestId,
    required this.sessionId,
    required this.serverId,
    required this.cardId,
  });

  final String requestId;
  final String sessionId;
  final String serverId;
  final String cardId;
  Timer? retryTimer;
  int attempts = 0;

  PersistedHardStop toPersisted() => PersistedHardStop(
    requestId: requestId,
    sessionId: sessionId,
    serverId: serverId,
    cardId: cardId,
  );

  static _PendingHardStop fromPersisted(PersistedHardStop persisted) =>
      _PendingHardStop(
        requestId: persisted.requestId,
        sessionId: persisted.sessionId,
        serverId: persisted.serverId,
        cardId: persisted.cardId,
      );
}

class ChatProvider extends ChangeNotifier with WidgetsBindingObserver {
  static const String _legacyCancelPrepend =
      '[The user cancelled your previous action. Follow their instructions below.]';
  static const String _sessionCachePrefsKey = 'cached_session_lists_v1';
  static const String _scheduledTaskCachePrefsKey =
      'cached_scheduled_task_lists_v1';
  static const String _pushRegisteredServersPrefsKey =
      'push_registered_server_ids';
  static const String _pendingHardStopsPrefsKey = 'pending_hard_stops_v1';
  static const Duration _downloadNotificationMinInterval = Duration(
    milliseconds: 750,
  );
  static const String _downloadActionCancel = 'download_cancel';
  static const String _downloadActionRetry = 'download_retry';
  static const String _downloadActionDismiss = 'download_dismiss';
  static const String _downloadActionOpenSession = 'download_open_session';
  static const String _downloadActionOpenFile = 'download_open_file';

  final ConnectionManager _connMgr = ConnectionManager();

  /// Backwards-compat getter — routes to active server's WebSocketService.
  /// Most existing _ws.send() calls work unchanged through this.
  WebSocketService get _ws => _connMgr.active ?? _fallbackWs;
  WebSocketService get _sessionWs {
    final serverId = _activeSessionServerId;
    if (serverId != null && serverId.isNotEmpty) {
      return _connMgr.getConnection(serverId) ?? _ws;
    }
    return _ws;
  }

  void _sendToActiveSessionServer(Map<String, dynamic> message) {
    final serverId = _activeSessionServerId ?? _connMgr.activeServerId;
    if (serverId != null && serverId.isNotEmpty) {
      _connMgr.sendToServer(serverId, message);
    } else {
      _ws.send(message);
    }
  }

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
  final _backendAuthRequiredController =
      StreamController<Map<String, dynamic>>.broadcast();

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
  final StreamController<Map<String, dynamic>> _terminalEvents =
      StreamController.broadcast();
  String? _terminalServerId;
  Map<String, dynamic>? _terminalStatus;
  Map<String, dynamic>? _lastUsage;
  Map<String, dynamic>? _codexStatus;
  // All file maps keyed on fileId (hash of path+mtime+size from server)
  final Map<String, String> _receivedFiles = {}; // fileId → local path
  final Map<String, String> _serverFiles = {}; // fileId → server path
  final Map<String, String> _serverFileNames = {}; // fileId → display name
  final Map<String, int> _serverFileSizes = {}; // fileId → bytes
  final Map<String, String> _serverFileVersions =
      {}; // fileId → server identity
  final Map<String, String> _downloadServerIds = {}; // fileId → server id
  final Map<String, String> _downloadSessionIds = {}; // fileId → session id
  final Set<String> _downloadingFiles = {}; // fileId set
  final Set<String> _cancelledDownloads = {}; // fileId set
  final Map<String, double> _downloadProgress = {}; // fileId → progress
  final Map<String, String> _downloadErrors = {}; // fileId → error
  final Map<String, Timer> _downloadWatchdogs = {}; // fileId → watchdog timer
  final Map<String, int> _downloadRetryCounts = {}; // fileId → retry count
  final Map<String, double> _lastNotifiedProgress = {}; // throttle UI updates
  final Map<String, Timer> _downloadNotificationTimers = {};
  final Map<String, DateTime> _downloadNotificationLastShownAt = {};
  final Map<String, _DownloadProgressNotification>
  _pendingDownloadNotifications = {};
  final Map<String, int> _downloadReceivedBytes = {}; // fileId → bytes saved
  final Map<String, int> _downloadExpectedBytes = {}; // fileId → expected size
  final Map<String, IOSink> _activeDownloads = {}; // fileId → write sink
  final Map<String, String> _downloadTempPaths = {}; // fileId → temp path
  final Map<String, String> _socketDownloadTokens =
      {}; // fileId → active socket transfer token
  final Map<String, BytesBuilder> _fileBytesBuffers = {};
  final Map<String, Completer<String?>> _fileBytesCompleters = {};
  final Map<String, String> _filePathToId = {}; // serverPath → latest fileId
  final Map<String, String> _authRequestServers = {};
  final Map<String, String> _authRequestSessions = {};
  String? _activeSessionId;
  String? _activeSessionServerId;
  String? _activeSessionCwd;
  String? _activeSessionTitle;
  final Map<String, List<Map<String, dynamic>>> _skillsByServer = {};
  final Map<String, List<Map<String, dynamic>>> _codexSlashCommandsByServer =
      {};
  // Per-session notification toggles
  Set<String> _notifMutedSessions = {};
  final Set<String> _pushRegisteredServers = {};
  // Pinned sessions
  Set<String> _pinnedSessionIds = {};
  final Map<String, Session> _pendingArchivedSessions = {};
  final Map<String, DateTime> _archivedSessionTombstones = {};
  static const Duration _archiveTombstoneTtl = Duration(seconds: 30);
  // Persistent recent CWDs per server (serverId → ordered list, most recent first)
  final Map<String, List<String>> _recentCwds = {};
  // Backends each server supports. Health/auth state is tracked separately in
  // _serverBackendHealth so unhealthy backends can remain visible and repairable.
  final Map<String, List<String>> _serverBackends = {};
  final Map<String, List<Map<String, dynamic>>> _serverCodexCollaborationModes =
      {};
  final Map<String, BackendInstallState> _backendInstallStates = {};
  final Map<String, Timer> _backendInstallAckTimers = {};
  final Map<String, List<Map<String, dynamic>>> _serverBackendHealth = {};
  final Map<String, Map<String, dynamic>> _serverRuntimeInfo = {};
  final Map<String, _RunningSessionInfo> _runningSessionNotifications = {};
  final SessionTranscriptCache _transcriptCache = SessionTranscriptCache();
  final Map<String, Timer> _scheduledTaskRefreshRetries = {};
  final Map<String, String> _scheduledTaskLoadedRevisions = {};
  // Backend driving the currently active session ('claude' | 'codex' | null).
  // Surfaced by the chat header so the user knows what they're talking to.
  String? _activeSessionBackend;
  String? _viewingSessionId; // set by HomeScreen when user is on that screen
  String? _viewingServerId;
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
  DateTime? _currentPromptStartedAt;
  Timer? _promptRuntimeTimer;
  Timer? _initialHistoryTimeout;
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
  int _pendingInjectedMessageCount = 0;
  final Set<String> _pendingLocalUserMessageIds = {};
  // The visible bubble intentionally omits attachment metadata, while the
  // durable transcript stores the exact prompt sent to the server. Retain that
  // exact text until its positioned history event arrives so the live cache
  // never claims a complete cursor with a lossy user entry.
  final Map<String, String> _pendingCacheUserPromptContent = {};
  final List<Map<String, String>> _pendingImageLoads =
      []; // {toolUseId, filePath}
  bool _isLoadingHistory = false;
  bool _isRefreshingHistory = false;
  bool _isLoadingMore = false;
  int _historyWindowRevision = 0;
  int _historyOffset = 0; // index of oldest loaded entry (0 = all loaded)
  // The server deliberately bounds the first history paint. Keep paging after
  // that paint until a useful recent conversation window is present.
  bool _autoBackfillRecentPrompts = false;
  int _historyBackfillTargetUserPrompts = 1;
  String? _initialHistoryRequestId;
  String? _olderHistoryRequestId;
  int _historyRequestSequence = 0;
  final Map<String, DateTime> _historyOpenTraceStartedAt = {};
  final Map<String, _PendingHardStop> _pendingHardStops = {};
  Future<void> _pendingHardStopPersistence = Future<void>.value();
  bool _ttsEnabled = false;
  String _effort = 'high';
  bool _codexFastMode = false;
  bool _claudeAutoCompactEnabled = true;
  String _codexCollaborationMode = 'default';
  Map<String, dynamic> _thinking = {'type': 'adaptive'};
  List<String> _availableTools = [];
  // Per-session disallowed tools and system prompt caches
  final Map<String, List<String>> _sessionDisallowedTools = {};
  final Map<String, String> _sessionSystemPrompts = {};
  final Map<String, bool> _sessionCodexFastModes = {};
  final Map<String, bool> _sessionClaudeAutoCompact = {};
  final Set<String> _locallyClearedSessions = {};
  // Background tasks: taskId → {status, summary, outputFile}
  final Map<String, Map<String, dynamic>> _backgroundTasks = {};
  // Subagent tasks: toolUseId → {description, status}
  final Map<String, Map<String, dynamic>> _subagentTasks = {};
  ChatMessage? _currentStreamingMessage;
  String? _currentStreamingStreamId;
  ChatMessage? _currentThinkingMessage;
  final Map<String, ChatMessage> _streamingMessagesByKey = {};
  final Map<String, ChatMessage> _thinkingMessagesByKey = {};
  final Map<String, ChatMessage> _assistantMessagesByStreamKey = {};
  final Map<String, ChatMessage> _thinkingMessagesByStreamKey = {};
  final Set<String> _appliedSessionDeliveryIds = {};
  final List<String> _appliedSessionDeliveryOrder = [];
  final Set<String> _appliedSessionEventKeys = {};
  final List<String> _appliedSessionEventKeyOrder = [];
  // Tool events can straddle a reconnect/history replacement. Keep results
  // keyed by toolUseId until their call card is present instead of rendering a
  // nameless standalone Tool card.
  final ToolEventReconciler _toolEventReconciler = ToolEventReconciler();
  final Set<String> _suppressedToolUseIds = {};
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
  final List<PendingFileAttachment> _pendingFileAttachments = [];
  final List<PendingSecretAttachment> _pendingSecretAttachments = [];
  List<SecretMetadata> _secretInventory = [];
  bool _secretInventoryLoading = false;
  String? _secretInventoryError;
  final SecretInventoryRequestTracker _secretInventoryRequestTracker =
      SecretInventoryRequestTracker();
  final Map<String, Completer<SecretMetadata>> _secretWriteCompleters = {};
  final Map<String, Completer<void>> _secretDeleteCompleters = {};
  List<HtmlPlan> _htmlPlans = [];
  bool _htmlPlansLoading = false;
  String? _htmlPlansError;
  String? _htmlPlanListRequestId;
  Timer? _htmlPlanListTimeout;
  final Map<String, Completer<HtmlPlan>> _htmlPlanRenameCompleters = {};
  final Map<String, Completer<void>> _htmlPlanDeleteCompleters = {};
  final Map<String, Completer<List<HtmlPlanRevisionSummary>>>
  _htmlPlanRevisionListCompleters = {};
  final Map<String, Completer<HtmlPlanRevisionDetail>>
  _htmlPlanRevisionDetailCompleters = {};
  final Map<String, Completer<HtmlPlan>> _htmlPlanRollbackCompleters = {};
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

  // Multi-server
  List<ServerConfig> _serverConfigs = [];
  // Per-server session lists, merged into _sessions
  final Map<String, List<Session>> _perServerSessions = {};
  // Per-server installed plugin names (from status_sync)
  final Map<String, List<String>> _serverPlugins = {};
  final Map<String, int> _serverSecretManagementVersions = {};

  // Subscription
  String _subscriberEmail = '';
  String _subscriberToken = ''; // HMAC-signed token from relay
  bool _subscriptionActive = false;
  bool _subscriptionChecked = false;
  String _subscriptionStatus = ''; // "active", "trialing", "owner"
  DateTime? _trialEnd;
  DateTime? _periodEnd;
  bool _cancelAtPeriodEnd = false;
  DateTime? _subscriptionCheckedAt;
  Future<bool>? _subscriptionCheckInFlight;
  static const Duration _subscriptionRefreshInterval = Duration(hours: 6);

  final Completer<void> _settingsLoaded = Completer<void>();
  Completer<Map<String, dynamic>>? _pendingCwdCheck;
  String? _pendingCwdCheckRequestId;
  String? _pendingCwdCheckServerId;
  Map<String, dynamic>? _lastCwdCheck;
  Completer<Map<String, dynamic>>? _pendingDirList;
  final Map<String, Completer<SdkSessionPage>> _sdkSessionCompleters = {};
  final Map<String, String?> _sdkSessionRequestServers = {};
  final Map<String, String> _sdkSessionRequestCwds = {};
  final Map<String, int> _sdkSessionRequestLimits = {};
  final Map<String, Completer<FileManagerListing>> _fileManagerListCompleters =
      {};
  final Map<String, Completer<Map<String, dynamic>>>
  _fileManagerProtectedCompleters = {};
  final Map<String, Completer<Map<String, dynamic>>>
  _fileManagerOperationCompleters = {};
  final Map<String, Completer<Map<String, dynamic>>>
  _fileManagerTextCompleters = {};
  int _sdkSessionsRequestSeq = 0;
  Completer<Map<String, dynamic>>? _pendingVersionCheck;
  String? _pendingVersionCheckServerId;
  Completer<Map<String, dynamic>>? _pendingForceUpdate;
  Completer<Map<String, dynamic>?>? _pendingCodexStatus;
  final Map<String, Completer<bool>> _pushRegistrationCompleters = {};
  final Map<String, Completer<Map<String, dynamic>>>
  _adbBridgeSidecarCompleters = {};
  final Map<String, Completer<Map<String, dynamic>>> _adbCommandCompleters = {};
  final Map<String, _PhoneAdbFileTransfer> _phoneAdbFileTransfers = {};

  StreamSubscription? _messageSub;
  StreamSubscription? _statusSub;
  StreamSubscription? _speechResultSub;
  StreamSubscription? _speechStatusSub;
  Timer? _foregroundResumeTimer;
  DateTime? _backgroundedAt;

  List<ChatMessage> get messages => _messages;
  List<Session> get sessions => _sessions;
  List<Map<String, dynamic>> get todos => _todos;
  List<Map<String, dynamic>> get scheduledTasks => _scheduledTasks;
  List<ArchiveEntry> get archives => _archives;
  Stream<String> get archiveFeedback => _archiveFeedback.stream;
  Stream<Map<String, dynamic>> get terminalEvents => _terminalEvents.stream;
  Stream<Map<String, dynamic>> get backendAuthRequiredEvents =>
      _backendAuthRequiredController.stream;
  Map<String, dynamic>? get terminalStatus => _terminalStatus;
  String? get terminalServerId => _terminalServerId;
  Map<String, dynamic>? get lastUsage => _lastUsage;
  Map<String, dynamic>? get codexStatus => _codexStatus;
  String? get activeSessionId => _activeSessionId;
  String? get activeSessionCwd => _activeSessionCwd;
  String? get activeSessionTitle => _activeSessionTitle;

  // Session notifications
  bool isNotifEnabled(String sessionId) =>
      !_notifMutedSessions.contains(sessionId);

  bool isPushRegisteredForServer(String serverId) =>
      _pushRegisteredServers.contains(serverId);

  int get pushRegisteredServerCount => _pushRegisteredServers.length;

  void toggleSessionNotifications(String sessionId) {
    if (_notifMutedSessions.contains(sessionId)) {
      _notifMutedSessions.remove(sessionId);
    } else {
      _notifMutedSessions.add(sessionId);
    }
    SharedPreferences.getInstance().then((prefs) {
      prefs.setStringList('notif_muted_sessions', _notifMutedSessions.toList());
    });
    _syncOngoingSessionNotifications();
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

  void setViewingSession(String? sessionId, {String? serverId}) {
    final resolvedServerId = sessionId == null
        ? null
        : serverId ?? _connMgr.activeServerId;
    _viewingSessionId = sessionId;
    _viewingServerId = resolvedServerId;
    if (sessionId != null) {
      unawaited(
        _notifications.markSessionCompletionRead(
          _sessionCompletionNotificationId(
            sessionId,
            serverId: resolvedServerId,
          ),
        ),
      );
    }
    _syncOngoingSessionNotifications();
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

  void attachTerminal({
    String? serverId,
    String? cwd,
    int cols = 100,
    int rows = 30,
  }) {
    final sid = serverId ?? _connMgr.activeServerId;
    if (sid == null || sid.isEmpty) return;
    _terminalServerId = sid;
    _connMgr.sendToServer(sid, {
      'type': 'terminal_attach',
      if (cwd != null && cwd.trim().isNotEmpty) 'cwd': cwd.trim(),
      'cols': cols,
      'rows': rows,
    });
  }

  void sendTerminalInput(String data, {String? serverId}) {
    if (data.isEmpty) return;
    final sid = serverId ?? _terminalServerId ?? _connMgr.activeServerId;
    if (sid == null || sid.isEmpty) return;
    _connMgr.sendToServer(sid, {'type': 'terminal_input', 'data': data});
  }

  void resizeTerminal({
    required int cols,
    required int rows,
    String? serverId,
  }) {
    final sid = serverId ?? _terminalServerId ?? _connMgr.activeServerId;
    if (sid == null || sid.isEmpty) return;
    _connMgr.sendToServer(sid, {
      'type': 'terminal_resize',
      'cols': cols,
      'rows': rows,
    });
  }

  void detachTerminal({String? serverId}) {
    final sid = serverId ?? _terminalServerId;
    if (sid == null || sid.isEmpty) return;
    _connMgr.sendToServer(sid, {'type': 'terminal_detach'});
  }

  void killTerminal({String? serverId}) {
    final sid = serverId ?? _terminalServerId ?? _connMgr.activeServerId;
    if (sid == null || sid.isEmpty) return;
    _connMgr.sendToServer(sid, {'type': 'terminal_kill'});
  }

  int _sessionCompletionNotificationId(String sessionId, {String? serverId}) {
    return NotificationService.sessionCompletionId(
      sessionId,
      serverId: serverId,
    );
  }

  bool _isViewingSession(String sessionId, {String? serverId}) {
    if (!_appInForeground || _viewingSessionId != sessionId) return false;
    final viewingServerId = _viewingServerId;
    if (serverId != null &&
        serverId.isNotEmpty &&
        viewingServerId != null &&
        viewingServerId.isNotEmpty) {
      return viewingServerId == serverId;
    }
    return true;
  }

  String _runningSessionKey(String serverId, String sessionId) {
    return '$serverId\u0001$sessionId';
  }

  void _syncOngoingSessionNotifications() {
    // WebSocket state updates UI only. FCM owns Android notifications.
  }

  String _sessionTitleFor(String sessionId, {String? serverId}) {
    final exact = _sessions
        .where(
          (s) =>
              s.id == sessionId &&
              (serverId == null || serverId.isEmpty || s.serverId == serverId),
        )
        .firstOrNull;
    if (exact != null) {
      return exact.title.isNotEmpty ? exact.title : exact.cwd;
    }
    if (sessionId == _activeSessionId) return _sessionTitle();
    return 'Session';
  }

  void _markSessionRunning(
    String? sessionId, {
    String? serverId,
    String? titleOverride,
    DateTime? startedAt,
    bool compacting = false,
    bool suppressOngoingNotification = false,
    bool sync = true,
  }) {
    if (sessionId == null || sessionId.isEmpty) return;
    final sid = serverId ?? _connMgr.activeServerId ?? '';
    final config = sid.isEmpty
        ? null
        : _serverConfigs.where((c) => c.id == sid).firstOrNull;
    _runningSessionNotifications[_runningSessionKey(
      sid,
      sessionId,
    )] = _RunningSessionInfo(
      sessionId: sessionId,
      serverId: sid,
      serverName: config?.name ?? '',
      title: titleOverride?.trim().isNotEmpty == true
          ? titleOverride!.trim()
          : _sessionTitleFor(sessionId, serverId: sid),
      startedAt: startedAt,
      compacting: compacting,
      suppressOngoingNotification: suppressOngoingNotification,
    );
    if (sync) _syncOngoingSessionNotifications();
  }

  void _markSessionIdle(String? sessionId, {String? serverId}) {
    if (sessionId == null || sessionId.isEmpty) return;
    final matchingKeys = _runningSessionNotifications.keys.where((key) {
      final info = _runningSessionNotifications[key];
      if (info == null || info.sessionId != sessionId) return false;
      if (serverId == null || serverId.isEmpty) return true;
      return info.serverId == serverId;
    }).toList();
    for (final key in matchingKeys) {
      _runningSessionNotifications.remove(key);
    }
    _syncOngoingSessionNotifications();
  }

  void _replaceRunningSessionsForServer(
    String? serverId,
    Set<String> runningSessionIds,
    Map<String, DateTime?> startedAtBySessionId, {
    Map<String, String> titlesBySessionId = const <String, String>{},
    Set<String> compactingSessionIds = const <String>{},
    Set<String> suppressOngoingSessionIds = const <String>{},
  }) {
    final sid = serverId ?? '';
    final prefix = '$sid\u0001';
    _runningSessionNotifications.removeWhere(
      (key, _) => key.startsWith(prefix),
    );
    for (final sessionId in runningSessionIds) {
      _markSessionRunning(
        sessionId,
        serverId: sid,
        titleOverride: titlesBySessionId[sessionId],
        startedAt: startedAtBySessionId[sessionId],
        compacting: compactingSessionIds.contains(sessionId),
        suppressOngoingNotification: suppressOngoingSessionIds.contains(
          sessionId,
        ),
        sync: false,
      );
    }
    _syncOngoingSessionNotifications();
  }

  bool _shouldDisplayForegroundPushNotification(Map<String, dynamic> data) {
    final sessionId = data['sessionId'] as String?;
    if (sessionId == null || sessionId.isEmpty) return true;
    final serverId = data['serverId'] as String?;
    final kind = data['kind'] as String? ?? '';
    if (_notifMutedSessions.contains(sessionId)) return false;
    if (kind == 'tool_notification') return true;
    if (kind == 'session_started' || kind == 'session_running') return true;
    if (kind == 'session_finished') return true;
    if (_isViewingSession(sessionId, serverId: serverId)) return false;
    return true;
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
  Duration? get currentPromptElapsed {
    final startedAt = _currentPromptStartedAt;
    if (!_isProcessing || startedAt == null) return null;
    final elapsed = DateTime.now().difference(startedAt);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  bool get isCompacting => _isCompacting;
  bool get requiresAction => _requiresAction;
  String? get permissionMode => _permissionMode;
  bool get isPlanMode => _permissionMode == 'plan';
  bool get isRateLimited => _isRateLimited;
  double? get rateLimitUtilization => _rateLimitUtilization;
  bool get isRetrying => _isRetrying;
  String? get activeHookName => _activeHookName;
  List<String> serverPlugins(String serverId) => _serverPlugins[serverId] ?? [];
  List<Map<String, dynamic>> backendHealthForServer(String serverId) =>
      _serverBackendHealth[serverId] ?? const <Map<String, dynamic>>[];
  Map<String, dynamic> serverRuntimeInfo(String serverId) =>
      Map.unmodifiable(_serverRuntimeInfo[serverId] ?? const {});

  Map<String, dynamic>? backendWarningForServer(String serverId) {
    final health = backendHealthForServer(serverId);
    for (final item in health) {
      final severity = item['severity'] as String?;
      if (severity == 'error') return item;
    }
    for (final item in health) {
      final severity = item['severity'] as String?;
      if (severity == 'warning') return item;
    }
    return null;
  }

  Map<String, dynamic>? get contextUsage => _contextUsage;
  List<String> get promptSuggestions => _promptSuggestions;
  List<dynamic>? get supportedCommands => _supportedCommands;
  List<dynamic>? get supportedAgents => _supportedAgents;
  String get codexCollaborationMode => _codexCollaborationMode;

  DateTime? _parseServerDateTime(dynamic value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value)?.toLocal();
  }

  DateTime? _activeStartedAtFromStatusSync(Map<String, dynamic> msg) {
    final sessionId = _activeSessionId;
    final values = msg['sessionActiveStartedAt'];
    if (sessionId == null || values is! Map) return null;
    return _parseServerDateTime(values[sessionId]);
  }

  void _startPromptRuntime({
    DateTime? startedAt,
    bool replace = false,
    String? titleOverride,
    bool suppressOngoingNotification = false,
  }) {
    final effectiveStartedAt = startedAt ?? DateTime.now();
    if (replace || _currentPromptStartedAt == null) {
      _currentPromptStartedAt = effectiveStartedAt;
    }
    _promptRuntimeTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isProcessing || _currentPromptStartedAt == null) {
        _stopPromptRuntime();
        return;
      }
      notifyListeners();
    });
    _markSessionRunning(
      _activeSessionId,
      serverId: _connMgr.activeServerId,
      titleOverride: titleOverride,
      startedAt: _currentPromptStartedAt,
      compacting: _isCompacting,
      suppressOngoingNotification: suppressOngoingNotification,
    );
  }

  void _stopPromptRuntime() {
    _processingSetAt = null;
    _currentPromptStartedAt = null;
    _promptRuntimeTimer?.cancel();
    _promptRuntimeTimer = null;
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
      final nativeCommands = (_codexSlashCommandsByServer[serverId] ?? const [])
          .map((command) {
            final mapped = Map<String, dynamic>.from(command);
            return {
              ...mapped,
              'name': _cleanSlashName((mapped['name'] ?? '').toString()),
              'kind': 'command',
              'agent': 'codex',
            };
          })
          .where((command) {
            return (command['name'] as String? ?? '').isNotEmpty &&
                (command['name'] as String) != 'skills';
          })
          .toList();
      final skills = _skillsByServer[serverId] ?? const [];
      final skillCommands = skills
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
      nativeCommands.sort(
        (a, b) =>
            (a['name'] as String? ?? '').compareTo(b['name'] as String? ?? ''),
      );
      skillCommands.sort(
        (a, b) =>
            (a['name'] as String? ?? '').compareTo(b['name'] as String? ?? ''),
      );
      return [...nativeCommands, ...skillCommands];
    }

    final merged = <String, Map<String, dynamic>>{};
    final commands = _supportedCommands ?? const [];
    for (final command
        in commands
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
            .where((cmd) => (cmd['name'] as String? ?? '').isNotEmpty)) {
      merged[(command['name'] as String).toLowerCase()] = command;
    }

    final serverId = _connMgr.activeServerId;
    final skills = serverId == null
        ? const <Map<String, dynamic>>[]
        : _skillsByServer[serverId] ?? const <Map<String, dynamic>>[];
    final localClaudeCommands = skills
        .where(
          (skill) =>
              skill['agent'] == 'claude' &&
              (skill['name'] as String? ?? '').isNotEmpty,
        )
        .map((skill) {
          final cleanName = _cleanSlashName(skill['name'] as String? ?? '');
          return {
            ...skill,
            'name': cleanName,
            'kind': skill['format'] == 'skill' ? 'skill' : 'command',
            'agent': 'claude',
          };
        })
        .where((cmd) => (cmd['name'] as String? ?? '').isNotEmpty);
    for (final command in localClaudeCommands) {
      merged.putIfAbsent(
        (command['name'] as String).toLowerCase(),
        () => command,
      );
    }

    final result = merged.values.toList();
    result.sort(
      (a, b) =>
          (a['name'] as String? ?? '').compareTo(b['name'] as String? ?? ''),
    );
    return result;
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
  bool get isRefreshingHistory => _isRefreshingHistory;
  bool get isLoadingMore => _isLoadingMore;
  int get historyWindowRevision => _historyWindowRevision;
  bool get hasMoreHistory => _historyOffset > 0;
  bool get rawMode => _rawMode;
  List<SdkItem> get rawItems => _rawItems;
  bool get ttsEnabled => _ttsEnabled;
  String get effort => _effort;
  bool get codexFastMode => _codexFastMode;
  bool get claudeAutoCompactEnabled => _claudeAutoCompactEnabled;
  Map<String, dynamic> get thinking => _thinking;
  Map<String, Map<String, dynamic>> get backgroundTasks => _backgroundTasks;

  Set<String> _activeBackgroundTaskIds() {
    return _backgroundTasks.entries
        .where((entry) {
          final status = entry.value['status']?.toString() ?? 'running';
          return status == 'running' || status == 'started';
        })
        .map((entry) => entry.key)
        .toSet();
  }

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
    if (_pendingInjectedMessageCount == 0) return visible;

    final queued = visible.where(_isPendingInjectedMessage).toList();
    if (queued.isEmpty) return visible;

    return [...visible.where((m) => !queued.contains(m)), ...queued];
  }

  /// Get child messages for a subagent by its toolUseId
  List<ChatMessage> getSubagentChildren(String toolUseId) {
    return _messages.where((m) => m.parentToolUseId == toolUseId).toList();
  }

  bool get hasAttachment =>
      _pendingFileAttachments.isNotEmpty ||
      _pendingSecretAttachments.isNotEmpty;
  List<PendingFileAttachment> get pendingFileAttachments =>
      List.unmodifiable(_pendingFileAttachments);
  List<PendingSecretAttachment> get pendingSecretAttachments =>
      List.unmodifiable(_pendingSecretAttachments);
  List<SecretMetadata> get secretInventory =>
      List.unmodifiable(_secretInventory);
  bool get secretInventoryLoading => _secretInventoryLoading;
  String? get secretInventoryError => _secretInventoryError;
  List<HtmlPlan> get htmlPlans => List.unmodifiable(_htmlPlans);
  bool get htmlPlansLoading => _htmlPlansLoading;
  String? get htmlPlansError => _htmlPlansError;
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
  WebSocketService get ws => _ws;
  ConnectionManager get connMgr => _connMgr;
  List<ServerConfig> get serverConfigs => _serverConfigs;
  String? get activeServerId => _connMgr.activeServerId;
  Map<String, dynamic>? get lastCwdCheck => _lastCwdCheck;

  ConnectionStatus sessionServerStatus(Session session) {
    if (session.serverId.isNotEmpty) {
      return _connMgr.statusOf(session.serverId);
    }
    return _connectionStatus;
  }

  bool isSessionAvailable(Session session) =>
      sessionServerStatus(session) == ConnectionStatus.connected;

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
    final ownerServerId = resolveDownloadServerId(
      serverId,
      _connMgr.activeServerId,
    );
    if (ownerServerId != null) {
      _downloadServerIds[fileId] = ownerServerId;
    }

    final request = {
      'type': 'request_file',
      'filePath': filePath,
      'fileId': fileId,
    };
    if (ownerServerId != null) {
      _connMgr.sendToServer(ownerServerId, request);
    } else {
      _connMgr.send(request);
    }

    return completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _fileBytesCompleters.remove(fileId);
        _fileBytesBuffers.remove(fileId);
        _downloadReceivedBytes.remove(fileId);
        _downloadServerIds.remove(fileId);
        return null;
      },
    );
  }

  SherpaSpeechService get speech => _speech;
  AsrModelManager get asrModelManager => _asrModelManager;
  CryptoService get crypto => _crypto;
  ConnectionMode get connectionMode => _connMgr.active?.mode ?? _ws.mode;
  Future<void> get settingsReady => _settingsLoaded.future;
  String get subscriberEmail => _subscriberEmail;
  String get subscriberToken => _subscriberToken;
  bool get subscriptionActive => _subscriptionActive;
  bool get subscriptionChecked => _subscriptionChecked;
  String get subscriptionStatus => _subscriptionStatus;
  DateTime? get trialEnd => _trialEnd;
  DateTime? get periodEnd => _periodEnd;
  bool get cancelAtPeriodEnd => _cancelAtPeriodEnd;
  bool get hasCachedRelayAccess =>
      _subscriberToken.isNotEmpty &&
      (!_subscriptionChecked || _subscriptionActive);
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
    PushNotificationService.onTokenRefresh = _handlePushTokenRefresh;
    PushNotificationService.shouldDisplayForegroundNotification =
        _shouldDisplayForegroundPushNotification;
    PushNotificationService.shouldBadgeForegroundSessionCompletion = (data) {
      final sessionId = data['sessionId'] as String? ?? '';
      final serverId = data['serverId'] as String?;
      return sessionId.isEmpty ||
          !_isViewingSession(sessionId, serverId: serverId);
    };
    _loadSettings();
    _setupListeners();
    unawaited(AdbBridgeService.instance.restoreLocalAdbConnection());
  }

  @override
  void notifyListeners() {
    if (_pendingInjectedMessageCount > 0) {
      _keepPendingInjectedMessagesAtEnd();
    }
    super.notifyListeners();
  }

  bool _isPendingInjectedMessage(ChatMessage m) {
    return m.sender == MessageSender.user &&
        m.isPending &&
        m.injectionPriority != null;
  }

  void _recountPendingInjectedMessages() {
    _pendingInjectedMessageCount = _messages
        .where(_isPendingInjectedMessage)
        .length;
  }

  void _keepPendingInjectedMessagesAtEnd() {
    final pending = _messages.where(_isPendingInjectedMessage).toList();
    _pendingInjectedMessageCount = pending.length;
    if (pending.isEmpty) return;

    final pendingIds = pending.map((m) => m.id).toSet();
    _messages.removeWhere((m) => pendingIds.contains(m.id));
    _messages.addAll(pending);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    _appInForeground = resumed;
    if (resumed) {
      _syncOngoingSessionNotifications();
      requestServerSettings();
      _resumeActiveSessionAfterForeground();
    } else {
      _backgroundedAt ??= DateTime.now();
      _syncOngoingSessionNotifications();
    }
  }

  void _resumeActiveSessionAfterForeground() {
    _foregroundResumeTimer?.cancel();
    _foregroundResumeTimer = Timer(const Duration(milliseconds: 250), () {
      final sessionId = _activeSessionId;
      final serverId = _connMgr.activeServerId;
      if (sessionId == null || serverId == null) return;

      final wasAwayFor = _backgroundedAt == null
          ? Duration.zero
          : DateTime.now().difference(_backgroundedAt!);
      _backgroundedAt = null;

      final ws = _connMgr.getConnection(serverId);
      if (ws == null) return;

      // Android can suspend a socket without us immediately seeing onDone.
      // Reconnect after a real background stint; otherwise just reattach.
      if (wasAwayFor > const Duration(seconds: 1) ||
          ws.status != ConnectionStatus.connected) {
        ws.connect(force: wasAwayFor > const Duration(seconds: 1));
      } else {
        // The still-open socket is already attached to this session. Asking
        // for a full resume here creates a history snapshot on every brief
        // Android lifecycle wobble, which can race live stream events.
        _connMgr.sendToServer(serverId, {'type': 'get_status_sync'});
      }
    });
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
      // Migrate relay URLs that cannot work from the phone.
      bool relayMigrated = false;
      _serverConfigs = _serverConfigs.map((c) {
        final normalizedRelayUrl = _normalizeRelayUrl(c.relayUrl);
        if (normalizedRelayUrl != c.relayUrl) {
          relayMigrated = true;
          return c.copyWith(relayUrl: normalizedRelayUrl);
        }
        return c;
      }).toList();
      final dedupedConfigs = dedupeServerConfigs(_serverConfigs);
      final duplicateConfigsRemoved =
          dedupedConfigs.length != _serverConfigs.length;
      _serverConfigs = dedupedConfigs;
      if (relayMigrated || duplicateConfigsRemoved) {
        await _saveServerConfigs();
      }
    }
    // Migrate old single-server config if no multi-server configs exist
    if (_serverConfigs.isEmpty && _serverHost.isNotEmpty) {
      // Migrate global relay pairing data into the server config
      final relayUrl = _normalizeRelayUrl(prefs.getString('relay_url') ?? '');
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

    await _loadSessionCache(prefs);
    unawaited(
      _transcriptCache.prewarm(
        _sessions
            .take(SessionTranscriptCache.maxSnapshots)
            .map(
              (session) => (serverId: session.serverId, sessionId: session.id),
            ),
      ),
    );
    _loadScheduledTaskCache(prefs);
    _pushRegisteredServers
      ..clear()
      ..addAll(
        prefs.getStringList(_pushRegisteredServersPrefsKey) ?? const <String>[],
      );
    _pushRegisteredServers.retainAll(_serverConfigs.map((c) => c.id).toSet());

    // Initialize ConnectionManager with server configs (per-server relay)
    _connMgr.setSubscriberToken(_subscriberToken);
    await _connMgr.setServers(_serverConfigs);
    _restorePendingHardStops(prefs);
    await _registerPushNotifications();
    _lastServerStartedAt = prefs.getString('server_started_at');
    _notifMutedSessions = (prefs.getStringList('notif_muted_sessions') ?? [])
        .toSet();
    _pinnedSessionIds = (prefs.getStringList('pinned_sessions') ?? []).toSet();
    // Recent CWDs are now server-side — loaded via get_recent_cwds on connect
    _ttsEnabled = prefs.getBool('tts_enabled') ?? false;
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

  Future<void> _savePushRegisteredServers() async {
    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    _cachedPrefs = prefs;
    await prefs.setStringList(
      _pushRegisteredServersPrefsKey,
      _pushRegisteredServers.toList(),
    );
  }

  void _markPushRegistered(String? serverId) {
    if (serverId == null || serverId.isEmpty) return;
    final completer = _pushRegistrationCompleters.remove(serverId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(true);
    }
    if (_pushRegisteredServers.add(serverId)) {
      unawaited(_savePushRegisteredServers());
      notifyListeners();
    }
  }

  void _markPushUnregistered(String? serverId) {
    if (serverId == null || serverId.isEmpty) return;
    final completer = _pushRegistrationCompleters.remove(serverId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(true);
    }
    if (_pushRegisteredServers.remove(serverId)) {
      unawaited(_savePushRegisteredServers());
      notifyListeners();
    }
  }

  void _handlePushTokenRefresh(String token) {
    unawaited(_registerPushNotifications(fcmToken: token));
  }

  Future<bool> _registerPushNotifications({
    String? serverId,
    String? fcmToken,
  }) async {
    final token = fcmToken ?? await PushNotificationService().getFcmToken();
    if (token == null || token.isEmpty) return false;
    final message = {
      'type': 'register_push_token',
      'fcmToken': token,
      'platform': 'android',
    };
    if (serverId != null) {
      final config = _serverConfigs
          .where((item) => item.id == serverId)
          .firstOrNull;
      if (config == null) return false;
      final ws = _connMgr.getConnection(serverId);
      if (ws?.status != ConnectionStatus.connected) return false;
      if (config.isRelayPaired) {
        final relayRegistered = await RelayPushService.register(
          relayUrl: config.relayUrl,
          pairingToken: config.pairingToken,
          subscriberToken: _subscriberToken,
          fcmToken: token,
          serverId: serverId,
        );
        if (!relayRegistered) {
          debugPrint('[Push] Relay FCM registration failed for $serverId');
          return false;
        }
      }
      ws!.send({...message, 'appServerId': serverId});
      return true;
    }
    var sent = false;
    for (final config in _serverConfigs) {
      if (!_pushRegisteredServers.contains(config.id)) continue;
      final ws = _connMgr.getConnection(config.id);
      if (ws?.status == ConnectionStatus.connected) {
        if (config.isRelayPaired) {
          final relayRegistered = await RelayPushService.register(
            relayUrl: config.relayUrl,
            pairingToken: config.pairingToken,
            subscriberToken: _subscriberToken,
            fcmToken: token,
            serverId: config.id,
          );
          if (!relayRegistered) {
            debugPrint('[Push] Relay FCM registration failed for ${config.id}');
            continue;
          }
        }
        ws!.send({...message, 'appServerId': config.id});
        sent = true;
      }
    }
    return sent;
  }

  Future<bool> registerPushNotificationsNow() => _registerPushNotifications();

  Future<bool> registerPushNotificationsForServer(String serverId) async {
    _pushRegistrationCompleters.remove(serverId)?.complete(false);
    final completer = Completer<bool>();
    _pushRegistrationCompleters[serverId] = completer;

    final sent = await _registerPushNotifications(serverId: serverId);
    if (!sent) {
      _pushRegistrationCompleters.remove(serverId);
      if (!completer.isCompleted) completer.complete(false);
      return false;
    }

    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        if (_pushRegistrationCompleters[serverId] == completer) {
          _pushRegistrationCompleters.remove(serverId);
        }
        return _pushRegisteredServers.contains(serverId);
      },
    );
  }

  Future<bool> unregisterPushNotificationsForServer(String serverId) async {
    _pushRegistrationCompleters.remove(serverId)?.complete(false);
    final completer = Completer<bool>();
    _pushRegistrationCompleters[serverId] = completer;

    final token = await PushNotificationService().getFcmToken();
    final ws = _connMgr.getConnection(serverId);
    if (token == null ||
        token.isEmpty ||
        ws?.status != ConnectionStatus.connected) {
      _pushRegistrationCompleters.remove(serverId);
      if (!completer.isCompleted) completer.complete(false);
      return false;
    }

    ws!.send({
      'type': 'unregister_push_token',
      'fcmToken': token,
      'appServerId': serverId,
    });

    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        if (_pushRegistrationCompleters[serverId] == completer) {
          _pushRegistrationCompleters.remove(serverId);
        }
        return !_pushRegisteredServers.contains(serverId);
      },
    );
  }

  Future<void> _syncPushRegistrationForServer(String serverId) async {
    final ws = _connMgr.getConnection(serverId);
    if (ws?.status != ConnectionStatus.connected) return;

    if (_pushRegisteredServers.contains(serverId)) {
      await _registerPushNotifications(serverId: serverId);
      return;
    }

    final token = await PushNotificationService().getFcmToken();
    if (token == null || token.isEmpty) return;
    ws!.send({
      'type': 'get_push_registration',
      'fcmToken': token,
      'appServerId': serverId,
    });
  }

  Future<void> _captureRelayPairingFromCapabilities(
    String serverId,
    Map<String, dynamic> msg,
  ) async {
    final relay = msg['relayPairing'];
    final directE2e = msg['directE2e'];
    final rawRelayUrl = relay is Map ? relay['relayUrl'] as String? ?? '' : '';
    final relayUrl = _normalizeRelayUrl(rawRelayUrl);
    final pairingToken = relay is Map
        ? relay['pairingToken'] as String? ?? ''
        : '';
    final relayServerPubkey = relay is Map
        ? relay['serverPubkey'] as String? ?? ''
        : '';
    final directServerPubkey = directE2e is Map
        ? directE2e['serverPubkey'] as String? ?? ''
        : '';
    final idx = _serverConfigs.indexWhere((c) => c.id == serverId);
    if (idx < 0) return;
    final existing = _serverConfigs[idx];
    if (!existing.useRelay &&
        existing.serverPubkey.isEmpty &&
        directServerPubkey.isNotEmpty) {
      debugPrint(
        '[Direct E2E] Ignoring server public key learned over untrusted direct socket',
      );
      return;
    }
    final serverPubkey = relayServerPubkey.isNotEmpty
        ? relayServerPubkey
        : directServerPubkey;
    if (serverPubkey.isEmpty) {
      return;
    }
    final effectiveRelayUrl = relayUrl.isEmpty
        ? existing.relayUrl
        : _isLocalRelayUrl(rawRelayUrl) &&
              existing.relayUrl.isNotEmpty &&
              !_isLocalRelayUrl(existing.relayUrl)
        ? existing.relayUrl
        : relayUrl;
    final effectivePairingToken = pairingToken.isEmpty
        ? existing.pairingToken
        : pairingToken;
    if (existing.relayUrl == effectiveRelayUrl &&
        existing.pairingToken == effectivePairingToken &&
        existing.serverPubkey == serverPubkey) {
      return;
    }
    final shouldReconnectForDirectE2e =
        !existing.useRelay && existing.serverPubkey != serverPubkey;

    _serverConfigs[idx] = existing.copyWith(
      relayUrl: effectiveRelayUrl,
      pairingToken: effectivePairingToken,
      serverPubkey: serverPubkey,
    );
    await _saveServerConfigs();
    if (shouldReconnectForDirectE2e) {
      _connMgr.getConnection(serverId)?.disconnect();
    }
    await _connMgr.setServers(_serverConfigs);
    if (shouldReconnectForDirectE2e) {
      _connMgr.getConnection(serverId)?.connect();
    }
    await _registerPushNotifications();
    notifyListeners();
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
    _serverConfigs.add(config);
    await _saveServerConfigs();
    await _connMgr.setServers(_serverConfigs);
    await _registerPushNotifications();
    notifyListeners();
  }

  Future<void> updateServer(ServerConfig config) async {
    final idx = _serverConfigs.indexWhere((c) => c.id == config.id);
    final previous = idx >= 0 ? _serverConfigs[idx] : null;
    final systemPromptEditable =
        _connMgr.statusOf(config.id) == ConnectionStatus.connected;
    if (idx >= 0) {
      _serverConfigs[idx] = config;
    } else {
      _serverConfigs.add(config);
    }
    await _saveServerConfigs();
    final reconnect =
        previous == null || _requiresServerReconnect(previous, config);
    if (reconnect) {
      _connMgr.getConnection(config.id)?.disconnect();
    }
    await _connMgr.setServers(_serverConfigs);
    await _registerPushNotifications();
    if (reconnect) {
      _connMgr.getConnection(config.id)?.connect();
    }
    _sendServerSettings(
      config.id,
      defaultCwd: config.defaultCwd,
      systemPrompt: systemPromptEditable ? config.systemPrompt : null,
    );
    notifyListeners();
  }

  bool _requiresServerReconnect(ServerConfig previous, ServerConfig next) {
    return previous.host != next.host ||
        previous.port != next.port ||
        previous.token != next.token ||
        previous.useRelay != next.useRelay ||
        previous.relayUrl != next.relayUrl ||
        previous.pairingToken != next.pairingToken ||
        previous.serverPubkey != next.serverPubkey;
  }

  Future<void> removeServer(String serverId) async {
    _serverConfigs.removeWhere((c) => c.id == serverId);
    _perServerSessions.remove(serverId);
    _perServerScheduledTasks.remove(serverId);
    _scheduledTaskLoadedRevisions.remove(serverId);
    _scheduledTaskRefreshRetries.remove(serverId)?.cancel();
    _rebuildScheduledTaskList();
    final removedPushRegistration = _pushRegisteredServers.remove(serverId);
    await _saveServerConfigs();
    if (removedPushRegistration) {
      await _savePushRegisteredServers();
    }
    await _saveSessionCache();
    await _saveScheduledTaskCache();
    await _connMgr.setServers(_serverConfigs);
    await _registerPushNotifications();
    _rebuildSessionList();
    notifyListeners();
  }

  void _rebuildSessionList() {
    _sessions = _perServerSessions.values.expand((list) => list).toList()
      ..sort((a, b) => b.lastActive.compareTo(a.lastActive));
  }

  void _rebuildScheduledTaskList() {
    _scheduledTasks = combineScheduledTaskLists(_perServerScheduledTasks);
  }

  void _loadScheduledTaskCache(SharedPreferences prefs) {
    final loaded = decodeScheduledTaskCache(
      prefs.getString(_scheduledTaskCachePrefsKey),
      _serverConfigs.map((config) => config.id).toSet(),
    );
    if (loaded.isEmpty) return;
    _perServerScheduledTasks
      ..clear()
      ..addAll(loaded);
    _rebuildScheduledTaskList();
  }

  Future<void> _saveScheduledTaskCache() async {
    try {
      final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
      _cachedPrefs = prefs;
      final encoded = encodeScheduledTaskCache(
        _perServerScheduledTasks,
        _serverConfigs.map((config) => config.id),
      );
      await prefs.setString(_scheduledTaskCachePrefsKey, encoded);
    } catch (e) {
      debugPrint('[ScheduledTasks] Failed to save task cache: $e');
    }
  }

  void _saveScheduledTaskCacheSoon() {
    unawaited(_saveScheduledTaskCache());
  }

  Future<void> _loadSessionCache(SharedPreferences prefs) async {
    final raw = prefs.getString(_sessionCachePrefsKey);
    if (raw == null || raw.isEmpty || _serverConfigs.isEmpty) return;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;

      final configsById = {
        for (final config in _serverConfigs) config.id: config,
      };
      final loaded = <String, List<Session>>{};
      for (final entry in decoded.entries) {
        final serverId = entry.key.toString();
        final config = configsById[serverId];
        if (config == null || entry.value is! List) continue;

        final sessions = <Session>[];
        for (final item in entry.value as List) {
          if (item is! Map) continue;
          final session = Session.fromJson(Map<String, dynamic>.from(item))
              .withServer(
                serverId: serverId,
                serverName: config.name,
                serverColor: config.colorValue,
              )
              .copyWith(running: false);
          if (!_isSessionArchiveHidden(serverId, session.id)) {
            sessions.add(session);
          }
        }
        loaded[serverId] = sessions;
      }

      if (loaded.isEmpty) return;
      _perServerSessions
        ..clear()
        ..addAll(loaded);
      _rebuildSessionList();
    } catch (e) {
      debugPrint('[Sessions] Failed to load session cache: $e');
    }
  }

  Future<void> _saveSessionCache() async {
    try {
      final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
      _cachedPrefs = prefs;
      final payload = <String, List<Map<String, dynamic>>>{};
      for (final config in _serverConfigs) {
        final sessions = _perServerSessions[config.id] ?? const <Session>[];
        payload[config.id] = sessions
            .map((session) => session.copyWith(running: false).toJson())
            .toList();
      }
      await prefs.setString(_sessionCachePrefsKey, jsonEncode(payload));
    } catch (e) {
      debugPrint('[Sessions] Failed to save session cache: $e');
    }
  }

  void _saveSessionCacheSoon() {
    unawaited(_saveSessionCache());
  }

  String _archivePendingKey(String? serverId, String sessionId) {
    return '${serverId ?? ''}\u0001$sessionId';
  }

  String _archiveKeySessionId(String key) {
    final separator = key.indexOf('\u0001');
    return separator >= 0 ? key.substring(separator + 1) : key;
  }

  void _pruneArchivedSessionTombstones() {
    final cutoff = DateTime.now().subtract(_archiveTombstoneTtl);
    _archivedSessionTombstones.removeWhere((_, at) => at.isBefore(cutoff));
  }

  void _markArchivedSessionHidden(String? serverId, String sessionId) {
    _pruneArchivedSessionTombstones();
    _archivedSessionTombstones[_archivePendingKey(serverId, sessionId)] =
        DateTime.now();
  }

  bool _isSessionArchiveHidden(String? serverId, String sessionId) {
    _pruneArchivedSessionTombstones();
    if (_pendingArchivedSessions.containsKey(
      _archivePendingKey(serverId, sessionId),
    )) {
      return true;
    }
    if (_archivedSessionTombstones.containsKey(
      _archivePendingKey(serverId, sessionId),
    )) {
      return true;
    }
    return _pendingArchivedSessions.values.any((s) => s.id == sessionId) ||
        _archivedSessionTombstones.keys.any(
          (key) => _archiveKeySessionId(key) == sessionId,
        );
  }

  void _clearArchiveMarkers(String? serverId, String sessionId) {
    _pendingArchivedSessions.remove(_archivePendingKey(serverId, sessionId));
    _archivedSessionTombstones.remove(_archivePendingKey(serverId, sessionId));
    _pendingArchivedSessions.removeWhere(
      (_, session) => session.id == sessionId,
    );
    _archivedSessionTombstones.removeWhere(
      (key, _) => _archiveKeySessionId(key) == sessionId,
    );
  }

  void _removeSessionFromLists(String? serverId, String sessionId) {
    _sessions.removeWhere((s) => s.id == sessionId);
    if (serverId != null && serverId.isNotEmpty) {
      _perServerSessions[serverId]?.removeWhere((s) => s.id == sessionId);
    } else {
      for (final sessions in _perServerSessions.values) {
        sessions.removeWhere((s) => s.id == sessionId);
      }
    }
    if (_perServerSessions.isNotEmpty) {
      _rebuildSessionList();
    }
    _saveSessionCacheSoon();
  }

  Session? _takePendingArchivedSession(String? serverId, String sessionId) {
    final exact = _pendingArchivedSessions.remove(
      _archivePendingKey(serverId, sessionId),
    );
    if (exact != null) return exact;

    for (final entry in _pendingArchivedSessions.entries) {
      if (entry.value.id == sessionId &&
          (serverId == null || entry.value.serverId == serverId)) {
        _pendingArchivedSessions.remove(entry.key);
        return entry.value;
      }
    }
    return null;
  }

  void _dropPendingArchivedSession(String? serverId, String sessionId) {
    _takePendingArchivedSession(serverId, sessionId);
    _markArchivedSessionHidden(serverId, sessionId);
    _removeSessionFromLists(serverId, sessionId);
  }

  void _restorePendingArchivedSession(String? serverId, String sessionId) {
    final session = _takePendingArchivedSession(serverId, sessionId);
    _archivedSessionTombstones.removeWhere(
      (key, _) => _archiveKeySessionId(key) == sessionId,
    );
    if (session == null) return;

    if (session.serverId.isNotEmpty) {
      final list = _perServerSessions.putIfAbsent(session.serverId, () => []);
      if (!list.any((s) => s.id == session.id)) {
        list.add(session);
      }
      _rebuildSessionList();
      _saveSessionCacheSoon();
    } else if (!_sessions.any((s) => s.id == session.id)) {
      _sessions.add(session);
      _sessions.sort((a, b) => b.lastActive.compareTo(a.lastActive));
    }
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
        _retryPendingAbortForServer(update.serverId);
        _syncStateToServer(serverId: update.serverId);
        unawaited(_syncPushRegistrationForServer(update.serverId));
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

    sendTo({'type': 'set_tts', 'enabled': _ttsEnabled});
    sendTo({
      'type': 'set_raw_mode',
      'enabled': _rawMode,
      if (_activeSessionId != null) 'sessionId': _activeSessionId,
    });
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
    final config = _serverConfigs
        .where((item) => item.id == (serverId ?? _connMgr.activeServerId))
        .firstOrNull;
    if (config != null && config.systemPrompt.isNotEmpty) {
      sendTo({
        'type': 'set_server_settings',
        'systemPromptIfUnset': config.systemPrompt,
      });
    }

    // Request session list from this server (or all if no serverId)
    if (serverId != null) {
      _connMgr.sendToServer(serverId, {'type': 'get_server_settings'});
      _connMgr.sendToServer(serverId, {'type': 'list_sessions'});
      _connMgr.sendToServer(serverId, {'type': 'list_scheduled_tasks'});
    } else {
      requestServerSettings();
      requestSessionList();
      requestScheduledTasks();
      _requestActiveCodexMetadata();
    }

    // Resume active session only on the server that owns it
    if (_activeSessionId != null &&
        serverId != null &&
        serverId == _connMgr.activeServerId) {
      final historyRequestId = _beginInitialHistoryRequest(_activeSessionId!);
      final cachedSnapshot = _transcriptCache.peek(serverId, _activeSessionId!);
      final checkpoint = _transcriptCache.resumeCheckpoint(cachedSnapshot);
      _connMgr.sendToServer(serverId, {
        'type': 'resume_session',
        'sessionId': _activeSessionId,
        'historyRequestId': historyRequestId,
        'openTraceId': historyRequestId,
        if (checkpoint != null) ...{
          'knownSessionSeq': checkpoint.latestSessionSeq,
          'knownHistoryOffset': checkpoint.historyOffset,
          'knownHistoryEntryCount': checkpoint.entryCount,
        },
      });
      _connMgr.sendToServer(serverId, {'type': 'get_status_sync'});
    }
  }

  /// Switch connection mode for a specific server (or first relay server).
  Future<void> setConnectionMode(
    ConnectionMode mode, {
    String? serverId,
  }) async {
    if (serverId != null) {
      final idx = _serverConfigs.indexWhere((c) => c.id == serverId);
      if (idx >= 0) {
        _serverConfigs[idx] = _serverConfigs[idx].copyWith(
          useRelay: mode == ConnectionMode.relay,
        );
        await _saveServerConfigs();
        await _connMgr.setServers(_serverConfigs);
      }
    } else {
      // Legacy: find first relay server
      for (var i = 0; i < _serverConfigs.length; i++) {
        final config = _serverConfigs[i];
        if (config.useRelay || config.isRelayPaired) {
          _serverConfigs[i] = config.copyWith(
            useRelay: mode == ConnectionMode.relay,
          );
          break;
        }
      }
      await _saveServerConfigs();
      await _connMgr.setServers(_serverConfigs);
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

  /// Derive HTTP URL from relay WebSocket URL.
  ///
  /// Prefer the active/per-server relay config. The legacy shared-pref
  /// `relay_url` can be stale on upgraded installs and should only be a
  /// fallback.
  String? _relayHttpUrl() {
    return _relayHttpUrlCandidates().firstOrNull;
  }

  List<String> _relayHttpUrlCandidates() {
    final candidates = <String>[
      if (_connMgr.activeConfig?.relayUrl.isNotEmpty == true)
        _connMgr.activeConfig!.relayUrl,
      ..._serverConfigs
          .where((config) => config.relayUrl.isNotEmpty)
          .map((config) => config.relayUrl),
      if (_cachedPrefs?.getString('relay_url')?.isNotEmpty == true)
        _cachedPrefs!.getString('relay_url')!,
      'wss://relay.jarofdirt.info',
    ];

    final urls = <String>[];
    final seen = <String>{};
    for (final candidate in candidates) {
      final normalized = _relayHttpUrlFromWs(candidate);
      if (normalized != null && seen.add(normalized)) {
        urls.add(normalized);
      }
    }
    return urls;
  }

  String? _relayHttpUrlFromWs(String relayUrl) {
    var value = relayUrl.trim();
    if (value.isEmpty) return null;
    if (value == 'ws://jarofdirt.info:9988' ||
        value == 'http://jarofdirt.info:9988') {
      value = 'wss://relay.jarofdirt.info';
    }
    final httpUrl = value
        .replaceFirst('wss://', 'https://')
        .replaceFirst('ws://', 'http://');
    return httpUrl.replaceFirst(RegExp(r'/+$'), '');
  }

  SharedPreferences? _cachedPrefs;

  bool get _subscriptionRefreshDue {
    if (_subscriberToken.isEmpty) return false;
    if (_subscriptionCheckInFlight != null) return false;
    if (!_subscriptionChecked) return true;
    final checkedAt = _subscriptionCheckedAt;
    if (checkedAt == null) return true;
    return DateTime.now().difference(checkedAt) >= _subscriptionRefreshInterval;
  }

  void refreshSubscriptionStatusIfStale() {
    if (!_subscriptionRefreshDue) return;
    unawaited(checkSubscriptionStatus());
  }

  /// Check subscription status via relay HTTP API (uses signed token).
  /// Calls are coalesced so several UI surfaces cannot stampede the relay.
  Future<bool> checkSubscriptionStatus() {
    final inFlight = _subscriptionCheckInFlight;
    if (inFlight != null) return inFlight;

    final future = _checkSubscriptionStatus();
    _subscriptionCheckInFlight = future;
    return future.whenComplete(() {
      if (_subscriptionCheckInFlight == future) {
        _subscriptionCheckInFlight = null;
      }
    });
  }

  Future<bool> _checkSubscriptionStatus() async {
    final token = _subscriberToken;
    if (token.isEmpty) {
      _subscriptionActive = false;
      _subscriptionChecked = true;
      _subscriptionCheckedAt = DateTime.now();
      notifyListeners();
      return false;
    }

    final prefs = await SharedPreferences.getInstance();
    _cachedPrefs = prefs;
    final httpUrl = _relayHttpUrl();
    if (httpUrl == null) {
      _subscriptionChecked = true;
      _subscriptionCheckedAt = DateTime.now();
      notifyListeners();
      return false;
    }

    try {
      final uri = Uri.parse(
        '$httpUrl/api/subscription-status?token=${Uri.encodeComponent(token)}',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (_subscriberToken != token) return _subscriptionActive;
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
      debugPrint('[Subscription] Status check error: $e');
      if (_subscriberToken != token) return _subscriptionActive;
      if (token.isNotEmpty) {
        _subscriptionActive = true;
        if (_subscriptionStatus.isEmpty) _subscriptionStatus = 'unknown';
      } else {
        _subscriptionActive = false;
        _subscriptionStatus = '';
        _trialEnd = null;
        _periodEnd = null;
        _cancelAtPeriodEnd = false;
      }
    }

    _subscriptionChecked = true;
    _subscriptionCheckedAt = DateTime.now();
    notifyListeners();
    return _subscriptionActive;
  }

  /// Create a Stripe Checkout Session (or get owner bypass token).
  /// Returns a Map with either {url: checkoutUrl} or {ownerBypass: true, token: signedToken}.
  Future<Map<String, dynamic>?> createCheckoutSession(String email) async {
    final prefs = await SharedPreferences.getInstance();
    _cachedPrefs = prefs;
    final httpUrls = _relayHttpUrlCandidates();
    if (httpUrls.isEmpty) {
      return {'error': 'Relay checkout URL is not configured'};
    }

    Object? lastError;
    for (final httpUrl in httpUrls) {
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
        // Return server error so the UI can display it.
        try {
          final errBody = jsonDecode(response.body) as Map<String, dynamic>;
          return {
            'error':
                errBody['error'] ?? 'Server error (${response.statusCode})',
          };
        } catch (_) {
          return {'error': 'Server error (${response.statusCode})'};
        }
      } catch (e) {
        lastError = e;
        debugPrint('[Subscription] Checkout error via $httpUrl: $e');
      }
    }
    return {
      'error':
          'Could not reach relay checkout at ${httpUrls.join(', ')}: $lastError',
    };
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
    _subscriptionCheckedAt = DateTime.now();
    notifyListeners();
  }

  /// Clear subscriber token (sign out)
  Future<void> clearSubscriberToken() async {
    _subscriberToken = '';
    _subscriberEmail = '';
    _subscriptionActive = false;
    _subscriptionChecked = false;
    _subscriptionCheckedAt = null;
    _subscriptionCheckInFlight = null;
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
    _subscriptionCheckedAt = DateTime.now();
    notifyListeners();
  }

  void disconnect() {
    _connMgr.disconnectAll();
  }

  void toggleRawMode() {
    _rawMode = !_rawMode;
    _ws.send({
      'type': 'set_raw_mode',
      'enabled': _rawMode,
      if (_activeSessionId != null) 'sessionId': _activeSessionId,
    });
    if (_rawMode && _activeSessionId != null && _rawItems.isEmpty) {
      _ws.send({
        'type': 'get_sdk_event_history',
        'sessionId': _activeSessionId,
        'limit': 300,
      });
    }
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

  bool _handleNotificationOnlyServerMessage(
    String type,
    Map<String, dynamic> msg,
    String? serverId,
  ) {
    switch (type) {
      case 'session_state_changed':
        final sessionState = msg['state'] as String? ?? 'idle';
        final stateSessionId = msg['sessionId'] as String? ?? '';
        if (stateSessionId.isEmpty) return true;
        final serverActiveStartedAt = _parseServerDateTime(
          msg['activeStartedAt'],
        );
        if (sessionState == 'running') {
          _markSessionRunning(
            stateSessionId,
            serverId: serverId,
            startedAt: serverActiveStartedAt,
          );
        } else if (sessionState == 'idle') {
          _markSessionIdle(stateSessionId, serverId: serverId);
        }
        return true;
      case 'result':
        final sessionId = msg['sessionId'] as String? ?? '';
        if (sessionId.isEmpty) return true;
        _markSessionIdle(sessionId, serverId: serverId);
        return true;
    }
    return false;
  }

  void _handleServerMessage(Map<String, dynamic> msg, [String? serverId]) {
    final type = msg['type'] as String?;
    if (type == null) return;

    final messageSessionId = msg['sessionId'] as String?;
    _cacheDurableLiveEvent(msg, serverId);
    final isForVisibleSession =
        messageSessionId != null &&
        messageSessionId.isNotEmpty &&
        _viewingSessionId == messageSessionId &&
        (_viewingServerId == null ||
            serverId == null ||
            _viewingServerId == serverId);

    // Messages that should be processed from ANY server
    const globalTypes = {
      'session_list',
      'status_sync',
      'subscription_required',
      'directory_listing',
      'file_manager_list_result',
      'file_manager_protected_result',
      'file_manager_operation_result',
      'file_manager_text_result',
      'cwd_check',
      'sdk_session_list',
      'version_info',
      'update_result',
      'recent_cwds',
      'archive_list',
      'archive_history',
      'session_archived',
      'session_archive_failed',
      'archive_restored',
      'archive_restore_failed',
      'archive_deleted',
      'server_capabilities',
      'secret_inventory',
      'html_plan_list',
      'html_plan_operation_result',
      'html_plan_revision_list',
      'html_plan_revision',
      'server_settings',
      'backend_install_progress',
      'backend_auth_required',
      'terminal_status',
      'terminal_output',
      'terminal_exited',
      'terminal_error',
      'adb_bridge_sidecar_status',
      'adb_command_result',
      'phone_adb_request',
      'phone_adb_file_chunk',
      'phone_adb_file_end',
      'phone_adb_cancel',
      'file',
      'file_data',
      'file_chunk',
      'file_complete',
      'file_error',
      'push_token_registered',
      'push_token_unregistered',
      'push_registration_status',
      'abort_ack',
      'scheduled_task_notification',
      'reminder',
    };
    final isGlobalType =
        globalTypes.contains(type) || isScheduledTaskStateMessage(type);

    // Route: only process non-global messages from the active server
    final fromInactiveServer =
        !isGlobalType &&
        !isForVisibleSession &&
        serverId != null &&
        _connMgr.activeServerId != null &&
        serverId != _connMgr.activeServerId;
    if (fromInactiveServer) {
      _handleNotificationOnlyServerMessage(type, msg, serverId);
      _ackDeferredSessionDelivery(msg, serverId);
      return;
    }

    // Visible chat state is single-session. If a long-running session emits
    // messages after the user has opened another session, do not append those
    // events to the current chat; they will be restored from that session's
    // persisted history when the user opens it again.
    final replacementSessionId = type == 'session_created'
        ? msg['replacesSessionId'] as String?
        : null;
    final replacesActiveSession =
        replacementSessionId != null &&
        replacementSessionId.isNotEmpty &&
        replacementSessionId == _activeSessionId;
    if (!isGlobalType &&
        messageSessionId != null &&
        messageSessionId.isNotEmpty) {
      if (_activeSessionId == null) {
        if (!isForVisibleSession && type != 'session_created') {
          _handleNotificationOnlyServerMessage(type, msg, serverId);
          _ackDeferredSessionDelivery(msg, serverId);
          return;
        }
      } else if (!isForVisibleSession &&
          messageSessionId != _activeSessionId &&
          !replacesActiveSession) {
        _handleNotificationOnlyServerMessage(type, msg, serverId);
        _ackDeferredSessionDelivery(msg, serverId);
        return;
      }
    }

    // Capture SDK events for raw debug mode (coalesced)
    if (type == 'sdk_event') {
      _processRawEvent(msg);
      return; // Don't process sdk_event further — it's debug-only
    }

    final deliveryId = msg['deliveryId'] as String?;
    final deliverySessionId = msg['sessionId'] as String?;
    final acknowledgesDelivery =
        deliveryId != null &&
        deliveryId.isNotEmpty &&
        deliverySessionId != null &&
        deliverySessionId.isNotEmpty &&
        (type == 'tool_call' ||
            type == 'tool_result' ||
            type == 'html_plan' ||
            type == 'text' ||
            type == 'thinking');
    final deliveryEventKey = acknowledgesDelivery
        ? acknowledgedSessionEventKey(msg)
        : null;
    if (acknowledgesDelivery &&
        (_appliedSessionDeliveryIds.contains(deliveryId) ||
            (deliveryEventKey != null &&
                _appliedSessionEventKeys.contains(deliveryEventKey)))) {
      _ackSessionDelivery(deliverySessionId, deliveryId, serverId);
      return;
    }
    if (isStaleTranscriptRevision(_messages, msg)) {
      if (acknowledgesDelivery) {
        _rememberAppliedSessionDelivery(deliveryId);
        if (deliveryEventKey != null) {
          _rememberAppliedSessionEventKey(deliveryEventKey);
        }
        _ackSessionDelivery(deliverySessionId, deliveryId, serverId);
      }
      return;
    }

    try {
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
        case 'secure_input_request':
          _handleSecureInputRequest(msg);
          break;
        case 'secure_input_saved':
          _handleSecureInputSaved(msg);
          break;
        case 'secure_input_cancelled':
          _handleSecureInputCancelled(msg);
          break;
        case 'secret_inventory':
          _handleSecretInventory(msg, serverId);
          break;
        case 'secret_operation_result':
          _handleSecretOperationResult(msg);
          break;
        case 'html_plan':
          _handleHtmlPlan(msg);
          break;
        case 'html_plan_list':
          _handleHtmlPlanList(msg);
          break;
        case 'html_plan_operation_result':
          _handleHtmlPlanOperationResult(msg);
          break;
        case 'html_plan_revision_list':
          _handleHtmlPlanRevisionList(msg);
          break;
        case 'html_plan_revision':
          _handleHtmlPlanRevision(msg);
          break;
        case 'result':
          _handleResult(msg);
          break;
        case 'abort_ack':
          _handleAbortAck(msg, serverId);
          break;
        case 'subagent_result':
          _handleSubagentResult(msg);
          break;
        case 'active_subagents':
          _handleActiveSubagents(msg);
          break;
        case 'session_created':
          _handleSessionCreated(msg, serverId);
          break;
        case 'session_history':
          _handleSessionHistory(msg, serverId: serverId);
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
              final secretManagement = msg['secretManagement'];
              _serverSecretManagementVersions[serverId] =
                  secretManagement is Map
                  ? (secretManagement['version'] as num?)?.toInt() ?? 0
                  : 0;
              _captureCodexDriverSettings(msg, serverId);
              unawaited(_captureRelayPairingFromCapabilities(serverId, msg));
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
        case 'backend_install_progress':
          _handleBackendInstallProgress(msg, serverId);
          break;
        case 'backend_auth_required':
          _handleBackendAuthRequired(msg, serverId);
          break;
        case 'terminal_status':
        case 'terminal_output':
        case 'terminal_exited':
        case 'terminal_error':
          _handleTerminalMessage(msg, serverId);
          break;
        case 'adb_bridge_sidecar_status':
          _handleAdbBridgeSidecarStatus(msg);
          break;
        case 'adb_command_result':
          _handleAdbCommandResult(msg);
          break;
        case 'phone_adb_request':
          _handlePhoneAdbRequest(msg, serverId);
          break;
        case 'phone_adb_file_chunk':
          _handlePhoneAdbFileChunk(msg);
          break;
        case 'phone_adb_file_end':
          _handlePhoneAdbFileEnd(msg);
          break;
        case 'phone_adb_cancel':
          _handlePhoneAdbCancel(msg);
          break;
        case 'push_token_registered':
          {
            final appServerId = msg['appServerId'];
            _markPushRegistered(
              serverId ?? (appServerId is String ? appServerId : null),
            );
            break;
          }
        case 'push_token_unregistered':
          {
            final appServerId = msg['appServerId'];
            _markPushUnregistered(
              serverId ?? (appServerId is String ? appServerId : null),
            );
            break;
          }
        case 'push_registration_status':
          {
            final appServerId = msg['appServerId'];
            final effectiveServerId =
                serverId ?? (appServerId is String ? appServerId : null);
            if (msg['registered'] == true) {
              _markPushRegistered(effectiveServerId);
            } else {
              _markPushUnregistered(effectiveServerId);
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
                _codexCollaborationMode = currentMode;
              }
              notifyListeners();
            }
            break;
          }
        case 'codex_collaboration_mode_changed':
          {
            final mode = msg['mode'] as String? ?? 'default';
            _codexCollaborationMode = mode;
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
        case 'codex_status':
          {
            if (msg['error'] == null && msg['payload'] is Map) {
              _codexStatus = Map<String, dynamic>.from(msg['payload'] as Map);
              _pendingCodexStatus?.complete(_codexStatus);
              _pendingCodexStatus = null;
              notifyListeners();
            } else {
              _pendingCodexStatus?.complete(null);
              _pendingCodexStatus = null;
            }
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
          _handleFileMessage(msg, serverId);
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
        case 'file_error':
          _handleFileError(msg);
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
          final result = Map<String, dynamic>.from(msg);
          if (serverId != null && serverId.isNotEmpty) {
            result['serverId'] = serverId;
          }
          _lastCwdCheck = result;
          final requestId = result['requestId'] as String?;
          final responseServerId = result['serverId'] as String?;
          final serverMatches =
              _pendingCwdCheckServerId == null ||
              responseServerId == null ||
              responseServerId == _pendingCwdCheckServerId;
          if (_pendingCwdCheck != null &&
              serverMatches &&
              (_pendingCwdCheckRequestId == null ||
                  requestId == null ||
                  requestId == _pendingCwdCheckRequestId)) {
            _pendingCwdCheck?.complete(result);
            _pendingCwdCheck = null;
            _pendingCwdCheckRequestId = null;
            _pendingCwdCheckServerId = null;
          }
          break;
        case 'directory_listing':
          _pendingDirList?.complete(Map<String, dynamic>.from(msg));
          _pendingDirList = null;
          break;
        case 'file_manager_list_result':
          {
            final requestId = msg['requestId'] as String? ?? '';
            final completer = _fileManagerListCompleters.remove(requestId);
            if (completer != null && !completer.isCompleted) {
              if (msg['ok'] == true) {
                completer.complete(FileManagerListing.fromJson(msg));
              } else {
                completer.completeError(
                  Exception(msg['error'] as String? ?? 'Failed to list files'),
                );
              }
            }
            break;
          }
        case 'file_manager_protected_result':
          {
            final requestId = msg['requestId'] as String? ?? '';
            final completer = _fileManagerProtectedCompleters.remove(requestId);
            if (completer != null && !completer.isCompleted) {
              if (msg['ok'] == true) {
                completer.complete(Map<String, dynamic>.from(msg));
              } else {
                completer.completeError(
                  Exception(
                    msg['error'] as String? ?? 'Failed to update protection',
                  ),
                );
              }
            }
            break;
          }
        case 'file_manager_operation_result':
          {
            final requestId = msg['requestId'] as String? ?? '';
            final completer = _fileManagerOperationCompleters.remove(requestId);
            if (completer != null && !completer.isCompleted) {
              if (msg['ok'] == true) {
                completer.complete(Map<String, dynamic>.from(msg));
              } else {
                completer.completeError(
                  Exception(msg['error'] as String? ?? 'File operation failed'),
                );
              }
            }
            break;
          }
        case 'file_manager_text_result':
          {
            final requestId = msg['requestId'] as String? ?? '';
            final completer = _fileManagerTextCompleters.remove(requestId);
            if (completer != null && !completer.isCompleted) {
              if (msg['ok'] == true) {
                completer.complete(Map<String, dynamic>.from(msg));
              } else {
                completer.completeError(
                  Exception(msg['error'] as String? ?? 'Failed to read text'),
                );
              }
            }
            break;
          }
        case 'recent_cwds':
          final cwds = (msg['cwds'] as List?)?.cast<String>() ?? [];
          final key = serverId ?? '';
          _recentCwds[key] = cwds;
          notifyListeners();
          break;
        case 'sdk_session_list':
          final sessions =
              (msg['sessions'] as List?)
                  ?.map((e) => Map<String, dynamic>.from(e as Map))
                  .toList() ??
              <Map<String, dynamic>>[];
          final requestId = msg['requestId'] as String?;
          if (requestId != null && requestId.isNotEmpty) {
            final expectedServer = _sdkSessionRequestServers[requestId];
            if (expectedServer != null &&
                serverId != null &&
                serverId != expectedServer) {
              break;
            }
            _sdkSessionRequestServers.remove(requestId);
            _sdkSessionRequestCwds.remove(requestId);
            final requestedLimit =
                _sdkSessionRequestLimits.remove(requestId) ?? 30;
            final completer = _sdkSessionCompleters.remove(requestId);
            if (completer != null && !completer.isCompleted) {
              completer.complete(
                SdkSessionPage(
                  sessions: sessions,
                  total: msg['total'] as int? ?? sessions.length,
                  hasMore:
                      msg['hasMore'] as bool? ??
                      sessions.length >= requestedLimit,
                ),
              );
            }
            break;
          }

          // Compatibility with servers that predate request IDs. Route by the
          // echoed cwd/server, preferring the newest identical lookup. Identical
          // requests have interchangeable results, and the picker separately
          // ignores callbacks from older UI generations.
          final responseCwd = msg['cwd'] as String?;
          final matchingIds = _sdkSessionRequestServers.entries
              .where(
                (entry) =>
                    (entry.value == null ||
                        serverId == null ||
                        entry.value == serverId) &&
                    (responseCwd == null ||
                        _sdkSessionRequestCwds[entry.key] == responseCwd),
              )
              .map((entry) => entry.key)
              .toList();
          if (matchingIds.isNotEmpty) {
            final legacyId = matchingIds.last;
            _sdkSessionRequestServers.remove(legacyId);
            _sdkSessionRequestCwds.remove(legacyId);
            final requestedLimit =
                _sdkSessionRequestLimits.remove(legacyId) ?? 30;
            final completer = _sdkSessionCompleters.remove(legacyId);
            if (completer != null && !completer.isCompleted) {
              completer.complete(
                SdkSessionPage(
                  sessions: sessions,
                  total: msg['total'] as int? ?? sessions.length,
                  hasMore:
                      msg['hasMore'] as bool? ??
                      sessions.length >= requestedLimit,
                ),
              );
            }
          }
          break;
        case 'version_info':
          if (_pendingVersionCheckServerId != null &&
              serverId != null &&
              serverId != _pendingVersionCheckServerId) {
            break;
          }
          if (serverId != null) {
            _captureServerRuntimeInfo(msg, serverId);
          }
          _pendingVersionCheck?.complete(Map<String, dynamic>.from(msg));
          _pendingVersionCheck = null;
          _pendingVersionCheckServerId = null;
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
            if (progressSummary != null) {
              _subagentTasks[progressToolId]!['progressSummary'] =
                  progressSummary;
            }
            final lastTool = msg['lastToolName'] as String?;
            if (lastTool != null) {
              _subagentTasks[progressToolId]!['lastToolName'] = lastTool;
            }
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
            lcText =
                'Session ended${lcReason.isNotEmpty ? ' ($lcReason)' : ''}';
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
        case 'session_settings':
          _handleSessionSettings(msg);
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
          final stateSessionId =
              msg['sessionId'] as String? ?? _activeSessionId;
          final serverActiveStartedAt = _parseServerDateTime(
            msg['activeStartedAt'],
          );
          _requiresAction = sessionState == 'requires_action';
          // Use SDK state as authoritative source for running status
          if (sessionState == 'running') {
            _markSessionRunning(
              stateSessionId,
              serverId: serverId ?? _connMgr.activeServerId,
              startedAt: serverActiveStartedAt,
            );
            _isProcessing = true;
            _processingSetAt = null; // server confirmed
            _startPromptRuntime(
              startedAt: serverActiveStartedAt,
              replace: serverActiveStartedAt != null,
            );
          } else if (sessionState == 'idle') {
            _markSessionIdle(
              stateSessionId,
              serverId: serverId ?? _connMgr.activeServerId,
            );
            _isProcessing = false;
            _processingSetAt = null;
            _stopPromptRuntime();
            _closeLiveStreamsForParent(null);
            settleIdleToolCards(
              _messages,
              activeBackgroundTaskIds: _activeBackgroundTaskIds(),
            );
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
              _sessions[idx] = old.copyWith(cwd: newCwd);
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
              if (_isPendingInjectedMessage(_messages[idx]) &&
                  _pendingInjectedMessageCount > 0) {
                _pendingInjectedMessageCount--;
              }
              _messages[idx].isPending = false;
              _messages[idx].injectionPriority = null;
              notifyListeners();
            }
          } else {
            // No messageId — promote the oldest pending message
            final idx = _messages.indexWhere(_isPendingInjectedMessage);
            if (idx >= 0) {
              if (_pendingInjectedMessageCount > 0) {
                _pendingInjectedMessageCount--;
              }
              _messages[idx].isPending = false;
              _messages[idx].injectionPriority = null;
              notifyListeners();
            }
          }
          break;
        case 'injection_failed':
          final failedMsgId = msg['messageId'] as String? ?? '';
          final reason = msg['message'] as String? ?? 'Message was not sent';
          var removed = false;
          if (failedMsgId.isNotEmpty) {
            final idx = _messages.indexWhere(
              (m) => m.id == failedMsgId && m.isPending,
            );
            if (idx >= 0) {
              if (_isPendingInjectedMessage(_messages[idx]) &&
                  _pendingInjectedMessageCount > 0) {
                _pendingInjectedMessageCount--;
              }
              _pendingLocalUserMessageIds.remove(failedMsgId);
              _pendingCacheUserPromptContent.remove(failedMsgId);
              _messages.removeAt(idx);
              removed = true;
            }
          }
          if (!removed) {
            final idx = _messages.indexWhere(_isPendingInjectedMessage);
            if (idx >= 0) {
              if (_pendingInjectedMessageCount > 0) {
                _pendingInjectedMessageCount--;
              }
              final messageId = _messages[idx].id;
              _pendingLocalUserMessageIds.remove(messageId);
              _pendingCacheUserPromptContent.remove(messageId);
              _messages.removeAt(idx);
            }
          }
          _messages.add(ChatMessage.error('Message was not sent: $reason'));
          notifyListeners();
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
            _codexSlashCommandsByServer[serverId] =
                (msg['codexSlashCommands'] as List? ?? [])
                    .map((command) => Map<String, dynamic>.from(command as Map))
                    .toList();
            notifyListeners();
          }
          break;
        case 'codex_command_result':
          final command = msg['command'] as String? ?? 'command';
          final summary = msg['summary'] as String? ?? '';
          final status = msg['status'] as String? ?? 'completed';
          final payload = msg['payload'] is Map
              ? Map<String, dynamic>.from(msg['payload'] as Map)
              : <String, dynamic>{};
          _messages.add(
            ChatMessage.codexCommand(
              command: command,
              summary: summary,
              status: status,
              payload: payload,
            ),
          );
          notifyListeners();
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
          final serverSaysCompacting = msg['compacting'] == true;
          final serverActiveStartedAt = _parseServerDateTime(
            msg['activeStartedAt'],
          );
          final awaitingAbort = _hasPendingHardStop(
            _activeSessionId,
            serverId: serverId,
          );
          _isProcessing =
              msg['running'] == true || serverSaysCompacting || awaitingAbort;
          if (!_isProcessing) {
            _markSessionIdle(
              _activeSessionId,
              serverId: _connMgr.activeServerId,
            );
            _isCompacting = false;
            _stopPromptRuntime();
            _closeLiveStreamsForParent(null);
            settleIdleToolCards(
              _messages,
              activeBackgroundTaskIds: _activeBackgroundTaskIds(),
            );
          } else {
            _markSessionRunning(
              _activeSessionId,
              serverId: _connMgr.activeServerId,
              startedAt: serverActiveStartedAt,
              compacting: serverSaysCompacting,
            );
            // Restore compacting state on resume. Compacting is active work even
            // if the agent turn itself is between running status updates.
            _isCompacting = serverSaysCompacting;
            _processingSetAt = null; // server confirmed
            _startPromptRuntime(
              startedAt: serverActiveStartedAt,
              replace: serverActiveStartedAt != null,
            );
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
            _captureServerRuntimeInfo(msg, serverId);
            final taskRevision = msg['scheduledTaskRevision']?.toString();
            if (scheduledTaskRevisionNeedsRefresh(
              _scheduledTaskLoadedRevisions[serverId],
              taskRevision,
            )) {
              _requestScheduledTasksFromServer(serverId);
            }
          }
          final runningSessions = (msg['runningSessions'] as List?)
              ?.map((e) => e.toString())
              .toSet();
          final compactingSessions = (msg['compactingSessions'] as List?)
              ?.map((e) => e.toString())
              .toSet();
          final notificationSuppressedSessions =
              (msg['notificationSuppressedSessions'] as List?)
                  ?.map((e) => e.toString())
                  .toSet();
          if (serverId != null && runningSessions != null) {
            final rawStartedAt = msg['sessionActiveStartedAt'];
            final startedAtBySession = <String, DateTime?>{};
            if (rawStartedAt is Map) {
              for (final entry in rawStartedAt.entries) {
                startedAtBySession[entry.key.toString()] = _parseServerDateTime(
                  entry.value,
                );
              }
            }
            final rawSessionTitles = msg['sessionTitles'];
            final titlesBySession = <String, String>{};
            if (rawSessionTitles is Map) {
              for (final entry in rawSessionTitles.entries) {
                final title = entry.value?.toString().trim() ?? '';
                if (title.isNotEmpty) {
                  titlesBySession[entry.key.toString()] = title;
                }
              }
            }
            _replaceRunningSessionsForServer(
              serverId,
              runningSessions,
              startedAtBySession,
              titlesBySessionId: titlesBySession,
              compactingSessionIds: compactingSessions ?? const <String>{},
              suppressOngoingSessionIds:
                  notificationSuppressedSessions ?? const <String>{},
            );
          }
          // Only process remaining status_sync fields from the active server
          if (serverId != null && serverId != _connMgr.activeServerId) break;
          // Check if THIS session is running, not just any session
          final serverActiveStartedAt = _activeStartedAtFromStatusSync(msg);
          final serverSaysCompacting =
              compactingSessions != null &&
              _activeSessionId != null &&
              compactingSessions.contains(_activeSessionId);
          final serverSuppressesOngoing =
              notificationSuppressedSessions != null &&
              _activeSessionId != null &&
              notificationSuppressedSessions.contains(_activeSessionId);
          final rawActiveSessionTitle = msg['sessionTitles'] is Map
              ? (msg['sessionTitles'] as Map)[_activeSessionId]?.toString()
              : null;
          final serverActiveSessionTitle =
              rawActiveSessionTitle?.trim().isNotEmpty == true
              ? rawActiveSessionTitle!.trim()
              : null;
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
          serverSaysRunning = serverSaysRunning || serverSaysCompacting;
          // Don't let status_sync clear processing during the grace period after
          // sendPrompt() — the server may not have started the SDK query yet.
          if (!serverSaysRunning && _isProcessing && _processingSetAt != null) {
            final elapsed = DateTime.now().difference(_processingSetAt!);
            if (elapsed.inSeconds < 15) {
              // Keep _isProcessing true — server hasn't caught up yet
            } else {
              _isProcessing = false;
              _processingSetAt = null;
              _stopPromptRuntime();
            }
          } else {
            _isProcessing = serverSaysRunning;
            if (serverSaysRunning) _processingSetAt = null; // server confirmed
          }
          final serverTaskIds =
              (msg['backgroundTaskIds'] as List?)
                  ?.map((e) => e.toString())
                  .toSet() ??
              <String>{};
          final durableMonitors = msg['durableMonitors'] as List?;
          if (durableMonitors != null && _activeSessionId != null) {
            for (final rawMonitor in durableMonitors) {
              if (rawMonitor is! Map ||
                  rawMonitor['sessionId']?.toString() != _activeSessionId) {
                continue;
              }
              final taskId = rawMonitor['taskId']?.toString() ?? '';
              if (taskId.isEmpty) continue;
              _backgroundTasks[taskId] = {
                ...?_backgroundTasks[taskId],
                'status': 'running',
                'summary':
                    rawMonitor['description']?.toString() ??
                    'Monitored process',
                'isMonitor': true,
                'startedAt': rawMonitor['startedAt']?.toString(),
              };
            }
          }
          if (!_isProcessing) {
            _isCompacting = false;
            _stopPromptRuntime();
            _closeLiveStreamsForParent(null);
            settleIdleToolCards(
              _messages,
              activeBackgroundTaskIds: serverTaskIds,
            );
          } else {
            _isCompacting = serverSaysCompacting;
            _startPromptRuntime(
              startedAt: serverActiveStartedAt,
              replace: serverActiveStartedAt != null,
              titleOverride: serverActiveSessionTitle,
              suppressOngoingNotification: serverSuppressesOngoing,
            );
          }
          // Reconcile background tasks — remove any not reported by server
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
          if (_isLoadingHistory) {
            _isLoadingHistory = false;
            _initialHistoryTimeout?.cancel();
            _initialHistoryTimeout = null;
          }
          _messages.add(ChatMessage.error(msg['message'] ?? 'Unknown error'));
          _markSessionIdle(_activeSessionId, serverId: _connMgr.activeServerId);
          _isProcessing = false;
          _stopPromptRuntime();
          settleIdleToolCards(_messages);
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
          _stopPromptRuntime();
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
                (a) =>
                    ArchiveEntry.fromJson(
                      Map<String, dynamic>.from(a as Map),
                    ).withServer(
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
        case 'session_archived':
          final archivedId = msg['sessionId'] as String? ?? '';
          if (archivedId.isNotEmpty) {
            _dropPendingArchivedSession(serverId, archivedId);
            notifyListeners();
          }
          break;
        case 'session_archive_failed':
          final failedId = msg['sessionId'] as String? ?? '';
          if (failedId.isNotEmpty) {
            _restorePendingArchivedSession(serverId, failedId);
          }
          _messages.add(
            ChatMessage.error(
              'Archive failed: ${msg['error'] ?? 'unknown error'}',
            ),
          );
          notifyListeners();
          break;
        case 'archive_restored':
          final restoredId =
              (msg['session'] as Map?)?['id'] as String? ??
              msg['sid'] as String? ??
              '';
          if (restoredId.isNotEmpty) {
            _clearArchiveMarkers(serverId, restoredId);
          }
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
          if (clearedId != null && clearedId.isNotEmpty) {
            _locallyClearedSessions.add(clearedId);
          }
          if (clearedId == _activeSessionId) {
            _messages.clear();
            _pendingInjectedMessageCount = 0;
            _pendingLocalUserMessageIds.clear();
            _pendingCacheUserPromptContent.clear();
            _todos.clear();
            _clearLiveMessageStreams();
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
          if (serverId != null) {
            _scheduledTaskRefreshRetries.remove(serverId)?.cancel();
            final revision = msg['revision']?.toString();
            if (revision != null && revision.isNotEmpty) {
              _scheduledTaskLoadedRevisions[serverId] = revision;
            }
          }
          final tasks = (msg['tasks'] as List? ?? [])
              .map(
                (t) =>
                    Map<String, dynamic>.from(t as Map)
                      ..['_serverId'] = serverId ?? '',
              )
              .toList();
          if (serverId != null) {
            _perServerScheduledTasks[serverId] = tasks;
            _rebuildScheduledTaskList();
            _saveScheduledTaskCacheSoon();
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
            _rebuildScheduledTaskList();
            _saveScheduledTaskCacheSoon();
          } else {
            final idx = _scheduledTasks.indexWhere(
              (t) => t['id'] == task['id'],
            );
            if (idx >= 0) {
              _scheduledTasks[idx] = task;
            } else {
              _scheduledTasks.add(task);
            }
          }
          notifyListeners();
          break;
        case 'scheduled_task_notification':
          final sid = msg['sessionId'] as String? ?? '';
          if (msg['sessionCompletion'] == true && sid.isNotEmpty) {
            _markSessionIdle(sid, serverId: serverId);
          }
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
            final receivedChunks =
                (msg['receivedChunks'] as num?)?.toInt() ?? 0;
            if (uploadId == null || total <= 0) break;
            final state = _uploadStates[uploadId];
            if (state != null) {
              debugPrint(
                '[Upload] ack: chunks=$receivedChunks bytes=$received/$total',
              );
              state.target.uploadProgress =
                  state.progressBase +
                  (received / total).clamp(0.0, 1.0) * state.progressSpan;
              state.noteAck(receivedChunks);
              notifyListeners();
            }
            break;
          }
        case 'compact_boundary':
          _closeLiveStreamsForParent(null);
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
          _handleOutlookAuth(msg, serverId);
          break;
        case 'ibs_auth':
          _handleIBSAuth(msg, serverId);
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
          _subscriptionCheckedAt = DateTime.now();
          _subscriptionRequiredController.add(null);
          notifyListeners();
          break;
      }
    } catch (error, stackTrace) {
      final activeServer = serverId ?? _connMgr.activeServerId;
      final errorText = error.toString();
      debugPrint(
        '[SessionEvent] Failed to apply $type delivery=$deliveryId: '
        '$errorText\n$stackTrace',
      );
      if (activeServer != null && activeServer.isNotEmpty) {
        _connMgr.sendToServer(activeServer, {
          'type': 'client_event_error',
          'sessionId': deliverySessionId ?? messageSessionId ?? '',
          'eventType': type,
          'deliveryId': deliveryId ?? '',
          'toolUseId': msg['toolUseId']?.toString() ?? '',
          'message': errorText,
        });
      }

      // A malformed or unexpectedly typed optional field must never erase the
      // whole tool event. Render the stable core fields so the result can still
      // reconcile into a visible, resumable card.
      if (type == 'tool_call') {
        final fallbackToolUseId = msg['toolUseId']?.toString() ?? '';
        final existing = fallbackToolUseId.isEmpty
            ? -1
            : _messages.lastIndexWhere(
                (message) =>
                    message.type == MessageType.toolCall &&
                    message.toolUseId == fallbackToolUseId,
              );
        if (existing < 0) {
          final rawInput = msg['input'];
          final fallbackInput = rawInput is Map
              ? Map<String, dynamic>.fromEntries(
                  rawInput.entries.map(
                    (entry) => MapEntry(entry.key.toString(), entry.value),
                  ),
                )
              : <String, dynamic>{};
          final fallback = ChatMessage.toolCall(
            tool: normalizeSocketAgentToolName(
              msg['tool']?.toString() ?? 'Tool',
            ),
            input: fallbackInput,
            toolUseId: fallbackToolUseId,
          );
          fallback.toolStreaming = true;
          fallback.parentToolUseId = msg['parentToolUseId']?.toString();
          applyTranscriptPosition(fallback, msg);
          _messages.add(fallback);
          notifyListeners();
        }
      }
    }

    final positionOrdered = orderByTranscriptPosition(_messages);
    var positionChanged = false;
    for (var index = 0; index < _messages.length; index++) {
      if (!identical(_messages[index], positionOrdered[index])) {
        positionChanged = true;
        break;
      }
    }
    if (positionChanged) {
      _messages = positionOrdered;
      notifyListeners();
    }

    // Card-defining session events are retained and retried by the server
    // until the live reducer confirms it actually applied them. A WebSocket
    // frame reaching the phone is not enough: session/provider transitions
    // can otherwise discard a tool card while ordinary text keeps streaming.
    if (acknowledgesDelivery) {
      _rememberAppliedSessionDelivery(deliveryId);
      if (deliveryEventKey != null) {
        _rememberAppliedSessionEventKey(deliveryEventKey);
      }
      _ackSessionDelivery(deliverySessionId, deliveryId, serverId);
    }
  }

  void _cacheDurableLiveEvent(
    Map<String, dynamic> msg,
    String? sourceServerId,
  ) {
    final sessionId = msg['sessionId']?.toString() ?? '';
    final serverId =
        sourceServerId ?? _activeSessionServerId ?? _connMgr.activeServerId;
    if (sessionId.isEmpty || serverId == null || serverId.isEmpty) return;

    String? userContent;
    if (msg['type'] == 'user_message_uuid') {
      final clientMessageId = msg['clientMessageId']?.toString() ?? '';
      final uuid = msg['uuid']?.toString() ?? '';
      var localMessage = clientMessageId.isNotEmpty
          ? _messages
                .where((message) => message.id == clientMessageId)
                .firstOrNull
          : null;
      localMessage ??= _messages.reversed
          .where(
            (message) =>
                message.sender == MessageSender.user &&
                (message.type == MessageType.text ||
                    message.type == MessageType.skillInvocation) &&
                (uuid.isEmpty || message.uuid == null || message.uuid == uuid),
          )
          .firstOrNull;
      final cacheMessageId =
          clientMessageId.isNotEmpty &&
              _pendingCacheUserPromptContent.containsKey(clientMessageId)
          ? clientMessageId
          : localMessage?.id;
      userContent =
          (cacheMessageId == null
              ? null
              : _pendingCacheUserPromptContent.remove(cacheMessageId)) ??
          localMessage?.textContent;
    }
    final entry = transcriptCacheEntryFromServerEvent(
      msg,
      userContent: userContent,
    );
    if (entry != null) {
      unawaited(_transcriptCache.mergeLiveEntry(serverId, sessionId, entry));
    }
  }

  /// The server persists these transcript events before the user can open the
  /// session again. When an event belongs to another visible chat/server, the
  /// live reducer intentionally defers it to history; acknowledge that choice
  /// and remember the identity so queued relay copies cannot later masquerade
  /// as fresh live cards.
  void _ackDeferredSessionDelivery(Map<String, dynamic> msg, String? serverId) {
    final type = msg['type'] as String? ?? '';
    final deliveryId = msg['deliveryId'] as String? ?? '';
    final sessionId = msg['sessionId'] as String? ?? '';
    final tracked =
        deliveryId.isNotEmpty &&
        sessionId.isNotEmpty &&
        (type == 'tool_call' ||
            type == 'tool_result' ||
            type == 'html_plan' ||
            type == 'text' ||
            type == 'thinking');
    if (!tracked) return;

    _rememberAppliedSessionDelivery(deliveryId);
    final eventKey = acknowledgedSessionEventKey(msg);
    if (eventKey != null) _rememberAppliedSessionEventKey(eventKey);
    _ackSessionDelivery(sessionId, deliveryId, serverId);
  }

  void _rememberAppliedSessionDelivery(String deliveryId) {
    if (!_appliedSessionDeliveryIds.add(deliveryId)) return;
    _appliedSessionDeliveryOrder.add(deliveryId);
    while (_appliedSessionDeliveryOrder.length > 2000) {
      final oldest = _appliedSessionDeliveryOrder.removeAt(0);
      _appliedSessionDeliveryIds.remove(oldest);
    }
  }

  void _rememberAppliedSessionEventKey(String eventKey) {
    if (!_appliedSessionEventKeys.add(eventKey)) return;
    _appliedSessionEventKeyOrder.add(eventKey);
    while (_appliedSessionEventKeyOrder.length > 2000) {
      final oldest = _appliedSessionEventKeyOrder.removeAt(0);
      _appliedSessionEventKeys.remove(oldest);
    }
  }

  void _ackSessionDelivery(
    String sessionId,
    String deliveryId,
    String? serverId,
  ) {
    final ack = {
      'type': 'session_event_ack',
      'sessionId': sessionId,
      'deliveryId': deliveryId,
    };
    if (serverId != null && serverId.isNotEmpty) {
      _connMgr.sendToServer(serverId, ack);
    } else {
      _connMgr.send(ack);
    }
  }

  void _rememberAuthRequestRoute(
    String authRequestId,
    Map<String, dynamic> msg,
    String? serverId,
  ) {
    if (serverId != null && serverId.isNotEmpty) {
      _authRequestServers[authRequestId] = serverId;
    }
    final sessionId = msg['sessionId'] as String?;
    if (sessionId != null && sessionId.isNotEmpty) {
      _authRequestSessions[authRequestId] = sessionId;
    }
  }

  void _clearAuthRequestRoute(String authRequestId) {
    _authRequestServers.remove(authRequestId);
    _authRequestSessions.remove(authRequestId);
  }

  void _sendAuthAnswer(String authRequestId, Map<String, String> answers) {
    final serverId = _authRequestServers[authRequestId];
    final sessionId = _authRequestSessions[authRequestId];
    final msg = <String, dynamic>{
      'type': 'answer',
      'questionId': authRequestId,
      'answers': answers,
      if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
    };

    if (serverId != null && serverId.isNotEmpty) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _connMgr.send(msg);
    }
  }

  void _handleOutlookAuth(Map<String, dynamic> msg, [String? serverId]) {
    _closeLiveStreamsForParent(null);
    final authRequestId = msg['authRequestId'] as String? ?? '';
    if (authRequestId.isEmpty) return;

    _rememberAuthRequestRoute(authRequestId, msg, serverId);
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
    _sendAuthAnswer(authRequestId, answers);
    notifyListeners();
  }

  void _handleOutlookAuthResult(Map<String, dynamic> msg) {
    final authRequestId = msg['authRequestId'] as String? ?? '';
    if (authRequestId.isNotEmpty) {
      _clearAuthRequestRoute(authRequestId);
    }
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
    _closeLiveStreamsForParent(null);
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

  void _handleIBSAuth(Map<String, dynamic> msg, [String? serverId]) {
    _closeLiveStreamsForParent(null);
    final authRequestId = msg['authRequestId'] as String? ?? '';
    if (authRequestId.isEmpty) return;

    _rememberAuthRequestRoute(authRequestId, msg, serverId);
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
    _sendAuthAnswer(authRequestId, answers);
    notifyListeners();
  }

  void _handleIBSAuthResult(Map<String, dynamic> msg) {
    final authRequestId = msg['authRequestId'] as String? ?? '';
    if (authRequestId.isNotEmpty) {
      _clearAuthRequestRoute(authRequestId);
    }
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

  String _hierarchyStreamKey(Map<String, dynamic> msg) {
    final streamId = msg['streamId'] as String?;
    if (streamId != null && streamId.isNotEmpty) return 'stream:$streamId';
    final uuid = msg['uuid'] as String?;
    if (uuid != null && uuid.isNotEmpty) return 'uuid:$uuid';
    final parentToolUseId = msg['parentToolUseId'] as String?;
    if (parentToolUseId != null && parentToolUseId.isNotEmpty) {
      return 'parent:$parentToolUseId';
    }
    return 'main';
  }

  void _clearLiveMessageStreams() {
    _streamingMessagesByKey.clear();
    _thinkingMessagesByKey.clear();
    _assistantMessagesByStreamKey.clear();
    _thinkingMessagesByStreamKey.clear();
    _currentStreamingMessage = null;
    _currentStreamingStreamId = null;
    _closeThinkingMessage();
  }

  void _closeLiveStreamsForParent(String? parentToolUseId) {
    _streamingMessagesByKey.removeWhere(
      (_, message) => message.parentToolUseId == parentToolUseId,
    );
    _thinkingMessagesByKey.removeWhere((_, message) {
      final matches = message.parentToolUseId == parentToolUseId;
      if (matches) message.toolStreaming = false;
      return matches;
    });
    _assistantMessagesByStreamKey.removeWhere(
      (_, message) => message.parentToolUseId == parentToolUseId,
    );
    _thinkingMessagesByStreamKey.removeWhere((_, message) {
      final matches = message.parentToolUseId == parentToolUseId;
      if (matches) message.toolStreaming = false;
      return matches;
    });
    if (liveMessageMatchesParent(_currentStreamingMessage, parentToolUseId)) {
      _currentStreamingMessage = null;
      _currentStreamingStreamId = null;
    }
    if (liveMessageMatchesParent(_currentThinkingMessage, parentToolUseId)) {
      _currentThinkingMessage!.toolStreaming = false;
      _currentThinkingMessage = null;
    }
  }

  void _handleTextMessage(Map<String, dynamic> msg) {
    _processingSetAt = null; // server confirmed processing
    final content = msg['content'] as String? ?? '';
    final streamId = msg['streamId'] as String?;
    final isReplay = msg['replay'] == true;
    final isSnapshot = isReplay || msg['snapshot'] == true;
    final parentToolUseId = msg['parentToolUseId'] as String?;
    final streamKey = _hierarchyStreamKey(msg);
    final entryId = msg['entryId'] as String?;
    ChatMessage? positionedMessage;
    if (entryId != null && entryId.isNotEmpty) {
      for (final message in _messages.reversed) {
        if (message.entryId == entryId) {
          positionedMessage = message;
          break;
        }
      }
    }

    final thinking = _thinkingMessagesByKey.remove(streamKey);
    if (thinking != null) thinking.toolStreaming = false;
    if (identical(_currentThinkingMessage, thinking)) {
      _currentThinkingMessage = null;
    }

    // Cumulative snapshots, including the final durable frame, must reconcile
    // with a bubble that was already created by deltas. A tool event can close
    // the stream maps before item/completed arrives; treating only retries as
    // snapshots creates a second full assistant bubble at that boundary.
    if (isSnapshot) {
      final existing =
          positionedMessage ??
          _streamingMessagesByKey[streamKey] ??
          _assistantMessagesByStreamKey[streamKey] ??
          _findReplayedAssistantMessage(
            content,
            parentToolUseId: parentToolUseId,
          );
      if (existing != null) {
        existing.textContent = mergeLiveStreamContent(
          current: existing.textContent,
          incoming: content,
          isReplay: true,
          hasStreamId: streamId != null,
        );
        _streamingMessagesByKey[streamKey] = existing;
        _assistantMessagesByStreamKey[streamKey] = existing;
        existing.streamId = streamId;
        applyTranscriptPosition(existing, msg);
        _currentStreamingMessage = existing;
        _currentStreamingStreamId = streamId;
        if (existing.textContent.trim().isNotEmpty &&
            !_messages.contains(existing)) {
          _messages.add(existing);
        }
        notifyListeners();
        return;
      }
    }

    var streamMessage =
        positionedMessage ??
        _streamingMessagesByKey[streamKey] ??
        _assistantMessagesByStreamKey[streamKey];
    if (streamMessage != null && !_messages.contains(streamMessage)) {
      final reconciled = _findReplayedAssistantMessage(
        content,
        parentToolUseId: parentToolUseId,
      );
      if (reconciled != null) streamMessage = reconciled;
    }
    if (streamMessage == null) {
      streamMessage = ChatMessage.assistantText(msg['sessionId'] ?? '');
      _currentStreamingStreamId = streamId;
      // Forward SDK hierarchy fields
      streamMessage.parentToolUseId = parentToolUseId;
      streamMessage.uuid = msg['uuid'] as String?;
      // Don't add to _messages yet — wait until there's visible content
    } else if (_currentStreamingStreamId == null && streamId != null) {
      _currentStreamingStreamId = streamId;
    }
    streamMessage.streamId = streamId;
    applyTranscriptPosition(streamMessage, msg);
    _streamingMessagesByKey[streamKey] = streamMessage;
    _assistantMessagesByStreamKey[streamKey] = streamMessage;
    _currentStreamingMessage = streamMessage;

    streamMessage.textContent = mergeLiveStreamContent(
      current: streamMessage.textContent,
      incoming: content,
      isReplay: isSnapshot,
      hasStreamId: streamId != null,
    );

    // Extract task notifications and create notification messages
    final rawText = streamMessage.textContent;
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
              parentToolUseId: parentToolUseId,
            ),
          );
        }
      }
      streamMessage.textContent = cleaned;
    }

    // Strip system-reminder blocks
    streamMessage.textContent = streamMessage.textContent.replaceAll(
      _systemReminderRegex,
      '',
    );

    // Only add to the message list once there's visible content
    if (streamMessage.textContent.trim().isNotEmpty &&
        !_messages.contains(streamMessage)) {
      _messages.add(streamMessage);
    }

    notifyListeners();
  }

  void _closeThinkingMessage() {
    if (_currentThinkingMessage != null) {
      _currentThinkingMessage!.toolStreaming = false;
      _thinkingMessagesByKey.removeWhere(
        (_, message) => identical(message, _currentThinkingMessage),
      );
      _currentThinkingMessage = null;
    }
  }

  void _handleThinkingMessage(Map<String, dynamic> msg) {
    _processingSetAt = null; // server confirmed processing
    final content = msg['content'] as String? ?? '';
    final isReplay = msg['replay'] == true;
    final isSnapshot = isReplay || msg['snapshot'] == true;
    final parentToolUseId = msg['parentToolUseId'] as String?;
    final streamKey = _hierarchyStreamKey(msg);
    final entryId = msg['entryId'] as String?;
    ChatMessage? positionedMessage;
    if (entryId != null && entryId.isNotEmpty) {
      for (final message in _messages.reversed) {
        if (message.entryId == entryId) {
          positionedMessage = message;
          break;
        }
      }
    }
    if (isReplay) {
      final existing =
          positionedMessage ??
          _thinkingMessagesByKey[streamKey] ??
          _thinkingMessagesByStreamKey[streamKey] ??
          _findReplayedThinkingMessage(
            content,
            parentToolUseId: parentToolUseId,
          );
      if (existing != null) {
        existing.textContent = content;
        existing.toolStreaming = true;
        _thinkingMessagesByKey[streamKey] = existing;
        _thinkingMessagesByStreamKey[streamKey] = existing;
        existing.streamId = msg['streamId'] as String?;
        applyTranscriptPosition(existing, msg);
        _currentThinkingMessage = existing;
        notifyListeners();
        return;
      }
    }
    var thinkingMessage =
        positionedMessage ??
        _thinkingMessagesByKey[streamKey] ??
        _thinkingMessagesByStreamKey[streamKey];
    if (thinkingMessage == null) {
      thinkingMessage = ChatMessage.thinking();
      thinkingMessage.parentToolUseId = parentToolUseId;
      thinkingMessage.uuid = msg['uuid'] as String?;
      _messages.add(thinkingMessage);
    }
    thinkingMessage.streamId = msg['streamId'] as String?;
    applyTranscriptPosition(thinkingMessage, msg);
    _thinkingMessagesByKey[streamKey] = thinkingMessage;
    _thinkingMessagesByStreamKey[streamKey] = thinkingMessage;
    thinkingMessage.textContent = isSnapshot
        ? content
        : thinkingMessage.textContent + content;
    thinkingMessage.toolStreaming = true;
    _currentThinkingMessage = thinkingMessage;
    notifyListeners();
  }

  void _handleToolCall(Map<String, dynamic> msg) {
    _processingSetAt = null; // server confirmed processing

    final tool = normalizeSocketAgentToolName(
      msg['tool']?.toString() ?? 'Unknown',
    );
    final rawInput = msg['input'];
    final input = rawInput is Map
        ? Map<String, dynamic>.fromEntries(
            rawInput.entries.map(
              (entry) => MapEntry(entry.key.toString(), entry.value),
            ),
          )
        : <String, dynamic>{};

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

    final toolUseId = msg['toolUseId']?.toString() ?? '';
    if (tool == 'HtmlPlan') {
      if (toolUseId.isNotEmpty) {
        _toolEventReconciler.discard(toolUseId);
        _suppressedToolUseIds.add(toolUseId);
      }
      return;
    }
    if (tool.endsWith('RequestSecureInput')) {
      if (toolUseId.isNotEmpty) {
        _toolEventReconciler.discard(toolUseId);
        _suppressedToolUseIds.add(toolUseId);
      }
      return;
    }
    var syntheticSendFileIndex = -1;
    if (tool == 'SendFile') {
      final filePath = input['file_path']?.toString() ?? '';
      if (filePath.isNotEmpty) {
        syntheticSendFileIndex = _messages.lastIndexWhere(
          (message) =>
              message.type == MessageType.toolCall &&
              message.toolName == 'SendFile' &&
              message.toolUseId?.startsWith('file_') == true &&
              message.toolInput?['file_path'] == filePath,
        );
        if (syntheticSendFileIndex >= 0) {
          mergeSendFileTransportMetadata(
            input,
            _messages[syntheticSendFileIndex].toolInput,
          );
        }
      }
    }
    var toolMsg = ChatMessage.toolCall(
      tool: tool,
      input: input,
      toolUseId: toolUseId,
    );
    toolMsg.toolStreaming = true; // tool is actively running
    toolMsg.parentToolUseId = msg['parentToolUseId']?.toString();
    toolMsg.uuid = msg['uuid']?.toString();
    applyTranscriptPosition(toolMsg, msg);
    final entryId = msg['entryId'] as String?;
    var existingIndex = entryId == null || entryId.isEmpty
        ? -1
        : _messages.lastIndexWhere((message) => message.entryId == entryId);
    if (existingIndex < 0 && toolUseId.isNotEmpty) {
      existingIndex = _messages.lastIndexWhere(
        (message) =>
            message.type == MessageType.toolCall &&
            message.toolUseId == toolUseId,
      );
    }
    final replacesSyntheticSendFile =
        existingIndex < 0 && syntheticSendFileIndex >= 0;
    if (replacesSyntheticSendFile) {
      existingIndex = syntheticSendFileIndex;
    }
    // Retransmission is the same transcript event. Only a genuinely new tool
    // call closes the preceding assistant stream.
    if (existingIndex < 0) {
      _closeLiveStreamsForParent(msg['parentToolUseId']?.toString());
    }
    if (existingIndex >= 0) {
      final existing = _messages[existingIndex];
      if (replacesSyntheticSendFile ||
          shouldReplaceToolCardMetadata(
            existingName: existing.toolName,
            existingInput: existing.toolInput,
            incomingName: tool,
            incomingInput: input,
          )) {
        toolMsg.toolOutput = existing.toolOutput;
        toolMsg.toolStreaming = existing.toolStreaming;
        toolMsg.parentToolUseId ??= existing.parentToolUseId;
        toolMsg.uuid ??= existing.uuid;
        _messages[existingIndex] = toolMsg;
      } else {
        toolMsg = existing;
        applyTranscriptPosition(toolMsg, msg);
        toolMsg.toolStreaming = toolMsg.toolOutput == null;
        toolMsg.parentToolUseId ??= msg['parentToolUseId']?.toString();
        toolMsg.uuid ??= msg['uuid']?.toString();
      }
    }
    final pendingResult = _toolEventReconciler.takeResult(toolUseId);
    final pendingStream = _toolEventReconciler.takeStream(toolUseId);
    if (pendingResult != null) {
      toolMsg.toolOutput = pendingResult.output;
      toolMsg.toolStreaming = false;
      toolMsg.parentToolUseId ??= pendingResult.parentToolUseId;
    } else if (pendingStream != null) {
      toolMsg.toolOutput = pendingStream.output;
      toolMsg.toolStreaming = !pendingStream.done;
    }
    if (existingIndex < 0) {
      _messages.add(toolMsg);
    }
    // A reliable-delivery replay can arrive after the turn's result/idle
    // event. Do not resurrect a spinner for work the server says is over.
    if (!_isProcessing && !toolMsg.isBackgrounded) {
      toolMsg.toolOutput ??= '';
      toolMsg.toolStreaming = false;
    }

    // Track Task/Agent tool calls as subagent tasks
    final subagentType = input['subagent_type']?.toString() ?? '';
    if ((tool == 'Task' || tool == 'Agent') &&
        !_codexAgentControlTypes.contains(subagentType)) {
      final desc = input['description'] as String? ?? 'Sub agent task';
      _subagentTasks[toolUseId] = {
        'description': desc,
        'prompt': input['prompt'] as String? ?? '',
        'subagentType': subagentType,
        'status': toolMsg.toolStreaming ? 'running' : 'completed',
        'toolUseId': toolUseId,
        if (input['agentId'] != null) 'agentId': input['agentId'],
        if (toolMsg.parentToolUseId != null)
          'parentToolUseId': toolMsg.parentToolUseId,
      };
    }
    notifyListeners();
  }

  void _handleToolResult(Map<String, dynamic> msg) {
    final toolUseId = msg['toolUseId'] as String? ?? '';
    final output = msg['output'] as String? ?? '';

    if (_suppressedToolUseIds.remove(toolUseId)) return;

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
    } else if (toolUseId.isNotEmpty && output.trim().isNotEmpty) {
      _toolEventReconciler.bufferResult(
        toolUseId,
        output,
        parentToolUseId: msg['parentToolUseId'] as String?,
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
    } else if (toolUseId.isNotEmpty && content.isNotEmpty) {
      _toolEventReconciler.bufferChunk(
        toolUseId,
        content,
        chunkIndex: chunkIndex,
        done: done,
      );
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
    _closeLiveStreamsForParent(msg['parentToolUseId'] as String?);

    final questionId = msg['questionId'] as String? ?? '';

    // Deduplicate: if this question already exists (e.g. restored from history,
    // then re-sent by server on reconnect), just ensure it's marked unanswered
    final existingIdx = _messages.indexWhere(
      (m) => m.questionId == questionId && m.type == MessageType.question,
    );
    if (existingIdx >= 0) {
      _messages[existingIdx].answered = false;
      _messages[existingIdx].toolInput?['status'] = 'pending';
      applyTranscriptPosition(_messages[existingIdx], msg);
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

    final questionMessage = ChatMessage.question(
      questionId: questionId,
      questions: questions,
      emailPreview: emailPreview,
    );
    applyTranscriptPosition(questionMessage, msg);
    _messages.add(questionMessage);
    notifyListeners();
  }

  void _handleSecureInputRequest(Map<String, dynamic> msg) {
    _closeLiveStreamsForParent(msg['parentToolUseId'] as String?);
    final requestId = msg['requestId'] as String? ?? '';
    if (requestId.isEmpty) return;
    final existingIdx = _messages.indexWhere(
      (m) => m.type == MessageType.secureInput && m.questionId == requestId,
    );
    if (existingIdx >= 0) {
      _messages[existingIdx].answered = false;
      _messages[existingIdx].toolInput?['status'] = 'pending';
      applyTranscriptPosition(_messages[existingIdx], msg);
      refreshSecretInventory();
      notifyListeners();
      return;
    }
    final label = msg['label'] as String? ?? 'Secret';
    final reason = msg['reason'] as String? ?? '';
    final envHint = msg['envHint'] as String? ?? '';
    final scope = msg['scope'] as String? ?? 'session';
    final secureMessage = ChatMessage.secureInput(
      requestId: requestId,
      label: label,
      reason: reason,
      envHint: envHint,
      scope: scope,
    );
    applyTranscriptPosition(secureMessage, msg);
    _messages.add(secureMessage);
    refreshSecretInventory();
    notifyListeners();
  }

  void _handleSecureInputSaved(Map<String, dynamic> msg) {
    final requestId = msg['requestId'] as String? ?? '';
    final label = msg['label'] as String? ?? 'Secret';
    final filePath = msg['filePath'] as String? ?? '';
    if (requestId.isNotEmpty) {
      final idx = _messages.indexWhere(
        (m) => m.type == MessageType.secureInput && m.questionId == requestId,
      );
      if (idx >= 0) {
        _messages[idx].answered = true;
        _messages[idx].toolInput?['status'] = 'saved';
      }
    }
    _messages.add(
      ChatMessage(
        id: 'secure_saved_${DateTime.now().microsecondsSinceEpoch}',
        sender: MessageSender.system,
        type: MessageType.taskNotification,
        timestamp: DateTime.now(),
        textContent: filePath.isNotEmpty
            ? 'Secure input saved: $label\n$filePath'
            : 'Secure input saved: $label',
        toolName: 'secure_input_saved',
      ),
    );
    notifyListeners();
  }

  void _handleSecureInputCancelled(Map<String, dynamic> msg) {
    final requestId = msg['requestId'] as String? ?? '';
    final idx = _messages.indexWhere(
      (m) => m.type == MessageType.secureInput && m.questionId == requestId,
    );
    if (idx >= 0) {
      _messages[idx].answered = true;
      _messages[idx].toolInput?['status'] = 'cancelled';
      notifyListeners();
    }
  }

  void _handleSecretInventory(Map<String, dynamic> msg, String? serverId) {
    if (serverId == null ||
        !_secretInventoryRequestTracker.accept(
          serverId: serverId,
          requestId: msg['requestId'] as String?,
          sessionId: msg['sessionId'] as String?,
        )) {
      return;
    }
    _secretInventory = (msg['secrets'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (entry) => SecretMetadata.fromJson(Map<String, dynamic>.from(entry)),
        )
        .where((entry) => entry.secretId.isNotEmpty)
        .toList();
    _secretInventoryLoading = false;
    _secretInventoryError = null;
    notifyListeners();
  }

  void _handleSecretOperationResult(Map<String, dynamic> msg) {
    final requestId = msg['requestId'] as String? ?? '';
    final ok = msg['ok'] == true;
    final error = msg['error'] as String? ?? 'Secret operation failed';
    final writeCompleter = _secretWriteCompleters.remove(requestId);
    if (writeCompleter != null && !writeCompleter.isCompleted) {
      if (ok && msg['secret'] is Map) {
        writeCompleter.complete(
          SecretMetadata.fromJson(
            Map<String, dynamic>.from(msg['secret'] as Map),
          ),
        );
      } else {
        writeCompleter.completeError(Exception(error));
      }
    }
    final deleteCompleter = _secretDeleteCompleters.remove(requestId);
    if (deleteCompleter != null && !deleteCompleter.isCompleted) {
      if (ok) {
        deleteCompleter.complete();
      } else {
        deleteCompleter.completeError(Exception(error));
      }
    }
    refreshSecretInventory();
  }

  void _handleHtmlPlan(Map<String, dynamic> msg) {
    final plan = HtmlPlan.fromJson(msg);
    if (plan.planId.isEmpty || plan.html.isEmpty) return;
    final existingPlan = _htmlPlans.indexWhere(
      (item) => item.planId == plan.planId,
    );
    if (existingPlan >= 0) {
      _htmlPlans[existingPlan] = plan;
    } else {
      _htmlPlans.insert(0, plan);
    }
    final card = ChatMessage.htmlPlan(plan.toJson());
    applyTranscriptPosition(card, msg);
    final existingCard = _messages.indexWhere(
      (message) =>
          message.type == MessageType.htmlPlan &&
          message.toolUseId == plan.planId,
    );
    if (existingCard >= 0) {
      _messages[existingCard] = card;
    } else {
      _closeLiveStreamsForParent(null);
      _messages.add(card);
    }
    notifyListeners();
  }

  void _handleHtmlPlanList(Map<String, dynamic> msg) {
    final requestId = msg['requestId'] as String?;
    if (_htmlPlanListRequestId != null && requestId != _htmlPlanListRequestId) {
      return;
    }
    final sessionId = msg['sessionId'] as String? ?? '';
    if (_activeSessionId != null && sessionId != _activeSessionId) return;
    _htmlPlanListTimeout?.cancel();
    _htmlPlanListTimeout = null;
    _htmlPlanListRequestId = null;
    _htmlPlans = (msg['plans'] as List? ?? const [])
        .whereType<Map>()
        .map((entry) => HtmlPlan.fromJson(Map<String, dynamic>.from(entry)))
        .where((entry) => entry.planId.isNotEmpty)
        .toList();
    _htmlPlansLoading = false;
    _htmlPlansError = null;
    notifyListeners();
  }

  void _handleHtmlPlanOperationResult(Map<String, dynamic> msg) {
    final requestId = msg['requestId'] as String? ?? '';
    final ok = msg['ok'] == true;
    final error = msg['error'] as String? ?? 'HTML plan operation failed';
    final renameCompleter = _htmlPlanRenameCompleters.remove(requestId);
    if (renameCompleter != null && !renameCompleter.isCompleted) {
      if (ok && msg['plan'] is Map) {
        final plan = HtmlPlan.fromJson(
          Map<String, dynamic>.from(msg['plan'] as Map),
        );
        final planIndex = _htmlPlans.indexWhere(
          (item) => item.planId == plan.planId,
        );
        if (planIndex >= 0) _htmlPlans[planIndex] = plan;
        final cardIndex = _messages.indexWhere(
          (message) =>
              message.type == MessageType.htmlPlan &&
              message.toolUseId == plan.planId,
        );
        if (cardIndex >= 0) {
          _messages[cardIndex] = _updatedHtmlPlanCard(
            _messages[cardIndex],
            plan,
          );
        }
        renameCompleter.complete(plan);
      } else {
        renameCompleter.completeError(Exception(error));
      }
    }
    final deleteCompleter = _htmlPlanDeleteCompleters.remove(requestId);
    if (deleteCompleter != null && !deleteCompleter.isCompleted) {
      if (ok) {
        final planId = msg['planId'] as String? ?? '';
        _htmlPlans.removeWhere((plan) => plan.planId == planId);
        _messages.removeWhere(
          (message) =>
              message.type == MessageType.htmlPlan &&
              message.toolUseId == planId,
        );
        deleteCompleter.complete();
      } else {
        deleteCompleter.completeError(Exception(error));
      }
    }
    final rollbackCompleter = _htmlPlanRollbackCompleters.remove(requestId);
    if (rollbackCompleter != null && !rollbackCompleter.isCompleted) {
      if (ok && msg['plan'] is Map) {
        final plan = HtmlPlan.fromJson(
          Map<String, dynamic>.from(msg['plan'] as Map),
        );
        final planIndex = _htmlPlans.indexWhere(
          (item) => item.planId == plan.planId,
        );
        if (planIndex >= 0) {
          _htmlPlans[planIndex] = plan;
        } else {
          _htmlPlans.insert(0, plan);
        }
        final cardIndex = _messages.indexWhere(
          (message) =>
              message.type == MessageType.htmlPlan &&
              message.toolUseId == plan.planId,
        );
        if (cardIndex >= 0) {
          _messages[cardIndex] = _updatedHtmlPlanCard(
            _messages[cardIndex],
            plan,
          );
        }
        rollbackCompleter.complete(plan);
      } else {
        rollbackCompleter.completeError(Exception(error));
      }
    }
    notifyListeners();
  }

  ChatMessage _updatedHtmlPlanCard(ChatMessage previous, HtmlPlan plan) {
    final updated = ChatMessage.htmlPlan(plan.toJson());
    updated.entryId = previous.entryId;
    updated.sessionSeq = previous.sessionSeq;
    updated.revision = previous.revision + 1;
    updated.parentToolUseId = previous.parentToolUseId;
    updated.originToolUseId = previous.originToolUseId;
    return updated;
  }

  void _handleHtmlPlanRevisionList(Map<String, dynamic> msg) {
    final requestId = msg['requestId'] as String? ?? '';
    final completer = _htmlPlanRevisionListCompleters.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    if (msg['ok'] != true) {
      completer.completeError(
        Exception(msg['error']?.toString() ?? 'Could not load revisions'),
      );
      return;
    }
    final revisions = (msg['revisions'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (entry) => HtmlPlanRevisionSummary.fromJson(
            Map<String, dynamic>.from(entry),
          ),
        )
        .where((revision) => revision.revision >= 0)
        .toList();
    completer.complete(revisions);
  }

  void _handleHtmlPlanRevision(Map<String, dynamic> msg) {
    final requestId = msg['requestId'] as String? ?? '';
    final completer = _htmlPlanRevisionDetailCompleters.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    if (msg['ok'] != true || msg['revision'] is! Map) {
      completer.completeError(
        Exception(msg['error']?.toString() ?? 'Could not load revision'),
      );
      return;
    }
    completer.complete(
      HtmlPlanRevisionDetail(
        revision: HtmlPlanRevision.fromJson(
          Map<String, dynamic>.from(msg['revision'] as Map),
        ),
        baseRevision: int.tryParse(msg['baseRevision']?.toString() ?? ''),
        diff: (msg['diff'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (entry) => HtmlPlanDiffSegment.fromJson(
                Map<String, dynamic>.from(entry),
              ),
            )
            .toList(),
      ),
    );
  }

  void _handleResult(Map<String, dynamic> msg) {
    final awaitingAbort = _hasPendingHardStop(
      _activeSessionId,
      serverId: _connMgr.activeServerId,
    );
    if (!awaitingAbort) {
      _markSessionIdle(_activeSessionId, serverId: _connMgr.activeServerId);
    }
    _closeLiveStreamsForParent(null);
    _isProcessing = awaitingAbort;
    _stopPromptRuntime();
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
    if (msg['usage'] != null) {
      _lastUsage = Map<String, dynamic>.from(msg['usage'] as Map);
      _lastUsage!['costUsd'] = msg['costUsd'];
      _lastUsage!['numTurns'] = msg['numTurns'];
      if (msg['stopReason'] != null) {
        _lastUsage!['stopReason'] = msg['stopReason'];
      }
      if (msg['resultSubtype'] != null) {
        _lastUsage!['resultSubtype'] = msg['resultSubtype'];
      }
      if (msg['errors'] != null) _lastUsage!['errors'] = msg['errors'];
      if (msg['durationApiMs'] != null) {
        _lastUsage!['durationApiMs'] = msg['durationApiMs'];
      }
      if (msg['permissionDenials'] != null) {
        _lastUsage!['permissionDenials'] = msg['permissionDenials'];
      }
      if (msg['totalUsage'] != null) {
        _lastUsage!['totalUsage'] = Map<String, dynamic>.from(
          msg['totalUsage'] as Map,
        );
      }
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
    // Mark any foreground tool calls that never got a result so spinners stop.
    // Background commands remain live only while their task is still tracked.
    if (!awaitingAbort) {
      settleIdleToolCards(
        _messages,
        activeBackgroundTaskIds: _activeBackgroundTaskIds(),
      );
      // Clear completed background tasks
      _backgroundTasks.removeWhere(
        (_, t) =>
            t['status'] == 'completed' ||
            t['status'] == 'failed' ||
            t['status'] == 'stopped',
      );
    }
    notifyListeners();
  }

  void _handleSubagentResult(Map<String, dynamic> msg) {
    final parentToolUseId = msg['parentToolUseId'] as String? ?? '';
    _closeLiveStreamsForParent(parentToolUseId);
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
    final messageSessionId = msg['sessionId'] as String?;
    if (messageSessionId != null &&
        _activeSessionId != null &&
        messageSessionId != _activeSessionId) {
      return;
    }
    final tasks = msg['tasks'] as List<dynamic>? ?? [];
    final source = msg['backend'] as String?;
    final replace = msg['replace'] == true;
    final incomingIds = <String>{};
    for (final task in tasks) {
      final t = task as Map<String, dynamic>;
      final toolUseId = t['toolUseId'] as String? ?? '';
      final description = t['description'] as String? ?? 'Sub agent task';
      final subagentType = t['subagentType'] as String? ?? '';
      final rawStatus = t['status'] as String? ?? 'running';
      if (toolUseId.isEmpty) continue;

      final isActive = rawStatus == 'running' || rawStatus == 'pending';
      if (!isActive) {
        final existing = _subagentTasks[toolUseId];
        if (existing != null) {
          existing['status'] = 'completed';
          existing['terminalStatus'] = rawStatus;
        }
        for (final message in _messages) {
          if (message.type == MessageType.toolCall &&
              message.toolUseId == toolUseId) {
            message.toolStreaming = false;
          }
        }
        continue;
      }
      incomingIds.add(toolUseId);

      final previous = _subagentTasks[toolUseId];
      _subagentTasks[toolUseId] = {
        ...?previous,
        'description': description,
        'prompt': t['prompt'] as String? ?? previous?['prompt'] ?? '',
        'subagentType': subagentType,
        'status': 'running',
        'terminalStatus': rawStatus,
        'toolUseId': toolUseId,
        'source': source ?? previous?['source'],
        if (t['agentId'] != null) 'agentId': t['agentId'],
        if (t['model'] != null) 'model': t['model'],
        if (t['reasoningEffort'] != null)
          'reasoningEffort': t['reasoningEffort'],
        if (t['agentPath'] != null) 'agentPath': t['agentPath'],
        if (t['parentToolUseId'] != null)
          'parentToolUseId': t['parentToolUseId'],
      };

      // If the Task tool_call message isn't in _messages, create a synthetic one
      final hasToolCall = _messages.any(
        (m) => m.type == MessageType.toolCall && m.toolUseId == toolUseId,
      );
      if (!hasToolCall) {
        final syntheticMsg = ChatMessage.toolCall(
          tool: 'Agent',
          input: {
            'description': description,
            'subagent_type': subagentType,
            if (t['agentId'] != null) 'agentId': t['agentId'],
            if (t['model'] != null) 'model': t['model'],
            if (t['reasoningEffort'] != null)
              'reasoningEffort': t['reasoningEffort'],
          },
          toolUseId: toolUseId,
        );
        syntheticMsg.toolStreaming = true;
        syntheticMsg.parentToolUseId = t['parentToolUseId'] as String?;
        _messages.add(syntheticMsg);
      } else {
        final toolCall = _messages
            .where(
              (m) => m.type == MessageType.toolCall && m.toolUseId == toolUseId,
            )
            .lastOrNull;
        if (toolCall != null) {
          toolCall.toolStreaming = true;
          toolCall.toolInput?.addAll({
            'description': description,
            'prompt': t['prompt'] as String? ?? previous?['prompt'] ?? '',
            'subagent_type': subagentType,
            if (t['agentId'] != null) 'agentId': t['agentId'],
            if (t['model'] != null) 'model': t['model'],
            if (t['reasoningEffort'] != null)
              'reasoningEffort': t['reasoningEffort'],
          });
          if (t['parentToolUseId'] != null) {
            toolCall.parentToolUseId = t['parentToolUseId'] as String?;
          }
        }
      }
    }
    if (replace && source != null) {
      final settledIds = _subagentTasks.entries
          .where(
            (entry) =>
                entry.value['source'] == source &&
                !incomingIds.contains(entry.key),
          )
          .map((entry) => entry.key)
          .toSet();
      for (final id in settledIds) {
        _subagentTasks[id]!['status'] = 'completed';
        _subagentTasks[id]!['terminalStatus'] ??= 'completed';
      }
      for (final message in _messages) {
        if (message.type == MessageType.toolCall &&
            settledIds.contains(message.toolUseId)) {
          message.toolStreaming = false;
        }
      }
    }
    notifyListeners();
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

    if (taskId.isNotEmpty) {
      for (final message in _messages.reversed) {
        if (message.type != MessageType.toolCall ||
            message.toolName != 'Monitor') {
          continue;
        }
        final knownTaskId = message.toolInput?['_monitorTaskId']?.toString();
        if (knownTaskId == taskId ||
            (message.toolOutput?.contains(taskId) ?? false)) {
          message.toolInput?['_monitorTaskId'] = taskId;
          message.toolInput?['_monitorStatus'] = status;
          break;
        }
      }
    }

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
      originToolUseId: originToolUseId,
    );
    // Parent controls subagent nesting; origin links to the Bash card.
    notifMsg.parentToolUseId =
        msg['parentToolUseId'] as String? ?? originToolUseId;
    _messages.add(notifMsg);
    notifyListeners();
  }

  void _handleMonitorStarted(Map<String, dynamic> msg) {
    final taskId = msg['taskId'] as String? ?? '';
    final description = msg['description'] as String? ?? 'Monitored process';
    final monitoring = msg['monitoring'] as bool? ?? false;
    final command = msg['command'] as String?;

    for (final message in _messages.reversed) {
      if (message.type != MessageType.toolCall ||
          message.toolName != 'Monitor') {
        continue;
      }
      final knownTaskId = message.toolInput?['_monitorTaskId']?.toString();
      final matchesResult = message.toolOutput?.contains(taskId) ?? false;
      final matchesStart =
          monitoring &&
          knownTaskId == null &&
          (command == null || message.toolInput?['command'] == command);
      if (knownTaskId == taskId || matchesResult || matchesStart) {
        message.toolInput?['_monitorTaskId'] = taskId;
        message.toolInput?['_monitorStatus'] = monitoring
            ? 'running'
            : 'stopped';
        break;
      }
    }

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
      existing.toolOutput = '${existing.toolOutput ?? ''}\n$content';
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
    final parentToolUseId = msg['parentToolUseId'] as String?;
    _closeLiveStreamsForParent(parentToolUseId);
    final summary = msg['summary'] as String? ?? '';
    final precedingIds =
        (msg['precedingToolUseIds'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        [];
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
      _supportedModels = models.map((m) {
        final model = m is Map
            ? Map<String, dynamic>.from(m)
            : <String, dynamic>{'value': m.toString()};
        final value = (model['value'] ?? model['id'] ?? '').toString();
        if (value.isNotEmpty) {
          model['value'] = value;
          model.putIfAbsent('id', () => value);
        }
        return model;
      }).toList();
      final currentModel = msg['currentModel'] as String?;
      if (currentModel != null && currentModel.isNotEmpty) {
        _sessionModel = currentModel;
      } else if (_sessionModel == null || _sessionModel!.isEmpty) {
        for (final model in _supportedModels) {
          if (model['current'] == true) {
            final value = (model['value'] ?? model['id'] ?? '').toString();
            if (value.isNotEmpty) {
              _sessionModel = value;
              break;
            }
          }
        }
      }
      _normalizeCodexEffortForSelectedModel();
      notifyListeners();
    }
  }

  void _handleSessionSettings(Map<String, dynamic> msg) {
    final sessionId = msg['sessionId']?.toString() ?? '';
    if (sessionId.isEmpty || sessionId != _activeSessionId) return;
    final raw = msg['settings'];
    if (raw is! Map) return;
    final settings = Map<String, dynamic>.from(raw);

    final model = settings['model']?.toString();
    if (model != null && model.isNotEmpty) _sessionModel = model;
    final effort = settings['effort']?.toString();
    if (effort != null && effort.isNotEmpty) _effort = effort;
    if (settings['thinking'] is Map) {
      _thinking = Map<String, dynamic>.from(settings['thinking'] as Map);
    }
    final fastMode = settings['codexFastMode'];
    if (fastMode is bool) {
      _codexFastMode = fastMode;
      _sessionCodexFastModes[sessionId] = fastMode;
    }
    final autoCompact = settings['claudeAutoCompact'];
    if (autoCompact is bool) {
      _claudeAutoCompactEnabled = autoCompact;
      _sessionClaudeAutoCompact[sessionId] = autoCompact;
    }
    final collaborationMode = settings['codexCollaborationMode']?.toString();
    if (collaborationMode != null && collaborationMode.isNotEmpty) {
      _codexCollaborationMode = collaborationMode;
    }
    final disallowedTools = settings['disallowedTools'];
    if (disallowedTools is List) {
      _sessionDisallowedTools[sessionId] = disallowedTools
          .map((value) => value.toString())
          .toList();
    }
    if (settings.containsKey('systemPrompt')) {
      _sessionSystemPrompts[sessionId] =
          settings['systemPrompt']?.toString() ?? '';
    } else {
      _sessionSystemPrompts.remove(sessionId);
    }
    notifyListeners();
  }

  List<Map<String, dynamic>> get codexReasoningEfforts {
    final currentModel = _sessionModel ?? '';
    for (final model in _supportedModels) {
      final value = (model['value'] ?? model['id'] ?? '').toString();
      if (value != currentModel) continue;
      final rawEfforts = model['supportedReasoningEfforts'];
      if (rawEfforts is! List) break;
      final efforts = rawEfforts
          .map((entry) {
            if (entry is Map) return Map<String, dynamic>.from(entry);
            return <String, dynamic>{'reasoningEffort': entry.toString()};
          })
          .where((entry) {
            return (entry['reasoningEffort'] ?? entry['effort'] ?? '')
                .toString()
                .isNotEmpty;
          })
          .toList();
      if (efforts.isNotEmpty) return efforts;
      break;
    }
    return const [
      {'reasoningEffort': 'minimal'},
      {'reasoningEffort': 'low'},
      {'reasoningEffort': 'medium'},
      {'reasoningEffort': 'high'},
      {'reasoningEffort': 'xhigh'},
    ];
  }

  void _normalizeCodexEffortForSelectedModel() {
    if (_activeSessionBackend != 'codex') return;
    final supported = codexReasoningEfforts
        .map(
          (entry) =>
              (entry['reasoningEffort'] ?? entry['effort'] ?? '').toString(),
        )
        .where((value) => value.isNotEmpty)
        .toList();
    if (supported.isEmpty || supported.contains(_effort)) return;

    String? defaultEffort;
    final currentModel = _sessionModel ?? '';
    for (final model in _supportedModels) {
      final value = (model['value'] ?? model['id'] ?? '').toString();
      if (value == currentModel) {
        defaultEffort = model['defaultReasoningEffort']?.toString();
        break;
      }
    }
    setEffort(
      defaultEffort != null && supported.contains(defaultEffort)
          ? defaultEffort
          : supported.first,
    );
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
    _connMgr.send({'type': 'set_model', if (model != null) 'model': model});
    if (model != null) _sessionModel = model;
    _normalizeCodexEffortForSelectedModel();
    notifyListeners();
  }

  void setPermissionMode(String mode) {
    _connMgr.send({'type': 'set_permission_mode', 'mode': mode});
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
        if (_activeSessionBackend == 'codex') return 'Read Only';
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
      _stopPromptRuntime();
      _clearLiveMessageStreams();
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
      _stopPromptRuntime();
      _clearLiveMessageStreams();
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
    final clientMessageId = msg['clientMessageId'] as String?;
    if (clientMessageId != null && clientMessageId.isNotEmpty) {
      final idx = _messages.indexWhere((m) => m.id == clientMessageId);
      if (idx >= 0) {
        _messages[idx].uuid = uuid;
        applyTranscriptPosition(_messages[idx], msg);
        _messages = orderByTranscriptPosition(_messages);
        // The UUID acknowledges that the server persisted this prompt, but an
        // older history request may still be in flight. Keep protecting the
        // optimistic bubble until an authoritative history response actually
        // contains the prompt; otherwise that stale response can erase it.
        if (_isPendingInjectedMessage(_messages[idx]) &&
            _pendingInjectedMessageCount > 0) {
          _pendingInjectedMessageCount--;
          _messages[idx].isPending = false;
          _messages[idx].injectionPriority = null;
        }
        notifyListeners();
        return;
      }
    }
    // Find the most recent user text message without a UUID and assign it
    for (int i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.sender == MessageSender.user &&
          (m.type == MessageType.text ||
              m.type == MessageType.skillInvocation) &&
          m.uuid == null) {
        m.uuid = uuid;
        applyTranscriptPosition(m, msg);
        _messages = orderByTranscriptPosition(_messages);
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

  RegExpMatch? _parseCodexSlashInvocation(String text) {
    if (_activeSessionBackend != 'codex') return null;
    return RegExp(
      r'''^/(?:"([^"]+)"|'([^']+)'|([^\s]+))(?:\s+([\s\S]*))?$''',
    ).firstMatch(text.trim());
  }

  Map<String, dynamic>? _knownCodexSlashCommand(String text) {
    final match = _parseCodexSlashInvocation(text);
    if (match == null) return null;
    final rawName = match.group(1) ?? match.group(2) ?? match.group(3) ?? '';
    final name = _cleanSlashName(rawName);
    if (name.isEmpty) return null;
    return slashCommands.where((candidate) {
      return candidate['kind'] == 'command' &&
          _cleanSlashName((candidate['name'] ?? '').toString()).toLowerCase() ==
              name.toLowerCase();
    }).firstOrNull;
  }

  String _codexSlashInvocationName(RegExpMatch match) {
    return _cleanSlashName(
      match.group(1) ?? match.group(2) ?? match.group(3) ?? '',
    );
  }

  String _codexSlashInvocationArgs(RegExpMatch match) {
    return (match.group(4) ?? '').trim();
  }

  ChatMessage? _buildSkillInvocationMessage(String text) {
    final match = _parseCodexSlashInvocation(text);
    if (match == null) return null;

    final name = _codexSlashInvocationName(match);
    if (name.isEmpty) return null;
    final args = _codexSlashInvocationArgs(match);
    final command = slashCommands.where((candidate) {
      return candidate['kind'] == 'skill' &&
          _cleanSlashName((candidate['name'] ?? '').toString()).toLowerCase() ==
              name.toLowerCase();
    }).firstOrNull;
    if (command == null) return null;

    return ChatMessage.skillInvocation(
      name: name,
      args: args,
      description: (command['description'] ?? '').toString(),
      body: (command['body'] ?? '').toString(),
    );
  }

  bool _sendCodexSlashCommand(String text) {
    final match = _parseCodexSlashInvocation(text);
    if (match == null) return false;
    final name = _codexSlashInvocationName(match);
    if (name.isEmpty) return false;
    final args = _codexSlashInvocationArgs(match);

    _messages.add(ChatMessage.userText(text.trim()));
    _promptSuggestions = [];
    notifyListeners();

    if (name == 'fork') {
      if (_activeSessionId == null || _activeSessionId!.isEmpty) {
        _messages.add(ChatMessage.error('No Codex session to fork'));
        notifyListeners();
        return true;
      }
      _connMgr.send({'type': 'fork_session', 'sessionId': _activeSessionId});
      return true;
    }

    _connMgr.send({
      'type': 'codex_slash_command',
      'name': name,
      'args': args,
      if (_activeSessionId != null) 'sessionId': _activeSessionId,
    });
    return true;
  }

  void _handleSessionCreated(Map<String, dynamic> msg, String? serverId) {
    final sessionId = msg['sessionId'] as String?;
    final replacesSessionId = msg['replacesSessionId'] as String?;
    final backend = msg['backend'] as String?;
    if (backend != null) _activeSessionBackend = backend;
    if (sessionId != null && sessionId.isNotEmpty) {
      if (replacesSessionId != null && replacesSessionId.isNotEmpty) {
        _locallyClearedSessions.remove(replacesSessionId);
      }
      _activeSessionId = sessionId;
      if (serverId != null && serverId.isNotEmpty) {
        _activeSessionServerId = serverId;
      } else {
        _activeSessionServerId ??= _connMgr.activeServerId;
      }
      if (_activeSessionBackend == 'codex') {
        _sessionCodexFastModes[sessionId] = _codexFastMode;
      } else {
        _sessionClaudeAutoCompact.putIfAbsent(
          sessionId,
          () => _claudeAutoCompactEnabled,
        );
      }
      _loadPrepends();
    }
    _activeSessionCwd = msg['cwd'] as String?;
    _activeSessionTitle = msg['title'] as String?;
    // Server echoes the backend on the second session_created (the one with
    // the real id). Capture it so the chat header label is right immediately.
    final permissionMode = msg['permissionMode'] as String?;
    if (permissionMode != null) _permissionMode = permissionMode;
    _requestActiveCodexMetadata();
    notifyListeners();
  }

  void _handleSessionHistory(
    Map<String, dynamic> msg, {
    String? serverId,
    bool fromCache = false,
  }) {
    final historySessionId = msg['sessionId'] as String?;
    final decision = fromCache
        ? const SessionHistoryDecision(
            accept: true,
            kind: SessionHistoryKind.initial,
          )
        : gateSessionHistoryResponse(
            responseSessionId: historySessionId,
            activeSessionId: _activeSessionId,
            historyKind: msg['historyKind'] as String?,
            requestId: msg['requestId'] as String?,
            expectedInitialRequestId: _initialHistoryRequestId,
            expectedOlderRequestId: _olderHistoryRequestId,
            legacyAppend: msg['append'] == true,
            legacyLoadingMore: _isLoadingMore,
            hasVisibleMessages: _messages.isNotEmpty,
          );
    if (!decision.accept) return;

    if ((decision.kind == SessionHistoryKind.initial ||
            decision.kind == SessionHistoryKind.delta) &&
        !fromCache) {
      _initialHistoryTimeout?.cancel();
      _initialHistoryTimeout = null;
      _initialHistoryRequestId = null;
      _olderHistoryRequestId = null;
      _isLoadingMore = false;
    } else if (decision.kind == SessionHistoryKind.older) {
      _olderHistoryRequestId = null;
    }

    final liveBeforeSnapshot = [..._messages];
    final rawMessages = normalizeSendFileHistoryEntries(
      msg['messages'] as List? ?? const [],
    );
    final offset = (msg['offset'] as num?)?.toInt() ?? 0;
    final isDelta = decision.kind == SessionHistoryKind.delta;
    final isAppend = decision.kind == SessionHistoryKind.append || isDelta;
    final isPrepend = decision.kind == SessionHistoryKind.older;
    if (historySessionId != null &&
        _locallyClearedSessions.contains(historySessionId) &&
        rawMessages.isNotEmpty) {
      _isLoadingHistory = false;
      _isLoadingMore = false;
      notifyListeners();
      return;
    }

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

    var loaded = <ChatMessage>[];
    var historyPrevTodos = <Map<String, dynamic>>[];
    final skippedToolUseIds = <String>{};
    for (final entry in rawMessages) {
      final loadedStartIndex = loaded.length;
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

          // Strip all queued attachment prefixes and recreate their visible
          // metadata-only cards. Secret values are never part of this text.
          var attachmentIndex = 0;
          while (true) {
            final fileMatch = RegExp(
              r'^\[Attached file: (.+?)\]\n?',
            ).firstMatch(userText);
            if (fileMatch != null) {
              final filePath = fileMatch.group(1)!;
              final fileName = filePath.split('/').last;
              userText = userText.substring(fileMatch.end);
              loaded.add(
                ChatMessage(
                  id: 'upload_${DateTime.now().microsecondsSinceEpoch}_${offset}_$attachmentIndex',
                  sender: MessageSender.system,
                  type: MessageType.taskNotification,
                  timestamp: DateTime.now(),
                  textContent: 'Uploaded: $fileName',
                  toolName: 'uploaded',
                ),
              );
              attachmentIndex++;
              continue;
            }
            final secretMatch = RegExp(
              r'^\[Attached secret: (.+)\]\n?',
            ).firstMatch(userText);
            if (secretMatch != null) {
              try {
                final metadata = Map<String, dynamic>.from(
                  jsonDecode(secretMatch.group(1)!) as Map,
                );
                final label = metadata['label'] as String? ?? 'Secret';
                final scope = metadata['scope'] as String? ?? 'session';
                loaded.add(
                  ChatMessage(
                    id: 'secret_attach_${DateTime.now().microsecondsSinceEpoch}_${offset}_$attachmentIndex',
                    sender: MessageSender.system,
                    type: MessageType.taskNotification,
                    timestamp: DateTime.now(),
                    textContent: 'Attached secret: $label ($scope)',
                    toolName: 'secure_attached',
                  ),
                );
              } catch (_) {
                // The prefix is still hidden if metadata was malformed.
              }
              userText = userText.substring(secretMatch.end);
              attachmentIndex++;
              continue;
            }
            break;
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
                  parentToolUseId: entry['parentToolUseId'] as String?,
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
              m.parentToolUseId = entry['parentToolUseId'] as String?;
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
              m.parentToolUseId = entry['parentToolUseId'] as String?;
              loaded.add(m);
            }
          }
          break;
        case 'notification':
          if (content.isNotEmpty) {
            final status = entry['status'] as String? ?? 'info';
            final originToolUseId = entry['originToolUseId'] as String?;
            final commandName = entry['commandName'] as String?;
            final commandPayload = entry['commandPayload'] is Map
                ? Map<String, dynamic>.from(entry['commandPayload'] as Map)
                : null;
            if (commandName != null && commandPayload != null) {
              loaded.add(
                ChatMessage.codexCommand(
                  command: commandName,
                  summary: content,
                  status: status,
                  payload: commandPayload,
                ),
              );
              break;
            }
            final notifMsg = ChatMessage(
              id: 'notif_${DateTime.now().microsecondsSinceEpoch}_$offset',
              sender: MessageSender.system,
              type: MessageType.taskNotification,
              timestamp: DateTime.now(),
              textContent: content,
              toolName: status,
            );
            notifMsg.originToolUseId = originToolUseId;
            notifMsg.parentToolUseId =
                entry['parentToolUseId'] as String? ?? originToolUseId;
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
                  '${existingMonitor.toolOutput ?? ''}\n$content';
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
          final toolName = normalizeSocketAgentToolName(
            entry['toolName'] as String? ?? 'Tool',
          );
          final rawToolInput = entry['toolInput'];
          final toolInput = rawToolInput is Map
              ? Map<String, dynamic>.from(rawToolInput)
              : <String, dynamic>{};
          final toolUseId = entry['toolUseId'] as String? ?? '';
          if (toolName == 'Agent' &&
              _codexAgentControlTypes.contains(
                toolInput['subagent_type'] as String? ?? '',
              )) {
            if (toolUseId.isNotEmpty) skippedToolUseIds.add(toolUseId);
            break;
          }
          if (toolName == 'SendFile') {
            final filePath = toolInput['file_path'] as String? ?? '';
            if (filePath.isNotEmpty) {
              final historyFileId =
                  entry['fileId'] as String? ??
                  _filePathToId[filePath] ??
                  filePath;
              final historyFileName =
                  entry['fileName'] as String? ?? filePath.split('/').last;
              final historyFileSize = (entry['fileSize'] as num?)?.toInt();
              _serverFiles[historyFileId] = filePath;
              _serverFileNames[historyFileId] = historyFileName;
              if (historyFileSize != null && historyFileSize > 0) {
                _serverFileSizes[historyFileId] = historyFileSize;
              }
              toolInput['_file_id'] = historyFileId;
              toolInput['_file_name'] = historyFileName;
              if (historyFileSize != null && historyFileSize > 0) {
                toolInput['_file_size'] = historyFileSize;
              }
              _filePathToId[filePath] = historyFileId;
              final activeServerId = _connMgr.activeServerId;
              if (activeServerId != null && activeServerId.isNotEmpty) {
                _downloadServerIds[historyFileId] = activeServerId;
              }
              if (historySessionId != null && historySessionId.isNotEmpty) {
                _downloadSessionIds[historyFileId] = historySessionId;
              }
            }
          }
          if (toolName.endsWith('RequestSecureInput')) {
            if (toolUseId.isNotEmpty) skippedToolUseIds.add(toolUseId);
            break;
          }
          if (toolName == 'HtmlPlan') {
            if (toolUseId.isNotEmpty) skippedToolUseIds.add(toolUseId);
            break;
          }
          final toolCallMsg = ChatMessage.toolCall(
            tool: toolName,
            input: toolInput,
            toolUseId: toolUseId,
          );
          toolCallMsg.uuid = entry['uuid'] as String?;
          toolCallMsg.parentToolUseId = entry['parentToolUseId'] as String?;
          final orphanResult = _toolEventReconciler.takeResult(toolUseId);
          if (orphanResult != null) {
            toolCallMsg.toolOutput = orphanResult.output;
            toolCallMsg.toolStreaming = false;
          }
          loaded.add(toolCallMsg);
          break;
        case 'tool_result':
          final toolUseId = entry['toolUseId'] as String? ?? '';
          if (skippedToolUseIds.contains(toolUseId)) break;
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
            final existingIdx = isAppend
                ? _messages.lastIndexWhere(
                    (m) =>
                        m.type == MessageType.toolCall &&
                        m.toolUseId == toolUseId,
                  )
                : -1;
            if (existingIdx >= 0) {
              _messages[existingIdx].toolOutput = output;
              _messages[existingIdx].toolStreaming = false;
            } else {
              _toolEventReconciler.bufferResult(
                toolUseId,
                output,
                parentToolUseId: entry['parentToolUseId'] as String?,
              );
            }
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
            historyPrevTodos = (jsonDecode(content) as List)
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
        case 'secure_input':
          final requestId = entry['questionId'] as String? ?? '';
          final input = Map<String, dynamic>.from(
            (entry['toolInput'] as Map?) ?? const {},
          );
          final status = secureInputHistoryStatus(
            entry['status'],
            input['status'],
          );
          final existingIdx = loaded.lastIndexWhere(
            (m) =>
                m.type == MessageType.secureInput && m.questionId == requestId,
          );
          if (existingIdx >= 0) {
            loaded[existingIdx].answered = status != 'pending';
            loaded[existingIdx].toolInput?['status'] = status;
          } else if (requestId.isNotEmpty) {
            final secureMessage = ChatMessage.secureInput(
              requestId: requestId,
              label: input['label'] as String? ?? 'Secret',
              reason: input['reason'] as String? ?? content,
              envHint: input['envHint'] as String? ?? '',
              scope: input['scope'] as String? ?? 'session',
              status: status,
            );
            secureMessage.answered = status != 'pending';
            loaded.add(secureMessage);
          }
          break;
        case 'html_plan':
          final rawPlan = entry['toolInput'];
          if (rawPlan is Map) {
            final plan = Map<String, dynamic>.from(rawPlan);
            final planId = plan['planId']?.toString() ?? '';
            if (planId.isNotEmpty &&
                (plan['html']?.toString() ?? '').isNotEmpty) {
              final planMessage = ChatMessage.htmlPlan(plan);
              final existingIndex = loaded.indexWhere(
                (message) =>
                    message.type == MessageType.htmlPlan &&
                    message.toolUseId == planId,
              );
              if (existingIndex >= 0) {
                loaded[existingIndex] = planMessage;
              } else {
                loaded.add(planMessage);
              }
            }
          }
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
      for (var index = loadedStartIndex; index < loaded.length; index++) {
        applyTranscriptPosition(loaded[index], entry);
      }
    }

    // Clear orphaned tool calls that never got a result (e.g. server was
    // killed mid-query). Without this they'd show as blank spinning cards.
    for (final m in loaded) {
      if (m.type == MessageType.toolCall && m.toolOutput == null) {
        m.toolOutput = '';
      }
    }
    loaded = _dedupeLoadedHistory(loaded);
    // Appends add newer events and must not move the boundary of the oldest
    // page already in memory. Moving it here makes the next pagination request
    // fetch a recent/duplicate slice instead of the preceding page.
    if (!isAppend) {
      _historyOffset = offset;
    } else if (isDelta && msg['offset'] is num) {
      // Preserve the oldest cached boundary. A delta begins after the cached
      // tail, so its own offset is not a pagination boundary.
      _historyOffset = _historyOffset
          .clamp(0, (msg['offset'] as num).toInt())
          .toInt();
    }

    if (isAppend) {
      // Append missed messages (e.g., from server downtime recovery)
      // Deduplicate text entries whose content already exists in recent
      // messages. Codex native sync can append the finalized assistant message
      // while its streamed bubble is already visible.
      final deduped = <ChatMessage>[];
      for (final msg in loaded) {
        if ((msg.sender == MessageSender.user ||
                msg.sender == MessageSender.assistant) &&
            msg.type == MessageType.text) {
          final normalizedText = _normalizeHistoryText(msg.textContent);
          final isDupe =
              _messages.reversed
                  .take(20)
                  .any(
                    (m) =>
                        m.sender == msg.sender &&
                        m.type == MessageType.text &&
                        m.parentToolUseId == msg.parentToolUseId &&
                        _normalizeHistoryText(m.textContent) == normalizedText,
                  ) ||
              (_currentStreamingMessage != null &&
                  _currentStreamingMessage!.sender == msg.sender &&
                  _currentStreamingMessage!.type == MessageType.text &&
                  _currentStreamingMessage!.parentToolUseId ==
                      msg.parentToolUseId &&
                  _normalizeHistoryText(
                        _currentStreamingMessage!.textContent,
                      ) ==
                      normalizedText);
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
      // Reconcile the full visible live transcript. ChatMessage timestamps
      // can originate on the server, so comparing them with the local receipt
      // time loses completed tool/text events that raced this snapshot.
      loaded = reconcileLiveTranscriptWithSnapshot(loaded, liveBeforeSnapshot);
      final localPendingUserPrompts = _messages
          .where(_isPendingLocalUserPrompt)
          .where((m) => !_hasEquivalentUserMessage(loaded, m))
          .toList();
      for (final m in _messages.where(_isPendingLocalUserPrompt)) {
        if (_hasEquivalentUserMessage(loaded, m)) {
          _pendingLocalUserMessageIds.remove(m.id);
          _pendingCacheUserPromptContent.remove(m.id);
        }
      }
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
      _messages = [...loaded, ...localPendingUserPrompts, ...localOnlyCards];
      // A cached transcript can already be painted when an authoritative
      // resume falls back from a large delta to a bounded tail. Replacing that
      // window changes every scroll extent; tell ChatView to discard the
      // offset that belonged to the previous window.
      _historyWindowRevision++;
      _backgroundTasks.clear();
      _subagentTasks.clear();
      _isLoadingHistory = false;
    }
    _messages = orderByTranscriptPosition(_messages);
    _recountPendingInjectedMessages();
    // Fallback: if server didn't include 'todos' field (old server compat),
    // sync _todos from the last todos_update in history for dedup.
    if (rawTodos == null && historyPrevTodos.isNotEmpty) {
      _todos = historyPrevTodos;
    }
    // Rebuild subagent tasks from loaded messages (for expandable Task cards)
    for (final m in _messages) {
      if (m.type == MessageType.toolCall &&
          (m.toolName == 'Task' || m.toolName == 'Agent') &&
          m.toolUseId != null &&
          !_codexAgentControlTypes.contains(
            m.toolInput?['subagent_type'] as String? ?? '',
          )) {
        final desc = m.toolInput?['description'] as String? ?? 'Sub agent task';
        final hasResult = m.toolOutput != null;
        _subagentTasks[m.toolUseId!] = {
          'description': desc,
          'prompt': m.toolInput?['prompt'] as String? ?? '',
          'subagentType': m.toolInput?['subagent_type'] as String? ?? '',
          'status': hasResult ? 'completed' : 'running',
          'toolUseId': m.toolUseId!,
          if (m.toolInput?['agentId'] != null)
            'agentId': m.toolInput?['agentId'],
          if (m.parentToolUseId != null) 'parentToolUseId': m.parentToolUseId,
        };
      }
    }
    _loadDismissedSubagents();
    if (fromCache) {
      _isLoadingHistory = false;
      _isRefreshingHistory = true;
    } else if (decision.kind == SessionHistoryKind.initial || isDelta) {
      _isRefreshingHistory = false;
      final ownerServerId = serverId ?? _activeSessionServerId ?? '';
      if (historySessionId != null && ownerServerId.isNotEmpty) {
        if (isDelta) {
          unawaited(
            _transcriptCache.mergeDelta(ownerServerId, historySessionId, msg),
          );
        } else {
          unawaited(
            _transcriptCache.save(ownerServerId, historySessionId, msg),
          );
        }
      }
    } else if (isPrepend) {
      final ownerServerId = serverId ?? _activeSessionServerId ?? '';
      if (historySessionId != null && ownerServerId.isNotEmpty) {
        unawaited(
          _transcriptCache.mergeOlderPage(ownerServerId, historySessionId, msg),
        );
      }
    }

    if ((decision.kind == SessionHistoryKind.initial || isDelta) &&
        msg['totalUserPrompts'] is num) {
      _historyBackfillTargetUserPrompts = recentUserPromptBackfillTarget(
        (msg['totalUserPrompts'] as num).toInt(),
      );
    }
    if (isPrepend || decision.kind == SessionHistoryKind.initial || isDelta) {
      _autoBackfillRecentPrompts = shouldBackfillRecentHistory(
        oldestLoadedOffset: _historyOffset,
        deferredContextAvailable:
            !isPrepend && msg['deferredContextAvailable'] == true,
        loadedUserPrompts: _messages.where(_isUserPromptMessage).length,
        targetUserPrompts: _historyBackfillTargetUserPrompts,
      );
    }
    _ensurePendingHardStopCard(
      historySessionId,
      serverId: serverId ?? _activeSessionServerId,
    );
    notifyListeners();

    // A cache paint can arrive before the authoritative initial/delta reply.
    // Wait for that network reply before paginating so the two request
    // generations cannot race each other.
    if (!fromCache &&
        _autoBackfillRecentPrompts &&
        !_isLoadingMore &&
        _historyOffset > 0) {
      final sessionId = _activeSessionId;
      // Yield one event-loop turn so the bounded page paints before any
      // potentially large older page is requested and parsed.
      Timer.run(() {
        if (_activeSessionId != sessionId || !_autoBackfillRecentPrompts) {
          return;
        }
        loadMoreHistory();
      });
    }

    final openTraceId = fromCache
        ? _initialHistoryRequestId
        : msg['openTraceId'] as String? ?? msg['requestId'] as String?;
    final traceStarted = openTraceId == null
        ? null
        : _historyOpenTraceStartedAt[openTraceId];
    if (openTraceId != null && traceStarted != null) {
      final phase = fromCache ? 'cache-painted' : 'network-reconciled';
      final elapsedMs = DateTime.now().difference(traceStarted).inMilliseconds;
      debugPrint(
        '[SessionOpen] $phase trace=$openTraceId elapsedMs=$elapsedMs '
        'raw=${rawMessages.length} visible=${_messages.length}',
      );
      if (!fromCache) _historyOpenTraceStartedAt.remove(openTraceId);
    }

    // Fetch pending image data from server for history tool_image entries.
    if (_pendingImageLoads.isNotEmpty) {
      _fetchPendingImages();
    }
  }

  String _normalizeHistoryText(String text) {
    return text.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  List<ChatMessage> _dedupeLoadedHistory(List<ChatMessage> messages) {
    final deduped = <ChatMessage>[];
    final seenMessageKeys = <String>{};
    for (final msg in messages) {
      final uuid = msg.uuid;
      if (uuid != null && uuid.isNotEmpty) {
        final key =
            '${msg.sender.name}:${msg.type.name}:${msg.parentToolUseId ?? ''}:$uuid';
        if (!seenMessageKeys.add(key)) continue;
      }
      if ((msg.sender == MessageSender.user ||
              msg.sender == MessageSender.assistant) &&
          msg.type == MessageType.text) {
        final normalized = _normalizeHistoryText(msg.textContent);
        if (normalized.isNotEmpty && deduped.isNotEmpty) {
          final previous = deduped.last;
          if (previous.sender == msg.sender &&
              previous.type == MessageType.text &&
              previous.parentToolUseId == msg.parentToolUseId &&
              _normalizeHistoryText(previous.textContent) == normalized) {
            continue;
          }
        }
      }
      deduped.add(msg);
    }
    return deduped;
  }

  ChatMessage? _findReplayedAssistantMessage(
    String content, {
    String? parentToolUseId,
  }) {
    final normalized = _normalizeHistoryText(content);
    if (normalized.isEmpty) return null;
    final lastUserIndex = _messages.lastIndexWhere(
      (m) =>
          m.sender == MessageSender.user &&
          (m.type == MessageType.text || m.type == MessageType.skillInvocation),
    );
    for (var i = _messages.length - 1; i > lastUserIndex; i--) {
      final candidate = _messages[i];
      if (candidate.sender != MessageSender.assistant ||
          candidate.type != MessageType.text ||
          candidate.parentToolUseId != parentToolUseId) {
        continue;
      }
      final candidateText = _normalizeHistoryText(candidate.textContent);
      if (candidateText.isEmpty) continue;
      if (candidateText == normalized ||
          candidateText.startsWith(normalized) ||
          normalized.startsWith(candidateText)) {
        return candidate;
      }
    }
    return null;
  }

  ChatMessage? _findReplayedThinkingMessage(
    String content, {
    String? parentToolUseId,
  }) {
    final normalized = _normalizeHistoryText(content);
    if (normalized.isEmpty) return null;
    final lastUserIndex = _messages.lastIndexWhere(
      (m) =>
          m.sender == MessageSender.user &&
          (m.type == MessageType.text || m.type == MessageType.skillInvocation),
    );
    for (var i = _messages.length - 1; i > lastUserIndex; i--) {
      final candidate = _messages[i];
      if (candidate.type != MessageType.thinking ||
          candidate.parentToolUseId != parentToolUseId) {
        continue;
      }
      final candidateText = _normalizeHistoryText(candidate.textContent);
      if (candidateText.isEmpty) continue;
      if (candidateText == normalized ||
          candidateText.startsWith(normalized) ||
          normalized.startsWith(candidateText)) {
        return candidate;
      }
    }
    return null;
  }

  bool _isPendingLocalUserPrompt(ChatMessage message) {
    return _pendingLocalUserMessageIds.contains(message.id) &&
        message.sender == MessageSender.user &&
        (message.type == MessageType.text ||
            message.type == MessageType.skillInvocation);
  }

  bool _isUserPromptMessage(ChatMessage message) {
    return message.sender == MessageSender.user &&
        (message.type == MessageType.text ||
            message.type == MessageType.skillInvocation);
  }

  bool _hasEquivalentUserMessage(
    List<ChatMessage> messages,
    ChatMessage target,
  ) {
    final normalized = _normalizeHistoryText(target.textContent);
    if (normalized.isEmpty) return false;
    return messages.any((m) {
      if (m.sender != MessageSender.user ||
          (m.type != MessageType.text &&
              m.type != MessageType.skillInvocation)) {
        return false;
      }
      final candidate = _normalizeHistoryText(m.textContent);
      return candidate == normalized ||
          candidate.endsWith(normalized) ||
          normalized.endsWith(candidate);
    });
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
        .where((s) => !_isSessionArchiveHidden(serverId, s.id))
        .toList();

    if (serverId != null) {
      // Store per-server and rebuild merged list
      _perServerSessions[serverId] = sessions;
      _rebuildSessionList();
      _replaceRunningSessionsForServer(
        serverId,
        sessions.where((session) => session.running).map((s) => s.id).toSet(),
        {
          for (final session in sessions.where((session) => session.running))
            session.id: _parseServerDateTime(session.activeStartedAt),
        },
      );
      _saveSessionCacheSoon();
    } else {
      // Legacy single-server path
      _sessions = sessions;
    }
    notifyListeners();
  }

  Future<void> sendPrompt(String text, {String? priority}) async {
    if (text.trim().isEmpty && !hasAttachment) return;

    final knownSlashCommand = _knownCodexSlashCommand(text);
    if (knownSlashCommand != null && !hasAttachment && priority == null) {
      _sendCodexSlashCommand(text);
      return;
    }

    // Snapshot the entire composer queue. Values remain memory-only until the
    // server acknowledges storage, and are never included in prompt/history.
    final fileAttachments = [..._pendingFileAttachments];
    final secretAttachments = [..._pendingSecretAttachments];
    final attachmentCount = fileAttachments.length + secretAttachments.length;
    final hasAttachmentsForSend = attachmentCount > 0;

    // Show the user's message immediately (original text only)
    final displayText = text.trim().isEmpty
        ? [
            if (fileAttachments.isNotEmpty)
              '📎 ${fileAttachments.length} ${fileAttachments.length == 1 ? "file" : "files"}',
            if (secretAttachments.isNotEmpty)
              '🔐 ${secretAttachments.length} ${secretAttachments.length == 1 ? "secret" : "secrets"}',
          ].join(' · ')
        : text;
    final userMsg = _buildUserDisplayMessage(displayText);
    _pendingLocalUserMessageIds.add(userMsg.id);
    // Mark as pending if injecting with non-immediate priority OR if we're
    // about to spend time uploading. The bubble renders pending state with
    // reduced opacity + a progress indicator while the file streams up.
    if (priority != null && _isProcessing) {
      userMsg.isPending = true;
      userMsg.injectionPriority = priority;
      _pendingInjectedMessageCount++;
    }
    if (hasAttachmentsForSend) {
      userMsg.isPending = true;
      if (fileAttachments.isNotEmpty) {
        userMsg.uploadProgress = 0.0;
        userMsg.uploadFileName = fileAttachments.length == 1
            ? fileAttachments.first.name
            : '${fileAttachments.length} files';
      }
    }
    _messages.add(userMsg);
    // Don't null _currentStreamingMessage here — if Claude is mid-stream,
    // let it keep appending to the existing message at its current position
    // (before the user message). It gets cleared by _handleResult when the
    // turn ends, so the response to the injected message starts fresh.
    _isProcessing = true;
    final promptStartedAt = DateTime.now();
    _processingSetAt = promptStartedAt;
    _startPromptRuntime(startedAt: promptStartedAt);
    _promptSuggestions = [];

    // The queue is now committed to this bubble. Do not clear the snapshotted
    // secret values until each has either been stored or the send has failed.
    _pendingFileAttachments.clear();
    _pendingSecretAttachments.clear();
    _uploadProgress = null;
    _pendingUploadId = null;
    notifyListeners();

    String prompt = text;
    final uploadedPaths = <String>[];
    final attachedSecrets = <SecretMetadata>[];
    final attachmentCards = <ChatMessage>[];

    if (hasAttachmentsForSend) {
      try {
        for (var i = 0; i < fileAttachments.length; i++) {
          final attachment = fileAttachments[i];
          if (!attachment.exists) {
            throw Exception('File is no longer available: ${attachment.name}');
          }
          final count = fileAttachments.length;
          final serverPath = await _uploadFromPath(
            path: attachment.path,
            name: attachment.name,
            progressTarget: userMsg,
            progressBase: count == 0 ? 0 : i / count,
            progressSpan: count == 0 ? 1 : 1 / count,
          );
          uploadedPaths.add(serverPath);
          attachmentCards.add(
            ChatMessage(
              id: 'upload_${DateTime.now().microsecondsSinceEpoch}_$i',
              sender: MessageSender.system,
              type: MessageType.taskNotification,
              timestamp: DateTime.now(),
              textContent: 'Uploaded: ${serverPath.split('/').last}',
              toolName: 'uploaded',
            ),
          );
        }

        for (var i = 0; i < secretAttachments.length; i++) {
          final attachment = secretAttachments[i];
          final metadata =
              attachment.metadata ??
              await storeSecureInput(
                label: attachment.label,
                value: attachment.value,
                scope: attachment.scope,
                envHint: attachment.envHint,
              );
          attachment.clearValue();
          attachedSecrets.add(metadata);
          _resolveMatchingSecureInput(metadata);
          attachmentCards.add(
            ChatMessage(
              id: 'secret_attach_${DateTime.now().microsecondsSinceEpoch}_$i',
              sender: MessageSender.system,
              type: MessageType.taskNotification,
              timestamp: DateTime.now(),
              textContent:
                  'Attached secret: ${metadata.label} (${metadata.scope})',
              toolName: 'secure_attached',
            ),
          );
        }

        final prefixes = <String>[
          for (final serverPath in uploadedPaths)
            '[Attached file: $serverPath]',
          for (final secret in attachedSecrets)
            '[Attached secret: ${jsonEncode({'label': secret.label, 'scope': secret.scope, 'envHint': secret.envHint, 'filePath': secret.filePath})}]',
        ];
        prompt = '${prefixes.join('\n')}\n$prompt';

        final idx = _messages.indexOf(userMsg);
        if (idx >= 0) {
          _messages.insertAll(idx, attachmentCards);
        } else {
          _messages.addAll(attachmentCards);
        }
      } catch (e) {
        for (final secret in secretAttachments) {
          secret.clearValue();
        }
        _pendingLocalUserMessageIds.remove(userMsg.id);
        userMsg.isPending = false;
        userMsg.uploadProgress = null;
        _messages.add(ChatMessage.error('Attachment failed: $e'));
        _isProcessing = false;
        _stopPromptRuntime();
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

    _pendingCacheUserPromptContent[userMsg.id] = prompt;
    final useCodexFastMode = _activeSessionBackend == 'codex' && _codexFastMode;
    _sendToActiveSessionServer({
      'type': 'prompt',
      'text': prompt,
      if (_activeSessionId != null) 'sessionId': _activeSessionId,
      if (priority != null) 'priority': priority,
      'messageId': userMsg.id,
      if (_activeSessionId == null && _activeSessionCwd != null)
        'cwd': _activeSessionCwd,
      if (useCodexFastMode) 'codexFastMode': true,
    });

    // Upload + dispatch done — bubble is officially "sent" now (unless it's
    // queued behind a running query, in which case keep the pending state).
    if (hasAttachmentsForSend && userMsg.injectionPriority == null) {
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
    if (_pendingInjectedMessageCount > 0) {
      _pendingInjectedMessageCount--;
    }
    _pendingLocalUserMessageIds.remove(messageId);
    _pendingCacheUserPromptContent.remove(messageId);
    _sendToActiveSessionServer({
      'type': 'retract_queued_prompt',
      'messageId': messageId,
    });
    notifyListeners();
    return text;
  }

  Future<void> pickFiles({bool imagesOnly = false}) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: imagesOnly ? FileType.image : FileType.any,
    );
    if (result == null) return;
    final existingPaths = _pendingFileAttachments
        .map((item) => item.path)
        .toSet();
    for (final file in result.files) {
      final filePath = file.path;
      if (filePath == null || !existingPaths.add(filePath)) continue;
      _pendingFileAttachments.add(
        PendingFileAttachment(
          path: filePath,
          name: file.name,
          isImage:
              imagesOnly || PendingFileAttachment.looksLikeImage(file.name),
        ),
      );
    }
    notifyListeners();
  }

  Future<void> pickFile() => pickFiles();

  void removeFileAttachment(String id) {
    _pendingFileAttachments.removeWhere((item) => item.id == id);
    notifyListeners();
  }

  void queueSecureAttachment({
    required String label,
    required String value,
    String scope = 'session',
    String? envHint,
  }) {
    if (label.trim().isEmpty || value.isEmpty) return;
    _pendingSecretAttachments.add(
      PendingSecretAttachment.newValue(
        label: label.trim(),
        value: value,
        scope: scope,
        envHint: (envHint == null || envHint.trim().isEmpty)
            ? label.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), '_')
            : envHint.trim(),
      ),
    );
    notifyListeners();
  }

  void attachStoredSecret(SecretMetadata secret) {
    if (_pendingSecretAttachments.any(
      (item) => item.metadata?.secretId == secret.secretId,
    )) {
      return;
    }
    _pendingSecretAttachments.add(PendingSecretAttachment.stored(secret));
    notifyListeners();
  }

  void removeSecretAttachment(String id) {
    final matches = _pendingSecretAttachments.where((item) => item.id == id);
    for (final item in matches) {
      item.clearValue();
    }
    _pendingSecretAttachments.removeWhere((item) => item.id == id);
    notifyListeners();
  }

  void removeAttachment() {
    for (final secret in _pendingSecretAttachments) {
      secret.clearValue();
    }
    _pendingFileAttachments.clear();
    _pendingSecretAttachments.clear();
    _uploadProgress = null;
    _pendingUploadId = null;
    notifyListeners();
  }

  Future<String> _uploadFromPath({
    required String path,
    required String name,
    required ChatMessage progressTarget,
    double progressBase = 0,
    double progressSpan = 1,
  }) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    final ws = _sessionWs;
    final binary = ws.serverSupportsBinary;
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
      progressBase: progressBase,
      progressSpan: progressSpan,
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

    ws.send({
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
        ws.sendUploadChunkBinary(
          uploadId: uploadId,
          chunkIndex: i,
          bytes: chunk,
        );
      } else {
        ws.send({
          'type': 'upload_chunk',
          'uploadId': uploadId,
          'chunkIndex': i,
          'data': base64Encode(chunk),
        });
        // Legacy fallback: drive spinner from chunk-loop iteration so it's
        // not stuck at 0 when the server isn't emitting progress events.
        progressTarget.uploadProgress =
            progressBase + ((i + 1) / totalChunks) * progressSpan;
        notifyListeners();
      }
    }

    // No wall-clock timeout — completion is gated by server `upload_complete`
    // (success) or the stall detector inside `state` (failure after 30s
    // without a progress event).
    return completer.future;
  }

  Future<void> abortQuery() async {
    final sessionId = _activeSessionId ?? _viewingSessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    final serverId =
        _viewingServerId ??
        _activeSessionServerId ??
        _connMgr.activeServerId ??
        '';
    final key = _hardStopKey(serverId, sessionId);
    final existing = _pendingHardStops[key];
    if (existing != null) {
      _transmitPendingAbort(existing);
      return;
    }

    final now = DateTime.now().microsecondsSinceEpoch;
    final pending = _PendingHardStop(
      requestId: 'abort_${now}_$sessionId',
      sessionId: sessionId,
      serverId: serverId,
      cardId: 'stopping_$now',
    );
    _pendingHardStops[key] = pending;
    _messages.add(
      ChatMessage(
        id: pending.cardId,
        sender: MessageSender.system,
        type: MessageType.taskNotification,
        timestamp: DateTime.now(),
        textContent: 'Stopping — waiting for server confirmation…',
        toolName: 'stopping',
      ),
    );
    // Keep the session in a stopping state until abort_ack proves that the
    // backend and its owned work have terminated.
    _isProcessing = true;
    _isCompacting = false;
    notifyListeners();
    // Persist the cancellation intent before its first network send. If the
    // app process dies now, startup restores and retransmits the same request.
    await _persistPendingHardStops();
    if (!_pendingHardStops.containsValue(pending)) return;
    _transmitPendingAbort(pending);
  }

  String _hardStopKey(String serverId, String sessionId) =>
      '$serverId\u0001$sessionId';

  void _restorePendingHardStops(SharedPreferences prefs) {
    for (final persisted in decodePersistedHardStops(
      prefs.getString(_pendingHardStopsPrefsKey),
    )) {
      final pending = _PendingHardStop.fromPersisted(persisted);
      _pendingHardStops[_hardStopKey(pending.serverId, pending.sessionId)] =
          pending;
    }
  }

  Future<void> _persistPendingHardStops() {
    final snapshot = encodePersistedHardStops(
      _pendingHardStops.values.map((pending) => pending.toPersisted()),
    );
    _pendingHardStopPersistence = _pendingHardStopPersistence.then((_) async {
      final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
      _cachedPrefs = prefs;
      if (snapshot == '[]') {
        await prefs.remove(_pendingHardStopsPrefsKey);
      } else {
        await prefs.setString(_pendingHardStopsPrefsKey, snapshot);
      }
    });
    return _pendingHardStopPersistence;
  }

  bool _hasPendingHardStop(String? sessionId, {String? serverId}) {
    if (sessionId == null || sessionId.isEmpty) return false;
    return _pendingHardStops.values.any(
      (pending) =>
          pending.sessionId == sessionId &&
          (serverId == null ||
              serverId.isEmpty ||
              pending.serverId.isEmpty ||
              pending.serverId == serverId),
    );
  }

  _PendingHardStop? _pendingHardStopFor(String? sessionId, {String? serverId}) {
    if (sessionId == null || sessionId.isEmpty) return null;
    return _pendingHardStops.values
        .where(
          (pending) =>
              pending.sessionId == sessionId &&
              (serverId == null ||
                  serverId.isEmpty ||
                  pending.serverId.isEmpty ||
                  pending.serverId == serverId),
        )
        .firstOrNull;
  }

  void _ensurePendingHardStopCard(String? sessionId, {String? serverId}) {
    final pending = _pendingHardStopFor(sessionId, serverId: serverId);
    if (pending == null) return;
    _isProcessing = true;
    if (_messages.any((message) => message.id == pending.cardId)) return;
    _messages.add(
      ChatMessage(
        id: pending.cardId,
        sender: MessageSender.system,
        type: MessageType.taskNotification,
        timestamp: DateTime.now(),
        textContent: 'Stopping — waiting for server confirmation…',
        toolName: 'stopping',
      ),
    );
  }

  void _transmitPendingAbort(_PendingHardStop pending) {
    if (!_pendingHardStops.containsValue(pending)) return;
    final message = {
      'type': 'abort',
      'requestId': pending.requestId,
      'sessionId': pending.sessionId,
    };
    final sent = pending.serverId.isNotEmpty
        ? _connMgr.sendToServer(pending.serverId, message)
        : _connMgr.send(message);
    pending.attempts++;
    if (!sent && pending.serverId.isNotEmpty) {
      _connMgr.connectServer(pending.serverId);
    }
    pending.retryTimer?.cancel();
    final delay = hardStopRetryDelay(pending.attempts);
    pending.retryTimer = Timer(delay, () => _transmitPendingAbort(pending));
  }

  void _retryPendingAbortForServer(String serverId) {
    for (final pending
        in _pendingHardStops.values
            .where((pending) => pending.serverId == serverId)
            .toList()) {
      _transmitPendingAbort(pending);
    }
  }

  void _handleAbortAck(Map<String, dynamic> msg, String? serverId) {
    final requestId = msg['requestId'] as String?;
    final sessionId = msg['sessionId'] as String?;
    if (requestId == null || sessionId == null) return;
    final pending = _pendingHardStops.values
        .where(
          (candidate) => hardStopAckMatches(
            pendingRequestId: candidate.requestId,
            pendingSessionId: candidate.sessionId,
            pendingServerId: candidate.serverId,
            responseRequestId: requestId,
            responseSessionId: sessionId,
            responseServerId: serverId,
          ),
        )
        .firstOrNull;
    if (pending == null) return;
    if (msg['stopped'] != true) {
      final card = _messages
          .where((message) => message.id == pending.cardId)
          .firstOrNull;
      if (card != null) {
        card.textContent = 'Stop has not been confirmed; retrying…';
      }
      notifyListeners();
      return;
    }

    pending.retryTimer?.cancel();
    _pendingHardStops.remove(_hardStopKey(pending.serverId, pending.sessionId));
    unawaited(_persistPendingHardStops());
    _markSessionIdle(pending.sessionId, serverId: pending.serverId);
    final isVisible =
        (pending.sessionId == _activeSessionId ||
            pending.sessionId == _viewingSessionId) &&
        (pending.serverId.isEmpty ||
            _activeSessionServerId == null ||
            pending.serverId == _activeSessionServerId);
    if (isVisible) {
      _messages.removeWhere((message) => message.id == pending.cardId);
      _clearLiveMessageStreams();
      _isProcessing = false;
      _stopPromptRuntime();
      _isCompacting = false;
      settleIdleToolCards(_messages);
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
      _dropLegacyCancelPrepends();
    }
    notifyListeners();
  }

  void submitAuthCode(String code, {String? serverId, String? authRequestId}) {
    final msg = {
      'type': 'auth_code',
      'code': code,
      'sessionId': _activeSessionId,
      if (authRequestId != null && authRequestId.isNotEmpty)
        'authRequestId': authRequestId,
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
    _sendToActiveSessionServer({
      'type': 'answer',
      'questionId': questionId,
      'answers': answers,
    });
    notifyListeners();
  }

  void submitSecureInput(String requestId, String value) {
    if (requestId.isEmpty || value.isEmpty) return;
    final idx = _messages.indexWhere(
      (m) => m.type == MessageType.secureInput && m.questionId == requestId,
    );
    if (idx >= 0) _messages[idx].answered = true;
    _sendToActiveSessionServer({
      'type': 'secure_input_response',
      'requestId': requestId,
      'value': value,
      if (_activeSessionId != null) 'sessionId': _activeSessionId,
    });
    notifyListeners();
  }

  void cancelSecureInput(String requestId) {
    if (requestId.isEmpty) return;
    final idx = _messages.indexWhere(
      (m) => m.type == MessageType.secureInput && m.questionId == requestId,
    );
    if (idx >= 0) {
      _messages[idx].answered = true;
    }
    _sendToActiveSessionServer({
      'type': 'secure_input_response',
      'requestId': requestId,
      'cancelled': true,
      if (_activeSessionId != null) 'sessionId': _activeSessionId,
    });
    notifyListeners();
  }

  void submitStoredSecureInput(String requestId, SecretMetadata secret) {
    if (requestId.isEmpty || secret.secretId.isEmpty) return;
    final idx = _messages.indexWhere(
      (message) =>
          message.type == MessageType.secureInput &&
          message.questionId == requestId,
    );
    if (idx >= 0) {
      _messages[idx].answered = true;
      _messages[idx].toolInput?['status'] = 'saved';
    }
    _sendToActiveSessionServer({
      'type': 'secure_input_response',
      'requestId': requestId,
      'secretId': secret.secretId,
      if (_activeSessionId != null) 'sessionId': _activeSessionId,
    });
    notifyListeners();
  }

  void _resolveMatchingSecureInput(SecretMetadata secret) {
    String normalize(String value) =>
        value.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), '_');
    final secretLabel = normalize(secret.label);
    final secretEnv = normalize(secret.envHint);
    final pending = _messages.where((message) {
      if (message.type != MessageType.secureInput || message.answered) {
        return false;
      }
      final status = message.toolInput?['status'] as String? ?? 'pending';
      if (status != 'pending') return false;
      final label = normalize(message.toolInput?['label'] as String? ?? '');
      final envHint = normalize(message.toolInput?['envHint'] as String? ?? '');
      return (secretEnv.isNotEmpty && envHint == secretEnv) ||
          (secretLabel.isNotEmpty && label == secretLabel);
    }).firstOrNull;
    final requestId = pending?.questionId;
    if (requestId != null && requestId.isNotEmpty) {
      submitStoredSecureInput(requestId, secret);
    }
  }

  Future<SecretMetadata> storeSecureInput({
    required String label,
    required String value,
    String scope = 'session',
    String? envHint,
  }) async {
    if (label.trim().isEmpty || value.isEmpty) {
      throw ArgumentError('Label and secret value are required');
    }
    final requestId = 'secret_create_${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<SecretMetadata>();
    _secretWriteCompleters[requestId] = completer;
    _sendToActiveSessionServer({
      'type': 'secure_input_store',
      'label': label.trim(),
      'value': value,
      'scope': scope,
      'clientRequestId': requestId,
      if (envHint != null && envHint.trim().isNotEmpty)
        'envHint': envHint.trim(),
      if (_activeSessionId != null) 'sessionId': _activeSessionId,
      if (_activeSessionCwd != null) 'cwd': _activeSessionCwd,
    });
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _secretWriteCompleters.remove(requestId);
        throw TimeoutException('Timed out saving secret');
      },
    );
  }

  void refreshSecretInventory() {
    final serverId = _activeSessionServerId ?? _connMgr.activeServerId;
    _secretInventoryRequestTracker.cancel();
    if (serverId == null || serverId.isEmpty) {
      _secretInventoryLoading = false;
      _secretInventoryError = 'No server is selected for this session.';
      notifyListeners();
      return;
    }

    final serverName = _serverConfigs
        .where((config) => config.id == serverId)
        .map((config) => config.name.trim())
        .where((name) => name.isNotEmpty)
        .firstOrNull;
    final serverLabel = serverName ?? 'The selected server';
    if (_connMgr.statusOf(serverId) != ConnectionStatus.connected) {
      _secretInventoryLoading = false;
      _secretInventoryError =
          '$serverLabel is offline. Reconnect it, then tap Refresh.';
      notifyListeners();
      return;
    }

    if (_serverSecretManagementVersions[serverId] == 0) {
      _secretInventoryLoading = false;
      _secretInventoryError =
          '$serverLabel is running an older SocketAgent server that does not '
          'support managed secrets. Update that server, then tap Refresh.';
      notifyListeners();
      return;
    }

    final requestId =
        'secret_inventory_${DateTime.now().microsecondsSinceEpoch}';
    _secretInventoryLoading = true;
    _secretInventoryError = null;
    _secretInventoryRequestTracker.begin(
      requestId: requestId,
      serverId: serverId,
      sessionId: _activeSessionId,
      onTimeout: (timeout) {
        _secretInventoryLoading = false;
        _secretInventoryError =
            '$serverLabel did not answer the managed-secrets request. Its '
            'connection may have dropped; reconnect it and tap Refresh.';
        notifyListeners();
      },
    );
    _connMgr.sendToServer(serverId, {
      'type': 'secret_inventory_request',
      'requestId': requestId,
      if (_activeSessionId != null) 'sessionId': _activeSessionId,
      if (_activeSessionCwd != null) 'cwd': _activeSessionCwd,
    });
    notifyListeners();
  }

  Future<SecretMetadata> replaceManagedSecret({
    required SecretMetadata secret,
    required String value,
    String? label,
    String? envHint,
  }) {
    if (value.isEmpty) throw ArgumentError('Replacement value is required');
    final requestId = 'secret_replace_${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<SecretMetadata>();
    _secretWriteCompleters[requestId] = completer;
    _sendToActiveSessionServer({
      'type': 'secret_replace',
      'requestId': requestId,
      'secretId': secret.secretId,
      'value': value,
      if (label != null && label.trim().isNotEmpty) 'label': label.trim(),
      if (envHint != null && envHint.trim().isNotEmpty)
        'envHint': envHint.trim(),
      if (_activeSessionId != null) 'sessionId': _activeSessionId,
      if (_activeSessionCwd != null) 'cwd': _activeSessionCwd,
    });
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _secretWriteCompleters.remove(requestId);
        throw TimeoutException('Timed out replacing secret');
      },
    );
  }

  Future<void> deleteManagedSecret(SecretMetadata secret) {
    final requestId = 'secret_delete_${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<void>();
    _secretDeleteCompleters[requestId] = completer;
    _sendToActiveSessionServer({
      'type': 'secret_delete',
      'requestId': requestId,
      'secretId': secret.secretId,
      if (_activeSessionId != null) 'sessionId': _activeSessionId,
      if (_activeSessionCwd != null) 'cwd': _activeSessionCwd,
    });
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _secretDeleteCompleters.remove(requestId);
        throw TimeoutException('Timed out deleting secret');
      },
    );
  }

  void refreshHtmlPlans() {
    final serverId = _activeSessionServerId ?? _connMgr.activeServerId;
    final sessionId = _activeSessionId;
    _htmlPlanListTimeout?.cancel();
    if (serverId == null ||
        serverId.isEmpty ||
        sessionId == null ||
        sessionId.isEmpty) {
      _htmlPlansLoading = false;
      _htmlPlansError = 'Open a saved session to manage its HTML plans.';
      notifyListeners();
      return;
    }
    if (_connMgr.statusOf(serverId) != ConnectionStatus.connected) {
      _htmlPlansLoading = false;
      _htmlPlansError =
          'The selected server is offline. Reconnect it and try again.';
      notifyListeners();
      return;
    }
    final requestId = 'html_plans_${DateTime.now().microsecondsSinceEpoch}';
    _htmlPlanListRequestId = requestId;
    _htmlPlansLoading = true;
    _htmlPlansError = null;
    _connMgr.sendToServer(serverId, {
      'type': 'html_plan_list',
      'requestId': requestId,
      'sessionId': sessionId,
    });
    _htmlPlanListTimeout = Timer(const Duration(seconds: 15), () {
      if (_htmlPlanListRequestId != requestId) return;
      _htmlPlanListRequestId = null;
      _htmlPlansLoading = false;
      _htmlPlansError =
          'The server did not answer the HTML plan request. Reconnect it, or update that server if it is running an older SocketAgent version.';
      notifyListeners();
    });
    notifyListeners();
  }

  Future<HtmlPlan> renameHtmlPlan(HtmlPlan plan, String title) {
    final sessionId = _activeSessionId;
    if (sessionId == null || sessionId.isEmpty) {
      throw StateError('No active session');
    }
    final requestId =
        'html_plan_rename_${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<HtmlPlan>();
    _htmlPlanRenameCompleters[requestId] = completer;
    _sendToActiveSessionServer({
      'type': 'html_plan_rename',
      'requestId': requestId,
      'sessionId': sessionId,
      'planId': plan.planId,
      'title': title.trim(),
    });
    return completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _htmlPlanRenameCompleters.remove(requestId);
        throw TimeoutException('Timed out renaming HTML plan');
      },
    );
  }

  Future<void> deleteHtmlPlan(HtmlPlan plan) {
    final sessionId = _activeSessionId;
    if (sessionId == null || sessionId.isEmpty) {
      throw StateError('No active session');
    }
    final requestId =
        'html_plan_delete_${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<void>();
    _htmlPlanDeleteCompleters[requestId] = completer;
    _sendToActiveSessionServer({
      'type': 'html_plan_delete',
      'requestId': requestId,
      'sessionId': sessionId,
      'planId': plan.planId,
    });
    return completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _htmlPlanDeleteCompleters.remove(requestId);
        throw TimeoutException('Timed out deleting HTML plan');
      },
    );
  }

  Future<List<HtmlPlanRevisionSummary>> getHtmlPlanRevisions(HtmlPlan plan) {
    final sessionId = _activeSessionId;
    if (sessionId == null || sessionId.isEmpty) {
      throw StateError('No active session');
    }
    final requestId =
        'html_plan_revisions_${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<List<HtmlPlanRevisionSummary>>();
    _htmlPlanRevisionListCompleters[requestId] = completer;
    _sendToActiveSessionServer({
      'type': 'html_plan_revision_list',
      'requestId': requestId,
      'sessionId': sessionId,
      'planId': plan.planId,
    });
    return completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _htmlPlanRevisionListCompleters.remove(requestId);
        throw TimeoutException('Timed out loading HTML plan revisions');
      },
    );
  }

  Future<HtmlPlanRevisionDetail> getHtmlPlanRevision(
    HtmlPlan plan,
    int revision, {
    int? baseRevision,
  }) {
    final sessionId = _activeSessionId;
    if (sessionId == null || sessionId.isEmpty) {
      throw StateError('No active session');
    }
    final requestId =
        'html_plan_revision_${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<HtmlPlanRevisionDetail>();
    _htmlPlanRevisionDetailCompleters[requestId] = completer;
    _sendToActiveSessionServer({
      'type': 'html_plan_revision_get',
      'requestId': requestId,
      'sessionId': sessionId,
      'planId': plan.planId,
      'revision': revision,
      if (baseRevision != null) 'baseRevision': baseRevision,
    });
    return completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _htmlPlanRevisionDetailCompleters.remove(requestId);
        throw TimeoutException('Timed out loading HTML plan revision');
      },
    );
  }

  Future<HtmlPlan> rollbackHtmlPlan(HtmlPlan plan, int revision) {
    final sessionId = _activeSessionId;
    if (sessionId == null || sessionId.isEmpty) {
      throw StateError('No active session');
    }
    final requestId =
        'html_plan_rollback_${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<HtmlPlan>();
    _htmlPlanRollbackCompleters[requestId] = completer;
    _sendToActiveSessionServer({
      'type': 'html_plan_rollback',
      'requestId': requestId,
      'sessionId': sessionId,
      'planId': plan.planId,
      'revision': revision,
    });
    return completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _htmlPlanRollbackCompleters.remove(requestId);
        throw TimeoutException('Timed out rolling back HTML plan');
      },
    );
  }

  /// Clear file attachment state (without notifyListeners)
  void _clearAttachment() {
    _secretInventoryRequestTracker.cancel();
    for (final secret in _pendingSecretAttachments) {
      secret.clearValue();
    }
    _pendingFileAttachments.clear();
    _pendingSecretAttachments.clear();
    _uploadProgress = null;
    _pendingUploadId = null;
    _uploadCompleter = null;
    _secretInventory = [];
    _secretInventoryLoading = false;
    _secretInventoryError = null;
    _htmlPlanListTimeout?.cancel();
    _htmlPlanListTimeout = null;
    _htmlPlanListRequestId = null;
    _htmlPlans = [];
    _htmlPlansLoading = false;
    _htmlPlansError = null;
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
    _pendingInjectedMessageCount = 0;
    _pendingLocalUserMessageIds.clear();
    _pendingCacheUserPromptContent.clear();
    _todos = [];
    _lastUsage = null;
    _activeSessionId = null;
    _activeSessionServerId = null;
    final effectiveBackend = backend ?? preferredBackendForServer(serverId);
    _activeSessionBackend = effectiveBackend;
    _codexFastMode = false;
    _claudeAutoCompactEnabled = true;
    _effort = 'high';
    _thinking = {'type': 'adaptive'};
    _codexCollaborationMode = 'default';
    _clearLiveMessageStreams();
    _isProcessing = false;
    _processingSetAt = null;
    _stopPromptRuntime();
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
    _toolEventReconciler.clear();
    _clearAttachment();
    _clearRawState();
    // Set active server to the target server
    if (serverId != null) {
      _connMgr.activeServerId = serverId;
    } else if (_connMgr.activeServerId == null && _serverConfigs.isNotEmpty) {
      _connMgr.activeServerId = _serverConfigs.first.id;
    }
    _activeSessionServerId = serverId ?? _connMgr.activeServerId;
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

  /// Backends the given server supports, ordered by UI preference. Defaults to ['claude'] when the
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

  String _backendInstallKey(String serverId, String backend) =>
      '$serverId::$backend';

  BackendInstallState? backendInstallState(String serverId, String backend) {
    return _backendInstallStates[_backendInstallKey(serverId, backend)];
  }

  void _runBackendOperation(
    String serverId, {
    String backend = 'codex',
    required bool reinstall,
    required bool authenticate,
    required String operation,
    bool forceAuthenticate = false,
  }) {
    if (_connMgr.statusOf(serverId) != ConnectionStatus.connected) return;
    final key = _backendInstallKey(serverId, backend);
    final requestId =
        'backend_${operation}_${backend}_${DateTime.now().millisecondsSinceEpoch}';
    final backendName = backend == 'codex'
        ? 'Codex'
        : backend == 'claude'
        ? 'Claude'
        : 'Backend';
    final operationName = operation == 'auth' ? 'sign-in' : 'repair';
    _backendInstallAckTimers.remove(key)?.cancel();
    _backendInstallStates[key] = BackendInstallState(
      backend: backend,
      requestId: requestId,
      operation: operation,
      phase: operation == 'auth' ? 'auth' : 'install',
      message: 'Starting $backendName $operationName...',
    );
    _connMgr.sendToServer(serverId, {
      'type': 'backend_install',
      'backend': backend,
      'reinstall': reinstall,
      'authenticate': authenticate,
      if (forceAuthenticate) 'forceAuthenticate': true,
      'operation': operation,
      'requestId': requestId,
    });
    _backendInstallAckTimers[key] = Timer(const Duration(seconds: 15), () {
      _backendInstallAckTimers.remove(key);
      final state = _backendInstallStates[key];
      if (state == null || !state.running) return;
      _backendInstallStates[key] = BackendInstallState(
        backend: backend,
        requestId: requestId,
        operation: operation,
        phase: operation == 'auth' ? 'auth' : 'install',
        status: 'failed',
        running: false,
        message:
            'Server did not acknowledge the $operationName request. It may be running an older SocketAgent build or the server process may be wedged. Run Check for Updates / Update Now, then try again.',
      );
      notifyListeners();
    });
    notifyListeners();
  }

  void repairBackend(
    String serverId, {
    String backend = 'codex',
    bool reinstall = true,
  }) {
    _runBackendOperation(
      serverId,
      backend: backend,
      reinstall: reinstall,
      authenticate: false,
      operation: 'repair',
    );
  }

  void authenticateBackend(
    String serverId, {
    String backend = 'codex',
    bool force = false,
  }) {
    _runBackendOperation(
      serverId,
      backend: backend,
      reinstall: false,
      authenticate: true,
      operation: 'auth',
      forceAuthenticate: force,
    );
  }

  void cancelBackendOperation(
    String serverId, {
    String backend = 'codex',
    bool force = false,
  }) {
    final key = _backendInstallKey(serverId, backend);
    final state = _backendInstallStates[key];
    if (state == null || (!state.running && !force)) return;
    _connMgr.sendToServer(serverId, {
      'type': 'backend_install_cancel',
      'backend': backend,
      if (!force) 'requestId': state.requestId,
    });
    state.message = 'Stopping backend operation...';
    state.status = 'running';
    state.running = true;
    notifyListeners();
  }

  void _handleBackendInstallProgress(
    Map<String, dynamic> msg,
    String? serverId,
  ) {
    if (serverId == null || serverId.isEmpty) return;
    final backend = msg['backend'] as String? ?? 'codex';
    final key = _backendInstallKey(serverId, backend);
    _backendInstallAckTimers.remove(key)?.cancel();
    final state =
        _backendInstallStates[key] ??
        BackendInstallState(
          backend: backend,
          requestId:
              msg['requestId'] as String? ??
              'backend_${DateTime.now().millisecondsSinceEpoch}',
          operation: msg['operation'] as String? ?? 'repair',
        );
    state.apply(msg);
    _backendInstallStates[key] = state;

    if (!state.running) {
      _backendInstallAckTimers.remove(key)?.cancel();
      requestServerSettings(serverId: serverId);
      _connMgr.sendToServer(serverId, {'type': 'list_sessions'});
    }
    notifyListeners();
  }

  void _handleBackendAuthRequired(Map<String, dynamic> msg, String? serverId) {
    if (serverId == null || serverId.isEmpty) return;
    final backend = msg['backend'] as String? ?? 'codex';
    final backendName = backend == 'codex' ? 'Codex' : 'Backend';
    final message =
        msg['message'] as String? ??
        '$backendName authentication is invalid or expired.';
    final detail = msg['detail'] as String?;

    final existingHealth = List<Map<String, dynamic>>.from(
      _serverBackendHealth[serverId] ?? const <Map<String, dynamic>>[],
    );
    final healthEntry = <String, dynamic>{
      'backend': backend,
      'enabled': true,
      'available': false,
      'severity': 'error',
      'reason': '$backendName authentication is invalid or expired.',
      if (detail != null && detail.isNotEmpty) 'detail': detail,
    };
    final idx = existingHealth.indexWhere(
      (entry) => entry['backend']?.toString() == backend,
    );
    if (idx >= 0) {
      existingHealth[idx] = {...existingHealth[idx], ...healthEntry};
    } else {
      existingHealth.add(healthEntry);
    }
    _serverBackendHealth[serverId] = existingHealth;

    final key = _backendInstallKey(serverId, backend);
    final state = _backendInstallStates[key];
    if (state?.running != true && backend == 'codex') {
      authenticateBackend(serverId, backend: backend);
    }

    _messages.add(
      ChatMessage.error(
        '$message I started Codex sign-in for this server. Open Settings > Servers > Backend Status to enter the device code.',
      ),
    );
    _isProcessing = false;
    _stopPromptRuntime();
    _backendAuthRequiredController.add({
      'serverId': serverId,
      'backend': backend,
      'message': message,
    });
    requestServerSettings(serverId: serverId);
    notifyListeners();
  }

  void _handleTerminalMessage(Map<String, dynamic> msg, String? serverId) {
    if (_terminalServerId != null &&
        serverId != null &&
        serverId != _terminalServerId) {
      return;
    }

    final enriched = <String, dynamic>{
      ...msg,
      if (serverId != null) '_serverId': serverId,
    };
    _terminalServerId ??= serverId;

    switch (msg['type']) {
      case 'terminal_status':
        _terminalStatus = enriched;
        break;
      case 'terminal_exited':
        _terminalStatus = {
          ...?_terminalStatus,
          'running': false,
          'exitCode': msg['exitCode'],
          if (msg['signal'] != null) 'signal': msg['signal'],
          if (serverId != null) '_serverId': serverId,
        };
        break;
      case 'terminal_error':
        _terminalStatus = {
          ...?_terminalStatus,
          'error': msg['message'],
          if (serverId != null) '_serverId': serverId,
        };
        break;
    }

    _terminalEvents.add(enriched);
    notifyListeners();
  }

  void _handleAdbBridgeSidecarStatus(Map<String, dynamic> msg) {
    final requestId = msg['requestId'] as String?;
    if (requestId == null || requestId.isEmpty) return;
    final completer = _adbBridgeSidecarCompleters.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(Map<String, dynamic>.from(msg));
    }
  }

  void _handleAdbCommandResult(Map<String, dynamic> msg) {
    final requestId = msg['requestId'] as String?;
    if (requestId == null || requestId.isEmpty) return;
    final completer = _adbCommandCompleters.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(Map<String, dynamic>.from(msg));
    }
  }

  void _handlePhoneAdbRequest(Map<String, dynamic> msg, String? serverId) {
    final requestId = msg['requestId'] as String?;
    if (requestId == null || requestId.isEmpty || serverId == null) return;
    unawaited(() async {
      Map<String, dynamic> result;
      try {
        final command = msg['command'] as String? ?? 'devices';
        switch (command) {
          case 'pair':
            result = await AdbBridgeService.instance.localAdbPair(
              port: _phoneAdbRequestPort(msg, 'pairPort'),
              code: msg['code']?.toString() ?? '',
            );
            break;
          case 'connect':
            result = await AdbBridgeService.instance.localAdbConnect(
              port: _phoneAdbRequestPort(msg, 'connectPort'),
            );
            break;
          case 'shell':
            result = await AdbBridgeService.instance.localAdbShell(
              msg['shellCommand'] as String? ?? '',
            );
            break;
          case 'adb':
          case 'command':
            result = await AdbBridgeService.instance.localAdbCommand(
              _phoneAdbStringList(msg['args']),
              timeoutSeconds: _phoneAdbInt(msg, 'timeoutSeconds', 30),
            );
            break;
          case 'install':
            final apkPath = await _receivePhoneAdbInstallFile(requestId, msg);
            try {
              result = await AdbBridgeService.instance.localAdbInstall(
                apkPath,
                args: _phoneAdbStringList(msg['args']),
              );
            } finally {
              unawaited(() async {
                try {
                  await File(apkPath).delete();
                } catch (_) {}
              }());
            }
            break;
          case 'open_apk':
          case 'open-apk':
          case 'stage_apk':
          case 'stage-apk':
            final apkPath = await _receivePhoneAdbInstallFile(requestId, msg);
            result = await _openPhoneAdbApkInstaller(apkPath);
            break;
          case 'logcat':
            result = await AdbBridgeService.instance.localAdbStream(
              streamId: requestId,
              args: <String>['logcat', ..._phoneAdbStringList(msg['args'])],
              timeoutSeconds: _phoneAdbInt(msg, 'timeoutSeconds', 30),
              maxBytes: _phoneAdbInt(msg, 'maxBytes', 1024 * 1024),
              onEvent: (event) {
                if (event['event'] != 'chunk') return;
                _connMgr.sendToServer(serverId, {
                  'type': 'phone_adb_stream_chunk',
                  'requestId': requestId,
                  'stream': event['stream']?.toString() ?? 'stdout',
                  'data': event['data']?.toString() ?? '',
                });
              },
            );
            break;
          case 'devices':
          default:
            result = await AdbBridgeService.instance.localAdbDevices();
            break;
        }
      } catch (e) {
        result = <String, dynamic>{
          'ok': false,
          'command': msg['command'] as String? ?? 'adb',
          'stdout': '',
          'stderr': '',
          'message': e.toString(),
        };
      }
      _connMgr.sendToServer(serverId, {
        'type': 'phone_adb_result',
        'requestId': requestId,
        'result': result,
      });
    }());
  }

  List<String> _phoneAdbStringList(Object? raw) {
    if (raw is! List) return <String>[];
    return raw
        .map((value) => value?.toString() ?? '')
        .where((value) => value.trim().isNotEmpty)
        .toList(growable: false);
  }

  int _phoneAdbInt(Map<String, dynamic> msg, String key, int fallback) {
    final raw = msg[key];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? fallback;
    return fallback;
  }

  int _phoneAdbRequestPort(Map<String, dynamic> msg, String key) {
    final direct = _phoneAdbInt(msg, key, 0);
    if (direct > 0) return direct;
    final args = _phoneAdbStringList(msg['args']);
    if (args.isNotEmpty) {
      final raw = args.first.contains(':')
          ? args.first.split(':').last
          : args.first;
      final parsed = int.tryParse(raw);
      if (parsed != null && parsed > 0) return parsed;
    }
    throw StateError('ADB port is required.');
  }

  Future<String> _receivePhoneAdbInstallFile(
    String requestId,
    Map<String, dynamic> msg,
  ) {
    final rawName = msg['fileName']?.toString().trim();
    final safeName =
        (rawName == null || rawName.isEmpty ? 'install.apk' : rawName)
            .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final expectedSize = _phoneAdbInt(msg, 'fileSize', 0);
    final tempDir = Directory('${Directory.systemTemp.path}/socketagent_adb');
    if (!tempDir.existsSync()) {
      tempDir.createSync(recursive: true);
    }
    final file = File('${tempDir.path}/${requestId}_$safeName');
    if (file.existsSync()) {
      file.deleteSync();
    }
    final transfer = _PhoneAdbFileTransfer(
      path: file.path,
      sink: file.openWrite(),
      completer: Completer<String>(),
      expectedSize: expectedSize,
    );
    _phoneAdbFileTransfers[requestId] = transfer;
    return transfer.completer.future.timeout(
      const Duration(minutes: 10),
      onTimeout: () {
        _failPhoneAdbTransfer(
          requestId,
          'Timed out receiving APK from server.',
        );
        throw TimeoutException('Timed out receiving APK from server.');
      },
    );
  }

  Future<Map<String, dynamic>> _openPhoneAdbApkInstaller(String apkPath) async {
    final result = await OpenFilex.open(
      apkPath,
      type: 'application/vnd.android.package-archive',
    );
    final ok = result.type == ResultType.done;
    return <String, dynamic>{
      'ok': ok,
      'command': 'open-apk',
      'endpoint': apkPath,
      'exitCode': null,
      'stdout': '',
      'stderr': '',
      'message': ok
          ? 'Android package installer opened.'
          : 'Could not open Android package installer: ${result.message}',
    };
  }

  void _handlePhoneAdbFileChunk(Map<String, dynamic> msg) {
    final requestId = msg['requestId'] as String?;
    if (requestId == null || requestId.isEmpty) return;
    final transfer = _phoneAdbFileTransfers[requestId];
    if (transfer == null) return;
    try {
      final data = msg['data'] as String? ?? '';
      final bytes = base64Decode(data);
      transfer.sink.add(bytes);
      transfer.receivedBytes += bytes.length;
    } catch (e) {
      _failPhoneAdbTransfer(requestId, 'Failed to decode APK chunk: $e');
    }
  }

  void _handlePhoneAdbFileEnd(Map<String, dynamic> msg) {
    final requestId = msg['requestId'] as String?;
    if (requestId == null || requestId.isEmpty) return;
    final transfer = _phoneAdbFileTransfers.remove(requestId);
    if (transfer == null) return;
    unawaited(() async {
      try {
        await transfer.sink.flush();
        await transfer.sink.close();
        if (msg['ok'] == false) {
          throw StateError(
            msg['message']?.toString() ?? 'APK transfer failed.',
          );
        }
        if (transfer.expectedSize > 0 &&
            transfer.receivedBytes != transfer.expectedSize) {
          throw StateError(
            'APK transfer size mismatch: received ${transfer.receivedBytes} of ${transfer.expectedSize} bytes.',
          );
        }
        if (!transfer.completer.isCompleted) {
          transfer.completer.complete(transfer.path);
        }
      } catch (e) {
        unawaited(() async {
          try {
            await File(transfer.path).delete();
          } catch (_) {}
        }());
        if (!transfer.completer.isCompleted) {
          transfer.completer.completeError(e);
        }
      }
    }());
  }

  void _handlePhoneAdbCancel(Map<String, dynamic> msg) {
    final requestId = msg['requestId'] as String?;
    if (requestId == null || requestId.isEmpty) return;
    unawaited(AdbBridgeService.instance.localAdbStopStream(requestId));
    _failPhoneAdbTransfer(requestId, 'Phone ADB request was cancelled.');
  }

  void _failPhoneAdbTransfer(String requestId, String message) {
    final transfer = _phoneAdbFileTransfers.remove(requestId);
    if (transfer == null) return;
    unawaited(() async {
      try {
        await transfer.sink.close();
      } catch (_) {}
      try {
        await File(transfer.path).delete();
      } catch (_) {}
    }());
    if (!transfer.completer.isCompleted) {
      transfer.completer.completeError(StateError(message));
    }
  }

  void _captureServerRuntimeInfo(Map<String, dynamic> msg, String serverId) {
    final existing = Map<String, dynamic>.from(
      _serverRuntimeInfo[serverId] ?? const <String, dynamic>{},
    );

    final running = msg['running'];
    if (running is Map) {
      existing.addAll(Map<String, dynamic>.from(running));
    }

    final version = msg['serverVersion'];
    if (version != null) existing['hash'] = version.toString();

    final startedAt = msg['serverStartedAt'];
    if (startedAt != null) existing['startedAt'] = startedAt.toString();

    final pid = msg['serverPid'];
    if (pid != null) existing['pid'] = pid;

    if (existing.isNotEmpty) {
      _serverRuntimeInfo[serverId] = existing;
    }
  }

  Map<String, dynamic> _attachServerRuntimeInfo(
    Map<String, dynamic> info,
    String? serverId,
  ) {
    if (serverId == null) return info;
    final runtime = _serverRuntimeInfo[serverId];
    if (runtime == null || runtime.isEmpty) return info;

    final mergedRuntime = Map<String, dynamic>.from(runtime);
    final returnedRuntime = info['running'];
    if (returnedRuntime is Map) {
      mergedRuntime.addAll(Map<String, dynamic>.from(returnedRuntime));
    }

    return {...info, 'running': mergedRuntime};
  }

  String preferredBackendForServer(String? serverId) {
    final backends = backendsForServer(serverId);
    final effectiveServerId =
        serverId ?? _connMgr.activeServerId ?? _serverConfigs.firstOrNull?.id;
    if (effectiveServerId == null) return backends.firstOrNull ?? 'claude';

    final health = _serverBackendHealth[effectiveServerId];
    if (health == null || health.isEmpty) {
      return backends.firstOrNull ?? 'claude';
    }

    bool isUsable(String backend) {
      final entry = health
          .where((item) => item['backend']?.toString() == backend)
          .firstOrNull;
      if (entry == null) return true;
      return entry['available'] == true &&
          entry['severity']?.toString() != 'error' &&
          entry['severity']?.toString() != 'disabled';
    }

    return backends.firstWhere(
      isUsable,
      orElse: () => backends.firstOrNull ?? 'claude',
    );
  }

  void _captureCodexDriverSettings(Map<String, dynamic> msg, String serverId) {
    final defaultCwd = msg['defaultCwd'] as String?;
    if (defaultCwd != null && defaultCwd.isNotEmpty) {
      final idx = _serverConfigs.indexWhere((config) => config.id == serverId);
      if (idx >= 0 && _serverConfigs[idx].defaultCwd != defaultCwd) {
        _serverConfigs[idx] = _serverConfigs[idx].copyWith(
          defaultCwd: defaultCwd,
        );
        unawaited(_saveServerConfigs());
      }
    }

    final systemPrompt = msg['systemPrompt'] as String?;
    if (systemPrompt != null) {
      final idx = _serverConfigs.indexWhere((config) => config.id == serverId);
      if (idx >= 0 && _serverConfigs[idx].systemPrompt != systemPrompt) {
        _serverConfigs[idx] = _serverConfigs[idx].copyWith(
          systemPrompt: systemPrompt,
        );
        unawaited(_saveServerConfigs());
      }
    }

    final rawModes = msg['codexCollaborationModes'];
    if (rawModes is List) {
      _serverCodexCollaborationModes[serverId] = rawModes
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    }

    final rawHealth = msg['backendHealth'];
    if (rawHealth is List) {
      final health = rawHealth
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      _serverBackendHealth[serverId] = health;

      for (final entry in health) {
        final backend = entry['backend']?.toString();
        final severity = entry['severity']?.toString();
        if (backend == null || backend.isEmpty || severity != 'ok') continue;

        final key = _backendInstallKey(serverId, backend);
        final state = _backendInstallStates[key];
        if (state == null) continue;
        if (state.operation == 'auth' && state.running) continue;

        _backendInstallAckTimers.remove(key)?.cancel();
        state.phase = 'probe';
        state.status = 'completed';
        state.running = false;
        state.message = backend == 'codex'
            ? 'Codex backend is available.'
            : 'Backend is available.';
        state.authUrl = null;
        state.authCode = null;
      }
    }
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

  void _requestActiveCodexMetadata() {
    if (_activeSessionBackend != 'codex') return;
    requestActiveSkills();
    requestCodexCollaborationModes();
  }

  void _sendServerSettings(
    String serverId, {
    String? defaultCwd,
    String? systemPrompt,
  }) {
    final msg = <String, dynamic>{
      'type': 'set_server_settings',
      if (defaultCwd != null) 'defaultCwd': defaultCwd,
      if (systemPrompt != null) 'systemPrompt': systemPrompt,
    };
    if (_connMgr.statusOf(serverId) == ConnectionStatus.connected) {
      _connMgr.sendToServer(serverId, msg);
      return;
    }
    Future.delayed(const Duration(seconds: 2), () {
      if (_connMgr.statusOf(serverId) == ConnectionStatus.connected) {
        _connMgr.sendToServer(serverId, msg);
      }
    });
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

  Future<Map<String, dynamic>?> requestCodexStatus() {
    _pendingCodexStatus?.complete(null);
    final completer = Completer<Map<String, dynamic>?>();
    _pendingCodexStatus = completer;
    _connMgr.send({'type': 'get_codex_status'});
    return completer.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () {
        if (_pendingCodexStatus == completer) {
          _pendingCodexStatus = null;
        }
        return null;
      },
    );
  }

  void setCodexCollaborationMode(String mode) {
    _codexCollaborationMode = mode;
    final serverId = _connMgr.activeServerId;
    if (serverId != null) {
      _connMgr.sendToServer(serverId, {
        'type': 'set_codex_collaboration_mode',
        'mode': mode,
      });
    } else {
      _connMgr.send({'type': 'set_codex_collaboration_mode', 'mode': mode});
    }
    notifyListeners();
  }

  String? get activeSessionBackend => _activeSessionBackend;

  void resumeSession(String sessionId, {String? serverId}) {
    _messages = [];
    _pendingInjectedMessageCount = 0;
    _pendingLocalUserMessageIds.clear();
    _pendingCacheUserPromptContent.clear();
    _todos = [];
    _lastUsage = null;
    _activeSessionId = sessionId;
    _activeSessionServerId = serverId;
    _effort = 'high';
    _thinking = {'type': 'adaptive'};
    _codexFastMode = false;
    _claudeAutoCompactEnabled = true;
    _codexCollaborationMode = 'default';
    _loadPrepends();
    _clearLiveMessageStreams();
    _isProcessing = false;
    _processingSetAt = null;
    _stopPromptRuntime();
    _permissionMode = null;
    _isCompacting = false;
    _isLoadingHistory = true;
    _isRefreshingHistory = false;
    _historyOffset = 0;
    _isLoadingMore = false;
    _autoBackfillRecentPrompts = false;
    _historyBackfillTargetUserPrompts = 1;
    final historyRequestId = _beginInitialHistoryRequest(sessionId);
    _sessionModel = null;
    _supportedModels = [];
    _mcpServers = [];
    _subagentTasks.clear();
    _backgroundTasks.clear();
    _promptSuggestions = [];
    _contextUsage = null;
    _requiresAction = false;
    _pendingImageLoads.clear();
    _toolEventReconciler.clear();
    _clearAttachment();
    _clearRawState();
    // Look up which server owns this session and switch active server
    final session =
        _sessions
            .where(
              (s) =>
                  s.id == sessionId &&
                  (serverId == null ||
                      serverId.isEmpty ||
                      s.serverId == serverId),
            )
            .firstOrNull ??
        _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (session != null) {
      _activeSessionTitle = session.title;
      _activeSessionCwd = session.cwd;
      _activeSessionBackend = session.backend;
      _activeSessionServerId = session.serverId.isNotEmpty
          ? session.serverId
          : serverId ?? _connMgr.activeServerId;
    } else {
      _activeSessionBackend = null; // legacy session without backend tag
      _activeSessionServerId = serverId ?? _connMgr.activeServerId;
    }
    final targetServerId = session?.serverId.isNotEmpty == true
        ? session!.serverId
        : serverId;
    final resolvedServerId = targetServerId ?? _connMgr.activeServerId ?? '';
    final cachedSnapshot = resolvedServerId.isEmpty
        ? null
        : _transcriptCache.peek(resolvedServerId, sessionId);
    final checkpoint = _transcriptCache.resumeCheckpoint(cachedSnapshot);
    if (cachedSnapshot != null) {
      _handleSessionHistory(
        cachedSnapshot,
        serverId: resolvedServerId,
        fromCache: true,
      );
    } else if (resolvedServerId.isNotEmpty) {
      unawaited(
        _loadTranscriptCacheAfterOpen(
          resolvedServerId,
          sessionId,
          historyRequestId,
        ),
      );
    }
    _ensurePendingHardStopCard(sessionId, serverId: resolvedServerId);
    if (targetServerId != null && targetServerId.isNotEmpty) {
      _activeSessionServerId = targetServerId;
      _connMgr.activeServerId = targetServerId;
      _connMgr.sendToServer(targetServerId, {
        'type': 'resume_session',
        'sessionId': sessionId,
        if (session != null) 'cwd': session.cwd,
        if (session?.backend != null) 'backend': session!.backend,
        'historyRequestId': historyRequestId,
        'openTraceId': historyRequestId,
        if (checkpoint != null) ...{
          'knownSessionSeq': checkpoint.latestSessionSeq,
          'knownHistoryOffset': checkpoint.historyOffset,
          'knownHistoryEntryCount': checkpoint.entryCount,
        },
      });
      _connMgr.sendToServer(targetServerId, {'type': 'get_status_sync'});
    } else {
      if (session != null) {
        _connMgr.send({
          'type': 'resume_session',
          'sessionId': sessionId,
          'cwd': session.cwd,
          if (session.backend != null) 'backend': session.backend,
          'historyRequestId': historyRequestId,
          'openTraceId': historyRequestId,
          if (checkpoint != null) ...{
            'knownSessionSeq': checkpoint.latestSessionSeq,
            'knownHistoryOffset': checkpoint.historyOffset,
            'knownHistoryEntryCount': checkpoint.entryCount,
          },
        });
      } else {
        _connMgr.send({
          'type': 'resume_session',
          'sessionId': sessionId,
          'historyRequestId': historyRequestId,
          'openTraceId': historyRequestId,
          if (checkpoint != null) ...{
            'knownSessionSeq': checkpoint.latestSessionSeq,
            'knownHistoryOffset': checkpoint.historyOffset,
            'knownHistoryEntryCount': checkpoint.entryCount,
          },
        });
      }
      _connMgr.send({'type': 'get_status_sync'});
    }

    notifyListeners();
  }

  Future<void> _loadTranscriptCacheAfterOpen(
    String serverId,
    String sessionId,
    String historyRequestId,
  ) async {
    final snapshot = await _transcriptCache.load(serverId, sessionId);
    if (snapshot == null ||
        _activeSessionId != sessionId ||
        _activeSessionServerId != serverId ||
        _initialHistoryRequestId != historyRequestId ||
        _messages.isNotEmpty) {
      return;
    }
    _handleSessionHistory(snapshot, serverId: serverId, fromCache: true);
  }

  void resumeSessionFromNotification(String sessionId, {String? serverId}) {
    if (serverId != null && serverId.isNotEmpty) {
      _connMgr.activeServerId = serverId;
    }
    resumeSession(sessionId, serverId: serverId);
  }

  void loadMoreHistory() {
    if (_isLoadingMore || _historyOffset <= 0 || _activeSessionId == null) {
      return;
    }
    _isLoadingMore = true;
    final limit = 50;
    final newOffset = (_historyOffset - limit).clamp(0, _historyOffset);
    final sessionId = _activeSessionId!;
    final requestId = _newHistoryRequestId('older', sessionId);
    _olderHistoryRequestId = requestId;
    final message = <String, dynamic>{
      'type': 'load_more_history',
      'sessionId': sessionId,
      'offset': newOffset,
      'limit': _historyOffset - newOffset,
      'requestId': requestId,
    };
    final serverId = _activeSessionServerId ?? _connMgr.activeServerId;
    if (serverId != null && serverId.isNotEmpty) {
      _connMgr.sendToServer(serverId, message);
    } else {
      _connMgr.send(message);
    }
    notifyListeners();
  }

  String _newHistoryRequestId(String kind, String sessionId) {
    _historyRequestSequence++;
    return 'history_${kind}_${DateTime.now().microsecondsSinceEpoch}_${_historyRequestSequence}_$sessionId';
  }

  String _beginInitialHistoryRequest(String sessionId) {
    final previousRequestId = _initialHistoryRequestId;
    if (previousRequestId != null) {
      _historyOpenTraceStartedAt.remove(previousRequestId);
    }
    final requestId = _newHistoryRequestId('initial', sessionId);
    _historyOpenTraceStartedAt[requestId] = DateTime.now();
    _initialHistoryRequestId = requestId;
    _olderHistoryRequestId = null;
    _initialHistoryTimeout?.cancel();
    _initialHistoryTimeout = Timer(const Duration(seconds: 10), () {
      if (_initialHistoryRequestId != requestId ||
          _activeSessionId != sessionId) {
        return;
      }
      if (_isRefreshingHistory && !_isLoadingHistory) {
        _initialHistoryRequestId = null;
        _isRefreshingHistory = false;
        _historyOpenTraceStartedAt.remove(requestId);
        notifyListeners();
        return;
      }
      if (!_isLoadingHistory) {
        _initialHistoryRequestId = null;
        _historyOpenTraceStartedAt.remove(requestId);
        return;
      }
      _isLoadingHistory = false;
      _historyOpenTraceStartedAt.remove(requestId);
      _messages.add(
        ChatMessage.error(
          'Timed out loading this session from its server. Check the server connection and try again.',
        ),
      );
      notifyListeners();
    });
    return requestId;
  }

  /// Check if a path exists on the server. Returns true if it exists.
  Future<bool> checkCwd(String path, {String? serverId}) async {
    final completer = Completer<Map<String, dynamic>>();
    final requestId = 'cwd_${DateTime.now().microsecondsSinceEpoch}';
    _pendingCwdCheck = completer;
    _pendingCwdCheckRequestId = requestId;
    _pendingCwdCheckServerId = serverId;
    final msg = {'type': 'check_cwd', 'path': path, 'requestId': requestId};
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _ws.send(msg);
    }
    final result = await completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        if (_pendingCwdCheck == completer) {
          _pendingCwdCheck = null;
          _pendingCwdCheckRequestId = null;
          _pendingCwdCheckServerId = null;
        }
        final timeout = <String, dynamic>{
          'type': 'cwd_check',
          'path': path,
          'exists': false,
          'isDirectory': false,
          'serverId': serverId,
          'error': 'Timed out waiting for server',
        };
        _lastCwdCheck = timeout;
        return timeout;
      },
    );
    return result['exists'] == true && result['isDirectory'] != false;
  }

  /// Ask the server to create a directory. Returns true if successful.
  Future<bool> createCwd(String path, {String? serverId}) async {
    final completer = Completer<Map<String, dynamic>>();
    final requestId = 'cwd_${DateTime.now().microsecondsSinceEpoch}';
    _pendingCwdCheck = completer;
    _pendingCwdCheckRequestId = requestId;
    _pendingCwdCheckServerId = serverId;
    final msg = {'type': 'create_cwd', 'path': path, 'requestId': requestId};
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _ws.send(msg);
    }
    final result = await completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        if (_pendingCwdCheck == completer) {
          _pendingCwdCheck = null;
          _pendingCwdCheckRequestId = null;
          _pendingCwdCheckServerId = null;
        }
        final timeout = <String, dynamic>{
          'type': 'cwd_check',
          'path': path,
          'exists': false,
          'isDirectory': false,
          'serverId': serverId,
          'error': 'Timed out waiting for server',
        };
        _lastCwdCheck = timeout;
        return timeout;
      },
    );
    return result['exists'] == true && result['isDirectory'] != false;
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

  Future<FileManagerListing> listFileManagerDirectory(
    String dirPath, {
    String? serverId,
    bool includeHidden = false,
  }) {
    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
    final completer = Completer<FileManagerListing>();
    _fileManagerListCompleters[requestId] = completer;
    final msg = {
      'type': 'file_manager_list',
      'requestId': requestId,
      'path': dirPath,
      'includeHidden': includeHidden,
    };
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _ws.send(msg);
    }
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _fileManagerListCompleters.remove(requestId);
        throw TimeoutException('Timed out listing files');
      },
    );
  }

  Future<Map<String, dynamic>> setFileManagerProtected({
    required String path,
    required bool protected,
    String? serverId,
    String? label,
    String pattern = 'exact',
  }) {
    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
    final completer = Completer<Map<String, dynamic>>();
    _fileManagerProtectedCompleters[requestId] = completer;
    final msg = {
      'type': 'file_manager_set_protected',
      'requestId': requestId,
      'path': path,
      'protected': protected,
      'pattern': pattern,
      if (label != null && label.trim().isNotEmpty) 'label': label.trim(),
    };
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _ws.send(msg);
    }
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _fileManagerProtectedCompleters.remove(requestId);
        throw TimeoutException('Timed out updating protection');
      },
    );
  }

  Future<void> downloadFileManagerFile({
    required String path,
    required String fileName,
    String? serverId,
    bool showInChat = false,
  }) async {
    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
    final fileId = _stableFileTransferId(path);
    final completer = Completer<Map<String, dynamic>>();
    _fileManagerOperationCompleters[requestId] = completer;
    _serverFiles[fileId] = path;
    _serverFileNames[fileId] = fileName;
    if (serverId != null && serverId.isNotEmpty) {
      _downloadServerIds[fileId] = serverId;
    }
    if (showInChat && _activeSessionId != null) {
      _downloadSessionIds[fileId] = _activeSessionId!;
    }
    _filePathToId[path] = fileId;
    _downloadRetryCounts[fileId] = 0;
    _cancelledDownloads.remove(fileId);
    _downloadingFiles.add(fileId);
    _downloadProgress[fileId] = 0;
    _downloadErrors.remove(fileId);
    _armDownloadWatchdog(fileId);
    _showDownloadProgressNotification(fileId, fileName, 0);
    if (showInChat) {
      final hasVisibleCard = _messages.any(
        (m) =>
            m.type == MessageType.toolCall &&
            m.toolName == 'SendFile' &&
            m.toolInput?['file_path'] == path,
      );
      if (!hasVisibleCard) {
        _messages.add(
          ChatMessage.toolCall(
            tool: 'SendFile',
            input: {'file_path': path},
            toolUseId: 'file_$fileId',
          ),
        );
      }
    }
    notifyListeners();

    final usedHttp = await _tryHttpFileDownload(
      fileId: fileId,
      serverPath: path,
      fileName: fileName,
      serverId: serverId,
    );
    if (usedHttp) {
      _fileManagerOperationCompleters.remove(requestId);
      return;
    }

    final offsetBytes = await _socketDownloadOffset(fileId);
    final msg = {
      'type': 'file_manager_download',
      'requestId': requestId,
      'path': path,
      'fileId': fileId,
      if (_serverFileVersions[fileId]?.isNotEmpty == true)
        'expectedFileVersion': _serverFileVersions[fileId],
      if (offsetBytes > 0) 'offsetBytes': offsetBytes,
    };
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _ws.send(msg);
    }

    try {
      await completer.future.timeout(const Duration(seconds: 10));
    } catch (e) {
      _fileManagerOperationCompleters.remove(requestId);
      _serverFiles.remove(fileId);
      _serverFileNames.remove(fileId);
      _serverFileSizes.remove(fileId);
      _serverFileVersions.remove(fileId);
      _downloadServerIds.remove(fileId);
      _downloadRetryCounts.remove(fileId);
      _filePathToId.remove(path);
      _downloadingFiles.remove(fileId);
      _downloadProgress.remove(fileId);
      _downloadErrors[fileId] = e.toString();
      _cancelDownloadWatchdog(fileId);
      notifyListeners();
      rethrow;
    }
  }

  Future<String?> fetchFileManagerFileBase64({
    required String path,
    required String fileName,
    String? serverId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
    final fileId = 'fm_preview_$requestId';
    final operationCompleter = Completer<Map<String, dynamic>>();
    final byteCompleter = Completer<String?>();

    _fileManagerOperationCompleters[requestId] = operationCompleter;
    _fileBytesCompleters[fileId] = byteCompleter;
    _fileBytesBuffers[fileId] = BytesBuilder(copy: false);

    final msg = {
      'type': 'file_manager_download',
      'requestId': requestId,
      'path': path,
      'fileId': fileId,
    };
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _ws.send(msg);
    }

    try {
      await operationCompleter.future.timeout(const Duration(seconds: 10));
      return await byteCompleter.future.timeout(timeout);
    } catch (e) {
      _fileManagerOperationCompleters.remove(requestId);
      _fileBytesCompleters.remove(fileId);
      _fileBytesBuffers.remove(fileId);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> readFileManagerText({
    required String path,
    String? serverId,
    int maxBytes = 512 * 1024,
  }) {
    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
    final completer = Completer<Map<String, dynamic>>();
    _fileManagerTextCompleters[requestId] = completer;
    final msg = {
      'type': 'file_manager_read_text',
      'requestId': requestId,
      'path': path,
      'maxBytes': maxBytes,
    };
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _ws.send(msg);
    }
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _fileManagerTextCompleters.remove(requestId);
        throw TimeoutException('Timed out reading file text');
      },
    );
  }

  Future<void> writeFileManagerText({
    required String path,
    required String content,
    String? serverId,
  }) async {
    await _sendFileManagerOperation({
      'type': 'file_manager_write_text',
      'path': path,
      'content': content,
    }, serverId: serverId);
  }

  Future<Map<String, dynamic>> _sendFileManagerOperation(
    Map<String, dynamic> msg, {
    String? serverId,
    Duration timeout = const Duration(seconds: 10),
  }) {
    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
    final completer = Completer<Map<String, dynamic>>();
    _fileManagerOperationCompleters[requestId] = completer;
    final withId = {'requestId': requestId, ...msg};
    if (serverId != null) {
      _connMgr.sendToServer(serverId, withId);
    } else {
      _ws.send(withId);
    }
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _fileManagerOperationCompleters.remove(requestId);
        throw TimeoutException('Timed out waiting for file operation');
      },
    );
  }

  Future<void> createFileManagerFolder({
    required String path,
    String? serverId,
  }) async {
    await _sendFileManagerOperation({
      'type': 'file_manager_mkdir',
      'path': path,
    }, serverId: serverId);
  }

  Future<void> renameFileManagerEntry({
    required String fromPath,
    required String toName,
    String? serverId,
  }) async {
    await _sendFileManagerOperation({
      'type': 'file_manager_rename',
      'fromPath': fromPath,
      'toName': toName,
    }, serverId: serverId);
  }

  Future<void> deleteFileManagerEntry({
    required String path,
    required bool recursive,
    String? serverId,
  }) async {
    await _sendFileManagerOperation({
      'type': 'file_manager_delete',
      'path': path,
      'recursive': recursive,
    }, serverId: serverId);
  }

  Future<String> uploadFileManagerFile({
    required String localPath,
    required String name,
    required String targetDir,
    String? serverId,
    String conflictPolicy = 'rename',
  }) async {
    final file = File(localPath);
    final bytes = await file.readAsBytes();
    final ws = serverId == null ? _ws : _connMgr.getConnection(serverId) ?? _ws;
    final binary = ws.serverSupportsBinary;
    final chunkSize = binary ? 1 * 1024 * 1024 : 512 * 1024;
    final totalChunks = (bytes.length / chunkSize)
        .ceil()
        .clamp(1, double.infinity)
        .toInt();
    final uploadId = DateTime.now().microsecondsSinceEpoch.toString();
    _pendingUploadId = uploadId;
    final uploadCompleter = Completer<String>();
    _uploadCompleter = uploadCompleter;

    final start = await _sendFileManagerOperation({
      'type': 'file_manager_upload_start',
      'uploadId': uploadId,
      'targetDir': targetDir,
      'fileName': name,
      'fileSize': bytes.length,
      'totalChunks': totalChunks,
      'chunkSize': chunkSize,
      'conflictPolicy': conflictPolicy,
    }, serverId: serverId);

    for (var i = 0; i < totalChunks; i++) {
      final chunkStart = i * chunkSize;
      final chunkEnd = (chunkStart + chunkSize).clamp(0, bytes.length);
      final chunk = Uint8List.fromList(bytes.sublist(chunkStart, chunkEnd));
      if (binary) {
        ws.sendUploadChunkBinary(
          uploadId: uploadId,
          chunkIndex: i,
          bytes: chunk,
        );
      } else if (serverId != null) {
        _connMgr.sendToServer(serverId, {
          'type': 'upload_chunk',
          'uploadId': uploadId,
          'chunkIndex': i,
          'data': base64Encode(chunk),
        });
      } else {
        _ws.send({
          'type': 'upload_chunk',
          'uploadId': uploadId,
          'chunkIndex': i,
          'data': base64Encode(chunk),
        });
      }
    }

    final serverPath = await uploadCompleter.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        throw TimeoutException('Timed out waiting for upload completion');
      },
    );
    _pendingUploadId = null;
    _uploadCompleter = null;
    return serverPath.isNotEmpty
        ? serverPath
        : (start['path'] as String? ?? '');
  }

  /// Request SDK sessions for a given CWD from the server.
  Future<SdkSessionPage> requestSdkSessions(
    String cwd, {
    String? serverId,
    int limit = 30,
  }) async {
    final seq = ++_sdkSessionsRequestSeq;
    final requestId = 'sdk_${DateTime.now().microsecondsSinceEpoch}_$seq';
    final completer = Completer<SdkSessionPage>();
    _sdkSessionCompleters[requestId] = completer;
    _sdkSessionRequestServers[requestId] = serverId;
    _sdkSessionRequestCwds[requestId] = cwd;
    _sdkSessionRequestLimits[requestId] = limit;
    final msg = {
      'type': 'list_sdk_sessions',
      'cwd': cwd,
      'requestId': requestId,
      'limit': limit,
    };
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _ws.send(msg);
    }
    try {
      return await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () =>
            const SdkSessionPage(sessions: [], total: 0, hasMore: false),
      );
    } finally {
      _sdkSessionCompleters.remove(requestId);
      _sdkSessionRequestServers.remove(requestId);
      _sdkSessionRequestCwds.remove(requestId);
      _sdkSessionRequestLimits.remove(requestId);
    }
  }

  /// Check server version and available updates.
  Future<Map<String, dynamic>> requestVersionCheck({String? serverId}) async {
    final completer = Completer<Map<String, dynamic>>();
    _pendingVersionCheck = completer;
    _pendingVersionCheckServerId = serverId;
    final msg = {'type': 'version_check'};
    if (serverId != null) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _ws.send(msg);
    }
    final result = await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => <String, dynamic>{
        'error': 'Timed out checking for updates',
      },
    );
    if (identical(_pendingVersionCheck, completer)) {
      _pendingVersionCheck = null;
      _pendingVersionCheckServerId = null;
    }
    return _attachServerRuntimeInfo(result, serverId);
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

  Future<Map<String, dynamic>> requestAdbBridgeSidecar(
    String serverId, {
    String action = 'status',
    int localPort = 5038,
  }) async {
    final requestId =
        'adb_bridge_${action}_${DateTime.now().millisecondsSinceEpoch}';
    final completer = Completer<Map<String, dynamic>>();
    _adbBridgeSidecarCompleters[requestId] = completer;

    final type = switch (action) {
      'start' => 'adb_bridge_sidecar_start',
      'stop' => 'adb_bridge_sidecar_stop',
      _ => 'adb_bridge_sidecar_status',
    };
    final message = <String, dynamic>{
      'type': type,
      'requestId': requestId,
      if (action == 'start') 'localPort': localPort,
    };
    _connMgr.sendToServer(serverId, message);

    return completer.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () {
        _adbBridgeSidecarCompleters.remove(requestId);
        return <String, dynamic>{
          'requestId': requestId,
          'running': false,
          'error': 'Timed out waiting for ADB sidecar status.',
        };
      },
    );
  }

  Future<Map<String, dynamic>> requestAdbCommand(
    String serverId, {
    required String command,
    required String host,
    required int port,
    String? code,
  }) async {
    final requestId = 'adb_${command}_${DateTime.now().millisecondsSinceEpoch}';
    final completer = Completer<Map<String, dynamic>>();
    _adbCommandCompleters[requestId] = completer;
    _connMgr.sendToServer(serverId, {
      'type': 'adb_command',
      'requestId': requestId,
      'command': command,
      'host': host,
      'port': port,
      if (code != null) 'code': code,
    });
    return completer.future.timeout(
      const Duration(seconds: 40),
      onTimeout: () {
        _adbCommandCompleters.remove(requestId);
        return <String, dynamic>{
          'requestId': requestId,
          'command': command,
          'ok': false,
          'message': 'Timed out waiting for adb $command.',
        };
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
    _pendingInjectedMessageCount = 0;
    _pendingLocalUserMessageIds.clear();
    _pendingCacheUserPromptContent.clear();
    _todos = [];
    _lastUsage = null;
    _activeSessionId = sessionId;
    _activeSessionServerId = serverId ?? _connMgr.activeServerId;
    _effort = 'high';
    _thinking = {'type': 'adaptive'};
    _codexFastMode = false;
    _claudeAutoCompactEnabled = true;
    _codexCollaborationMode = 'default';
    _isLoadingHistory = true;
    _isProcessing = false;
    _stopPromptRuntime();
    _isCompacting = false;
    _clearLiveMessageStreams();
    _promptSuggestions = [];
    _contextUsage = null;
    _requiresAction = false;
    final historyRequestId = _beginInitialHistoryRequest(sessionId);
    // Track the backend immediately so chat-header [CODEX] flag is right
    // before session_created comes back; falls through to whatever the
    // server confirms on the SessionInfo write-through.
    _activeSessionBackend = backend;
    final msg = {
      'type': 'resume_session',
      'sessionId': sessionId,
      'cwd': cwd,
      if (backend != null) 'backend': backend,
      'historyRequestId': historyRequestId,
    };
    if (serverId != null) {
      _connMgr.activeServerId = serverId;
      _activeSessionServerId = serverId;
      _connMgr.sendToServer(serverId, msg);
    } else {
      _connMgr.send(msg);
    }
    notifyListeners();
  }

  void requestSessionList() {
    _connMgr.sendToAll({'type': 'list_sessions'});
    _connMgr.sendToAll({'type': 'get_recent_cwds'});
    _connMgr.sendToAll({'type': 'get_server_settings'});
  }

  void requestScheduledTasks() {
    for (final config in _serverConfigs) {
      _requestScheduledTasksFromServer(config.id, force: true);
    }
  }

  void _requestScheduledTasksFromServer(String serverId, {bool force = false}) {
    if (_connMgr.statusOf(serverId) != ConnectionStatus.connected) return;
    if (!force && _scheduledTaskRefreshRetries.containsKey(serverId)) return;

    _connMgr.sendToServer(serverId, {'type': 'list_scheduled_tasks'});
    _scheduledTaskRefreshRetries.remove(serverId)?.cancel();
    _scheduledTaskRefreshRetries[serverId] = Timer(
      const Duration(seconds: 2),
      () {
        _scheduledTaskRefreshRetries.remove(serverId);
        if (_connMgr.statusOf(serverId) == ConnectionStatus.connected) {
          _connMgr.sendToServer(serverId, {'type': 'list_scheduled_tasks'});
        }
      },
    );
  }

  String? _serverIdForScheduledTask(String taskId) {
    final task = _scheduledTasks.where((t) => t['id'] == taskId).firstOrNull;
    final serverId = task?['_serverId'] as String?;
    return serverId != null && serverId.isNotEmpty ? serverId : null;
  }

  void scheduleTask({
    String? name,
    required String prompt,
    required String cwd,
    required String scheduledTime,
    String? backend,
    String? model,
    String effort = 'high',
    String permissionMode = 'bypassPermissions',
    String? recurrenceType,
    int? customIntervalMs,
    bool reuseSession = false,
    String notificationMode = 'completion',
    String? serverId,
  }) {
    final msg = <String, dynamic>{
      'type': 'schedule_task',
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      'prompt': prompt,
      'cwd': cwd,
      'backend': backend ?? preferredBackendForServer(serverId),
      if (model != null && model.isNotEmpty) 'model': model,
      'effort': effort,
      'permissionMode': permissionMode,
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
    bool? reuseSession,
    String? notificationMode,
  }) {
    final msg = <String, dynamic>{
      'type': 'update_scheduled_task',
      'taskId': taskId,
    };
    if (name != null) msg['name'] = name.trim();
    if (prompt != null) msg['prompt'] = prompt;
    if (cwd != null) msg['cwd'] = cwd;
    if (backend != null) msg['backend'] = backend;
    if (model != null) msg['model'] = model;
    if (effort != null) msg['effort'] = effort;
    if (permissionMode != null) msg['permissionMode'] = permissionMode;
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
    final taskIndex = _scheduledTasks.indexWhere(
      (task) => task['id'] == taskId,
    );
    if (taskIndex >= 0) {
      final updated = applyScheduledTaskUpdate(_scheduledTasks[taskIndex], msg);
      _scheduledTasks[taskIndex] = updated;

      if (serverId != null) {
        final serverTasks = _perServerScheduledTasks[serverId];
        final serverTaskIndex =
            serverTasks?.indexWhere((task) => task['id'] == taskId) ?? -1;
        if (serverTasks != null && serverTaskIndex >= 0) {
          serverTasks[serverTaskIndex] = updated;
        }
      }
      _saveScheduledTaskCacheSoon();
      notifyListeners();
    }

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
    _saveScheduledTaskCacheSoon();
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
      _saveSessionCacheSoon();
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
    final serverId = session?.serverId.isNotEmpty == true
        ? session!.serverId
        : null;
    _markArchivedSessionHidden(serverId, sessionId);
    if (session != null) {
      _pendingArchivedSessions[_archivePendingKey(serverId, sessionId)] =
          session;
    }
    _removeSessionFromLists(serverId, sessionId);
    if (serverId != null) {
      _connMgr.sendToServer(serverId, {
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
      final updated = s.copyWith(title: title);
      _sessions[idx] = updated;
      if (updated.serverId.isNotEmpty) {
        final serverSessions = _perServerSessions[updated.serverId];
        final serverIdx =
            serverSessions?.indexWhere((s) => s.id == sessionId) ?? -1;
        if (serverSessions != null && serverIdx >= 0) {
          serverSessions[serverIdx] = updated;
        }
      }
      _saveSessionCacheSoon();
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

  void setEffort(String effort) {
    _effort = effort;
    _connMgr.send({'type': 'set_effort', 'effort': effort});
    notifyListeners();
  }

  void setCodexFastMode(bool enabled) {
    _codexFastMode = enabled;
    if (_activeSessionId != null) {
      _sessionCodexFastModes[_activeSessionId!] = enabled;
    }
    _connMgr.send({'type': 'set_codex_fast_mode', 'enabled': enabled});
    notifyListeners();
  }

  void setClaudeAutoCompactEnabled(bool enabled) {
    _claudeAutoCompactEnabled = enabled;
    final sessionId = _activeSessionId;
    if (sessionId != null) {
      _sessionClaudeAutoCompact[sessionId] = enabled;
    }
    _connMgr.send({'type': 'set_claude_auto_compact', 'enabled': enabled});
    notifyListeners();
  }

  void setThinking(Map<String, dynamic> thinking) {
    _thinking = thinking;
    _connMgr.send({'type': 'set_thinking', 'thinking': thinking});
    notifyListeners();
  }

  // Per-session disallowed tools
  List<String> getDisallowedTools(String sessionId) {
    return _sessionDisallowedTools[sessionId] ?? [];
  }

  Future<void> setDisallowedTools(String sessionId, List<String> tools) async {
    _sessionDisallowedTools[sessionId] = tools;
    _sendSessionSetting(sessionId, {
      'type': 'set_disallowed_tools',
      'tools': tools,
    });
    notifyListeners();
  }

  // Per-session system prompt override
  String getSessionSystemPrompt(String sessionId) {
    return _sessionSystemPrompts[sessionId] ?? '';
  }

  String getEffectiveSystemPrompt(String sessionId) {
    final sessionOverride = _sessionSystemPrompts[sessionId];
    if (sessionOverride != null && sessionOverride.isNotEmpty) {
      return sessionOverride;
    }
    return _serverDefaultSystemPrompt(sessionId);
  }

  Future<void> setSessionSystemPrompt(String sessionId, String prompt) async {
    if (prompt.isEmpty) {
      _sessionSystemPrompts.remove(sessionId);
      _clearSessionSystemPromptOverride(sessionId);
    } else {
      _sessionSystemPrompts[sessionId] = prompt;
      _sendSessionSetting(sessionId, {
        'type': 'set_system_prompt',
        'prompt': prompt,
      });
    }
    notifyListeners();
  }

  String _serverDefaultSystemPrompt(String sessionId) {
    final session = _sessions.where((item) => item.id == sessionId).firstOrNull;
    final serverId = session?.serverId.isNotEmpty == true
        ? session!.serverId
        : _activeSessionServerId ?? _connMgr.activeServerId;
    return _serverConfigs
            .where((config) => config.id == serverId)
            .firstOrNull
            ?.systemPrompt
            .trim() ??
        '';
  }

  void _clearSessionSystemPromptOverride(String sessionId) {
    final message = {
      'type': 'set_system_prompt',
      'prompt': '',
      'inherited': true,
      'clearOverride': true,
    };
    _sendSessionSetting(sessionId, message);
  }

  void _sendSessionSetting(String sessionId, Map<String, dynamic> message) {
    message['sessionId'] = sessionId;
    final session = _sessions.where((item) => item.id == sessionId).firstOrNull;
    final serverId = session?.serverId.isNotEmpty == true
        ? session!.serverId
        : _activeSessionId == sessionId
        ? _activeSessionServerId
        : null;
    if (serverId != null && serverId.isNotEmpty) {
      _connMgr.sendToServer(serverId, message);
    } else {
      _connMgr.send(message);
    }
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
          a[i]['status'] != b[i]['status']) {
        return false;
      }
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
    final isMonitor = _backgroundTasks[taskId]?['isMonitor'] == true;
    _backgroundTasks.remove(taskId);
    notifyListeners();
    if (isMonitor) {
      _ws.sendStopMonitor(taskId);
    } else {
      _ws.sendStopTask(taskId);
    }
  }

  void forkSession(String sessionId) {
    _activeSessionId = null;
    _activeSessionServerId = null;
    _clearLiveMessageStreams();
    _isProcessing = false;
    _stopPromptRuntime();
    _pendingLocalUserMessageIds.clear();
    _pendingCacheUserPromptContent.clear();
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
    return _getDirectServerFor();
  }

  ({String host, int port, String token})? _getDirectServerFor([
    String? serverId,
  ]) {
    if (serverId != null && serverId.isNotEmpty) {
      final config = _serverConfigs.where((c) => c.id == serverId).firstOrNull;
      if (config != null && !config.useRelay && config.host.isNotEmpty) {
        return (host: config.host, port: config.port, token: config.token);
      }
      return null;
    }

    final activeServerId = _connMgr.activeServerId;
    if (activeServerId != null && activeServerId.isNotEmpty) {
      final config = _serverConfigs
          .where((c) => c.id == activeServerId)
          .firstOrNull;
      if (config != null && !config.useRelay && config.host.isNotEmpty) {
        return (host: config.host, port: config.port, token: config.token);
      }
    }

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

  bool _directServerUsesEncryptedSocket([String? serverId]) {
    if (serverId != null && serverId.isNotEmpty) {
      final config = _serverConfigs.where((c) => c.id == serverId).firstOrNull;
      return config != null &&
          !config.useRelay &&
          config.host.isNotEmpty &&
          config.serverPubkey.isNotEmpty;
    }

    final activeServerId = _connMgr.activeServerId;
    if (activeServerId != null && activeServerId.isNotEmpty) {
      final config = _serverConfigs
          .where((c) => c.id == activeServerId)
          .firstOrNull;
      if (config != null && !config.useRelay && config.host.isNotEmpty) {
        return config.serverPubkey.isNotEmpty;
      }
    }

    final direct = _serverConfigs
        .where((c) => !c.useRelay && c.host.isNotEmpty)
        .firstOrNull;
    return direct?.serverPubkey.isNotEmpty ?? false;
  }

  Future<void> downloadKokoroModel([
    KokoroModel model = KokoroModel.v019,
  ]) async {
    final server = _getDirectServer();
    if (server == null) {
      throw Exception('No direct server configured for model download');
    }
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

  /// Get advertised server file size by fileId, when provided by the server.
  int? getServerFileSize(String fileId) => _serverFileSizes[fileId];

  /// Whether a file is currently being downloaded by fileId
  bool isDownloading(String fileId) => _downloadingFiles.contains(fileId);

  /// Get download progress for a file (0.0 to 1.0), or null if not downloading
  double? getDownloadProgress(String fileId) => _downloadProgress[fileId];

  /// Get latest download error for a file, or null if there is no error.
  String? getDownloadError(String fileId) => _downloadErrors[fileId];

  /// Handle file metadata from server (no data yet — just registers availability)
  void _handleFileMessage(Map<String, dynamic> msg, [String? serverId]) {
    final fileId = msg['fileId'] as String? ?? '';
    // Sanitize: strip path separators to prevent directory traversal
    var fileName = msg['fileName'] as String? ?? 'file';
    fileName = fileName.split('/').last.split('\\').last.replaceAll('..', '');
    if (fileName.isEmpty) fileName = 'file';
    final filePath = msg['filePath'] as String? ?? '';
    final fileSize = (msg['fileSize'] as num?)?.toInt();
    final fileVersion = msg['fileVersion'] as String?;
    if (filePath.isNotEmpty && fileId.isNotEmpty) {
      _serverFiles[fileId] = filePath;
      _serverFileNames[fileId] = fileName;
      if (fileSize != null && fileSize > 0) {
        _serverFileSizes[fileId] = fileSize;
      }
      if (fileVersion != null && fileVersion.isNotEmpty) {
        _serverFileVersions[fileId] = fileVersion;
      }
      final currentServerId = serverId ?? _connMgr.activeServerId;
      if (currentServerId != null && currentServerId.isNotEmpty) {
        _downloadServerIds[fileId] = currentServerId;
      }
      final messageSessionId = msg['sessionId'] as String? ?? '';
      if (messageSessionId.isNotEmpty) {
        _downloadSessionIds[fileId] = messageSessionId;
      }
      debugPrint(
        '[File] Available for download: $fileName (id=$fileId, path=$filePath)',
      );
      final belongsToActiveSession = fileEventBelongsToVisibleSession(
        messageSessionId: messageSessionId,
        activeSessionId: _activeSessionId,
        messageServerId: currentServerId,
        activeServerId: _activeSessionServerId ?? _connMgr.activeServerId,
      );
      if (!belongsToActiveSession) {
        notifyListeners();
        return;
      }
      _filePathToId[filePath] = fileId;
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
            input: {
              'file_path': filePath,
              '_file_id': fileId,
              '_file_name': fileName,
              if (fileSize != null && fileSize > 0) '_file_size': fileSize,
            },
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
    _downloadErrors.remove(fileId);
    notifyListeners();
  }

  Future<void> cancelDownloadFromNotification(String fileId) async {
    _cancelledDownloads.add(fileId);
    await _cleanupActiveDownload(fileId, deleteTemp: true);
    _downloadRetryCounts.remove(fileId);
    _downloadErrors[fileId] = 'Download cancelled';
    await _notifications.cancel(_downloadNotificationId(fileId));
    notifyListeners();
  }

  void retryDownloadFromNotification(String fileId) {
    if (!_serverFiles.containsKey(fileId)) return;
    requestFile(fileId);
  }

  Future<void> dismissDownloadNotification(String fileId) async {
    await _notifications.cancel(_downloadNotificationId(fileId));
  }

  Future<void> openDownloadedFileFromNotification(
    String fileId, {
    String? localPath,
  }) async {
    final path = localPath?.isNotEmpty == true
        ? localPath!
        : _receivedFiles[fileId];
    if (path == null || path.isEmpty) return;
    final result = await OpenFilex.open(path);
    debugPrint(
      '[File] Open downloaded file result: ${result.type} (${result.message}) path=$path',
    );
  }

  /// Request file data from server (user tapped download).
  /// Direct/manual servers use HTTP for large-file speed; relay falls back to
  /// the encrypted socket chunk path.
  void requestFile(String fileId) {
    unawaited(_requestFile(fileId));
  }

  Future<void> _requestFile(String fileId) async {
    final serverPath = _serverFiles[fileId];
    if (serverPath == null) return;
    final fileName = _serverFileNames[fileId] ?? serverPath.split('/').last;
    await _cleanupActiveDownload(fileId, deleteTemp: false);
    _downloadErrors.remove(fileId);
    _downloadRetryCounts[fileId] = 0;
    _cancelledDownloads.remove(fileId);
    final ownerServerId = resolveDownloadServerId(
      _downloadServerIds[fileId],
      _connMgr.activeServerId,
    );
    if (ownerServerId != null) {
      _downloadServerIds[fileId] = ownerServerId;
    }
    _downloadingFiles.add(fileId);
    _downloadProgress[fileId] = 0;
    _armDownloadWatchdog(fileId);
    _showDownloadProgressNotification(fileId, fileName, 0);
    notifyListeners();
    unawaited(
      _tryHttpFileDownload(
        fileId: fileId,
        serverPath: serverPath,
        fileName: fileName,
        serverId: ownerServerId,
      ).then((usedHttp) {
        if (usedHttp || !_downloadingFiles.contains(fileId)) return;
        unawaited(
          _requestSocketFileDownload(
            fileId,
            serverPath,
            serverId: _downloadServerIds[fileId],
          ),
        );
      }),
    );
  }

  String _socketDownloadTempPath(String fileId) {
    final safeId = _safeDownloadTempId(fileId);
    return '/storage/emulated/0/Download/.$safeId.tmp';
  }

  Future<int> _socketDownloadOffset(String fileId) async {
    final tempFile = File(_socketDownloadTempPath(fileId));
    try {
      return await tempFile.exists() ? await tempFile.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _requestSocketFileDownload(
    String fileId,
    String serverPath, {
    String? serverId,
  }) async {
    final offsetBytes = await _socketDownloadOffset(fileId);
    final transferToken =
        '${DateTime.now().microsecondsSinceEpoch}_${_downloadRetryCounts[fileId] ?? 0}';
    _socketDownloadTokens[fileId] = transferToken;
    final msg = {
      'type': 'request_file',
      'filePath': serverPath,
      'fileId': fileId,
      'transferToken': transferToken,
      if (_serverFileVersions[fileId]?.isNotEmpty == true)
        'expectedFileVersion': _serverFileVersions[fileId],
      if (offsetBytes > 0) 'offsetBytes': offsetBytes,
    };
    _armDownloadWatchdog(fileId);
    if (serverId != null && serverId.isNotEmpty) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _ws.send(msg);
    }
  }

  int? _httpContentRangeTotal(Map<String, String> headers) {
    final value = headers['content-range'] ?? headers['Content-Range'];
    if (value == null) return null;
    final match = RegExp(r'bytes\s+\d+-\d+/(\d+|\*)').firstMatch(value);
    final total = match?.group(1);
    if (total == null || total == '*') return null;
    return int.tryParse(total);
  }

  String _formatDownloadBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(1)} GB';
  }

  Future<File> _moveHttpDownloadToUniqueTarget({
    required File tempFile,
    required Directory downloadsDir,
    required String safeName,
  }) async {
    final name = safeName.isEmpty ? 'file' : safeName;
    var targetFile = File('${downloadsDir.path}/$name');
    var counter = 1;
    while (targetFile.existsSync()) {
      final ext = name.contains('.') ? '.${name.split('.').last}' : '';
      final base = name.contains('.')
          ? name.substring(0, name.lastIndexOf('.'))
          : name;
      targetFile = File('${downloadsDir.path}/$base ($counter)$ext');
      counter++;
    }

    try {
      return await tempFile.rename(targetFile.path);
    } catch (_) {
      await tempFile.copy(targetFile.path);
      await tempFile.delete();
      return targetFile;
    }
  }

  void _setDownloadProgress(
    String fileId,
    String fileName,
    int received,
    int? total,
  ) {
    if (total != null && total > 0) {
      final progress = (received / total).clamp(0.0, 1.0).toDouble();
      final percent = NotificationService.progressPercent(progress);
      final lastProgress = _lastNotifiedProgress[fileId];
      final lastPercent = lastProgress == null
          ? -1
          : NotificationService.progressPercent(lastProgress);
      if (progress >= 1.0 || percent > lastPercent) {
        _downloadProgress[fileId] = progress;
        _lastNotifiedProgress[fileId] = progress;
        _downloadErrors.remove(fileId);
        _showDownloadProgressNotification(fileId, fileName, progress);
        notifyListeners();
      }
    } else {
      _showDownloadProgressNotification(fileId, fileName, null);
    }
  }

  Future<bool> _tryHttpFileDownload({
    required String fileId,
    required String serverPath,
    required String fileName,
    String? serverId,
  }) async {
    if (_directServerUsesEncryptedSocket(serverId)) {
      return false;
    }
    final server = _getDirectServerFor(serverId);
    if (server == null) return false;

    final uri = Uri(
      scheme: 'http',
      host: server.host,
      port: server.port,
      path: '/download-file',
      queryParameters: {'token': server.token, 'path': serverPath},
    );

    final safeName = fileName
        .split('/')
        .last
        .split('\\')
        .last
        .replaceAll('..', '');
    final downloadsDir = Directory('/storage/emulated/0/Download');
    final safeId = _safeDownloadTempId(fileId);
    final tempPath = '${downloadsDir.path}/.$safeId.http.tmp';
    final tempFile = File(tempPath);
    const maxAttempts = 5;
    const connectTimeout = Duration(seconds: 10);
    const idleTimeout = Duration(seconds: 15);
    var sawHttpResponse = false;
    Object? lastError;

    try {
      if (!downloadsDir.existsSync()) {
        downloadsDir.createSync(recursive: true);
      }
      _downloadTempPaths[fileId] = tempPath;
      _cancelDownloadWatchdog(fileId);

      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        if (!_downloadingFiles.contains(fileId)) return true;

        var existingBytes = tempFile.existsSync() ? await tempFile.length() : 0;
        final client = http.Client();
        IOSink? sink;
        try {
          final request = http.Request('GET', uri);
          if (existingBytes > 0) {
            request.headers['Range'] = 'bytes=$existingBytes-';
          }
          final response = await client.send(request).timeout(connectTimeout);
          sawHttpResponse = true;

          if (response.statusCode == 416 && existingBytes > 0) {
            final serverSize = _httpContentRangeTotal(response.headers);
            if (serverSize != null && existingBytes == serverSize) {
              final targetFile = await _moveHttpDownloadToUniqueTarget(
                tempFile: tempFile,
                downloadsDir: downloadsDir,
                safeName: safeName,
              );
              _downloadTempPaths.remove(fileId);
              _lastNotifiedProgress.remove(fileId);
              _receivedFiles[fileId] = targetFile.path;
              _downloadingFiles.remove(fileId);
              _downloadProgress.remove(fileId);
              _downloadErrors.remove(fileId);
              _downloadRetryCounts.remove(fileId);
              _showDownloadFinishedNotification(
                fileId,
                safeName.isEmpty ? 'file' : safeName,
              );
              notifyListeners();
              return true;
            }
            if (tempFile.existsSync()) await tempFile.delete();
            existingBytes = 0;
            throw Exception('Server rejected resume range');
          }

          var resume = false;
          if (response.statusCode == 206) {
            resume = existingBytes > 0;
          } else if (response.statusCode == 200) {
            if (existingBytes > 0 && tempFile.existsSync()) {
              await tempFile.delete();
              existingBytes = 0;
            }
          } else if (response.statusCode == 400 ||
              response.statusCode == 401 ||
              response.statusCode == 403 ||
              response.statusCode == 404) {
            _downloadTempPaths.remove(fileId);
            return false;
          } else {
            throw Exception('HTTP ${response.statusCode}');
          }

          final total = response.statusCode == 206
              ? _httpContentRangeTotal(response.headers) ??
                    (response.contentLength == null
                        ? null
                        : existingBytes + response.contentLength!)
              : response.contentLength;
          var received = resume ? existingBytes : 0;
          _setDownloadProgress(fileId, fileName, received, total);
          sink = tempFile.openWrite(
            mode: resume ? FileMode.append : FileMode.write,
          );

          await for (final chunk in response.stream.timeout(idleTimeout)) {
            if (!_downloadingFiles.contains(fileId)) {
              throw Exception('Download cancelled');
            }
            sink.add(chunk);
            received += chunk.length;
            _setDownloadProgress(fileId, fileName, received, total);
          }

          await sink.flush();
          await sink.close();
          sink = null;

          final savedBytes = await tempFile.length();
          if (total != null && total > 0 && savedBytes != total) {
            throw Exception(
              'Downloaded ${_formatDownloadBytes(savedBytes)} / ${_formatDownloadBytes(total)}',
            );
          }

          final targetFile = await _moveHttpDownloadToUniqueTarget(
            tempFile: tempFile,
            downloadsDir: downloadsDir,
            safeName: safeName,
          );

          _downloadTempPaths.remove(fileId);
          _lastNotifiedProgress.remove(fileId);
          _cancelDownloadWatchdog(fileId);
          _downloadExpectedBytes.remove(fileId);
          _receivedFiles[fileId] = targetFile.path;
          _downloadingFiles.remove(fileId);
          _downloadProgress.remove(fileId);
          _downloadErrors.remove(fileId);
          _downloadRetryCounts.remove(fileId);
          _showDownloadFinishedNotification(
            fileId,
            safeName.isEmpty ? 'file' : safeName,
          );
          debugPrint(
            '[File] HTTP download complete: ${targetFile.path} (fileId=$fileId)',
          );
          notifyListeners();
          return true;
        } catch (e) {
          lastError = e;
          debugPrint(
            '[File] HTTP download attempt $attempt/$maxAttempts failed: $e',
          );
          try {
            await sink?.flush();
            await sink?.close();
          } catch (_) {}
          final partialBytes = tempFile.existsSync()
              ? await tempFile.length()
              : 0;
          if (_cancelledDownloads.remove(fileId)) {
            _downloadTempPaths.remove(fileId);
            _lastNotifiedProgress.remove(fileId);
            _downloadProgress.remove(fileId);
            _downloadErrors[fileId] = 'Download cancelled';
            notifyListeners();
            return true;
          }
          if (attempt < maxAttempts && _downloadingFiles.contains(fileId)) {
            _downloadErrors[fileId] = partialBytes > 0
                ? 'Connection interrupted, retrying from ${_formatDownloadBytes(partialBytes)}...'
                : 'Connection interrupted, retrying...';
            _showDownloadProgressNotification(
              fileId,
              fileName,
              _downloadProgress[fileId],
            );
            notifyListeners();
            final retryDelaySeconds = attempt < 4 ? attempt * 2 : 8;
            await Future.delayed(Duration(seconds: retryDelaySeconds));
            continue;
          }
          break;
        } finally {
          client.close();
        }
      }

      final partialBytes = tempFile.existsSync() ? await tempFile.length() : 0;
      if (_cancelledDownloads.remove(fileId)) {
        _downloadTempPaths.remove(fileId);
        _lastNotifiedProgress.remove(fileId);
        _downloadProgress.remove(fileId);
        _downloadErrors[fileId] = 'Download cancelled';
        notifyListeners();
        return true;
      }
      if (partialBytes == 0 && !sawHttpResponse) {
        _downloadTempPaths.remove(fileId);
        return false;
      }

      _lastNotifiedProgress.remove(fileId);
      _cancelDownloadWatchdog(fileId);
      _downloadExpectedBytes.remove(fileId);
      _downloadingFiles.remove(fileId);
      _downloadProgress.remove(fileId);
      _downloadRetryCounts.remove(fileId);
      _downloadErrors[fileId] = partialBytes > 0
          ? 'Download interrupted after ${_formatDownloadBytes(partialBytes)}. Tap retry to resume.'
          : 'Download failed: ${lastError ?? 'unknown error'}';
      _showDownloadFailedNotification(fileId, _downloadErrors[fileId]!);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[File] HTTP download failed, falling back to socket: $e');
      _downloadTempPaths.remove(fileId);
      _lastNotifiedProgress.remove(fileId);
      _downloadProgress[fileId] = 0;
      _downloadExpectedBytes.remove(fileId);
      _armDownloadWatchdog(fileId);
      notifyListeners();
      return false;
    }
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
    _cancelDownloadWatchdog(fileId);

    if (base64Data.isEmpty) {
      _downloadErrors[fileId] = 'No file data returned';
      _showDownloadFailedNotification(fileId, 'No file data returned');
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
      _downloadErrors.remove(fileId);
      _downloadRetryCounts.remove(fileId);
      _showDownloadFinishedNotification(fileId, fileName);
      debugPrint(
        '[File] Saved: ${targetFile.path} (${(fileSize / 1024).toStringAsFixed(1)} KB)',
      );
      notifyListeners();
    } catch (e) {
      debugPrint('[File] Error saving file: $e');
      _downloadErrors[fileId] = e.toString();
      _showDownloadFailedNotification(fileId, e.toString());
      notifyListeners();
    }
  }

  /// Handle a file chunk from the server (chunked transfer)
  void _handleFileChunk(Map<String, dynamic> msg) {
    final fileId =
        msg['fileId'] as String? ?? msg['fileName'] as String? ?? 'file';
    final fileName =
        msg['fileName'] as String? ?? _serverFileNames[fileId] ?? 'file';
    final chunkIndex = msg['chunkIndex'] as int? ?? 0;
    final totalChunks = msg['totalChunks'] as int? ?? 1;
    final fileSize = (msg['fileSize'] as num?)?.toInt() ?? 0;
    final chunkOffset = (msg['offsetBytes'] as num?)?.toInt();
    final transferToken = msg['transferToken'] as String?;
    final binaryData = msg['binaryData'];
    final isBinaryChunk = binaryData is Uint8List;
    final base64Data = msg['data'] as String?;

    try {
      final expectedToken = _socketDownloadTokens[fileId];
      if (expectedToken != null &&
          transferToken != null &&
          transferToken != expectedToken) {
        debugPrint(
          '[File] Ignoring stale chunk for $fileId token=$transferToken',
        );
        return;
      }
      var bytes = binaryData is Uint8List
          ? binaryData
          : base64Decode(base64Data ?? '');
      if (fileSize > 0) {
        _downloadExpectedBytes[fileId] = fileSize;
      }
      final byteCompleter = _fileBytesCompleters[fileId];
      if (byteCompleter != null) {
        _fileBytesBuffers[fileId]?.add(bytes);
        final receivedBytes =
            (_downloadReceivedBytes[fileId] ?? chunkOffset ?? 0) + bytes.length;
        _downloadReceivedBytes[fileId] = receivedBytes;
        if (isBinaryChunk) {
          _sendFileDownloadAck(fileId, transferToken, receivedBytes);
        }
        return;
      }
      if (!_downloadingFiles.contains(fileId)) {
        debugPrint('[File] Ignoring stale chunk for $fileId');
        return;
      }

      // Open temp file on first chunk
      if (!_activeDownloads.containsKey(fileId)) {
        final tempPath = _socketDownloadTempPath(fileId);
        final tempFile = File(tempPath);
        final shouldAppend = chunkIndex > 0 && tempFile.existsSync();
        final existingBytes = shouldAppend ? tempFile.lengthSync() : 0;
        _activeDownloads[fileId] = tempFile.openWrite(
          mode: shouldAppend ? FileMode.append : FileMode.write,
        );
        _downloadReceivedBytes[fileId] = existingBytes;
        _downloadTempPaths[fileId] = tempPath;
        _downloadingFiles.add(fileId);
        debugPrint(
          '[File] Starting chunked download: $fileName (id=$fileId, $totalChunks chunks${shouldAppend ? ', resume' : ''})',
        );
      }

      final savedBytes = _downloadReceivedBytes[fileId] ?? 0;
      if (chunkOffset != null) {
        if (chunkOffset < savedBytes) {
          final overlap = savedBytes - chunkOffset;
          if (overlap >= bytes.length) {
            if (isBinaryChunk) {
              _sendFileDownloadAck(fileId, transferToken, savedBytes);
            }
            _armDownloadWatchdog(fileId);
            return;
          }
          bytes = Uint8List.fromList(bytes.sublist(overlap));
        } else if (chunkOffset > savedBytes) {
          _retrySocketFileDownload(
            fileId,
            'Transfer gap at ${_formatDownloadBytes(savedBytes)}; next chunk starts at ${_formatDownloadBytes(chunkOffset)}.',
          );
          return;
        }
      }

      _activeDownloads[fileId]!.add(bytes);
      final receivedBytes =
          (_downloadReceivedBytes[fileId] ?? 0) + bytes.length;
      _downloadReceivedBytes[fileId] = receivedBytes;
      if (isBinaryChunk) {
        _sendFileDownloadAck(fileId, transferToken, receivedBytes);
      }

      _downloadErrors.remove(fileId);
      _armDownloadWatchdog(fileId);
      if (fileSize > 0) {
        _setDownloadProgress(fileId, fileName, receivedBytes, fileSize);
      } else {
        final progress = (chunkIndex + 1) / totalChunks;
        _setDownloadProgress(fileId, fileName, chunkIndex + 1, totalChunks);
        _downloadProgress[fileId] = progress;
      }
    } catch (e) {
      debugPrint(
        '[File] Error handling chunk $chunkIndex/$totalChunks for $fileName: $e',
      );
      _failDownload(fileId, e.toString());
    }
  }

  void _sendFileDownloadAck(
    String fileId,
    String? transferToken,
    int receivedBytes,
  ) {
    final msg = {
      'type': 'file_download_ack',
      'fileId': fileId,
      if (transferToken != null && transferToken.isNotEmpty)
        'transferToken': transferToken,
      'receivedBytes': receivedBytes,
    };
    final serverId = _downloadServerIds[fileId];
    if (serverId != null && serverId.isNotEmpty) {
      _connMgr.sendToServer(serverId, msg);
    } else {
      _ws.send(msg);
    }
  }

  /// Handle file transfer complete (chunked transfer)
  Future<void> _handleFileComplete(Map<String, dynamic> msg) async {
    final fileId =
        msg['fileId'] as String? ?? msg['fileName'] as String? ?? 'file';
    final fileName = msg['fileName'] as String? ?? 'file';
    final fileSize = (msg['fileSize'] as num?)?.toInt();
    final transferToken = msg['transferToken'] as String?;
    final fileVersion = msg['fileVersion'] as String?;

    try {
      final expectedToken = _socketDownloadTokens[fileId];
      if (expectedToken != null &&
          transferToken != null &&
          transferToken != expectedToken) {
        debugPrint(
          '[File] Ignoring stale completion for $fileId token=$transferToken',
        );
        return;
      }
      final byteCompleter = _fileBytesCompleters.remove(fileId);
      if (byteCompleter != null) {
        final bytes = _fileBytesBuffers.remove(fileId)?.takeBytes();
        _downloadReceivedBytes.remove(fileId);
        _downloadServerIds.remove(fileId);
        if (!byteCompleter.isCompleted) {
          byteCompleter.complete(bytes == null ? null : base64Encode(bytes));
        }
        return;
      }
      if (!_downloadingFiles.contains(fileId)) {
        debugPrint('[File] Ignoring stale completion for $fileId');
        return;
      }
      if (fileVersion != null && fileVersion.isNotEmpty) {
        _serverFileVersions[fileId] = fileVersion;
      }

      // Close the temp file
      final sink = _activeDownloads.remove(fileId);
      await sink?.flush();
      await sink?.close();
      _lastNotifiedProgress.remove(fileId);
      _downloadReceivedBytes.remove(fileId);
      _cancelDownloadWatchdog(fileId);

      final tempPath = _downloadTempPaths.remove(fileId);
      if (tempPath == null) {
        debugPrint('[File] Error: no temp path for $fileId');
        _downloadingFiles.remove(fileId);
        _downloadProgress.remove(fileId);
        _downloadErrors[fileId] = 'Transfer completed without a temp file';
        _showDownloadFailedNotification(
          fileId,
          'Transfer completed without a temp file',
        );
        notifyListeners();
        return;
      }

      final tempFile = File(tempPath);
      if (!tempFile.existsSync()) {
        debugPrint('[File] Error: temp file missing at $tempPath');
        _downloadingFiles.remove(fileId);
        _downloadProgress.remove(fileId);
        _downloadErrors[fileId] = 'Downloaded temp file is missing';
        _showDownloadFailedNotification(
          fileId,
          'Downloaded temp file is missing',
        );
        notifyListeners();
        return;
      }
      final expectedBytes = fileSize ?? _downloadExpectedBytes[fileId];
      final savedBytes = await tempFile.length();
      if (expectedBytes != null &&
          expectedBytes > 0 &&
          savedBytes != expectedBytes) {
        debugPrint(
          '[File] Error: size mismatch for $fileId ($savedBytes/$expectedBytes)',
        );
        try {
          await tempFile.delete();
        } catch (_) {}
        _downloadingFiles.remove(fileId);
        _downloadProgress.remove(fileId);
        _downloadExpectedBytes.remove(fileId);
        _downloadErrors[fileId] =
            'Downloaded ${_formatDownloadBytes(savedBytes)} / ${_formatDownloadBytes(expectedBytes)}';
        _showDownloadFailedNotification(fileId, _downloadErrors[fileId]!);
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
      _downloadErrors.remove(fileId);
      _downloadRetryCounts.remove(fileId);
      _downloadExpectedBytes.remove(fileId);
      _socketDownloadTokens.remove(fileId);
      _showDownloadFinishedNotification(fileId, fileName);
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
      _downloadReceivedBytes.remove(fileId);
      _downloadExpectedBytes.remove(fileId);
      _socketDownloadTokens.remove(fileId);
      _downloadErrors[fileId] = e.toString();
      _cancelDownloadWatchdog(fileId);
      _showDownloadFailedNotification(fileId, e.toString());
      notifyListeners();
    }
  }

  void _handleFileError(Map<String, dynamic> msg) {
    final fileId = msg['fileId'] as String? ?? '';
    if (fileId.isEmpty) return;
    final transferToken = msg['transferToken'] as String?;
    final expectedToken = _socketDownloadTokens[fileId];
    if (expectedToken != null &&
        transferToken != null &&
        transferToken != expectedToken) {
      debugPrint(
        '[File] Ignoring stale error for $fileId token=$transferToken',
      );
      return;
    }

    final byteCompleter = _fileBytesCompleters.remove(fileId);
    if (byteCompleter != null) {
      _fileBytesBuffers.remove(fileId);
      if (!byteCompleter.isCompleted) byteCompleter.complete(null);
      return;
    }

    if (_downloadingFiles.contains(fileId)) {
      _failDownload(
        fileId,
        msg['message'] as String? ?? 'File download failed',
        deleteTemp: false,
      );
    }
  }

  String _stableFileTransferId(String path) {
    var hash = 0x811c9dc5;
    for (final unit in path.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return 'fm_${hash.toRadixString(16).padLeft(8, '0')}';
  }

  String _safeDownloadTempId(String fileId) {
    var hash = 0x811c9dc5;
    for (final unit in fileId.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  int _downloadNotificationId(String fileId) {
    return NotificationService.stableId('download:$fileId');
  }

  String _downloadNotificationPayload(String fileId) {
    final payload = <String, String>{
      'fileId': fileId,
      if (_receivedFiles[fileId]?.isNotEmpty == true)
        'localPath': _receivedFiles[fileId]!,
      if (_serverFiles[fileId]?.isNotEmpty == true)
        'serverPath': _serverFiles[fileId]!,
      if (_serverFileNames[fileId]?.isNotEmpty == true)
        'fileName': _serverFileNames[fileId]!,
      if (_downloadSessionIds[fileId]?.isNotEmpty == true)
        'sessionId': _downloadSessionIds[fileId]!,
      if (_downloadServerIds[fileId]?.isNotEmpty == true)
        'serverId': _downloadServerIds[fileId]!,
    };
    return 'download:${Uri.encodeComponent(jsonEncode(payload))}';
  }

  List<AndroidNotificationAction> _downloadProgressActions() {
    return const [
      AndroidNotificationAction(
        _downloadActionCancel,
        'Cancel',
        showsUserInterface: true,
        cancelNotification: true,
      ),
    ];
  }

  List<AndroidNotificationAction> _downloadFailedActions() {
    return const [
      AndroidNotificationAction(
        _downloadActionRetry,
        'Retry',
        showsUserInterface: true,
      ),
      AndroidNotificationAction(
        _downloadActionDismiss,
        'Dismiss',
        showsUserInterface: true,
        cancelNotification: true,
      ),
    ];
  }

  List<AndroidNotificationAction> _downloadFinishedActions(String fileId) {
    return [
      if (_downloadSessionIds[fileId]?.isNotEmpty == true)
        const AndroidNotificationAction(
          _downloadActionOpenSession,
          'Open session',
          showsUserInterface: true,
        ),
      const AndroidNotificationAction(
        _downloadActionOpenFile,
        'Open file',
        showsUserInterface: true,
      ),
    ];
  }

  void _showDownloadProgressNotification(
    String fileId,
    String fileName,
    double? progress,
  ) {
    _pendingDownloadNotifications[fileId] = _DownloadProgressNotification(
      fileId: fileId,
      fileName: fileName,
      progress: progress,
    );

    final now = DateTime.now();
    final lastShownAt = _downloadNotificationLastShownAt[fileId];
    final shouldFlushNow =
        lastShownAt == null ||
        (progress != null && progress >= 1.0) ||
        now.difference(lastShownAt) >= _downloadNotificationMinInterval;

    if (shouldFlushNow) {
      _flushDownloadProgressNotification(fileId);
      return;
    }

    if (_downloadNotificationTimers.containsKey(fileId)) return;
    final delay =
        _downloadNotificationMinInterval - now.difference(lastShownAt);
    _downloadNotificationTimers[fileId] = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => _flushDownloadProgressNotification(fileId),
    );
  }

  void _flushDownloadProgressNotification(String fileId) {
    _downloadNotificationTimers.remove(fileId)?.cancel();
    final update = _pendingDownloadNotifications.remove(fileId);
    if (update == null) return;
    _downloadNotificationLastShownAt[fileId] = DateTime.now();
    final progress = update.progress;
    unawaited(
      _notifications.showOngoingProgress(
        id: _downloadNotificationId(update.fileId),
        title: 'Downloading ${update.fileName}',
        body: progress == null
            ? 'Download in progress'
            : '${NotificationService.progressPercent(progress)}% complete',
        progress: progress,
        indeterminate: progress == null,
        payload: _downloadNotificationPayload(update.fileId),
        actions: _downloadProgressActions(),
      ),
    );
  }

  void _clearDownloadProgressNotification(String fileId) {
    _downloadNotificationTimers.remove(fileId)?.cancel();
    _pendingDownloadNotifications.remove(fileId);
    _downloadNotificationLastShownAt.remove(fileId);
  }

  void _showDownloadFinishedNotification(String fileId, String fileName) {
    _clearDownloadProgressNotification(fileId);
    unawaited(
      _notifications.showInstant(
        id: _downloadNotificationId(fileId),
        title: 'Download complete',
        body: fileName,
        payload: _downloadNotificationPayload(fileId),
        actions: _downloadFinishedActions(fileId),
      ),
    );
  }

  void _showDownloadFailedNotification(String fileId, String error) {
    _clearDownloadProgressNotification(fileId);
    unawaited(
      _notifications.showInstant(
        id: _downloadNotificationId(fileId),
        title: 'Download failed',
        body: error,
        payload: _downloadNotificationPayload(fileId),
        actions: _downloadFailedActions(),
      ),
    );
  }

  void _armDownloadWatchdog(String fileId) {
    _downloadWatchdogs[fileId]?.cancel();
    _downloadWatchdogs[fileId] = Timer(const Duration(seconds: 15), () {
      if (!_downloadingFiles.contains(fileId)) return;
      _retrySocketFileDownload(fileId, 'Transfer stalled.');
    });
  }

  void _cancelDownloadWatchdog(String fileId) {
    _downloadWatchdogs.remove(fileId)?.cancel();
  }

  Future<void> _cleanupActiveDownload(
    String fileId, {
    bool deleteTemp = false,
  }) async {
    _cancelDownloadWatchdog(fileId);
    _lastNotifiedProgress.remove(fileId);
    _clearDownloadProgressNotification(fileId);
    _downloadReceivedBytes.remove(fileId);
    _downloadExpectedBytes.remove(fileId);
    _socketDownloadTokens.remove(fileId);
    _downloadingFiles.remove(fileId);
    _downloadProgress.remove(fileId);
    final sink = _activeDownloads.remove(fileId);
    try {
      await sink?.flush();
      await sink?.close();
    } catch (_) {}
    final tempPath = _downloadTempPaths.remove(fileId);
    if (deleteTemp && tempPath != null) {
      try {
        final tempFile = File(tempPath);
        if (tempFile.existsSync()) await tempFile.delete();
      } catch (_) {}
    }
  }

  void _retrySocketFileDownload(String fileId, String error) {
    final serverPath = _serverFiles[fileId];
    if (serverPath == null || serverPath.isEmpty) {
      _failDownload(fileId, '$error Tap download to retry.', deleteTemp: false);
      return;
    }
    final retryCount = (_downloadRetryCounts[fileId] ?? 0) + 1;
    if (retryCount > 5) {
      _failDownload(fileId, '$error Tap retry to resume.', deleteTemp: false);
      return;
    }
    _downloadRetryCounts[fileId] = retryCount;
    _cancelDownloadWatchdog(fileId);
    _socketDownloadTokens[fileId] =
        'retrying_${DateTime.now().microsecondsSinceEpoch}_$retryCount';
    final sink = _activeDownloads.remove(fileId);
    unawaited(() async {
      try {
        await sink?.flush();
        await sink?.close();
      } catch (_) {}
      if (!_serverFiles.containsKey(fileId)) return;
      _downloadingFiles.add(fileId);
      _downloadErrors[fileId] = '$error Retrying...';
      notifyListeners();
      final delaySeconds = retryCount < 4 ? retryCount * 2 : 8;
      await Future.delayed(Duration(seconds: delaySeconds));
      if (!_downloadingFiles.contains(fileId)) return;
      await _requestSocketFileDownload(
        fileId,
        serverPath,
        serverId: _downloadServerIds[fileId],
      );
    }());
  }

  void _failDownload(String fileId, String error, {bool deleteTemp = true}) {
    _cleanupActiveDownload(fileId, deleteTemp: deleteTemp);
    _downloadErrors[fileId] = error;
    _showDownloadFailedNotification(fileId, error);
    notifyListeners();
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
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PushNotificationService.onTokenRefresh = null;
    PushNotificationService.shouldDisplayForegroundNotification = null;
    _promptRuntimeTimer?.cancel();
    for (final pending in _pendingHardStops.values) {
      pending.retryTimer?.cancel();
    }
    _pendingHardStops.clear();
    _initialHistoryTimeout?.cancel();
    _foregroundResumeTimer?.cancel();
    _secretInventoryRequestTracker.cancel();
    _htmlPlanListTimeout?.cancel();
    _messageSub?.cancel();
    _statusSub?.cancel();
    _speechResultSub?.cancel();
    _speechStatusSub?.cancel();
    for (final timer in _downloadWatchdogs.values) {
      timer.cancel();
    }
    _downloadWatchdogs.clear();
    for (final timer in _backendInstallAckTimers.values) {
      timer.cancel();
    }
    _backendInstallAckTimers.clear();
    for (final timer in _scheduledTaskRefreshRetries.values) {
      timer.cancel();
    }
    _scheduledTaskRefreshRetries.clear();
    for (final completer in _adbBridgeSidecarCompleters.values) {
      if (!completer.isCompleted) {
        completer.complete(<String, dynamic>{
          'running': false,
          'error': 'SocketAgent app is closing.',
        });
      }
    }
    _adbBridgeSidecarCompleters.clear();
    for (final completer in _adbCommandCompleters.values) {
      if (!completer.isCompleted) {
        completer.complete(<String, dynamic>{
          'ok': false,
          'message': 'SocketAgent app is closing.',
        });
      }
    }
    _adbCommandCompleters.clear();
    for (final requestId in _phoneAdbFileTransfers.keys.toList()) {
      _failPhoneAdbTransfer(requestId, 'SocketAgent app is closing.');
    }
    _connMgr.dispose();
    _speech.dispose();
    _tts.dispose();
    _subscriptionRequiredController.close();
    _backendAuthRequiredController.close();
    _terminalEvents.close();
    super.dispose();
  }
}

/// Per-upload runtime state. Tracks how many chunks the server has confirmed
/// receiving (used as a backpressure ack signal in the upload loop) and runs a
/// stall timer that fires the supplied callback if no progress event arrives
/// for 60s.
class _UploadState {
  _UploadState({
    required this.target,
    required this.onStall,
    this.progressBase = 0,
    this.progressSpan = 1,
  });

  final ChatMessage target;
  final void Function() onStall;
  final double progressBase;
  final double progressSpan;

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
