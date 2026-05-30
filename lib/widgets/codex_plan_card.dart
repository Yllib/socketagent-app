import 'package:flutter/material.dart';
import '../models/message.dart';

class CodexPlanCard extends StatefulWidget {
  final ChatMessage msg;

  const CodexPlanCard({super.key, required this.msg});

  @override
  State<CodexPlanCard> createState() => _CodexPlanCardState();
}

class _CodexPlanCardState extends State<CodexPlanCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final steps = (widget.msg.toolInput?['steps'] as List? ?? const [])
        .whereType<Map>()
        .map((s) => Map<String, dynamic>.from(s))
        .toList();
    final explanation =
        (widget.msg.toolInput?['explanation'] as String? ??
                widget.msg.textContent)
            .trim();
    final completed = steps.where((s) => s['status'] == 'completed').length;
    final total = steps.length;
    final progress = total > 0 ? completed / total : null;
    String? activeLabel;
    for (final step in steps) {
      if (step['status'] == 'in_progress' || step['status'] == 'inProgress') {
        activeLabel = step['step'] as String?;
        break;
      }
    }
    const accent = Color(0xFF89B4FA);

    return Container(
      margin: EdgeInsets.symmetric(horizontal: 8, vertical: _expanded ? 4 : 2),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E2E),
        borderRadius: BorderRadius.circular(_expanded ? 12 : 8),
        border: Border.all(color: const Color(0xFF313244), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(_expanded ? 12 : 8),
              topRight: Radius.circular(_expanded ? 12 : 8),
              bottomLeft: Radius.circular(_expanded ? 0 : 8),
              bottomRight: Radius.circular(_expanded ? 0 : 8),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                10,
                _expanded ? 10 : 6,
                6,
                _expanded ? 6 : 6,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.fact_check_outlined,
                    size: _expanded ? 16 : 14,
                    color: accent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    total > 0 ? '$completed/$total' : 'Plan',
                    style: TextStyle(
                      fontSize: _expanded ? 11 : 10,
                      color: const Color(0xFFA6ADC8),
                    ),
                  ),
                  if (!_expanded &&
                      activeLabel != null &&
                      activeLabel.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      width: 1,
                      height: 10,
                      color: const Color(0xFF313244),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        activeLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFFF9E2AF),
                        ),
                      ),
                    ),
                  ] else if (!_expanded && progress != null) ...[
                    const SizedBox(width: 6),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 2,
                          backgroundColor: const Color(0xFF313244),
                          color: const Color(0xFFA6E3A1),
                        ),
                      ),
                    ),
                  ] else ...[
                    const SizedBox(width: 4),
                    const Text(
                      'Codex Plan',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: accent,
                      ),
                    ),
                    const Spacer(),
                  ],
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: _expanded ? 18 : 16,
                    color: const Color(0xFF6C7086),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded && progress != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: const Color(0xFF313244),
                  color: const Color(0xFFA6E3A1),
                ),
              ),
            ),
          if (_expanded) ...[
            if (explanation.isNotEmpty) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  explanation,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.3,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            if (steps.isNotEmpty) ...[
              const SizedBox(height: 6),
              ...steps.map((step) => _buildStep(context, step)),
              const SizedBox(height: 6),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildStep(BuildContext context, Map<String, dynamic> step) {
    final theme = Theme.of(context);
    final status = step['status'] as String? ?? 'pending';
    final text = step['step'] as String? ?? '';
    final IconData icon;
    final Color color;
    switch (status) {
      case 'completed':
        icon = Icons.check_circle;
        color = Colors.green.shade300;
        break;
      case 'in_progress':
      case 'inProgress':
        icon = Icons.play_circle_fill;
        color = Colors.yellow.shade300;
        break;
      default:
        icon = Icons.radio_button_unchecked;
        color = theme.colorScheme.outline;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 14, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: theme.colorScheme.onSurface,
                fontSize: 12,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
