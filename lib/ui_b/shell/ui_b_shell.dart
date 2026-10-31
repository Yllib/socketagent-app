import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui_variant.dart';
import '../model/actions.dart';
import '../model/automation_model.dart';
import '../model/board_model.dart';
import '../model/session_model.dart';
import '../screens/automations_screen.dart';
import '../screens/board_screen.dart';
import '../screens/computers_screen.dart';
import '../screens/more_screen.dart';
import '../screens/new_session_sheet.dart';
import '../screens/session_screen.dart';
import '../theme/ui_b_theme.dart';
import '../widgets/answer_sheet.dart';
import '../widgets/palette.dart';
import '../widgets/primitives.dart';
import '../widgets/session_menu.dart';
import '../widgets/side_rail.dart';

enum ShellPage { board, automations, computers, more }

/// The frame around the screens. Phone: one page at a time with a bottom
/// bar, the session on top of the board. Desktop: board, log and side rail
/// side by side. Pure: everything it shows comes in as models.
class UiBShell extends StatefulWidget {
  const UiBShell({
    super.key,
    required this.board,
    required this.session,
    required this.automations,
    required this.actions,
    required this.themes,
    required this.desktop,
    this.onSessionVisible,
    this.initialPage = ShellPage.board,
    this.initialSessionOpen = false,
  });

  final BoardModel board;
  final SessionView session;
  final List<AutomationItem> automations;
  final UiBActions actions;
  final UiBThemeController themes;
  final bool desktop;

  /// Called when the session page shows or hides, so the live layer can
  /// mark it as being viewed.
  final void Function(bool visible)? onSessionVisible;
  final ShellPage initialPage;
  final bool initialSessionOpen;

  @override
  State<UiBShell> createState() => UiBShellState();
}

class UiBShellState extends State<UiBShell> {
  late ShellPage _page = widget.initialPage;
  late bool _sessionOpen = widget.initialSessionOpen;
  String? _focusEntryId;
  final _sessionKey = GlobalKey<SessionScreenState>();

  /// Shows the session that ChatProvider has made current.
  void showSession({String? entryId}) {
    setState(() {
      _sessionOpen = true;
      _focusEntryId = entryId;
    });
    widget.onSessionVisible?.call(true);
    if (entryId != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _sessionKey.currentState?.jumpToEntry(entryId),
      );
    }
  }

  void showBoard() {
    setState(() {
      _sessionOpen = false;
      _page = ShellPage.board;
    });
    widget.onSessionVisible?.call(false);
  }

  @override
  void initState() {
    super.initState();
    if (widget.desktop || _sessionOpen) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.onSessionVisible?.call(true),
      );
    }
  }

  void _openPalette() {
    showPalette(
      context,
      board: widget.board,
      actions: widget.actions,
      commands: [
        PaletteEntry(
          'New session',
          icon: Icons.add,
          hint: 'pick a computer and folder',
          run: _newSession,
        ),
        PaletteEntry(
          'Automations',
          icon: Icons.schedule_outlined,
          run: () => _goto(ShellPage.automations),
        ),
        PaletteEntry(
          'Computers',
          icon: Icons.devices_outlined,
          run: () => _goto(ShellPage.computers),
        ),
        PaletteEntry(
          'Settings',
          icon: Icons.tune,
          run: () => _goto(ShellPage.more),
        ),
        for (final id in UiBThemeId.values)
          PaletteEntry(
            'Theme ${uiBThemeLabel(id)}',
            icon: Icons.palette_outlined,
            run: () => widget.themes.setTheme(id),
          ),
        for (final v in UiVariant.values)
          if (v != UiVariant.b)
            PaletteEntry(
              'Switch to interface ${uiVariantLabel(v)}',
              icon: Icons.swap_horiz,
              run: () => widget.actions.setVariant(v),
            ),
        PaletteEntry(
          'Refresh session list',
          icon: Icons.refresh,
          run: widget.actions.requestSessionList,
        ),
      ],
    );
  }

  void _goto(ShellPage page) {
    final wasOpen = _sessionOpen;
    setState(() {
      _page = page;
      _sessionOpen = false;
    });
    if (wasOpen && !widget.desktop) widget.onSessionVisible?.call(false);
  }

  void _newSession([String? serverId]) => showNewSessionSheet(
    context,
    widget.board.computers,
    widget.actions,
    serverId: serverId,
  );

  BoardSession? _boardEntry(SessionView s) => s.id == null
      ? null
      : widget.board.sessions
            .where((b) => b.id == s.id && b.serverId == s.serverId)
            .firstOrNull;

  @override
  Widget build(BuildContext context) {
    final body = widget.desktop ? _desktop(context) : _phone(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _openPalette,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            _newSession,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
            _sessionKey.currentState?.toggleFind(),
      },
      child: Focus(autofocus: true, child: body),
    );
  }

  Widget _board(BuildContext context, {Widget? header, String? selectedKey}) =>
      BoardScreen(
        model: widget.board,
        actions: widget.actions,
        header: header,
        selectedKey: selectedKey,
        onOpenInbox: (item) =>
            openAnswerSheet(context, item, widget.actions, widget.session),
        onOpenComputer: (c) => _goto(ShellPage.computers),
        onSessionMenu: (s) => showSessionMenu(context, s, widget.actions),
      );

  Widget _current(
    BuildContext context, {
    Widget? header,
    String? selectedKey,
  }) => switch (_page) {
    ShellPage.board => _board(
      context,
      header: header,
      selectedKey: selectedKey,
    ),
    ShellPage.automations => AutomationsScreen(
      items: widget.automations,
      actions: widget.actions,
      header: header,
    ),
    ShellPage.computers => ComputersScreen(
      computers: widget.board.computers,
      actions: widget.actions,
      header: header,
      onNewSession: _newSession,
    ),
    ShellPage.more => MoreScreen(
      themes: widget.themes,
      actions: widget.actions,
      header: header,
      counts: {
        'Work reviews': widget.board.reviewsPending,
        'Browser windows': widget.board.browserWindows,
      },
    ),
  };

  Widget _phone(BuildContext context) {
    final t = UiBTheme.of(context);
    final s = widget.session;
    if (_sessionOpen) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) showBoard();
        },
        child: Scaffold(
          backgroundColor: t.bg,
          resizeToAvoidBottomInset: true,
          body: SafeArea(
            child: SessionScreen(
              key: _sessionKey,
              session: s,
              actions: widget.actions,
              desktop: false,
              focusEntryId: _focusEntryId,
              onBack: showBoard,
              onOpenRail: () => showRailSheet(
                context,
                s,
                widget.actions,
                onJumpToRun: (id) => _sessionKey.currentState?.jumpToRun(id),
              ),
              onMenu: () {
                final b = _boardEntry(s);
                if (b != null) showSessionMenu(context, b, widget.actions);
              },
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        bottom: false,
        child: _current(context, header: _phoneHeader(context)),
      ),
      bottomNavigationBar: _bottomBar(context),
    );
  }

  Widget _phoneHeader(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final b = widget.board;
    final title = switch (_page) {
      ShellPage.board => 'Board',
      ShellPage.automations => 'Automations',
      ShellPage.computers => 'Computers',
      ShellPage.more => 'Settings',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 2),
      child: Row(
        children: [
          Text(title, style: text.title),
          const SizedBox(width: 10),
          if (_page == ShellPage.board)
            Text(
              [
                if (b.needsMeCount > 0) '${b.needsMeCount} waiting',
                if (b.runningCount > 0) '${b.runningCount} running',
                if (b.needsMeCount == 0 && b.runningCount == 0) 'quiet',
              ].join(' · '),
              style: text.meta.copyWith(
                color: b.needsMeCount > 0 ? t.waiting : t.text2,
              ),
            ),
          const Spacer(),
          IconBtn(
            Icons.search,
            size: 18,
            tooltip: 'Find anything',
            onPressed: _openPalette,
          ),
          if (widget.session.id != null && _page == ShellPage.board)
            IconBtn(
              Icons.chat_bubble_outline,
              size: 18,
              tooltip: 'Back to the open session',
              onPressed: () => showSession(),
            ),
        ],
      ),
    );
  }

  Widget _bottomBar(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final b = widget.board;
    Widget tab(
      ShellPage p,
      IconData icon,
      String label, {
      int badge = 0,
      Color? badgeColor,
    }) {
      final on = _page == p;
      return Expanded(
        child: InkWell(
          onTap: () => _goto(p),
          child: SizedBox(
            height: 50,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(icon, size: 20, color: on ? t.accent : t.text2),
                    if (badge > 0)
                      Positioned(
                        right: -8,
                        top: -4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: badgeColor ?? t.accent,
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            '$badge',
                            style: text.micro.copyWith(
                              color: t.onAccent,
                              fontSize: 9,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: text.micro.copyWith(
                    color: on ? t.accent : t.text2,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(top: BorderSide(color: t.line)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            tab(
              ShellPage.board,
              Icons.dashboard_outlined,
              'Board',
              badge: b.needsMeCount,
              badgeColor: t.waiting,
            ),
            tab(
              ShellPage.automations,
              Icons.schedule_outlined,
              'Automations',
              badge: b.automationUnread,
            ),
            tab(
              ShellPage.computers,
              Icons.devices_outlined,
              'Computers',
              badge: b.computers.where((c) => c.worrying).length,
              badgeColor: t.failed,
            ),
            tab(ShellPage.more, Icons.tune, 'Settings'),
            Expanded(
              child: InkWell(
                onTap: _newSession,
                child: SizedBox(
                  height: 50,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_circle, size: 22, color: t.accent),
                      const SizedBox(height: 2),
                      Text(
                        'New',
                        style: text.micro.copyWith(
                          color: t.accent,
                          letterSpacing: 0,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _desktop(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final s = widget.session;
    final selectedKey = s.id == null ? null : '${s.serverId}\u0001${s.id}';
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 2),
      child: Row(
        children: [
          for (final (p, icon, label) in const [
            (ShellPage.board, Icons.dashboard_outlined, 'Board'),
            (ShellPage.automations, Icons.schedule_outlined, 'Automations'),
            (ShellPage.computers, Icons.devices_outlined, 'Computers'),
            (ShellPage.more, Icons.tune, 'Settings'),
          ])
            IconBtn(
              icon,
              size: 17,
              box: 30,
              tooltip: label,
              color: _page == p ? t.accent : null,
              onPressed: () => _goto(p),
            ),
          const Spacer(),
          IconBtn(
            Icons.search,
            size: 17,
            box: 30,
            tooltip: 'Find anything (Ctrl+K)',
            onPressed: _openPalette,
          ),
          IconBtn(
            Icons.add,
            size: 18,
            box: 30,
            tooltip: 'New session (Ctrl+N)',
            color: t.accent,
            onPressed: _newSession,
          ),
        ],
      ),
    );
    return Scaffold(
      backgroundColor: t.bg,
      body: Row(
        children: [
          SizedBox(
            width: 360,
            child: _current(context, header: header, selectedKey: selectedKey),
          ),
          Container(width: 1, color: t.line),
          Expanded(
            child: s.id == null && !_sessionOpen
                ? Center(
                    child: Text(
                      'Pick a session or press Ctrl+N',
                      style: text.meta,
                    ),
                  )
                : SessionScreen(
                    key: _sessionKey,
                    session: s,
                    actions: widget.actions,
                    desktop: true,
                    focusEntryId: _focusEntryId,
                    onMenu: () {
                      final b = _boardEntry(s);
                      if (b != null) {
                        showSessionMenu(context, b, widget.actions);
                      }
                    },
                  ),
          ),
          Container(width: 1, color: t.line),
          SizedBox(
            width: 320,
            child: SideRail(
              session: s,
              actions: widget.actions,
              onJumpToRun: (id) => _sessionKey.currentState?.jumpToRun(id),
            ),
          ),
        ],
      ),
    );
  }
}
