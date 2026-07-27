import 'package:flutter/material.dart';

import '../models/message.dart';

class WorkflowCard extends StatefulWidget {
  final ChatMessage message;
  final Map<String, dynamic> state;

  const WorkflowCard({super.key, required this.message, required this.state});

  @override
  State<WorkflowCard> createState() => _WorkflowCardState();
}

class _WorkflowCardState extends State<WorkflowCard> {
  bool _expanded = true;

  String _text(String key, [String fallback = '']) =>
      widget.state[key]?.toString() ?? fallback;

  int _number(String key) => (widget.state[key] as num?)?.toInt() ?? 0;

  bool get _active {
    final status = _text('status', 'running');
    return status == 'pending' || status == 'running' || status == 'paused';
  }

  Color get _statusColor {
    switch (_text('status', 'running')) {
      case 'completed':
        return const Color(0xFFA6E3A1);
      case 'failed':
        return const Color(0xFFF38BA8);
      case 'stopped':
        return const Color(0xFFFAB387);
      case 'paused':
        return const Color(0xFFF9E2AF);
      default:
        return const Color(0xFF89B4FA);
    }
  }

  String _duration(int milliseconds) {
    if (milliseconds <= 0) return '';
    final seconds = (milliseconds / 1000).round();
    if (seconds < 60) return '${seconds}s';
    return '${seconds ~/ 60}m ${seconds % 60}s';
  }

  @override
  Widget build(BuildContext context) {
    final phases = (widget.state['phases'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final progress = (widget.state['progress'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final title = _text('workflowName').trim().isNotEmpty
        ? _text('workflowName')
        : widget.message.toolInput?['workflow_name']?.toString() ?? 'Workflow';
    final summary = _text('summary');
    final metrics = <String>[
      if (_number('agentCount') > 0) '${_number('agentCount')} agents',
      if (_number('totalTokens') > 0) '${_number('totalTokens')} tokens',
      if (_number('totalToolCalls') > 0)
        '${_number('totalToolCalls')} tool calls',
      if (_number('durationMs') > 0) _duration(_number('durationMs')),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Material(
        color: const Color(0xFF181825),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFF45475A)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    _active
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _statusColor,
                            ),
                          )
                        : Icon(
                            _text('status') == 'completed'
                                ? Icons.check_circle
                                : Icons.error_outline,
                            size: 19,
                            color: _statusColor,
                          ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              color: Color(0xFFCDD6F4),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (summary.isNotEmpty)
                            Text(
                              summary,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFFA6ADC8),
                                fontSize: 11,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: _statusColor.withAlpha(28),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _text('status', 'running'),
                        style: TextStyle(
                          color: _statusColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      color: const Color(0xFF7F849C),
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded) ...[
              if (metrics.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 9),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: metrics
                        .map(
                          (metric) => Text(
                            metric,
                            style: const TextStyle(
                              color: Color(0xFF89B4FA),
                              fontSize: 10,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              const Divider(height: 1, color: Color(0xFF313244)),
              if (phases.isEmpty && progress.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'Waiting for workflow progress…',
                    style: TextStyle(color: Color(0xFF7F849C), fontSize: 11),
                  ),
                )
              else
                ...List.generate(phases.length, (index) {
                  final phase = phases[index];
                  final agents = progress
                      .where(
                        (item) =>
                            item['type'] == 'workflow_agent' &&
                            (item['phaseIndex'] as num?)?.toInt() == index,
                      )
                      .toList();
                  return _phase(
                    phase['title']?.toString() ?? 'Phase ${index + 1}',
                    phase['detail']?.toString(),
                    agents,
                  );
                }),
              if (phases.isEmpty)
                ...progress
                    .where((item) => item['type'] == 'workflow_agent')
                    .map(_agent),
              if (_text('resultPreview').isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: Color(0xFF313244))),
                  ),
                  child: Text(
                    _text('resultPreview'),
                    style: const TextStyle(
                      color: Color(0xFFCDD6F4),
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _phase(
    String title,
    String? detail,
    List<Map<String, dynamic>> agents,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFFCBA6F7),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (detail != null && detail.isNotEmpty)
            Text(
              detail,
              style: const TextStyle(color: Color(0xFF7F849C), fontSize: 10),
            ),
          const SizedBox(height: 4),
          ...agents.map(_agent),
        ],
      ),
    );
  }

  Widget _agent(Map<String, dynamic> agent) {
    final status = agent['state']?.toString() ?? 'queued';
    final active = status == 'running' || status == 'queued';
    final color = status == 'completed'
        ? const Color(0xFFA6E3A1)
        : status == 'failed'
        ? const Color(0xFFF38BA8)
        : const Color(0xFF89B4FA);
    final details = <String>[
      if (agent['model']?.toString().isNotEmpty == true)
        agent['model'].toString(),
      if ((agent['tokens'] as num?)?.toInt() case final tokens? when tokens > 0)
        '$tokens tokens',
      if ((agent['toolCalls'] as num?)?.toInt() case final calls?
          when calls > 0)
        '$calls tools',
      if ((agent['durationMs'] as num?)?.toInt() case final duration?
          when duration > 0)
        _duration(duration),
    ];
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(left: 24, bottom: 8),
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: active
          ? SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
            )
          : Icon(
              status == 'completed' ? Icons.check_circle : Icons.error_outline,
              color: color,
              size: 14,
            ),
      title: Text(
        agent['label']?.toString() ?? agent['agentId']?.toString() ?? 'Agent',
        style: const TextStyle(color: Color(0xFFCDD6F4), fontSize: 11),
      ),
      subtitle: details.isEmpty
          ? null
          : Text(
              details.join(' · '),
              style: const TextStyle(color: Color(0xFF7F849C), fontSize: 9),
            ),
      children: [
        if (agent['promptPreview']?.toString().isNotEmpty == true)
          _detail('PROMPT', agent['promptPreview'].toString()),
        if (agent['resultPreview']?.toString().isNotEmpty == true)
          _detail('RESULT', agent['resultPreview'].toString()),
        if (agent['error']?.toString().isNotEmpty == true)
          _detail('ERROR', agent['error'].toString()),
      ],
    );
  }

  Widget _detail(String label, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF7F849C),
            fontSize: 8,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          text,
          style: const TextStyle(
            color: Color(0xFFA6ADC8),
            fontSize: 10,
            height: 1.3,
          ),
        ),
      ],
    ),
  );
}
