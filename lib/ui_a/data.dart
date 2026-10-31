import 'package:flutter/foundation.dart';

import '../models/composer_attachment.dart';
import '../models/computer_access.dart';
import '../models/device_registry.dart';
import '../models/message.dart';
import '../services/websocket_service.dart';

export '../models/message.dart';
export '../services/websocket_service.dart' show ConnectionStatus;

/// One saved computer as Tower shows it.
@immutable
class TowerComputer {
  const TowerComputer({
    required this.id,
    required this.name,
    required this.status,
    this.color,
    this.expectedOnline = false,
    this.relay = false,
    this.pushRegistered = false,
  });

  final String id;
  final String name;
  final ConnectionStatus status;
  final int? color;
  final bool expectedOnline;
  final bool relay;
  final bool pushRegistered;

  bool get online => status == ConnectionStatus.connected;
}

/// What a session's agent is doing, as far as this device knows.
enum Live { running, compacting, idle }

/// Kinds of thing an agent can block on.
enum WaitKind { question, approval, secret, access, signIn, device, review }

/// One item blocking on the user. Built by [collectWaits] from live data.
@immutable
class TowerWait {
  const TowerWait({
    required this.kind,
    required this.id,
    required this.title,
    this.detail = '',
    this.sessionId,
    this.serverId,
    this.message,
    this.device,
    this.since,
    this.expiresAt,
  });

  final WaitKind kind;
  final String id;
  final String title;
  final String detail;
  final String? sessionId;
  final String? serverId;

  /// The transcript card behind the wait, for session-scoped kinds.
  final ChatMessage? message;

  /// The pairing device, for [WaitKind.device].
  final PendingDevice? device;
  final DateTime? since;
  final DateTime? expiresAt;
}

/// Delivery priority for a message sent while the agent works.
enum Priority { now, next, later }

/// Everything Tower reads and does. [ProviderTowerData] backs it with the
/// app's ChatProvider; tests back it with fixed data.
///
/// "Open" members describe the one session the app currently has loaded.
/// The app streams only that session in full; the rest of the fleet is known
/// through the session list and status updates.
abstract class TowerData extends ChangeNotifier {
  // Fleet
  List<TowerComputer> get computers;
  List<Session> get sessions;
  Live liveOf(Session session);
  DateTime? runStartedAt(Session session);

  /// A run finished after the user last opened this session here.
  bool hasUnread(Session session);
  bool isPinned(Session session);
  bool isMuted(Session session);
  void togglePin(Session session);
  void toggleMute(Session session);
  TowerComputer? computerOf(Session session) =>
      computers.where((c) => c.id == session.serverId).firstOrNull;

  List<PendingDevice> get pendingDevices;
  Future<void> approveDevice(PendingDevice device);
  Future<void> denyDevice(PendingDevice device);

  List<Map<String, dynamic>> get scheduledTasks;
  int get unreadScheduledTaskCount;
  void runScheduledTask(String taskId);
  void markScheduledTaskRead(String taskId);

  // Open session
  String? get openSessionId;
  String? get openServerId;
  Session? get openSession => sessions
      .where(
        (s) =>
            s.id == openSessionId &&
            (openServerId == null || s.serverId == openServerId),
      )
      .firstOrNull;

  /// A new session whose first prompt has not been sent.
  bool get isDraftSession;
  String? get openTitle;
  String? get openCwd;
  String? get openBackend;
  bool get openOffline;
  List<ChatMessage> get messages;
  bool get isProcessing;
  bool get isCompacting;
  DateTime? get openRunStartedAt;
  bool get hasMoreHistory;
  bool get isLoadingHistory;
  void loadMoreHistory();
  List<String> get promptSuggestions;
  List<Map<String, dynamic>> get slashCommands;

  /// Background commands, sub-agents and workflows, keyed by id. Each value
  /// carries `_kind`: bash, subagent or workflow.
  Map<String, Map<String, dynamic>> get tasks;
  List<Map<String, dynamic>> get todos;
  Map<String, dynamic>? get contextUsage;
  bool get condensedTools;
  void setCondensedTools(bool value);

  String? get permissionMode;
  String? get model;
  String get effort;
  List<Map<String, dynamic>> get models;
  List<String> get effortLevels;
  void setModel(String model);
  void setEffort(String effort);
  void setPermissionMode(String mode);

  // Actions on the open session
  void open(Session session);
  void closeOpen();
  void startDraft({
    required String serverId,
    required String backend,
    String? cwd,
    bool fleeting = false,
  });
  Future<bool> send(String text, {Priority? priority});
  String? retract(String messageId);
  Future<void> stop();
  void interrupt();
  void stopTask(String taskId);
  void backgroundTask(String toolUseId);
  bool get canBackgroundTasks;
  /// Hides a finished sub-agent or workflow on every device.
  void dismissTask(String id, String kind);
  void requestFullOutput(ChatMessage message);
  void compact();

  String draft();
  void saveDraft(String text);
  List<PendingFileAttachment> get fileAttachments;
  List<PendingSecretAttachment> get secretAttachments;
  Future<void> pickFiles({bool images = false});
  void removeFile(String id);
  void removeSecret(String id);

  Future<void> answerQuestion(String questionId, Map<String, String> answers);
  void submitSecret(String requestId, String value);
  void cancelSecret(String requestId);
  void useStoredSecret(String requestId, SecretMetadata secret);
  List<SecretMetadata> get storedSecrets;
  Future<void> answerAccess(
    String requestId,
    String decision, {
    ComputerAccess? access,
  });

  // Session management
  void rename(Session session, String title);
  void archive(Session session);
  void delete(Session session);
  void makePermanent(Session session);

  // Starting sessions
  List<String> backendsFor(String serverId);
  List<String> recentFolders(String serverId);

  /// Asks the computer for its recent folders; [recentFolders] updates.
  void refreshFolders(String serverId);
  String defaultFolder(String serverId);
}

/// Everything in [data] that waits on the user, oldest first. Only the open
/// session's transcript is known in full, so session-scoped waits come from
/// it; device approvals come from every computer.
List<TowerWait> collectWaits(TowerData data) {
  final waits = <TowerWait>[];
  final sid = data.openSessionId;
  final server = data.openServerId;
  final now = DateTime.now();
  for (final m in data.messages) {
    switch (m.type) {
      case MessageType.question when !m.answered && !m.expired:
        final first = m.questions?.firstOrNull;
        final approval =
            m.toolInput?['kind'] == 'approval' ||
            (first?.header?.toLowerCase().contains('approv') ?? false);
        waits.add(
          TowerWait(
            kind: approval ? WaitKind.approval : WaitKind.question,
            id: m.questionId ?? m.id,
            title: first?.question ?? 'Question',
            detail: (m.questions?.length ?? 0) > 1
                ? '${m.questions!.length} questions'
                : first?.header ?? '',
            sessionId: sid,
            serverId: server,
            message: m,
            since: m.timestamp,
          ),
        );
      case MessageType.secureInput
          when !m.answered && (m.toolInput?['status'] ?? 'pending') == 'pending':
        waits.add(
          TowerWait(
            kind: WaitKind.secret,
            id: m.questionId ?? m.id,
            title: m.toolInput?['label']?.toString() ?? 'Secret',
            detail: m.textContent,
            sessionId: sid,
            serverId: server,
            message: m,
            since: m.timestamp,
          ),
        );
      case MessageType.computerAccess:
        final request = ComputerAccessRequest.fromJson(m.toolInput);
        if (request == null || !request.pending || request.isExpired(now)) {
          break;
        }
        waits.add(
          TowerWait(
            kind: WaitKind.access,
            id: request.requestId,
            title: request.isLink
                ? '${request.askerLabel} wants a link to ${request.targetName}'
                : '${request.askerLabel}: ${request.actionLabel} on ${request.targetName}',
            detail: request.isLink ? request.reason : request.summary,
            sessionId: sid,
            serverId: server,
            message: m,
            since: m.timestamp,
            expiresAt: request.expiresAt > 0
                ? DateTime.fromMillisecondsSinceEpoch(request.expiresAt)
                : null,
          ),
        );
      case MessageType.elicitationUrl when !m.answered && !m.expired:
        waits.add(
          TowerWait(
            kind: WaitKind.signIn,
            id: m.questionId ?? m.id,
            title: 'Sign in to ${m.toolName ?? 'app'}',
            detail: m.textContent,
            sessionId: sid,
            serverId: server,
            message: m,
            since: m.timestamp,
          ),
        );
      case MessageType.backendAuth ||
          MessageType.claudeAuth ||
          MessageType.outlookAuth ||
          MessageType.ibsAuth when !m.answered && !m.expired:
        waits.add(
          TowerWait(
            kind: WaitKind.signIn,
            id: m.id,
            title: switch (m.type) {
              MessageType.outlookAuth => 'Outlook sign-in',
              MessageType.ibsAuth => 'IBS sign-in',
              _ => '${m.toolName ?? 'Harness'} sign-in',
            },
            detail: m.textContent,
            sessionId: sid,
            serverId: server,
            message: m,
            since: m.timestamp,
          ),
        );
      default:
        break;
    }
  }
  for (final device in data.pendingDevices) {
    waits.add(
      TowerWait(
        kind: WaitKind.device,
        id: '${device.serverId}:${device.publicKey}',
        title: '${device.name} wants to pair',
        detail: 'Code ${device.code}',
        serverId: device.serverId,
        device: device,
      ),
    );
  }
  return waits;
}
