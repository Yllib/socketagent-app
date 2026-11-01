import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/chat_provider.dart';
import 'task_model.dart';

enum TaskNoticeKind { pending, success, error }

/// One line of feedback for the Tasks screens: a save in flight, a confirmed
/// save, a refused action or a server error. [action] is an optional undo.
class TaskNotice {
  const TaskNotice(this.text, this.kind, {this.actionLabel, this.onAction});

  final String text;
  final TaskNoticeKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;
}

/// The feedback strip's state, shared by the fleet view, the session view
/// and the editor so a save started in one shows its outcome wherever the
/// user is. Success and pending notices clear themselves; errors stay until
/// replaced or dismissed.
class TasksFeedback extends ChangeNotifier {
  TaskNotice? _current;
  Timer? _clear;
  ChatProvider? _boundProvider;
  StreamSubscription<ScheduledTaskError>? _errors;
  final List<_PendingSave> _pending = [];

  TaskNotice? get current => _current;

  static const _successLinger = Duration(seconds: 6);
  static const _saveTimeout = Duration(seconds: 12);

  void show(
    String text, {
    TaskNoticeKind kind = TaskNoticeKind.success,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    _clear?.cancel();
    _current = TaskNotice(
      text,
      kind,
      actionLabel: actionLabel,
      onAction: onAction,
    );
    if (kind == TaskNoticeKind.success) {
      _clear = Timer(_successLinger, dismiss);
    }
    notifyListeners();
  }

  void dismiss() {
    _clear?.cancel();
    _clear = null;
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }

  /// Routes the provider's scheduled-task errors into the strip. Safe to call
  /// on every build; only the first call per provider subscribes.
  void bind(ChatProvider provider) {
    if (identical(_boundProvider, provider)) return;
    _errors?.cancel();
    _boundProvider = provider;
    _errors = provider.scheduledTaskErrors.listen((error) {
      final computer = error.serverId == null
          ? null
          : computerNameFor(provider, error.serverId!);
      show(
        computer == null ? error.message : '$computer: ${error.message}',
        kind: TaskNoticeKind.error,
      );
    });
  }

  /// Watches for [serverId]'s next list to carry a task matching [match].
  /// There is no save acknowledgement in the protocol, so this is the only
  /// confirmation: the list revision must move and the task must be there.
  /// Reports success or, after a timeout, that the computer never confirmed.
  void trackSave(
    ChatProvider provider, {
    required String serverId,
    required String label,
    required bool Function(ScheduledTaskView task) match,
  }) {
    final computer = computerNameFor(provider, serverId);
    show('Saving "$label" on $computer', kind: TaskNoticeKind.pending);
    late final _PendingSave pending;
    pending = _PendingSave(
      provider: provider,
      serverId: serverId,
      revisionAtSave: provider.scheduledTaskRevision(serverId),
      match: match,
      onConfirmed: () {
        _pending.remove(pending);
        show('Saved "$label" on $computer');
      },
      onTimeout: () {
        _pending.remove(pending);
        show(
          '$computer did not confirm saving "$label". Check its task list.',
          kind: TaskNoticeKind.error,
        );
      },
      timeout: _saveTimeout,
    );
    _pending.add(pending);
  }

  @visibleForTesting
  int get pendingSaveCount => _pending.length;

  /// Drops save watchers and their timeouts so a test can end cleanly.
  @visibleForTesting
  void cancelPendingSavesForTest() {
    for (final pending in List.of(_pending)) {
      pending.cancel();
    }
    _pending.clear();
  }

  @override
  void dispose() {
    _clear?.cancel();
    _errors?.cancel();
    for (final pending in List.of(_pending)) {
      pending.cancel();
    }
    super.dispose();
  }
}

class _PendingSave {
  _PendingSave({
    required this.provider,
    required this.serverId,
    required this.revisionAtSave,
    required this.match,
    required this.onConfirmed,
    required this.onTimeout,
    required Duration timeout,
  }) {
    provider.addListener(_check);
    _timer = Timer(timeout, () {
      cancel();
      onTimeout();
    });
    _check();
  }

  final ChatProvider provider;
  final String serverId;
  final String? revisionAtSave;
  final bool Function(ScheduledTaskView task) match;
  final VoidCallback onConfirmed;
  final VoidCallback onTimeout;
  late final Timer _timer;
  bool _done = false;

  void _check() {
    if (_done) return;
    final revision = provider.scheduledTaskRevision(serverId);
    if (revision == null || revision == revisionAtSave) return;
    final confirmed = parseScheduledTasks(
      provider.scheduledTasks,
    ).any((task) => task.serverId == serverId && match(task));
    if (!confirmed) return;
    cancel();
    onConfirmed();
  }

  void cancel() {
    if (_done) return;
    _done = true;
    _timer.cancel();
    provider.removeListener(_check);
  }
}

/// The shared strip state. One per app, like the provider it binds to.
final tasksFeedback = TasksFeedback();

/// The configured name of a computer, or a short id when it is gone.
String computerNameFor(ChatProvider provider, String serverId) {
  final config = provider.serverConfigs
      .where((c) => c.id == serverId)
      .firstOrNull;
  if (config != null && config.name.trim().isNotEmpty) return config.name;
  return serverId.isEmpty ? 'this computer' : serverId;
}
