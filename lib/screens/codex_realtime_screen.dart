import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_theme.dart';
import '../services/chat_provider.dart';
import '../services/codex_realtime_service.dart';
import '../widgets/realtime_orb.dart';

const _voicePreferenceKey = 'codex_realtime_voice';

/// Full-screen voice call with Codex. Opens the call on arrival and ends it
/// when dismissed. The orb reacts to who is talking; the transcript below it
/// streams in place; Codex handoffs show as "working" while the backing model
/// runs a turn in the chat behind this screen.
/// The voice call screen stays dark in light mode: the orb and transcript are
/// drawn for a black background, so the route takes the dark Codex theme.
class CodexRealtimeScreen extends StatelessWidget {
  const CodexRealtimeScreen({super.key, this.sessionId});

  /// The Codex session to join. Null starts a new session.
  final String? sessionId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.brightness == Brightness.dark
          ? theme
          : appTheme(accent: AppPalette.dark.codex),
      child: _CodexRealtimeBody(sessionId: sessionId),
    );
  }
}

class _CodexRealtimeBody extends StatefulWidget {
  const _CodexRealtimeBody({this.sessionId});

  final String? sessionId;

  @override
  State<_CodexRealtimeBody> createState() => _CodexRealtimeScreenState();
}

class _CodexRealtimeScreenState extends State<_CodexRealtimeBody> {
  final _textController = TextEditingController();
  final _textFocus = FocusNode();
  bool _typing = false;
  bool _closing = false;

  CodexRealtimeService get _service =>
      context.read<ChatProvider>().codexRealtime;

  @override
  void initState() {
    super.initState();
    unawaited(_begin());
  }

  Future<void> _begin() async {
    final service = _service;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_voicePreferenceKey);
    if (!mounted) return;
    if (saved != null && saved.isNotEmpty) service.selectVoice(saved);
    service.requestVoices(sessionId: widget.sessionId);
    await service.start(sessionId: widget.sessionId);
  }

  Future<void> _end() async {
    if (_closing) return;
    _closing = true;
    await _service.stop();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _restart() async {
    final service = _service;
    await service.stop();
    if (!mounted) return;
    await service.start(sessionId: service.sessionId ?? widget.sessionId);
  }

  Future<void> _chooseVoice(String? voice) async {
    final service = _service;
    final prefs = await SharedPreferences.getInstance();
    if (voice == null) {
      await prefs.remove(_voicePreferenceKey);
    } else {
      await prefs.setString(_voicePreferenceKey, voice);
    }
    if (!mounted) return;
    service.selectVoice(voice);
    if (service.isLive) await _restart();
  }

  void _sendTyped() {
    final text = _textController.text;
    if (_service.sendText(text)) {
      _textController.clear();
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _textFocus.dispose();
    final service = _service;
    if (service.isLive) unawaited(service.stop());
    super.dispose();
  }

  String _status(CodexRealtimeService service, bool working) {
    switch (service.phase) {
      case CodexRealtimePhase.idle:
      case CodexRealtimePhase.connecting:
        return 'Connecting';
      case CodexRealtimePhase.live:
        if (working) return 'Codex is working';
        if (service.muted) return 'Muted';
        return 'Listening';
      case CodexRealtimePhase.ended:
        return 'Call ended';
      case CodexRealtimePhase.failed:
        return service.error ?? 'Call failed';
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ChatProvider>();
    final service = provider.codexRealtime;
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final working =
        service.phase == CodexRealtimePhase.live && provider.isProcessing;
    final live = service.phase == CodexRealtimePhase.live;
    final over =
        service.phase == CodexRealtimePhase.ended ||
        service.phase == CodexRealtimePhase.failed;
    final transcript = service.lines.reversed.toList(growable: false);

    return PopScope(
      canPop: !service.isLive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_end());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: service.isLive ? 'End call' : 'Close',
                      icon: const Icon(Icons.keyboard_arrow_down),
                      onPressed: _end,
                    ),
                    const Expanded(
                      child: Text(
                        'Codex voice',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    _VoiceMenu(service: service, onChanged: _chooseVoice),
                  ],
                ),
              ),
              Expanded(
                flex: 5,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RealtimeOrb(
                        outputLevel: service.outputLevel,
                        inputLevel: service.inputLevel,
                        color: accent,
                        dimmed: !live,
                        working: working,
                      ),
                      const SizedBox(height: 20),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          _status(service, working),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            color: service.phase == CodexRealtimePhase.failed
                                ? theme.colorScheme.error
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 4,
                child: transcript.isEmpty
                    ? const SizedBox.shrink()
                    : ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 4,
                        ),
                        itemCount: transcript.length,
                        itemBuilder: (context, index) {
                          final line = transcript[index];
                          final mine = line.role == 'user';
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Text(
                              line.text,
                              textAlign: mine
                                  ? TextAlign.right
                                  : TextAlign.left,
                              style: TextStyle(
                                fontSize: 15,
                                height: 1.35,
                                color: mine
                                    ? theme.colorScheme.onSurfaceVariant
                                    : Colors.white,
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if (_typing && live)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _textController,
                          focusNode: _textFocus,
                          autofocus: true,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _sendTyped(),
                          decoration: const InputDecoration(
                            hintText: 'Type to Codex',
                            isDense: true,
                            border: UnderlineInputBorder(),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Send',
                        icon: const Icon(Icons.arrow_upward),
                        onPressed: _sendTyped,
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: over
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Close'),
                          ),
                          const SizedBox(width: 12),
                          FilledButton(
                            onPressed: () => unawaited(
                              service.start(
                                sessionId:
                                    service.sessionId ?? widget.sessionId,
                              ),
                            ),
                            child: const Text('Call again'),
                          ),
                        ],
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          IconButton(
                            tooltip: service.muted ? 'Unmute' : 'Mute',
                            iconSize: 28,
                            color: service.muted
                                ? theme.colorScheme.error
                                : Colors.white,
                            icon: Icon(
                              service.muted ? Icons.mic_off : Icons.mic,
                            ),
                            onPressed: live
                                ? () => unawaited(
                                    service.setMuted(!service.muted),
                                  )
                                : null,
                          ),
                          IconButton(
                            tooltip: service.speakerphone
                                ? 'Use earpiece'
                                : 'Use speaker',
                            iconSize: 28,
                            color: Colors.white,
                            icon: Icon(
                              service.speakerphone
                                  ? Icons.volume_up
                                  : Icons.hearing,
                            ),
                            onPressed: live
                                ? () => unawaited(
                                    service.setSpeakerphone(
                                      !service.speakerphone,
                                    ),
                                  )
                                : null,
                          ),
                          IconButton(
                            tooltip: 'Type instead',
                            iconSize: 28,
                            color: _typing ? accent : Colors.white,
                            icon: const Icon(Icons.keyboard_alt_outlined),
                            onPressed: live
                                ? () => setState(() => _typing = !_typing)
                                : null,
                          ),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: theme.colorScheme.error,
                              foregroundColor: theme.colorScheme.onError,
                            ),
                            onPressed: _end,
                            icon: const Icon(Icons.call_end),
                            label: const Text('End'),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VoiceMenu extends StatelessWidget {
  const _VoiceMenu({required this.service, required this.onChanged});

  final CodexRealtimeService service;
  final Future<void> Function(String?) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = service.selectedVoice ?? service.defaultVoice;
    if (service.voices.isEmpty) {
      return Text(
        current ?? '',
        style: TextStyle(
          fontSize: 13,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return PopupMenuButton<String>(
      tooltip: 'Voice',
      initialValue: current,
      onSelected: (voice) =>
          unawaited(onChanged(voice == service.defaultVoice ? null : voice)),
      itemBuilder: (context) => [
        for (final voice in service.voices)
          PopupMenuItem<String>(
            value: voice,
            child: Text(
              voice == service.defaultVoice ? '$voice (default)' : voice,
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              current ?? 'Voice',
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Icon(
              Icons.arrow_drop_down,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
