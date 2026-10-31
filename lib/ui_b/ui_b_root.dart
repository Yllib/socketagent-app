import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/chat_provider.dart';
import '../services/work_review_repository.dart';
import '../ui_variant.dart';
import 'live/live_actions.dart';
import 'live/live_models.dart';
import 'live/seen_ledger.dart';
import 'shell/ui_b_shell.dart';
import 'theme/ui_b_theme.dart';
import 'widgets/clock.dart';

/// Interface B, the dispatch board. Everything the agents are doing on every
/// computer on one screen, what needs an answer at the top, answerable in
/// place. Sessions are dense logs with internal work folded into bands.
class UiBRoot extends StatefulWidget {
  const UiBRoot({super.key});

  @override
  State<UiBRoot> createState() => _UiBRootState();
}

class _UiBRootState extends State<UiBRoot> {
  final _themes = UiBThemeController();
  final _clock = UiBClock();
  final _seen = SeenLedger();
  final _shellKey = GlobalKey<UiBShellState>();
  late final LiveActions _actions;
  late final UiVariantController _variant;
  ChatProvider? _provider;
  int _lastOpenRequest = 0;
  bool _viewing = false;
  String? _viewedKey;

  @override
  void initState() {
    super.initState();
    _themes.restore();
    _seen.load();
    _variant = context.read<UiVariantController>();
    _provider = context.read<ChatProvider>();
    _actions = LiveActions(_provider!, _variant)
      ..navigate = (serverId, sessionId, {entryId}) {
        _shellKey.currentState?.showSession(entryId: entryId);
      }
      ..onNewSession = () {
        _shellKey.currentState?.showSession();
      };
    _lastOpenRequest = _variant.sessionOpenRequests.value;
    _variant.sessionOpenRequests.addListener(_onOpenRequest);
    _provider!.requestSessionList();
    _provider!.requestScheduledTasks();
    for (final c in _provider!.serverConfigs) {
      _provider!.requestRecentCwds(serverId: c.id);
    }
  }

  void _onOpenRequest() {
    final v = _variant.sessionOpenRequests.value;
    if (v == _lastOpenRequest) return;
    _lastOpenRequest = v;
    final focus = _provider?.notificationTranscriptFocus;
    _shellKey.currentState?.showSession(entryId: focus?.entryId);
  }

  void _setViewing(bool visible) {
    final p = _provider;
    if (p == null) return;
    _viewing = visible;
    if (visible) {
      _viewedKey = '${p.activeSessionServerId}\u0001${p.activeSessionId}';
      p.setViewingSession(
        p.activeSessionId,
        serverId: p.activeSessionServerId,
        owner: this,
      );
    } else {
      _viewedKey = null;
      p.clearViewingSession(this);
    }
  }

  @override
  void dispose() {
    _variant.sessionOpenRequests.removeListener(_onOpenRequest);
    _provider?.clearViewingSession(this);
    _clock.dispose();
    _themes.dispose();
    _seen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<ChatProvider>();
    final reviews = context.watch<WorkReviewRepository>();
    return AnimatedBuilder(
      animation: Listenable.merge([_themes, _seen]),
      builder: (context, _) {
        final now = DateTime.now();
        final board = buildBoard(p, reviews, _seen, now: now);
        final session = buildSessionView(p, reviews);
        final desktop =
            Platform.isWindows || Platform.isLinux || Platform.isMacOS;
        _clock.setLive(board.anythingRunning || session.busy);
        // Keep the viewing state pointed at whatever session is current,
        // without re-telling the provider on every streamed token.
        final key = '${p.activeSessionServerId}\u0001${session.id}';
        if (_viewing && session.id != null && key != _viewedKey) {
          _viewedKey = key;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _viewing) {
              p.setViewingSession(
                session.id,
                serverId: p.activeSessionServerId,
                owner: this,
              );
            }
          });
        }
        if (_viewing && session.id != null && !session.running) {
          final done = session.runStats?.lastCompletedAt ?? now;
          _seen.markSeen(
            session.serverId,
            session.id!,
            done.isAfter(now) ? now : done,
          );
        }
        return UiBThemeScope(
          theme: _themes.theme,
          textScale: _themes.textScale,
          child: UiBClockScope(
            clock: _clock,
            child: Theme(
              data: _themes.theme.material(_themes.textScale),
              child: MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(_themes.textScale)),
                child: UiBShell(
                  key: _shellKey,
                  board: board,
                  session: session,
                  automations: buildAutomations(p),
                  actions: _actions,
                  themes: _themes,
                  desktop: desktop,
                  onSessionVisible: _setViewing,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
