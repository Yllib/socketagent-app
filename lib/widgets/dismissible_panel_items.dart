import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

bool isFinishedPanelItem(String status) => const {
  'completed',
  'failed',
  'stopped',
  'cancelled',
  'canceled',
}.contains(status);

/// Display-only dismissals, isolated by computer, session and panel identity.
/// Reopened items become visible again. No commands are sent to the backend.
class DismissiblePanelItems extends StatefulWidget {
  const DismissiblePanelItems({
    super.key,
    required this.scope,
    required this.items,
    this.builder,
    this.undoBuilder,
  }) : assert((builder == null) != (undoBuilder == null));

  final List<String>? scope;
  final Map<String, String> items;
  final Widget Function(Set<String> dismissed, ValueChanged<String> dismiss)?
  builder;
  final Widget Function(
    Set<String> dismissed,
    ValueChanged<String> dismiss,
    Set<String> undoable,
    ValueChanged<String> undo,
  )?
  undoBuilder;

  @override
  State<DismissiblePanelItems> createState() => _DismissiblePanelItemsState();
}

class _DismissiblePanelItemsState extends State<DismissiblePanelItems> {
  final Set<String> _dismissed = {};
  final Map<String, Timer> _undoTimers = {};
  SharedPreferences? _preferences;
  String? get _key => widget.scope == null
      ? null
      : 'dismissed_panel_items_${jsonEncode(widget.scope)}';
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(DismissiblePanelItems oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (jsonEncode(oldWidget.scope) != jsonEncode(widget.scope)) {
      _cancelUndoTimers();
      _dismissed.clear();
      _preferences = null;
      _load();
    } else if (_reconcile()) {
      _save();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final key = _key;
    if (key == null) return;
    final preferences = await SharedPreferences.getInstance();
    if (!mounted || generation != _generation) return;
    setState(() {
      _preferences = preferences;
      _dismissed.addAll(preferences.getStringList(key) ?? []);
      _reconcile();
    });
    _save();
  }

  bool _reconcile() {
    final count = _dismissed.length;
    _dismissed.removeWhere(
      (id) => !isFinishedPanelItem(widget.items[id] ?? ''),
    );
    for (final id in _undoTimers.keys.toList()) {
      if (!_dismissed.contains(id)) _undoTimers.remove(id)?.cancel();
    }
    return count != _dismissed.length;
  }

  void _save() {
    final key = _key;
    if (key != null) _preferences?.setStringList(key, _dismissed.toList());
  }

  void _dismiss(String id) {
    if (!isFinishedPanelItem(widget.items[id] ?? '')) return;
    setState(() {
      _dismissed.add(id);
      if (widget.undoBuilder != null) {
        _undoTimers.remove(id)?.cancel();
        _undoTimers[id] = Timer(const Duration(seconds: 5), () {
          if (mounted) setState(() => _undoTimers.remove(id));
        });
      }
    });
    _save();
  }

  void _undo(String id) {
    if (!_undoTimers.containsKey(id)) return;
    setState(() {
      _undoTimers.remove(id)?.cancel();
      _dismissed.remove(id);
    });
    _save();
  }

  void _cancelUndoTimers() {
    for (final timer in _undoTimers.values) {
      timer.cancel();
    }
    _undoTimers.clear();
  }

  @override
  void dispose() {
    _cancelUndoTimers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final generation = _generation;
    void dismiss(String id) {
      if (mounted && generation == _generation) _dismiss(id);
    }

    void undo(String id) {
      if (mounted && generation == _generation) _undo(id);
    }

    return KeyedSubtree(
      key: ValueKey(_key),
      child:
          widget.undoBuilder?.call(
            Set.unmodifiable(_dismissed),
            dismiss,
            Set.unmodifiable(_undoTimers.keys),
            undo,
          ) ??
          widget.builder!(Set.unmodifiable(_dismissed), dismiss),
    );
  }
}
