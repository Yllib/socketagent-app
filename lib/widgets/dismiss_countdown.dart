import 'dart:async';

import 'package:flutter/material.dart';

import '../config/app_palette.dart';

/// Delays dismissals so a mistaken tap can be cancelled. Items started
/// together count down together and expire in one [onExpire] call. Owned by a
/// State: call [dispose] from its dispose.
class DismissCountdown<T> {
  DismissCountdown({
    required this.onChanged,
    required this.onExpire,
    this.seconds = 3,
  });

  final VoidCallback onChanged;
  final void Function(List<T> ids) onExpire;
  final int seconds;
  final Map<T, _Batch<T>> _batches = {};

  /// Seconds left for [id], or null when it isn't being dismissed.
  int? remaining(T id) => _batches[id]?.remaining;

  bool get isEmpty => _batches.isEmpty;

  void start(Iterable<T> ids) {
    final fresh = ids.where((id) => !_batches.containsKey(id)).toSet();
    if (fresh.isEmpty) return;
    late final _Batch<T> batch;
    batch = _Batch(
      fresh,
      seconds,
      Timer.periodic(const Duration(seconds: 1), (_) => _tick(batch)),
    );
    for (final id in fresh) {
      _batches[id] = batch;
    }
    onChanged();
  }

  void cancel(Iterable<T> ids) {
    var changed = false;
    for (final id in ids.toList()) {
      final batch = _batches.remove(id);
      if (batch == null) continue;
      changed = true;
      batch.ids.remove(id);
      if (batch.ids.isEmpty) batch.timer.cancel();
    }
    if (changed) onChanged();
  }

  void cancelAll() => cancel(_batches.keys);

  void _tick(_Batch<T> batch) {
    batch.remaining--;
    if (batch.remaining > 0) {
      onChanged();
      return;
    }
    batch.timer.cancel();
    final ids = batch.ids.toList();
    for (final id in ids) {
      _batches.remove(id);
    }
    onChanged();
    onExpire(ids);
  }

  void dispose() {
    for (final batch in _batches.values.toSet()) {
      batch.timer.cancel();
    }
    _batches.clear();
  }
}

class _Batch<T> {
  _Batch(this.ids, this.remaining, this.timer);
  final Set<T> ids;
  int remaining;
  final Timer timer;
}

/// Red outline around a row that is counting down to dismissal.
class DismissingFrame extends StatelessWidget {
  const DismissingFrame({super.key, required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(6),
      border: Border.all(
        color: active ? context.palette.red : Colors.transparent,
      ),
    ),
    child: child,
  );
}

/// "Dismissing 3" with a Cancel button, in place of a row's dismiss button.
class DismissingControls extends StatelessWidget {
  const DismissingControls({
    super.key,
    required this.remaining,
    required this.onCancel,
  });
  final int remaining;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        'Dismissing $remaining',
        style: TextStyle(fontSize: 11, color: context.palette.red),
      ),
      TextButton(
        onPressed: onCancel,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 24),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
        child: const Text('Cancel', style: TextStyle(fontSize: 11)),
      ),
    ],
  );
}
