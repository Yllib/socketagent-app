import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/raw_event.dart';
import 'scroll_passthrough.dart';

/// Card for a single SdkItem — either a message group or standalone event
class RawEventCard extends StatefulWidget {
  final SdkItem item;
  const RawEventCard({super.key, required this.item});

  @override
  State<RawEventCard> createState() => _RawEventCardState();
}

class _RawEventCardState extends State<RawEventCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    switch (item.itemType) {
      case SdkItemType.message:
        return _buildMessageCard(item.messageGroup!);
      case SdkItemType.system:
        return _buildSystemCard(item);
      case SdkItemType.toolProgress:
        return _buildProgressCard(item);
      case SdkItemType.result:
        return _buildResultCard(item);
      case SdkItemType.standalone:
        return _buildStandaloneCard(item);
    }
  }

  // ─── Message Group Card ───────────────────────────────────────────

  Widget _buildMessageCard(MessageGroup g) {
    final color = g.hasToolUse ? Colors.orange.shade300 : Colors.green.shade300;
    final inputTokens = g.inputUsage?['input_tokens'];
    final cacheRead = g.inputUsage?['cache_read_input_tokens'];

    return _card(
      color: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  Text(_time(g.timestamp), style: _tsStyle),
                  const SizedBox(width: 6),
                  _chip('message', color),
                  const SizedBox(width: 6),
                  // Content summary badges
                  ...g.contentBlocks.map(
                    (b) => Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: _chip(
                        b.blockType == 'tool_use'
                            ? (b.toolName ?? 'tool')
                            : b.blockType,
                        b.blockType == 'tool_use'
                            ? Colors.orange.shade200
                            : Colors.green.shade200,
                      ),
                    ),
                  ),
                  const Spacer(),
                  // Token badges
                  if (inputTokens != null)
                    _tokenBadge('in', '$inputTokens', Colors.blue.shade200),
                  if (g.outputTokens != null)
                    _tokenBadge(
                      'out',
                      '${g.outputTokens}',
                      Colors.purple.shade200,
                    ),
                  // Streaming indicator
                  if (!g.complete)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: Color(0xFF585B70),
                        ),
                      ),
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: const Color(0xFF585B70),
                  ),
                ],
              ),
            ),
          ),
          // Expanded: show each content block as a section
          if (_expanded) ...[
            const Divider(height: 1, color: Color(0xFF313244)),
            // Metadata row
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
              child: Wrap(
                spacing: 12,
                children: [
                  if (g.model != null) _meta('model', g.model!),
                  if (inputTokens != null) _meta('input', '$inputTokens'),
                  if (cacheRead != null) _meta('cache_read', '$cacheRead'),
                  if (g.inputUsage?['cache_creation_input_tokens'] != null)
                    _meta(
                      'cache_create',
                      '${g.inputUsage!['cache_creation_input_tokens']}',
                    ),
                  if (g.outputTokens != null)
                    _meta('output', '${g.outputTokens}'),
                  if (g.stopReason != null) _meta('stop', g.stopReason!),
                  _meta('blocks', '${g.contentBlocks.length}'),
                  _meta('deltas', '${g.totalDeltas}'),
                ],
              ),
            ),
            // Content blocks
            ...g.contentBlocks.map(_buildContentBlockSection),
            // Tool results
            if (g.toolResults != null && g.toolResults!.isNotEmpty)
              ...g.toolResults!.map(_buildToolResultSection),
          ],
        ],
      ),
    );
  }

  Widget _buildContentBlockSection(ContentBlock b) {
    final isToolUse = b.blockType == 'tool_use';
    final color = isToolUse ? Colors.orange.shade300 : Colors.green.shade300;
    final label = isToolUse ? (b.toolName ?? 'tool_use') : b.blockType;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Block header
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
          child: Row(
            children: [
              _chip(label, color),
              const SizedBox(width: 6),
              Text(
                '${b.deltaCount} deltas · ${b.accumulatedText.length} chars',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9,
                  color: Color(0xFF6C7086),
                ),
              ),
              if (!b.complete) ...[
                const SizedBox(width: 6),
                const SizedBox(
                  width: 8,
                  height: 8,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Color(0xFF585B70),
                  ),
                ),
              ],
            ],
          ),
        ),
        // Block content
        if (b.accumulatedText.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(10, 2, 10, 6),
            constraints: const BoxConstraints(maxHeight: 200),
            decoration: BoxDecoration(
              color: const Color(0xFF11111B),
              borderRadius: BorderRadius.circular(4),
            ),
            child: ScrollPassthrough(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(8),
                child: SelectableText(
                  b.accumulatedText,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: isToolUse
                        ? Colors.orange.shade100
                        : const Color(0xFFA6ADC8),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildToolResultSection(Map<String, dynamic> result) {
    final type = result['type'] as String? ?? '?';
    final content = result['content']?.toString() ?? '';
    final preview = content.length > 300
        ? '${content.substring(0, 300)}...'
        : content;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
          child: Row(
            children: [
              _chip(
                type == 'tool_result' ? 'result' : type,
                Colors.amber.shade300,
              ),
              if (result['tool_use_id'] != null) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    result['tool_use_id'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 9,
                      color: Color(0xFF6C7086),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (preview.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(10, 2, 10, 6),
            constraints: const BoxConstraints(maxHeight: 150),
            decoration: BoxDecoration(
              color: const Color(0xFF11111B),
              borderRadius: BorderRadius.circular(4),
            ),
            child: ScrollPassthrough(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(8),
                child: SelectableText(
                  preview,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.amber.shade100,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ─── System Card ──────────────────────────────────────────────────

  Widget _buildSystemCard(SdkItem item) {
    final subtype = item.systemSubtype ?? '?';
    final color = subtype == 'status'
        ? Colors.yellow.shade300
        : Colors.cyan.shade300;

    // Build detail string from available fields
    final parts = <String>[];
    if (item.systemStatus != null) parts.add(item.systemStatus!);
    if (item.trigger != null) parts.add('trigger: ${item.trigger}');
    if (item.taskId != null) parts.add('task: ${item.taskId}');
    if (item.summary != null) parts.add(item.summary!);
    if (item.compactMetadata != null) {
      final cm = item.compactMetadata!;
      if (cm['pre_tokens'] != null) parts.add('pre: ${cm['pre_tokens']}');
      if (cm['post_tokens'] != null) parts.add('post: ${cm['post_tokens']}');
    }
    // Fall back to session ID if nothing else
    if (parts.isEmpty && item.sessionId != null) {
      parts.add(
        item.sessionId!.length > 12
            ? item.sessionId!.substring(0, 12)
            : item.sessionId!,
      );
    }

    return _compactCard(
      color: color,
      label: 'sys:$subtype',
      detail: parts.isEmpty ? '' : parts.join(' · '),
      timestamp: item.timestamp,
    );
  }

  // ─── Tool Progress Card ───────────────────────────────────────────

  Widget _buildProgressCard(SdkItem item) {
    return _compactCard(
      color: Colors.orange.shade200,
      label: 'progress',
      detail:
          '${item.progressToolName ?? '?'} · ${item.elapsed?.toStringAsFixed(1) ?? '?'}s',
      timestamp: item.timestamp,
    );
  }

  // ─── Result Card ──────────────────────────────────────────────────

  Widget _buildResultCard(SdkItem item) {
    final cost = item.cost != null ? '\$${item.cost!.toStringAsFixed(4)}' : '?';
    final turns = item.numTurns ?? '?';
    final dur = item.durationMs != null
        ? '${(item.durationMs! / 1000).toStringAsFixed(1)}s'
        : '';

    return _card(
      color: Colors.blue.shade300,
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  Text(_time(item.timestamp), style: _tsStyle),
                  const SizedBox(width: 6),
                  _chip('result', Colors.blue.shade300),
                  const SizedBox(width: 8),
                  _tokenBadge('cost', cost, Colors.blue.shade200),
                  _tokenBadge('turns', '$turns', Colors.purple.shade200),
                  if (dur.isNotEmpty)
                    _tokenBadge('time', dur, Colors.green.shade200),
                  if (item.isError == true)
                    _tokenBadge('ERROR', '', Colors.red.shade300),
                  const Spacer(),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: const Color(0xFF585B70),
                  ),
                ],
              ),
            ),
            if (_expanded && item.modelUsage != null) ...[
              const Divider(height: 1, color: Color(0xFF313244)),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 2,
                  children: item.modelUsage!.entries
                      .map((kv) => _meta(kv.key, '${kv.value}'))
                      .toList(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ─── Standalone (orphan assistant/user) Card ──────────────────────

  Widget _buildStandaloneCard(SdkItem item) {
    final role = item.standaloneRole ?? '?';
    final color = role == 'assistant'
        ? Colors.purple.shade300
        : Colors.teal.shade300;
    final blocks = item.standaloneBlocks ?? [];
    final summary = blocks
        .map((b) {
          final type = b['type'] as String? ?? '?';
          if (type == 'text') return 'text';
          if (type == 'tool_use') return b['name'] as String? ?? 'tool';
          if (type == 'tool_result') return 'result';
          return type;
        })
        .join(', ');

    final rawJson = item.rawData == null
        ? ''
        : const JsonEncoder.withIndent('  ').convert(item.rawData);

    return _card(
      color: color,
      child: InkWell(
        onTap: rawJson.isEmpty
            ? null
            : () => setState(() => _expanded = !_expanded),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  Text(_time(item.timestamp), style: _tsStyle),
                  const SizedBox(width: 6),
                  _chip(role, color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      summary.isEmpty ? '(empty)' : summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFFA6ADC8),
                      ),
                    ),
                  ),
                  if (rawJson.isNotEmpty)
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: const Color(0xFF585B70),
                    ),
                ],
              ),
            ),
            if (_expanded && rawJson.isNotEmpty) ...[
              const Divider(height: 1, color: Color(0xFF313244)),
              Container(
                constraints: const BoxConstraints(maxHeight: 240),
                padding: const EdgeInsets.all(10),
                child: ScrollPassthrough(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      rawJson,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: Color(0xFFA6ADC8),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ─── Shared Widgets ───────────────────────────────────────────────

  Widget _card({required Color color, required Widget child}) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E2E),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: child,
    );
  }

  Widget _compactCard({
    required Color color,
    required String label,
    required String detail,
    required DateTime timestamp,
  }) {
    return _card(
      color: color,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            Text(_time(timestamp), style: _tsStyle),
            const SizedBox(width: 6),
            _chip(label, color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: Color(0xFF9399B2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withAlpha(60), width: 0.5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _tokenBadge(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label ',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 9,
              color: color.withAlpha(150),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _meta(String key, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$key ',
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 9,
            color: Color(0xFF6C7086),
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 9,
            color: Color(0xFFA6ADC8),
          ),
        ),
      ],
    );
  }

  static const _tsStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: 9,
    color: Color(0xFF585B70),
  );

  static String _time(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }
}
