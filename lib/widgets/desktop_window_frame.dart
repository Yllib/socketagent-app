import 'package:flutter/material.dart';
import '../services/desktop_window_service.dart';

/// Above the Navigator so routes and dialogs retain the same window controls.
/// Native hit testing handles dragging, double-clicking and edge resizing.
class DesktopWindowFrame extends StatelessWidget {
  const DesktopWindowFrame({super.key, required this.child, this.window});
  final Widget child;
  final DesktopWindowService? window;

  @override
  Widget build(BuildContext context) {
    final service = window ?? DesktopWindowService.instance;
    final colors = Theme.of(context).colorScheme;
    return ValueListenableBuilder<DesktopWindowState>(
      valueListenable: service,
      builder: (context, state, _) => Material(
        color: colors.surface,
        child: Column(
          children: [
            // Dimensions are shared with DesktopShell::HitTest in the runner.
            SizedBox(
              height: 44,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  border: Border(
                    bottom: BorderSide(
                      color: colors.outlineVariant.withAlpha(90),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    Icon(
                      Icons.forum_rounded,
                      size: 19,
                      color: state.active
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'SocketAgent Desktop',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: state.active
                              ? colors.onSurface
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 184,
                      child: Row(
                        children: [
                          _WindowButton(
                            tooltip: 'App menu',
                            icon: Icons.more_horiz_rounded,
                            onPressed: service.showMenu,
                          ),
                          _WindowButton(
                            tooltip: 'Minimize',
                            icon: Icons.keyboard_arrow_down_rounded,
                            onPressed: service.minimize,
                          ),
                          _WindowButton(
                            tooltip: state.maximized
                                ? 'Restore window'
                                : 'Maximize',
                            icon: state.maximized
                                ? Icons.close_fullscreen_rounded
                                : Icons.open_in_full_rounded,
                            onPressed: service.toggleMaximize,
                          ),
                          _WindowButton(
                            tooltip: 'Hide to tray',
                            icon: Icons.system_update_alt_rounded,
                            onPressed: service.hide,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 46,
    height: 44,
    child: Center(
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon, size: 18),
        onPressed: onPressed,
        style: IconButton.styleFrom(
          minimumSize: const Size(36, 30),
          maximumSize: const Size(36, 30),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );
}
