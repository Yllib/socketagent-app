import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/composer_attachment.dart';
import '../../models/device_registry.dart' show PendingDevice;
import '../../models/message.dart';
import '../../services/chat_provider.dart';
import '../../ui_variant.dart';
import '../model/actions.dart';
import '../model/session_model.dart';

/// Every user action in this interface, forwarded to ChatProvider. The shell
/// sets [navigate] so opening a session also shows it.
class LiveActions implements UiBActions {
  LiveActions(this.p, this.variant);
  final ChatProvider p;
  final UiVariantController variant;

  void Function(String serverId, String sessionId, {String? entryId})? navigate;
  VoidCallback? onNewSession;

  @override
  void openSession(String serverId, String sessionId, {String? entryId}) {
    final sid = serverId.isEmpty ? null : serverId;
    if (p.activeSessionId != sessionId ||
        (sid != null && p.activeSessionServerId != sid)) {
      p.resumeSession(sessionId, serverId: sid);
    }
    navigate?.call(serverId, sessionId, entryId: entryId);
  }

  @override
  void startNewSession({
    String? serverId,
    String? backend,
    String? cwd,
    bool fleeting = false,
  }) {
    p.createNewSession(
      cwd: cwd,
      serverId: serverId,
      backend: backend,
      fleeting: fleeting,
    );
    onNewSession?.call();
  }

  @override
  void setVariant(UiVariant v) => variant.setVariant(v);

  @override
  void requestSessionList() => p.requestSessionList();

  @override
  Future<bool> send(String text, {String? priority}) =>
      p.sendPrompt(text, priority: priority);

  @override
  Future<void> stop() => p.abortQuery();

  @override
  void interrupt() => p.interruptQuery();

  @override
  void saveDraft(String text) => p.saveDraft(text);

  @override
  Future<void> pickFiles({bool imagesOnly = false}) =>
      p.pickFiles(imagesOnly: imagesOnly);

  @override
  void removeAttachment(String id) => p.removeFileAttachment(id);

  @override
  void removeSecretAttachment(String id) => p.removeSecretAttachment(id);

  @override
  void attachStoredSecret(SecretMetadata secret) =>
      p.attachStoredSecret(secret);

  @override
  void retractQueued(String messageId) => p.retractQueuedMessage(messageId);

  @override
  void toggleDictation() => p.toggleListening();

  @override
  void clearSuggestions() => p.clearPromptSuggestions();

  @override
  Future<void> answerQuestion(String questionId, Map<String, String> answers) =>
      p.answerQuestion(questionId, answers);

  @override
  void submitSecret(String requestId, String value) =>
      p.submitSecureInput(requestId, value);

  @override
  void useStoredSecret(String requestId, SecretMetadata secret) =>
      p.submitStoredSecureInput(requestId, secret);

  @override
  void cancelSecret(String requestId) => p.cancelSecureInput(requestId);

  @override
  Future<void> answerAccess(String requestId, String decision) =>
      p.answerComputerAccess(requestId, decision);

  @override
  Future<void> approveDevice(PendingDevice device) => p.approveDevice(device);

  @override
  Future<void> denyDevice(PendingDevice device) => p.denyDevice(device);

  @override
  Future<void> discardDelivery(String id) => p.discardOutgoing(id);

  @override
  void openUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  void togglePin(String sessionId) => p.toggleSessionPin(sessionId);

  @override
  void toggleMute(String sessionId) => p.toggleSessionNotifications(sessionId);

  @override
  void rename(String sessionId, String title) =>
      p.renameSession(sessionId, title);

  @override
  void archive(String serverId, String sessionId) =>
      p.archiveSession(sessionId, serverId: serverId.isEmpty ? null : serverId);

  @override
  void delete(String serverId, String sessionId) =>
      p.deleteSession(sessionId, serverId: serverId.isEmpty ? null : serverId);

  @override
  void makePermanent(String serverId, String sessionId) =>
      p.makeSessionPermanent(
        sessionId,
        serverId: serverId.isEmpty ? null : serverId,
      );

  @override
  void setPermissionMode(String mode) => p.setPermissionMode(mode);

  @override
  void setModel(String? model) => p.setModel(model);

  @override
  void setEffort(String effort) => p.setEffort(effort);

  @override
  void compact(String sessionId) {
    if (p.activeSessionBackend == 'codex') {
      p.compactCodexThread(sessionId);
    } else {
      p.sendPrompt('/compact');
    }
  }

  @override
  void clearContext(String sessionId) => p.clearSessionContext(sessionId);

  @override
  void rollback(String sessionId, int turns) =>
      p.rollbackCodexThread(sessionId, numTurns: turns);

  @override
  void loadMoreHistory() => p.loadMoreHistory();

  @override
  void requestFullOutput(ChatMessage message) => p.requestFullOutput(message);

  @override
  void dismissTask(TaskItem task) {
    switch (task.kind) {
      case TaskKind.workflow:
        p.dismissWorkflow(task.id);
      case TaskKind.subagent:
      case TaskKind.delegated:
        p.dismissSubagent(task.id);
      case TaskKind.background:
      case TaskKind.monitor:
        p.dismissTasks([task.id]);
    }
  }

  @override
  void stopTask(TaskItem task) => p.stopTask(task.id);

  @override
  void backgroundTask(String toolUseId) => p.backgroundTask(toolUseId);

  @override
  void dismissPlan() => p.dismissTodos();

  @override
  void setCondensed(bool value) => p.setCondensedToolUsage(value);

  @override
  void runAutomation(String serverId, String taskId) =>
      p.executeScheduledTask(taskId);

  @override
  void markAutomationRead(String serverId, String taskId, {bool read = true}) =>
      p.markScheduledTaskRead(
        taskId,
        read: read,
        serverId: serverId.isEmpty ? null : serverId,
      );

  @override
  void cancelAutomation(String serverId, String taskId) =>
      p.cancelScheduledTask(taskId);

  @override
  void archiveAutomation(String serverId, String taskId) =>
      p.archiveScheduledTask(taskId);

  @override
  void reconnectComputer(String serverId) =>
      p.connMgr.reconnectServer(serverId);

  @override
  void registerPush(String serverId) =>
      p.registerPushNotificationsForServer(serverId);
}
