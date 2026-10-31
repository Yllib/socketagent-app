import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../ui_variant.dart';
import '../screens/board_screen.dart';
import '../screens/more_screen.dart';
import '../screens/session_screen.dart';
import '../screens/sessions_screen.dart';
import '../state/ui_c_models.dart';
import '../state/ui_c_store.dart';
import '../theme/ui_c_theme.dart';
import '../widgets/primitives.dart';
import 'ui_c_nav.dart';

/// Width from which the three-column desktop layout is used. Windows always
/// qualifies; a phone never does.
const double uiCDesktopMinWidth = 980;

/// Picks the phone or desktop layout for the window.
class UiCShell extends StatelessWidget {
  const UiCShell({super.key, this.forceDesktop});

  final bool? forceDesktop;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop =
            forceDesktop ?? constraints.maxWidth >= uiCDesktopMinWidth;
        return desktop ? const _DesktopShell() : const _PhoneShell();
      },
    );
  }
}

class _PhoneShell extends StatelessWidget {
  const _PhoneShell();

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<UiCNav>();
    final store = context.watch<UiCStore>();
    final c = context.c;
    final waiting = store.inbox.length;
    final running = store.sessions.where((s) => s.running).length;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: nav.tab.index,
          children: const [
            BoardScreen(),
            SessionsScreen(),
            SessionScreen(),
            MoreScreen(),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(top: BorderSide(color: c.line)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const FleetStrip(),
              Row(
                children: [
                  _TabButton(
                    tab: UiCTab.board,
                    icon: Icons.inbox_outlined,
                    label: 'Board',
                    badge: waiting,
                    badgeColor: c.warn,
                  ),
                  _TabButton(
                    tab: UiCTab.sessions,
                    icon: Icons.view_list_outlined,
                    label: 'Sessions',
                    badge: running,
                    badgeColor: c.accent,
                  ),
                  _TabButton(
                    tab: UiCTab.session,
                    icon: Icons.chat_bubble_outline,
                    label:
                        store.activeSessionId == null && !store.isDraftSession
                        ? 'Session'
                        : store.activeTitle,
                  ),
                  const _TabButton(
                    tab: UiCTab.more,
                    icon: Icons.grid_view_outlined,
                    label: 'More',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.tab,
    required this.icon,
    required this.label,
    this.badge = 0,
    this.badgeColor,
  });

  final UiCTab tab;
  final IconData icon;
  final String label;
  final int badge;
  final Color? badgeColor;

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<UiCNav>();
    final c = context.c;
    final selected = nav.tab == tab;
    final tone = selected ? c.accent : c.textDim;
    return Expanded(
      child: InkWell(
        onTap: () => nav.go(tab),
        child: Container(
          height: 50,
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: selected ? c.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(icon, size: 20, color: tone),
                  if (badge > 0)
                    Positioned(
                      right: -10,
                      top: -5,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: badgeColor ?? c.accent,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          '$badge',
                          style: UiCFonts.condensed(
                            size: 10,
                            weight: FontWeight.w700,
                            color: c.bg,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: UiCFonts.condensed(
                  size: 11,
                  weight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: tone,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One line of computers: colored square, short name, running and waiting
/// counts. Tapping a computer filters the session list to it.
class FleetStrip extends StatelessWidget {
  const FleetStrip({super.key, this.showNames = true});

  final bool showNames;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<UiCStore>();
    final c = context.c;
    final computers = store.computers;
    if (computers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Text(
          'No computers paired',
          style: UiCFonts.condensed(size: 11, color: c.textFaint),
        ),
      );
    }
    return SizedBox(
      height: 24,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final computer in computers)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(
                children: [
                  ComputerMark(
                    name: showNames ? computer.name : computer.shortName,
                    color: computer.color,
                    connected: computer.isConnected,
                  ),
                  if (computer.link == LinkState.connecting)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(Icons.sync, size: 11, color: c.textFaint),
                    ),
                  if (computer.running > 0) ...[
                    const SizedBox(width: 5),
                    Text(
                      '${computer.running}',
                      style: UiCFonts.mono(size: 11, color: c.accent),
                    ),
                    Icon(Icons.play_arrow, size: 11, color: c.accent),
                  ],
                  if (computer.waiting > 0) ...[
                    const SizedBox(width: 4),
                    Text(
                      '${computer.waiting}',
                      style: UiCFonts.mono(size: 11, color: c.warn),
                    ),
                    Icon(Icons.priority_high, size: 11, color: c.warn),
                  ],
                  if (!computer.isConnected && computer.expectedOnline) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.warning_amber, size: 11, color: c.danger),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DesktopShell extends StatefulWidget {
  const _DesktopShell();

  @override
  State<_DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<_DesktopShell> {
  double _leftWidth = 300;
  double _rightWidth = 330;
  bool _rightOpen = true;
  final _focus = FocusNode(debugLabel: 'ui_c_desktop');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<UiCNav>();
    final c = context.c;
    final showMore = nav.tab == UiCTab.more;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
            nav.newSession(),
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            nav.focusSearch.value++,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
            nav.findInSession.value++,
        const SingleActivator(LogicalKeyboardKey.tab, control: true): () =>
            nav.stepSession(1),
        const SingleActivator(
          LogicalKeyboardKey.tab,
          control: true,
          shift: true,
        ): () =>
            nav.stepSession(-1),
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
            setState(() => _rightOpen = !_rightOpen),
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
            nav.go(showMore ? UiCTab.session : UiCTab.more),
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Scaffold(
          backgroundColor: c.bg,
          body: Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    SizedBox(
                      width: _leftWidth,
                      child: const SessionsScreen(sidebar: true),
                    ),
                    _Splitter(
                      onDrag: (dx) => setState(
                        () => _leftWidth = (_leftWidth + dx).clamp(220, 480),
                      ),
                    ),
                    Expanded(
                      child: showMore
                          ? const MoreScreen(desktop: true)
                          : const SessionScreen(desktop: true),
                    ),
                    if (_rightOpen) ...[
                      _Splitter(
                        onDrag: (dx) => setState(
                          () =>
                              _rightWidth = (_rightWidth - dx).clamp(260, 520),
                        ),
                      ),
                      SizedBox(
                        width: _rightWidth,
                        child: const BoardScreen(rail: true),
                      ),
                    ],
                  ],
                ),
              ),
              _StatusStrip(
                railOpen: _rightOpen,
                onToggleRail: () => setState(() => _rightOpen = !_rightOpen),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Splitter extends StatelessWidget {
  const _Splitter({required this.onDrag});
  final void Function(double dx) onDrag;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
        child: Container(width: 5, color: context.c.line.withValues(alpha: .6)),
      ),
    );
  }
}

/// Bottom line of the desktop window: fleet, shortcuts, interface switch.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.railOpen, required this.onToggleRail});

  final bool railOpen;
  final VoidCallback onToggleRail;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final nav = context.watch<UiCNav>();
    return Container(
      height: 26,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          const Expanded(child: FleetStrip()),
          const Kbd('Ctrl N'),
          _hint(c, 'new'),
          const Kbd('Ctrl K'),
          _hint(c, 'switch'),
          const Kbd('Ctrl F'),
          _hint(c, 'find'),
          const Kbd('Ctrl B'),
          _hint(c, railOpen ? 'hide board' : 'show board'),
          IconTap(
            Icons.tune,
            size: 14,
            pad: 4,
            tooltip: 'More and settings (Ctrl ,)',
            onTap: () =>
                nav.go(nav.tab == UiCTab.more ? UiCTab.session : UiCTab.more),
          ),
          const InterfaceSwitch(),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _hint(UiCTheme c, String text) => Padding(
    padding: const EdgeInsets.only(left: 4, right: 10),
    child: Text(text, style: UiCFonts.condensed(size: 11, color: c.textFaint)),
  );
}

/// Classic, A, B, C. Lives in the desktop status strip and in More so the
/// user is never stuck in this interface.
class InterfaceSwitch extends StatelessWidget {
  const InterfaceSwitch({super.key, this.expanded = false});

  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<UiVariantController>();
    final c = context.c;
    if (expanded) {
      return Wrap(
        spacing: 6,
        children: [
          for (final variant in UiVariant.values)
            Tag(
              uiVariantLabel(variant),
              color: variant == controller.variant ? c.accent : c.textDim,
              filled: variant == controller.variant,
              onTap: () => controller.setVariant(variant),
            ),
        ],
      );
    }
    return PopupMenuButton<UiVariant>(
      tooltip: 'Interface',
      onSelected: controller.setVariant,
      itemBuilder: (context) => [
        for (final variant in UiVariant.values)
          PopupMenuItem(
            value: variant,
            height: 32,
            child: Text(
              variant == controller.variant
                  ? '${uiVariantLabel(variant)}  (current)'
                  : uiVariantLabel(variant),
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          'UI ${uiVariantLabel(controller.variant)}',
          style: UiCFonts.condensed(
            size: 11,
            weight: FontWeight.w700,
            color: c.textDim,
          ),
        ),
      ),
    );
  }
}
