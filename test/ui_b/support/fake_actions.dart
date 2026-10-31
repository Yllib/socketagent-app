import 'package:app/models/composer_attachment.dart';
import 'package:app/models/device_registry.dart';
import 'package:app/models/message.dart';
import 'package:app/ui_b/model/actions.dart';
import 'package:app/ui_b/model/session_model.dart';
import 'package:app/ui_variant.dart';

/// Records every call as a line so tests assert on behaviour, not wiring.
class RecordingActions implements UiBActions {
  final List<String> log = [];
  void _r(String s) => log.add(s);

  @override
  void openSession(String serverId, String sessionId, {String? entryId}) =>
      _r('open $serverId/$sessionId');
  @override
  void startNewSession({
    required String serverId,
    required String backend,
    String? cwd,
    bool fleeting = false,
  }) => _r('new $serverId $backend $cwd fleeting=$fleeting');
  @override
  void setVariant(UiVariant variant) => _r('variant ${variant.name}');
  @override
  void requestSessionList() => _r('sessionList');
  @override
  Future<bool> send(String text, {String? priority}) async {
    _r('send[$priority] $text');
    return true;
  }

  @override
  Future<void> stop() async => _r('stop');
  @override
  void interrupt() => _r('interrupt');
  @override
  void saveDraft(String text) => _r('draft $text');
  @override
  Future<void> pickFiles({bool imagesOnly = false}) async => _r('pick');
  @override
  void removeAttachment(String id) => _r('removeAttachment $id');
  @override
  void removeSecretAttachment(String id) => _r('removeSecret $id');
  @override
  void attachStoredSecret(SecretMetadata secret) =>
      _r('attach ${secret.label}');
  @override
  void retractQueued(String messageId) => _r('retract $messageId');
  @override
  void toggleDictation() => _r('dictate');
  @override
  void clearSuggestions() => _r('clearSuggestions');
  @override
  Future<void> answerQuestion(
    String questionId,
    Map<String, String> answers,
  ) async => _r('answer $questionId ${answers.values.join('|')}');
  @override
  void submitSecret(String requestId, String value) =>
      _r('secret $requestId len=${value.length}');
  @override
  void useStoredSecret(String requestId, SecretMetadata secret) =>
      _r('storedSecret $requestId ${secret.label}');
  @override
  void cancelSecret(String requestId) => _r('cancelSecret $requestId');
  @override
  Future<void> answerAccess(String requestId, String decision) async =>
      _r('access $requestId $decision');
  @override
  Future<void> approveDevice(PendingDevice device) async =>
      _r('approveDevice ${device.name}');
  @override
  Future<void> denyDevice(PendingDevice device) async =>
      _r('denyDevice ${device.name}');
  @override
  Future<void> discardDelivery(String id) async => _r('discard $id');
  @override
  void openUrl(String url) => _r('url $url');
  @override
  void togglePin(String sessionId) => _r('pin $sessionId');
  @override
  void toggleMute(String sessionId) => _r('mute $sessionId');
  @override
  void rename(String sessionId, String title) => _r('rename $sessionId $title');
  @override
  void archive(String serverId, String sessionId) => _r('archive $sessionId');
  @override
  void delete(String serverId, String sessionId) => _r('delete $sessionId');
  @override
  void makePermanent(String serverId, String sessionId) =>
      _r('permanent $sessionId');
  @override
  void setPermissionMode(String mode) => _r('permission $mode');
  @override
  void setModel(String? model) => _r('model $model');
  @override
  void setEffort(String effort) => _r('effort $effort');
  @override
  void compact(String sessionId) => _r('compact');
  @override
  void clearContext(String sessionId) => _r('clearContext');
  @override
  void rollback(String sessionId, int turns) => _r('rollback $turns');
  @override
  void loadMoreHistory() => _r('loadMore');
  @override
  void requestFullOutput(ChatMessage message) => _r('fullOutput ${message.id}');
  @override
  void dismissTask(TaskItem task) => _r('dismissTask ${task.id}');
  @override
  void stopTask(TaskItem task) => _r('stopTask ${task.id}');
  @override
  void backgroundTask(String toolUseId) => _r('background $toolUseId');
  @override
  void dismissPlan() => _r('dismissPlan');
  @override
  void setCondensed(bool value) => _r('condensed $value');
  @override
  void runAutomation(String serverId, String taskId) => _r('runTask $taskId');
  @override
  void markAutomationRead(String serverId, String taskId, {bool read = true}) =>
      _r('readTask $taskId $read');
  @override
  void cancelAutomation(String serverId, String taskId) =>
      _r('cancelTask $taskId');
  @override
  void archiveAutomation(String serverId, String taskId) =>
      _r('archiveTask $taskId');
  @override
  void reconnectComputer(String serverId) => _r('reconnect $serverId');
  @override
  void registerPush(String serverId) => _r('push $serverId');
}
