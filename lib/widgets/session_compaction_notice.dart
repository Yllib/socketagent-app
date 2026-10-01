import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SessionCompactionNotice extends StatefulWidget {
  const SessionCompactionNotice({
    super.key,
    required this.serverId,
    required this.sessionId,
    required this.compactions,
    required this.onStartFresh,
  });

  final String serverId;
  final String sessionId;
  final int compactions;
  final VoidCallback? onStartFresh;

  @override
  State<SessionCompactionNotice> createState() =>
      _SessionCompactionNoticeState();
}

class _SessionCompactionNoticeState extends State<SessionCompactionNotice> {
  SharedPreferences? _prefs;
  int? _dismissedAt;
  String get _key =>
      'compaction_notice_${jsonEncode([widget.serverId, widget.sessionId])}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final key = _key;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || key != _key) return;
    setState(() {
      _prefs = prefs;
      _dismissedAt = prefs.getInt(key);
      _resetAfterRollover();
    });
  }

  @override
  void didUpdateWidget(SessionCompactionNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId != widget.serverId ||
        oldWidget.sessionId != widget.sessionId) {
      _prefs = null;
      _dismissedAt = null;
      _load();
    } else {
      _resetAfterRollover();
    }
  }

  void _resetAfterRollover() {
    if (_dismissedAt != null && widget.compactions < _dismissedAt!) {
      _dismissedAt = null;
      unawaited(_prefs?.remove(_key));
    }
  }

  Future<void> _dismiss() async {
    final count = widget.compactions;
    setState(() => _dismissedAt = count);
    await _prefs!.setInt(_key, count);
  }

  void _showInfo() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: Colors.black,
      title: const Text('Why start a new thread?'),
      content: const Text(
        'Compaction summarizes a long conversation to make room. '
        'Continuing a long thread can use more tokens and more of your usage allowance.\n\n'
        'A fresh thread starts with less context. Your history stays here, and the agent '
        'can use Remember to look up earlier transcripts when needed.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Got it'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final dismissed = _dismissedAt;
    if (_prefs == null ||
        widget.compactions <= 10 ||
        (dismissed != null &&
            widget.compactions >= dismissed &&
            widget.compactions < dismissed + 15)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: widget.onStartFresh,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '${widget.compactions} compactions. '),
                    TextSpan(
                      text: 'Start a new thread',
                      style: TextStyle(
                        color: widget.onStartFresh == null
                            ? Colors.white54
                            : Theme.of(context).colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ],
                ),
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.25,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          SizedBox.square(
            dimension: 28,
            child: IconButton(
              tooltip: 'More info',
              onPressed: _showInfo,
              icon: const Icon(Icons.info_outline, size: 16),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            ),
          ),
          SizedBox.square(
            dimension: 28,
            child: IconButton(
              tooltip: 'Dismiss for 15 more compactions',
              onPressed: _dismiss,
              icon: const Icon(Icons.close, size: 16),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            ),
          ),
        ],
      ),
    );
  }
}
