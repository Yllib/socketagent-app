import 'dart:async';

import 'package:flutter/material.dart';

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

  /// Reports the outcome of a save. The computer's
  /// `scheduled_task_save_result` for [requestId] decides it, including a
  /// refusal with its reason. Servers from before that message only show the
  /// result in their task list, so a new list revision carrying a task that
  /// fits [match] also counts. With neither, it times out.
  void trackSave(
    ChatProvider provider, {
    required String serverId,
    required String label,
    required bool Function(ScheduledTaskView task) match,
    String? requestId,
  }) {
    final computer = computerNameFor(provider, serverId);
    show('Saving "$label" on $computer', kind: TaskNoticeKind.pending);
    late final _PendingSave pending;
    pending = _PendingSave(
      provider: provider,
      serverId: serverId,
      revisionAtSave: provider.scheduledTaskRevision(serverId),
      match: match,
      requestId: requestId,
      onConfirmed: () {
        _pending.remove(pending);
        show('Saved "$label" on $computer');
      },
      onRefused: (error) {
        _pending.remove(pending);
        show(
          '$computer did not save "$label": $error',
          kind: TaskNoticeKind.error,
        );
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
    required this.requestId,
    required this.onConfirmed,
    required this.onRefused,
    required this.onTimeout,
    required Duration timeout,
  }) {
    provider.addListener(_check);
    if (requestId != null) {
      _results = provider.scheduledTaskSaveResults
          .where((r) => r.requestId == requestId)
          .listen((result) {
            final error = result.error;
            cancel();
            if (error == null) {
              onConfirmed();
            } else {
              onRefused(error);
            }
          });
    }
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
  final String? requestId;
  final VoidCallback onConfirmed;
  final void Function(String error) onRefused;
  final VoidCallback onTimeout;
  late final Timer _timer;
  StreamSubscription<ScheduledTaskSaveResult>? _results;
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
    unawaited(_results?.cancel());
    provider.removeListener(_check);
  }
}

/// The shared strip state. One per app, like the provider it binds to.
final tasksFeedback = TasksFeedback();

/// Follows a save started outside the Tasks screens, which have no feedback
/// strip, in a snack bar that updates from saving to saved or refused.
void showTaskSaveSnackBar(BuildContext context) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 8),
      content: ListenableBuilder(
        listenable: tasksFeedback,
        builder: (_, _) => Text(tasksFeedback.current?.text ?? ''),
      ),
    ),
  );
}

/// The configured name of a computer, or a short id when it is gone.
String computerNameFor(ChatProvider provider, String serverId) {
  final config = provider.serverConfigs
      .where((c) => c.id == serverId)
      .firstOrNull;
  if (config != null && config.name.trim().isNotEmpty) return config.name;
  return serverId.isEmpty ? 'this computer' : serverId;
}
