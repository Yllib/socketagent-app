import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/message.dart';
import 'scroll_passthrough.dart';
import 'structured_data_view.dart';

class SocketAgentToolCard extends StatefulWidget {
  final ChatMessage message;

  const SocketAgentToolCard({super.key, required this.message});

  static bool supports(ChatMessage message) => const {
    'ScheduleTask',
    'TaskBatch',
    'AgentSession',
    'SearchSkills',
    'ReadSkill',
  }.contains(message.toolName);

  @override
  State<SocketAgentToolCard> createState() => _SocketAgentToolCardState();
}

class _SocketAgentToolCardState extends State<SocketAgentToolCard> {
  bool _expanded = false;

  Map<String, dynamic> get _input =>
      widget.message.toolInput ?? const <String, dynamic>{};

  String get _title {
    switch (widget.message.toolName) {
      case 'ScheduleTask':
        return 'Scheduled Task';
      case 'TaskBatch':
        return 'Task List';
      case 'AgentSession':
        return 'Delegated Agent';
      case 'SearchSkills':
        return 'Search Skills';
      case 'ReadSkill':
        return 'Read Skill';
      default:
        return widget.message.toolName ?? 'SocketAgent';
    }
  }

  IconData get _icon {
    switch (widget.message.toolName) {
      case 'ScheduleTask':
        return Icons.event_repeat;
      case 'TaskBatch':
        return Icons.checklist;
      case 'AgentSession':
        return Icons.account_tree_outlined;
      case 'SearchSkills':
        return Icons.manage_search;
      case 'ReadSkill':
        return Icons.menu_book_outlined;
      default:
        return Icons.extension;
    }
  }

  String get _subtitle {
    switch (widget.message.toolName) {
      case 'ScheduleTask':
        return (_input['name'] ?? _input['prompt'] ?? '').toString();
      case 'TaskBatch':
        final tasks = _input['tasks'] as List?;
        final count = tasks?.length ?? (_input['task_ids'] as List?)?.length;
        return '${_input['mode'] ?? 'update'}${count == null ? '' : ' · $count'}';
      case 'AgentSession':
        return [_input['action'], _input['label'], _input['backend']]
            .where((value) => value?.toString().trim().isNotEmpty == true)
            .join(' · ');
      case 'SearchSkills':
        return _input['query']?.toString() ?? 'Available skills';
      case 'ReadSkill':
        return (_input['name'] ?? _input['filePath'] ?? '').toString();
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF94E2D5);
    final output = widget.message.toolOutput?.trim() ?? '';
    final decodedOutput = decodeJsonDocument(output);
    final hasDetails = _input.isNotEmpty || output.isNotEmpty;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: hasDetails
                ? () => setState(() => _expanded = !_expanded)
                : null,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  Icon(_icon, size: 17, color: accent),
                  const SizedBox(width: 8),
                  Text(
                    _title,
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: accent,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 10.5,
                        color: const Color(0xFFA6ADC8),
                      ),
                    ),
                  ),
                  if (widget.message.toolStreaming)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: accent,
                      ),
                    )
                  else
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: const Color(0xFF6C7086),
                    ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Container(
              constraints: const BoxConstraints(maxHeight: 360),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Color(0xFF313244))),
              ),
              child: ScrollPassthrough(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_input.isNotEmpty) ...[
                        const _SectionLabel('REQUEST'),
                        StructuredDataView(value: _input, accent: accent),
                      ],
                      if (output.isNotEmpty) ...[
                        const SizedBox(height: 7),
                        const _SectionLabel('RESULT'),
                        if (decodedOutput != null)
                          StructuredDataView(
                            value: decodedOutput,
                            accent: accent,
                          )
                        else
                          SelectableText(
                            output,
                            style: GoogleFonts.jetBrainsMono(
                              fontSize: 10.5,
                              height: 1.4,
                              color: const Color(0xFFCDD6F4),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF94E2D5),
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
