import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class TodoListCard extends StatefulWidget {
  final List<Map<String, dynamic>> todos;
  final VoidCallback? onDismiss;

  const TodoListCard({super.key, required this.todos, this.onDismiss});

  @override
  State<TodoListCard> createState() => _TodoListCardState();
}

class _TodoListCardState extends State<TodoListCard> {
  bool _collapsed = true;

  @override
  Widget build(BuildContext context) {
    if (widget.todos.isEmpty) return const SizedBox.shrink();

    final completed = widget.todos.where((t) => t['status'] == 'completed').length;
    final total = widget.todos.length;

    // Find the in-progress task label (if any)
    final inProgressTask = widget.todos.where((t) => t['status'] == 'in_progress').firstOrNull;
    final activeLabel = inProgressTask != null
        ? (inProgressTask['activeForm'] as String? ?? inProgressTask['content'] as String? ?? '')
        : null;

    return Container(
      margin: EdgeInsets.symmetric(horizontal: 8, vertical: _collapsed ? 2 : 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E2E),
        borderRadius: BorderRadius.circular(_collapsed ? 8 : 12),
        border: Border.all(color: const Color(0xFF313244), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header — tappable to toggle collapse
          InkWell(
            onTap: () => setState(() => _collapsed = !_collapsed),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(_collapsed ? 8 : 12),
              topRight: Radius.circular(_collapsed ? 8 : 12),
              bottomLeft: Radius.circular(_collapsed ? 8 : 0),
              bottomRight: Radius.circular(_collapsed ? 8 : 0),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(10, _collapsed ? 6 : 10, 6, _collapsed ? 6 : 6),
              child: Row(
                children: [
                  Icon(
                    Icons.checklist,
                    size: _collapsed ? 14 : 16,
                    color: const Color(0xFF89B4FA),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$completed/$total',
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: _collapsed ? 10 : 11,
                      color: const Color(0xFFA6ADC8),
                    ),
                  ),
                  // Show active task inline when collapsed
                  if (_collapsed && activeLabel != null) ...[
                    const SizedBox(width: 6),
                    Container(width: 1, height: 10, color: const Color(0xFF313244)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        activeLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 10,
                          color: const Color(0xFFF9E2AF),
                        ),
                      ),
                    ),
                  ] else if (_collapsed) ...[
                    const SizedBox(width: 6),
                    // Inline progress bar when collapsed
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: total > 0 ? completed / total : 0,
                          minHeight: 2,
                          backgroundColor: const Color(0xFF313244),
                          color: const Color(0xFFA6E3A1),
                        ),
                      ),
                    ),
                  ] else ...[
                    const SizedBox(width: 4),
                    Text(
                      'Tasks',
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF89B4FA),
                      ),
                    ),
                    const Spacer(),
                  ],
                  if (!_collapsed && widget.onDismiss != null)
                    GestureDetector(
                      onTap: widget.onDismiss,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(
                          Icons.close,
                          size: 16,
                          color: Color(0xFF6C7086),
                        ),
                      ),
                    ),
                  if (_collapsed) ...[
                    const SizedBox(width: 4),
                    if (widget.onDismiss != null)
                      GestureDetector(
                        onTap: widget.onDismiss,
                        child: const Icon(Icons.close, size: 14, color: Color(0xFF6C7086)),
                      ),
                  ],
                  Icon(
                    _collapsed ? Icons.expand_more : Icons.expand_less,
                    size: _collapsed ? 16 : 18,
                    color: const Color(0xFF6C7086),
                  ),
                ],
              ),
            ),
          ),
          // Progress bar — only when expanded
          if (!_collapsed)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: total > 0 ? completed / total : 0,
                  minHeight: 3,
                  backgroundColor: const Color(0xFF313244),
                  color: const Color(0xFFA6E3A1),
                ),
              ),
            ),
          // Todo items — hidden when collapsed
          if (!_collapsed) ...[
            const SizedBox(height: 6),
            ...widget.todos.map((todo) => _buildTodoItem(todo)),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  Widget _buildTodoItem(Map<String, dynamic> todo) {
    final status = todo['status'] as String? ?? 'pending';
    final content = todo['content'] as String? ?? '';
    final activeForm = todo['activeForm'] as String? ?? content;

    IconData icon;
    Color iconColor;
    String displayText;
    TextStyle textStyle;

    switch (status) {
      case 'completed':
        icon = Icons.check_circle;
        iconColor = const Color(0xFFA6E3A1); // green
        displayText = content;
        textStyle = GoogleFonts.jetBrainsMono(
          fontSize: 11,
          color: const Color(0xFF6C7086),
          decoration: TextDecoration.lineThrough,
          height: 1.4,
        );
        break;
      case 'in_progress':
        icon = Icons.play_circle_fill;
        iconColor = const Color(0xFFF9E2AF); // yellow
        displayText = activeForm;
        textStyle = GoogleFonts.jetBrainsMono(
          fontSize: 11,
          color: const Color(0xFFCDD6F4),
          fontWeight: FontWeight.w600,
          height: 1.4,
        );
        break;
      default: // pending
        icon = Icons.radio_button_unchecked;
        iconColor = const Color(0xFF585B70);
        displayText = content;
        textStyle = GoogleFonts.jetBrainsMono(
          fontSize: 11,
          color: const Color(0xFFA6ADC8),
          height: 1.4,
        );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 14, color: iconColor),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(displayText, style: textStyle),
          ),
        ],
      ),
    );
  }
}
