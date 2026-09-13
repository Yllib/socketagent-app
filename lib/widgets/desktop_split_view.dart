import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps both panes mounted when resizing or switching to the narrow layout.
class DesktopSplitView extends StatefulWidget {
  const DesktopSplitView({
    super.key,
    required this.sidebar,
    required this.conversationBuilder,
    required this.hasConversation,
    required this.openRevision,
    this.active = true,
  });

  static const breakpoint = 840.0;
  static const minSidebarWidth = 280.0;
  static const maxSidebarWidth = 420.0;
  static const preferenceKey = 'desktop_session_sidebar_width';
  final Widget sidebar;
  final Widget Function(
    BuildContext,
    bool visible,
    bool sidebarVisible,
    VoidCallback toggleSidebar,
  )
  conversationBuilder;
  final bool hasConversation;
  final int openRevision;
  final bool active;

  @override
  State<DesktopSplitView> createState() => _DesktopSplitViewState();
}

class _DesktopSplitViewState extends State<DesktopSplitView> {
  double _width = 320;
  bool _widthChanged = false;
  bool _collapsed = false;
  bool _narrowList = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getDouble(DesktopSplitView.preferenceKey);
      if (mounted && !_widthChanged && saved != null && saved.isFinite) {
        setState(
          () => _width = saved.clamp(
            DesktopSplitView.minSidebarWidth,
            DesktopSplitView.maxSidebarWidth,
          ),
        );
      }
    });
  }

  @override
  void didUpdateWidget(covariant DesktopSplitView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.openRevision != widget.openRevision) _narrowList = false;
  }

  void _saveWidth() {
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setDouble(DesktopSplitView.preferenceKey, _width),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= DesktopSplitView.breakpoint;
      final sidebarVisible = wide
          ? !_collapsed
          : !widget.hasConversation || _narrowList;
      final contentVisible = wide || !sidebarVisible;
      final maximum = (constraints.maxWidth - 508).clamp(
        DesktopSplitView.minSidebarWidth,
        DesktopSplitView.maxSidebarWidth,
      );
      final sidebarWidth = wide
          ? _width.clamp(DesktopSplitView.minSidebarWidth, maximum)
          : constraints.maxWidth;
      void toggleSidebar() => setState(() {
        if (wide) {
          _collapsed = !_collapsed;
        } else {
          _narrowList = !_narrowList;
        }
      });
      return Stack(
        children: [
          Positioned.fill(
            left: wide && sidebarVisible ? sidebarWidth + 8 : 0,
            child: Offstage(
              offstage: !contentVisible,
              child: ExcludeFocus(
                excluding: !contentVisible || !widget.active,
                child: widget.conversationBuilder(
                  context,
                  widget.active && contentVisible,
                  sidebarVisible,
                  toggleSidebar,
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: sidebarWidth,
            child: Offstage(
              offstage: !sidebarVisible,
              child: ExcludeFocus(
                excluding: !sidebarVisible || !widget.active,
                child: Material(
                  key: const ValueKey('desktop-session-sidebar'),
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  child: widget.sidebar,
                ),
              ),
            ),
          ),
          Positioned(
            left: sidebarWidth,
            top: 0,
            bottom: 0,
            width: 8,
            child: Offstage(
              offstage: !wide || !sidebarVisible,
              child: Semantics(
                label: 'Resize session sidebar',
                onIncrease: () {
                  setState(
                    () => _width = (_width + 24).clamp(
                      DesktopSplitView.minSidebarWidth,
                      maximum,
                    ),
                  );
                  _saveWidth();
                },
                onDecrease: () {
                  setState(
                    () => _width = (_width - 24).clamp(
                      DesktopSplitView.minSidebarWidth,
                      maximum,
                    ),
                  );
                  _saveWidth();
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: GestureDetector(
                    key: const ValueKey('desktop-sidebar-divider'),
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (_) {
                      _widthChanged = true;
                      _width = sidebarWidth;
                    },
                    onHorizontalDragUpdate: (details) => setState(() {
                      _widthChanged = true;
                      _width = (_width + details.delta.dx).clamp(
                        DesktopSplitView.minSidebarWidth,
                        maximum,
                      );
                    }),
                    onHorizontalDragEnd: (_) => _saveWidth(),
                    onDoubleTap: () {
                      setState(() => _width = 320);
                      _saveWidth();
                    },
                    child: const Center(child: VerticalDivider(width: 1)),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// Shared padding for the full-width transcript and composer.
class DesktopConversationWidth extends StatelessWidget {
  const DesktopConversationWidth({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: SizedBox(width: double.infinity, child: child),
  );
}
