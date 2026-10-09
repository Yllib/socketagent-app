import 'package:flutter/material.dart';

import '../models/message.dart';
import '../config/app_palette.dart';

class NotificationReceiptCard extends StatefulWidget {
  final ChatMessage message;

  const NotificationReceiptCard({super.key, required this.message});

  @override
  State<NotificationReceiptCard> createState() =>
      _NotificationReceiptCardState();
}

class _NotificationReceiptCardState extends State<NotificationReceiptCard> {
  bool _expanded = false;

  String get _title {
    final explicit =
        widget.message.toolInput?['title']?.toString().trim() ?? '';
    if (explicit.isNotEmpty) return explicit;
    return widget.message.textContent.split('\n').first.trim();
  }

  String get _body {
    final explicit = widget.message.toolInput?['body']?.toString().trim() ?? '';
    if (explicit.isNotEmpty) return explicit;
    final lines = widget.message.textContent.split('\n');
    return lines.length > 1 ? lines.skip(1).join('\n').trim() : '';
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.sky;
    final body = _body;
    final expandable = body.length > 180 || body.split('\n').length > 3;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: context.palette.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withAlpha(85)),
      ),
      child: InkWell(
        onTap: expandable ? () => setState(() => _expanded = !_expanded) : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: accent.withAlpha(24),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  Icons.notifications_active_outlined,
                  size: 18,
                  color: accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Notification sent',
                            style: TextStyle(
                              color: accent,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.35,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: context.palette.green.withAlpha(24),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            'SENT',
                            style: TextStyle(
                              color: context.palette.green,
                              fontSize: 8.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _title.isEmpty ? 'Phone notification' : _title,
                      style: TextStyle(
                        color: context.palette.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (body.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        body,
                        maxLines: _expanded ? null : 3,
                        overflow: _expanded
                            ? TextOverflow.visible
                            : TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.palette.textSecondary,
                          fontSize: 11.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (expandable)
                Padding(
                  padding: const EdgeInsets.only(left: 4, top: 34),
                  child: Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: context.palette.textMuted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
