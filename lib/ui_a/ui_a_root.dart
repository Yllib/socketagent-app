import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/chat_provider.dart';
import '../ui_variant.dart';
import 'board.dart';
import 'bits.dart';
import 'data.dart';
import 'inspector.dart';
import 'new_session.dart';
import 'provider_data.dart';
import 'session_view.dart';
import 'station.dart';
import 'theme.dart';

/// Entry point of redesign A, "Tower". The app shows this in place of the
/// classic interface when the user picks A. Wires the live [ChatProvider]
/// into [TowerShell].
class UiARoot extends StatefulWidget {
  const UiARoot({super.key});

  @override
  State<UiARoot> createState() => _UiARootState();
}

class _UiARootState extends State<UiARoot> {
  late final ProviderTowerData _data;
  final _themes = TowerThemeController();

  @override
  void initState() {
    super.initState();
    _data = ProviderTowerData(context.read<ChatProvider>());
    unawaited(_themes.restore());
  }

  @override
  void dispose() {
    _data.dispose();
    _themes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TowerShell(
      data: _data,
      themes: _themes,
      openRequests: context.read<UiVariantController>().sessionOpenRequests,
    );
  }
}

/// Lays Tower out for the space it has. Wide: board, session and inspector
/// side by side. Medium: board and session. Narrow (phone): the board, or one
/// session with the inspector as a sheet.
class TowerShell extends StatefulWidget {
  const TowerShell({
    super.key,
    required this.data,
    required this.themes,
    this.openRequests,
    this.startInSession = false,
  });

  final TowerData data;
  final TowerThemeController themes;

  /// Fires when a notification tap has made a session current.
  final Listenable? openRequests;

  /// Phone only: start on the open session instead of the board.
  final bool startInSession;

  @override
  State<TowerShell> createState() => _TowerShellState();
}

class _TowerShellState extends State<TowerShell> {
  late bool _inSession = widget.startInSession;
  bool _inspector = true;
  final _boardKey = GlobalKey<BoardState>();

  @override
  void initState() {
    super.initState();
    widget.openRequests?.addListener(_onOpenRequest);
  }

  @override
  void dispose() {
    widget.openRequests?.removeListener(_onOpenRequest);
    super.dispose();
  }

  void _onOpenRequest() {
    final s = widget.data.openSession;
    if (s != null) widget.data.open(s);
    setState(() => _inSession = true);
  }

  void _open(Session s) {
    widget.data.open(s);
    setState(() => _inSession = true);
  }

  void _back() {
    widget.data.closeOpen();
    setState(() => _inSession = false);
  }

  void _onWait(TowerWait w) {
    final s = widget.data.sessions
        .where((x) => x.id == w.sessionId && x.serverId == w.serverId)
        .firstOrNull;
    if (s != null) _open(s);
  }

  Future<void> _new(BuildContext context) async {
    await sheetTower<void>(
      context,
      (ctx) => NewSession(
        onStarted: () {
          Navigator.pop(ctx);
          setState(() => _inSession = true);
        },
      ),
    );
  }

  void _station(BuildContext context) {
    unawaited(pushTower<void>(context, Station(themes: widget.themes)));
  }

  void _inspectorSheet(BuildContext context) {
    unawaited(
      sheetTower<void>(
        context,
        (ctx) => SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.78,
          child: Inspector(
            onOpenSession: (s) {
              Navigator.pop(ctx);
              _open(s);
            },
            onClose: () => Navigator.pop(ctx),
          ),
        ),
      ),
    );
  }

  /// Moves to the next or previous session in board order.
  void _step(int delta) {
    final list = widget.data.sessions;
    if (list.isEmpty) return;
    final i = list.indexWhere(
      (s) => s.id == widget.data.openSessionId && s.serverId == widget.data.openServerId,
    );
    final next = list[(i + delta).clamp(0, list.length - 1)];
    _open(next);
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<TowerData>.value(
      value: widget.data,
      child: ListenableBuilder(
        listenable: widget.themes,
        builder: (context, _) => Tw.wrap(
          widget.themes.palette,
          Builder(builder: _layout),
        ),
      ),
    );
  }

  Widget _layout(BuildContext context) {
    final p = Tw.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 1180;
    final medium = width >= 760;
    final hasSession =
        widget.data.openSessionId != null || widget.data.isDraftSession;
    final overlay = p.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark;

    Widget board({required bool desktop}) => Board(
      key: _boardKey,
      desktop: desktop,
      onOpen: _open,
      onNew: () => _new(context),
      onStation: () => _station(context),
      onWait: _onWait,
    );

    final Widget body;
    if (!medium) {
      final showSession = _inSession && hasSession;
      body = PopScope(
        canPop: !showSession,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _back();
        },
        child: showSession
            ? SessionView(
                key: ValueKey('${widget.data.openServerId}|${widget.data.openSessionId}'),
                onBack: _back,
                onInspector: () => _inspectorSheet(context),
              )
            : board(desktop: false),
      );
    } else {
      final center = hasSession
          ? SessionView(
              key: ValueKey('${widget.data.openServerId}|${widget.data.openSessionId}'),
              onBack: null,
              desktop: true,
              onInspector: wide
                  ? () => setState(() => _inspector = !_inspector)
                  : () => _inspectorSheet(context),
            )
          : const _Idle();
      body = CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
              _boardKey.currentState?.searchFocus.requestFocus(),
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => _new(context),
          const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
              setState(() => _inspector = !_inspector),
          const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () => _step(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () => _step(-1),
        },
        child: Focus(
          autofocus: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: wide ? 380 : 330, child: board(desktop: true)),
              VerticalDivider(width: 1, thickness: 1, color: p.line),
              Expanded(child: center),
              if (wide && hasSession && _inspector) ...[
                VerticalDivider(width: 1, thickness: 1, color: p.line),
                SizedBox(
                  width: 340,
                  child: Inspector(onOpenSession: _open),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlay,
      child: Scaffold(
        backgroundColor: p.bg,
        body: SafeArea(child: body),
      ),
    );
  }
}

/// Desktop center when no session is open.
class _Idle extends StatelessWidget {
  const _Idle();

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    Widget key(String k, String what) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 90, child: Text(k, style: Ts.mono(p, color: p.accent, size: 12))),
          Text(what, style: Ts.meta(p)),
        ],
      ),
    );
    return ColoredBox(
      color: p.bg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            key('Ctrl K', 'find a session'),
            key('Ctrl N', 'new session'),
            key('Alt ↑ ↓', 'previous, next session'),
            key('Ctrl I', 'inspector'),
            key('Enter', 'send, Shift Enter for a new line'),
          ],
        ),
      ),
    );
  }
}
