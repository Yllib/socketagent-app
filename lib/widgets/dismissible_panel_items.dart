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
    required this.builder,
  });

  final List<String>? scope;
  final Map<String, String> items;
  final Widget Function(Set<String> dismissed, ValueChanged<String> dismiss)
  builder;

  @override
  State<DismissiblePanelItems> createState() => _DismissiblePanelItemsState();
}

class _DismissiblePanelItemsState extends State<DismissiblePanelItems> {
  final Set<String> _dismissed = {};
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
    return count != _dismissed.length;
  }

  void _save() {
    final key = _key;
    if (key != null) _preferences?.setStringList(key, _dismissed.toList());
  }

  void _dismiss(String id) {
    if (!isFinishedPanelItem(widget.items[id] ?? '')) return;
    setState(() => _dismissed.add(id));
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final generation = _generation;
    void dismiss(String id) {
      if (mounted && generation == _generation) _dismiss(id);
    }

    return KeyedSubtree(
      key: ValueKey(_key),
      child: widget.builder(Set.unmodifiable(_dismissed), dismiss),
    );
  }
}
