import '../../models/composer_attachment.dart';
import '../../models/device_registry.dart';
import '../../models/message.dart';
import '../../ui_variant.dart';
import 'session_model.dart';

/// Everything interface B can ask the app to do. Screens call this and never
/// touch ChatProvider, so widget tests drive them with a recording fake.
abstract class UiBActions {
  // Navigation and sessions
  void openSession(String serverId, String sessionId, {String? entryId});
  void startNewSession({
    required String serverId,
    required String backend,
    String? cwd,
    bool fleeting = false,
  });
  void setVariant(UiVariant variant);
  void requestSessionList();

  // Talking
  Future<bool> send(String text, {String? priority});
  Future<void> stop();
  void interrupt();
  void saveDraft(String text);
  Future<void> pickFiles({bool imagesOnly = false});
  void removeAttachment(String id);
  void removeSecretAttachment(String id);
  void attachStoredSecret(SecretMetadata secret);
  void retractQueued(String messageId);
  void toggleDictation();
  void clearSuggestions();

  // Answering
  Future<void> answerQuestion(String questionId, Map<String, String> answers);
  void submitSecret(String requestId, String value);
  void useStoredSecret(String requestId, SecretMetadata secret);
  void cancelSecret(String requestId);
  Future<void> answerAccess(String requestId, String decision);
  Future<void> approveDevice(PendingDevice device);
  Future<void> denyDevice(PendingDevice device);
  Future<void> discardDelivery(String id);
  void openUrl(String url);

  // Session management
  void togglePin(String sessionId);
  void toggleMute(String sessionId);
  void rename(String sessionId, String title);
  void archive(String serverId, String sessionId);
  void delete(String serverId, String sessionId);
  void makePermanent(String serverId, String sessionId);
  void setPermissionMode(String mode);
  void setModel(String? model);
  void setEffort(String effort);
  void compact(String sessionId);
  void clearContext(String sessionId);
  void rollback(String sessionId, int turns);
  void loadMoreHistory();
  void requestFullOutput(ChatMessage message);
  void dismissTask(TaskItem task);
  void stopTask(TaskItem task);
  void backgroundTask(String toolUseId);
  void dismissPlan();
  void setCondensed(bool value);

  // Automations
  void runAutomation(String serverId, String taskId);
  void markAutomationRead(String serverId, String taskId, {bool read = true});
  void cancelAutomation(String serverId, String taskId);
  void archiveAutomation(String serverId, String taskId);

  // Computers
  void reconnectComputer(String serverId);
  void registerPush(String serverId);
}
