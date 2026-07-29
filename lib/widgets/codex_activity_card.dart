import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/message.dart';
import 'scroll_passthrough.dart';
import 'tool_output_block.dart';

class CodexActivityCard extends StatefulWidget {
  final ChatMessage message;

  const CodexActivityCard({super.key, required this.message});

  static bool supports(ChatMessage message) {
    return const {
      'webSearch',
      'mcpToolCall',
      'dynamicToolCall',
      'reviewMode',
      'sleep',
      'hookPrompt',
      'modelRerouted',
      'safetyBuffering',
      'modelVerification',
      'autoApprovalReview',
      'unrecognized',
    }.contains(message.toolInput?['_codexItemType']?.toString());
  }

  @override
  State<CodexActivityCard> createState() => _CodexActivityCardState();
}

class _CodexActivityCardState extends State<CodexActivityCard> {
  bool _expanded = false;

  Map<String, dynamic> get _input =>
      widget.message.toolInput ?? const <String, dynamic>{};
  String get _kind => _input['_codexItemType']?.toString() ?? '';

  Color get _accent {
    switch (_kind) {
      case 'webSearch':
        return const Color(0xFFB4BEFE);
      case 'mcpToolCall':
        return const Color(0xFF89DCEB);
      case 'dynamicToolCall':
        return const Color(0xFFCBA6F7);
      case 'reviewMode':
        return const Color(0xFFA6E3A1);
      case 'sleep':
        return const Color(0xFFF9E2AF);
      case 'hookPrompt':
        return const Color(0xFFF5C2E7);
      case 'modelRerouted':
        return const Color(0xFFFAB387);
      case 'safetyBuffering':
        return const Color(0xFFF9E2AF);
      case 'modelVerification':
        return const Color(0xFFF38BA8);
      case 'autoApprovalReview':
        return const Color(0xFF94E2D5);
      case 'unrecognized':
        return const Color(0xFFFAB387);
      default:
        return const Color(0xFF89B4FA);
    }
  }

  IconData get _icon {
    switch (_kind) {
      case 'webSearch':
        return Icons.travel_explore;
      case 'mcpToolCall':
        return Icons.extension;
      case 'dynamicToolCall':
        return Icons.bolt;
      case 'reviewMode':
        return Icons.fact_check_outlined;
      case 'sleep':
        return Icons.timer_outlined;
      case 'hookPrompt':
        return Icons.account_tree_outlined;
      case 'modelRerouted':
        return Icons.swap_horiz;
      case 'safetyBuffering':
        return Icons.shield_outlined;
      case 'modelVerification':
        return Icons.verified_user_outlined;
      case 'autoApprovalReview':
        return Icons.policy_outlined;
      case 'unrecognized':
        return Icons.new_releases_outlined;
      default:
        return Icons.auto_awesome;
    }
  }

  String get _title {
    switch (_kind) {
      case 'webSearch':
        final action = _asMap(_input['action']);
        switch (action['type']?.toString()) {
          case 'openPage':
            return 'Open Page';
          case 'findInPage':
            return 'Find on Page';
          default:
            return 'Web Search';
        }
      case 'mcpToolCall':
        final context = _asMap(_input['_codexAppContext']);
        return context['appName']?.toString().trim().isNotEmpty == true
            ? context['appName'].toString()
            : _input['_codexServer']?.toString() ?? 'MCP';
      case 'dynamicToolCall':
        return _input['_codexNamespace']?.toString().trim().isNotEmpty == true
            ? _input['_codexNamespace'].toString()
            : 'Codex Tool';
      case 'reviewMode':
        return _input['phase'] == 'entered' ? 'Review Started' : 'Review';
      case 'sleep':
        return 'Waiting';
      case 'hookPrompt':
        return 'Hook Context';
      case 'modelRerouted':
        return 'Model Changed';
      case 'safetyBuffering':
        return 'Safety Check';
      case 'modelVerification':
        return 'Verification Required';
      case 'autoApprovalReview':
        return 'Approval Review';
      case 'unrecognized':
        return 'New Codex Item';
      default:
        return widget.message.toolName ?? 'Codex';
    }
  }

  String get _subtitle {
    switch (_kind) {
      case 'webSearch':
        final action = _asMap(_input['action']);
        return action['pattern']?.toString() ??
            action['url']?.toString() ??
            _input['query']?.toString() ??
            '';
      case 'mcpToolCall':
        return _input['_codexTool']?.toString() ??
            widget.message.toolName ??
            '';
      case 'dynamicToolCall':
        return _input['_codexTool']?.toString() ??
            widget.message.toolName ??
            '';
      case 'reviewMode':
        return _input['review']?.toString() ?? '';
      case 'sleep':
        final durationMs = (_input['durationMs'] as num?)?.toInt() ?? 0;
        return _formatDuration(durationMs);
      case 'hookPrompt':
        final fragments = _input['fragments'] as List? ?? const [];
        return '${fragments.length} context fragment${fragments.length == 1 ? '' : 's'}';
      case 'modelRerouted':
        return '${_input['fromModel'] ?? 'unknown'} → ${_input['toModel'] ?? 'unknown'}';
      case 'safetyBuffering':
        final model = _input['model']?.toString() ?? '';
        return model.isEmpty ? 'Checking response' : 'Checking $model response';
      case 'modelVerification':
        final verifications = _input['verifications'] as List? ?? const [];
        return '${verifications.length} requirement${verifications.length == 1 ? '' : 's'}';
      case 'autoApprovalReview':
        final action = _asMap(_input['action']);
        return action['type']?.toString() ?? 'Reviewing requested action';
      case 'unrecognized':
        return _input['itemType']?.toString() ?? 'Unknown event type';
      default:
        return '';
    }
  }

  bool get _hasDetails {
    if (_kind == 'sleep') return false;
    return _visibleArguments.isNotEmpty ||
        (widget.message.toolOutput?.trim().isNotEmpty ?? false) ||
        _input['review']?.toString().trim().isNotEmpty == true ||
        (_input['fragments'] as List?)?.isNotEmpty == true;
  }

  Map<String, dynamic> get _visibleArguments {
    return Map<String, dynamic>.fromEntries(
      _input.entries.where((entry) => !entry.key.startsWith('_')),
    )..removeWhere(
      (key, _) =>
          key == 'action' ||
          key == 'query' ||
          key == 'review' ||
          key == 'phase' ||
          key == 'durationMs' ||
          key == 'fragments',
    );
  }

  @override
  Widget build(BuildContext context) {
    final isStreaming = widget.message.toolStreaming;
    final output = widget.message.toolOutput?.trim() ?? '';
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _accent.withAlpha(85)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: _hasDetails
                ? () => setState(() => _expanded = !_expanded)
                : null,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  Icon(_icon, size: 17, color: _accent),
                  const SizedBox(width: 8),
                  Text(
                    _title,
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _accent,
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
                  if (isStreaming)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _accent,
                      ),
                    )
                  else if (_hasDetails)
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: const Color(0xFF6C7086),
                    )
                  else
                    const Icon(Icons.check, size: 16, color: Color(0xFF6C7086)),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            if (_kind == 'webSearch' && output.isNotEmpty)
              _buildWebResults(output)
            else ...[
              if (_visibleArguments.isNotEmpty)
                _section('INPUT', _pretty(_visibleArguments)),
              if (_kind == 'reviewMode' &&
                  _input['review']?.toString().trim().isNotEmpty == true)
                _section('REVIEW', _input['review'].toString()),
              if (_kind == 'hookPrompt')
                _section(
                  'CONTEXT',
                  (_input['fragments'] as List? ?? const [])
                      .map((fragment) => _asMap(fragment)['text']?.toString())
                      .whereType<String>()
                      .where((text) => text.trim().isNotEmpty)
                      .join('\n\n'),
                ),
              if (output.isNotEmpty &&
                  !(_kind == 'reviewMode' &&
                      output == _input['review']?.toString()) &&
                  _kind != 'hookPrompt')
                _section('RESULT', normalizeStructuredToolOutput(output)),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildWebResults(String raw) {
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return _section('RESULTS', raw);
    }
    if (decoded is! List || decoded.isEmpty) {
      return _section('RESULTS', _pretty(decoded));
    }
    final results = decoded.whereType<Map>().take(12).toList();
    if (results.isEmpty) return _section('RESULTS', _pretty(decoded));
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFF313244))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionLabel('RESULTS'),
          ...results.map((rawResult) {
            final result = Map<String, dynamic>.from(rawResult);
            final title =
                result['title']?.toString() ??
                result['name']?.toString() ??
                result['url']?.toString() ??
                'Result';
            final url =
                result['url']?.toString() ?? result['link']?.toString() ?? '';
            final snippet =
                result['snippet']?.toString() ??
                result['description']?.toString() ??
                result['text']?.toString() ??
                '';
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    title,
                    style: const TextStyle(
                      color: Color(0xFFCDD6F4),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (url.isNotEmpty)
                    SelectableText(
                      url,
                      style: const TextStyle(
                        color: Color(0xFF89B4FA),
                        fontSize: 9.5,
                      ),
                    ),
                  if (snippet.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        snippet,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFA6ADC8),
                          fontSize: 10,
                          height: 1.3,
                        ),
                      ),
                    ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _section(String label, String content) {
    if (content.trim().isEmpty) return const SizedBox.shrink();
    return Container(
      constraints: const BoxConstraints(maxHeight: 280),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFF313244))),
      ),
      child: ScrollPassthrough(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sectionLabel(label, padding: EdgeInsets.zero),
              SelectableText(
                content,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 10.5,
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

  Widget _sectionLabel(String label, {EdgeInsets? padding}) {
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(12, 9, 12, 7),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: _accent,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    return value is Map ? Map<String, dynamic>.from(value) : {};
  }

  static String _pretty(dynamic value) {
    if (value is String) return value;
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return value.toString();
    }
  }

  static String _formatDuration(int milliseconds) {
    if (milliseconds < 1000) return '${milliseconds}ms';
    final seconds = milliseconds / 1000;
    return seconds == seconds.roundToDouble()
        ? '${seconds.round()}s'
        : '${seconds.toStringAsFixed(1)}s';
  }
}
