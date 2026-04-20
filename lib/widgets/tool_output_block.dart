import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/message.dart';
import '../services/chat_provider.dart';
import 'scroll_passthrough.dart';

class ToolOutputBlock extends StatefulWidget {
  final ChatMessage message;
  final bool greenTheme;

  const ToolOutputBlock({super.key, required this.message, this.greenTheme = false});

  @override
  State<ToolOutputBlock> createState() => _ToolOutputBlockState();
}

class _ToolOutputBlockState extends State<ToolOutputBlock> {
  bool _expanded = false;

  bool get _isBash => widget.message.toolName == 'Bash';
  bool get _isEditTool => widget.message.toolName == 'Edit';
  bool get _isWriteTool => widget.message.toolName == 'Write';
  bool get _isTaskOutput => widget.message.toolName == 'TaskOutput';
  bool get _hasImage => widget.message.toolImageData != null && widget.message.toolImageData!.isNotEmpty;

  /// Parse TaskOutput XML-like result into structured fields
  Map<String, String>? get _parsedTaskOutput {
    if (!_isTaskOutput) return null;
    final raw = widget.message.toolOutput;
    if (raw == null || raw.isEmpty) return null;
    final result = <String, String>{};
    for (final tag in ['retrieval_status', 'task_id', 'task_type', 'status', 'exit_code']) {
      final match = RegExp('<$tag>(.*?)</$tag>', dotAll: true).firstMatch(raw);
      if (match != null) result[tag] = match.group(1)!.trim();
    }
    // Extract <output> content
    final outputMatch = RegExp(r'<output>(.*?)</output>', dotAll: true).firstMatch(raw);
    if (outputMatch != null) result['output'] = outputMatch.group(1)!.trim();
    return result.isEmpty ? null : result;
  }

  String get _toolDescription {
    final input = widget.message.toolInput;
    if (input == null) return '';
    if (input.containsKey('command')) return input['command'] as String? ?? '';
    if (input.containsKey('file_path')) {
      return input['file_path'] as String? ?? '';
    }
    if (input.containsKey('pattern')) return input['pattern'] as String? ?? '';
    if (input.containsKey('query')) return input['query'] as String? ?? '';
    if (input.containsKey('task_id')) {
      final taskDesc = input['_taskDescription'] as String?;
      if (taskDesc != null) return taskDesc;
      final taskId = input['task_id'] as String? ?? '';
      final timeout = input['timeout'] as num?;
      final blocking = input['block'] == true;
      final parts = <String>[taskId];
      if (blocking && timeout != null) parts.add('${(timeout / 1000).round()}s timeout');
      return parts.join(' · ');
    }
    return '';
  }

  /// For Bash, format the command with line breaks at && and ;
  String get _bashFormatted {
    final cmd = widget.message.toolInput?['command'] as String? ?? '';
    // Split on && and ; but keep the delimiter at the start of the next line
    return cmd
        .replaceAll(' && ', '\n&& ')
        .replaceAll('; ', '\n; ');
  }

  /// Short single-line summary for Bash header when collapsed
  String get _bashSummary {
    final input = widget.message.toolInput;
    if (input == null) return '';
    // Use description if available, otherwise first segment of command
    final desc = input['description'] as String?;
    if (desc != null && desc.isNotEmpty) return desc;
    final cmd = input['command'] as String? ?? '';
    // Take first command segment (before && or ;)
    final firstSeg = cmd.split(RegExp(r'\s*&&\s*|\s*;\s*')).first;
    return firstSeg;
  }

  String? get _editDiff {
    if (!_isEditTool) return null;
    final input = widget.message.toolInput;
    if (input == null) return null;
    final filePath = input['file_path'] as String? ?? '';
    final oldStr = input['old_string'] as String? ?? '';
    final newStr = input['new_string'] as String? ?? '';
    if (oldStr.isEmpty && newStr.isEmpty) return null;

    final buf = StringBuffer();
    if (filePath.isNotEmpty) {
      buf.writeln('--- $filePath');
      buf.writeln('+++ $filePath');
    }
    for (final line in oldStr.split('\n')) {
      buf.writeln('- $line');
    }
    for (final line in newStr.split('\n')) {
      buf.writeln('+ $line');
    }
    return buf.toString().trimRight();
  }

  @override
  Widget build(BuildContext context) {
    final rawToolName = widget.message.toolName ?? 'Tool';
    final parsed = _parsedTaskOutput;
    final taskStatus = parsed?['retrieval_status'] ?? parsed?['status'];
    final toolName = _isTaskOutput
        ? (widget.message.toolInput?['block'] == true ? 'Waiting' : 'Checking Task')
        : rawToolName;
    final output = widget.message.toolOutput;
    final gotResult = output != null;
    final hasOutput = output != null && output.isNotEmpty;
    final isStreaming = widget.message.toolStreaming;
    final elapsed = widget.message.toolElapsedSeconds;
    final editDiff = _editDiff;

    final colorful = context.select<ChatProvider, bool>((p) => p.colorfulCards);
    final accentColor = widget.greenTheme
        ? const Color(0xFFA6E3A1)
        : colorful
            ? _toolAccentColor(rawToolName)
            : const Color(0xFF89B4FA);

    // Always expandable if there's content to show
    final writeContent = _isWriteTool ? (widget.message.toolInput?['content'] as String?) : null;
    final hasExpandableContent = _isBash || _isWriteTool || hasOutput || editDiff != null || _hasImage;
    final isBg = widget.message.isBackgrounded;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isBg ? const Color(0xFF1E2030) : const Color(0xFF1E1E2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isBg
              ? accentColor.withAlpha(120)
              : colorful
                  ? accentColor.withAlpha(80)
                  : const Color(0xFF313244),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(12)),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    _toolIcon(rawToolName),
                    size: 16,
                    color: accentColor,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    toolName,
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: accentColor,
                    ),
                  ),
                  if (isBg) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF9E2AF).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'BG',
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFFF9E2AF),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _isBash ? _bashSummary : _toolDescription,
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 11,
                        color: const Color(0xFFA6ADC8),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // TaskOutput status badge
                  if (_isTaskOutput && taskStatus != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: _taskStatusColor(taskStatus).withAlpha(30),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        taskStatus,
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: _taskStatusColor(taskStatus),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  if (_hasImage && !_expanded) ...[
                    const Icon(
                      Icons.image,
                      size: 14,
                      color: Color(0xFFA6E3A1),
                    ),
                    const SizedBox(width: 4),
                  ],
                  if (hasExpandableContent && gotResult && !isStreaming)
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: const Color(0xFF6C7086),
                    )
                  else if (gotResult && !isStreaming)
                    const Icon(
                      Icons.check,
                      size: 16,
                      color: Color(0xFF6C7086),
                    )
                  else ...[
                    if (elapsed > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          '${elapsed.toStringAsFixed(0)}s',
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 10,
                            color: const Color(0xFF6C7086),
                          ),
                        ),
                      ),
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: accentColor,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // Bash: show formatted command + output when expanded
          if (_isBash && _expanded) ...[
            Container(
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: Color(0xFF313244), width: 1),
                ),
              ),
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                _bashFormatted,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 11,
                  color: const Color(0xFFF9E2AF),
                  height: 1.4,
                ),
              ),
            ),
            if (hasOutput) _buildOutputContainer(output),
          ],
          // Diff view for Edit tool
          if (_isEditTool && editDiff != null && _expanded)
            Container(
              constraints: const BoxConstraints(maxHeight: 300),
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: Color(0xFF313244), width: 1),
                ),
              ),
              child: ScrollPassthrough(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: _buildDiffView(editDiff),
                ),
              ),
            ),
          // Write: show file content when expanded
          if (_isWriteTool && writeContent != null && _expanded)
            _buildWriteContent(writeContent),
          // TaskOutput: show parsed content
          if (_isTaskOutput && hasOutput && _expanded)
            _buildTaskOutputContent(),
          // Regular output (for non-Bash, non-Edit, non-TaskOutput, non-Write tools)
          if (!_isBash && !_isEditTool && !_isWriteTool && !_isTaskOutput && hasOutput && _expanded)
            _buildOutputContainer(output),
          // Inline image (visible when expanded)
          if (_hasImage && _expanded)
            _buildInlineImage(),
          // Placeholder for images loading from history
          if (_expanded &&
              widget.message.toolImageFilePath != null &&
              widget.message.toolImageFilePath!.isNotEmpty &&
              !_hasImage)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: Color(0xFF313244), width: 1),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF6C7086)),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Loading image...',
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 11,
                      color: const Color(0xFF6C7086),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Color _taskStatusColor(String status) {
    switch (status) {
      case 'success':
        return const Color(0xFFA6E3A1); // green
      case 'completed':
        return const Color(0xFFA6E3A1);
      case 'timeout':
        return const Color(0xFFF9E2AF); // yellow
      case 'running':
        return const Color(0xFF89B4FA); // blue
      case 'error':
        return const Color(0xFFF38BA8); // red
      default:
        return const Color(0xFFA6ADC8); // grey
    }
  }

  Widget _buildTaskOutputContent() {
    final parsed = _parsedTaskOutput;
    if (parsed == null) return _buildOutputContainer(widget.message.toolOutput);

    final taskOutput = parsed['output'];
    final exitCode = parsed['exit_code'];
    final status = parsed['retrieval_status'] ?? parsed['status'];

    // If no meaningful content, show nothing
    if (taskOutput == null && status == null) {
      return _buildOutputContainer(widget.message.toolOutput);
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 300),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(0xFF313244), width: 1),
        ),
      ),
      child: ScrollPassthrough(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (exitCode != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    'Exit code: $exitCode',
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 10,
                      color: exitCode == '0'
                          ? const Color(0xFFA6E3A1)
                          : const Color(0xFFF38BA8),
                    ),
                  ),
                ),
              if (taskOutput != null)
                SelectableText(
                  taskOutput,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 11,
                    color: const Color(0xFFCDD6F4),
                    height: 1.4,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInlineImage() {
    final bytes = base64Decode(widget.message.toolImageData!);
    return GestureDetector(
      onTap: () => _showFullscreenImage(bytes),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 300),
        decoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: Color(0xFF313244), width: 1),
          ),
        ),
        padding: const EdgeInsets.all(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }

  void _showFullscreenImage(List<int> bytes) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 5.0,
              child: Center(
                child: Image.memory(
                  bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
                  fit: BoxFit.contain,
                ),
              ),
            ),
            Positioned(
              top: 40,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWriteContent(String content) {
    final lines = content.split('\n');
    return Container(
      constraints: const BoxConstraints(maxHeight: 400),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(0xFF313244), width: 1),
        ),
      ),
      child: ScrollPassthrough(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Line count header
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${lines.length} lines',
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 10,
                    color: const Color(0xFF6C7086),
                  ),
                ),
              ),
              // File content with line numbers
              ...List.generate(lines.length, (i) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 36,
                      child: Text(
                        '${i + 1}',
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 11,
                          color: const Color(0xFF6C7086),
                          height: 1.4,
                        ),
                        textAlign: TextAlign.right,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SelectableText(
                        lines[i],
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 11,
                          color: const Color(0xFFA6E3A1),
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOutputContainer(String? text) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 300),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(0xFF313244), width: 1),
        ),
      ),
      child: ScrollPassthrough(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: SelectableText(
            text ?? '',
            style: GoogleFonts.jetBrainsMono(
              fontSize: 11,
              color: const Color(0xFFCDD6F4),
              height: 1.4,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDiffView(String diff) {
    final lines = diff.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: lines.map((line) {
        Color textColor;
        Color? bgColor;
        if (line.startsWith('---') || line.startsWith('+++')) {
          textColor = const Color(0xFFA6ADC8);
          bgColor = null;
        } else if (line.startsWith('- ')) {
          textColor = const Color(0xFFF38BA8); // red
          bgColor = const Color(0xFFF38BA8).withAlpha(20);
        } else if (line.startsWith('+ ')) {
          textColor = const Color(0xFFA6E3A1); // green
          bgColor = const Color(0xFFA6E3A1).withAlpha(20);
        } else {
          textColor = const Color(0xFFCDD6F4);
          bgColor = null;
        }
        return Container(
          color: bgColor,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: SelectableText(
            line,
            style: GoogleFonts.jetBrainsMono(
              fontSize: 11,
              color: textColor,
              height: 1.4,
            ),
          ),
        );
      }).toList(),
    );
  }

  static Color _toolAccentColor(String toolName) {
    switch (toolName) {
      case 'Bash':
        return const Color(0xFFF9E2AF); // yellow
      case 'Read':
        return const Color(0xFFA6E3A1); // green
      case 'Write':
        return const Color(0xFFFAB387); // peach
      case 'Edit':
        return const Color(0xFFCBA6F7); // mauve
      case 'Grep':
        return const Color(0xFF94E2D5); // teal
      case 'Glob':
        return const Color(0xFF89DCFE); // sky
      case 'WebSearch':
        return const Color(0xFFB4BEFE); // lavender
      case 'WebFetch':
        return const Color(0xFF74C7EC); // sapphire
      case 'TodoWrite':
        return const Color(0xFFF2CDCD); // flamingo
      case 'TaskOutput':
        return const Color(0xFFF9E2AF); // yellow
      case 'Task':
      case 'Agent':
        return const Color(0xFFEBA0AC); // maroon
      default:
        return const Color(0xFF89B4FA); // blue
    }
  }

  IconData _toolIcon(String toolName) {
    switch (toolName) {
      case 'Bash':
        return Icons.terminal;
      case 'Read':
        return Icons.description;
      case 'Write':
        return Icons.edit_document;
      case 'Edit':
        return Icons.edit;
      case 'Grep':
        return Icons.search;
      case 'Glob':
        return Icons.folder_open;
      case 'WebSearch':
        return Icons.travel_explore;
      case 'WebFetch':
        return Icons.download;
      case 'TodoWrite':
        return Icons.checklist;
      case 'TaskOutput':
        return Icons.hourglass_top;
      case 'Task':
      case 'Agent':
        return Icons.account_tree;
      default:
        return Icons.build;
    }
  }
}
