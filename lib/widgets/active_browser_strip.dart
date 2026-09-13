import 'package:flutter/material.dart';
import '../models/active_browser_session.dart';

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
        color: const Color(0xFF1E1E2E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Color(0xFF313244)),
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
                  const Icon(Icons.public, size: 14, color: Color(0xFF89B4FA)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFFA6ADC8),
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
                              style: const TextStyle(
                                fontSize: 10,
                                color: Color(0xFFF9E2AF),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: Color(0xFF6C7086),
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
                      color: const Color(0xFF6C7086),
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
