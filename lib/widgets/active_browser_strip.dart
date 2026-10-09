import 'package:flutter/material.dart';
import '../models/active_browser_session.dart';
import '../config/app_palette.dart';

/// Compact browser access beside the session's task and plan summaries.
class ActiveBrowserStrip extends StatelessWidget {
  const ActiveBrowserStrip({
    super.key,
    required this.browsers,
    required this.onOpen,
    this.onHide,
    this.hidingNotice,
  });

  final List<ActiveBrowserSession> browsers;
  final VoidCallback onOpen;
  final VoidCallback? onHide;
  final Widget? hidingNotice;

  @override
  Widget build(BuildContext context) {
    if (browsers.isEmpty) return const SizedBox.shrink();
    if (hidingNotice != null) return hidingNotice!;
    final single = browsers.length == 1 ? browsers.single : null;
    final title = single?.label ?? '${browsers.length} active browsers';
    final host = single == null ? '' : Uri.tryParse(single.url)?.host ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: context.palette.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: context.palette.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 4, 2),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 24),
              child: Row(
                children: [
                  Icon(Icons.public, size: 14, color: context.palette.blue),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: context.palette.textSecondary,
                            ),
                          ),
                        ),
                        if (host.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              host,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: context.palette.yellow,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: context.palette.textMuted,
                  ),
                  if (onHide != null)
                    IconButton(
                      tooltip: 'Hide browser strip. Browser stays running',
                      onPressed: onHide,
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        minimumSize: const Size(24, 24),
                        maximumSize: const Size(24, 24),
                      ),
                      constraints: const BoxConstraints.tightFor(
                        width: 24,
                        height: 24,
                      ),
                      iconSize: 16,
                      color: context.palette.textMuted,
                      icon: const Icon(Icons.visibility_off_outlined),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
