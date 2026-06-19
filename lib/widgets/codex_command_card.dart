import 'package:flutter/material.dart';

import '../models/message.dart';

class CodexCommandCard extends StatelessWidget {
  final ChatMessage message;

  const CodexCommandCard({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final command =
        message.toolName ??
        (message.toolInput?['command'] as String?) ??
        'command';
    final status = message.toolInput?['status'] as String? ?? 'completed';
    final payload = message.toolInput?['payload'] is Map
        ? Map<String, dynamic>.from(message.toolInput!['payload'] as Map)
        : <String, dynamic>{};
    final isFailed = status == 'failed';
    final color = isFailed
        ? theme.colorScheme.error
        : theme.colorScheme.tertiary;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(90)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_commandIcon(command), size: 16, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '/$command',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withAlpha(24),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  isFailed ? 'FAILED' : 'COMMAND',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (command == 'status' && payload.isNotEmpty)
            _buildStatusPayload(payload, theme)
          else if (command == 'mcp' && payload['servers'] is List)
            _buildMcpPayload(payload, theme)
          else if (command == 'model' && payload['models'] is List)
            _buildModelPayload(payload, theme)
          else if (command == 'permissions' && payload['label'] != null)
            _kvRow(theme, 'Mode', payload['label'].toString())
          else
            Text(
              message.textContent.replaceFirst(RegExp(r'^/[^\n]+\n?'), ''),
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  IconData _commandIcon(String command) {
    switch (command) {
      case 'status':
        return Icons.speed_outlined;
      case 'mcp':
        return Icons.hub_outlined;
      case 'model':
        return Icons.psychology_outlined;
      case 'permissions':
        return Icons.shield_outlined;
      default:
        return Icons.terminal;
    }
  }

  Widget _buildStatusPayload(Map<String, dynamic> payload, ThemeData theme) {
    final thread = payload['thread'] is Map
        ? Map<String, dynamic>.from(payload['thread'] as Map)
        : <String, dynamic>{};
    final config = payload['config'] is Map
        ? Map<String, dynamic>.from(payload['config'] as Map)
        : <String, dynamic>{};
    final limits = payload['limits'] is List
        ? payload['limits'] as List
        : const [];
    final usage = payload['usage'] is Map
        ? Map<String, dynamic>.from(payload['usage'] as Map)
        : <String, dynamic>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _metricPill(
              theme,
              'State',
              thread['state']?.toString() ?? 'unknown',
            ),
            _metricPill(
              theme,
              'Model',
              config['model']?.toString() ?? 'default',
            ),
            _metricPill(
              theme,
              'Effort',
              config['effort']?.toString() ?? 'default',
            ),
            _metricPill(
              theme,
              'Permissions',
              config['permissionLabel']?.toString() ?? '',
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (limits.isNotEmpty) ...[
          Text(
            'Limits',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          ...limits.map(
            (limit) =>
                _limitBlock(theme, Map<String, dynamic>.from(limit as Map)),
          ),
        ],
        if (usage.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Usage',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _metricPill(theme, 'Today', _formatTokens(usage['todayTokens'])),
              _metricPill(
                theme,
                'Lifetime',
                _formatTokens(usage['lifetimeTokens']),
              ),
              _metricPill(
                theme,
                'Peak day',
                _formatTokens(usage['peakDailyTokens']),
              ),
              _metricPill(
                theme,
                'Streak',
                '${usage['currentStreakDays'] ?? 'unknown'}d',
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _limitBlock(ThemeData theme, Map<String, dynamic> limit) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            limit['label']?.toString() ?? 'Codex',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          _limitBar(theme, 'Primary', limit['primary']),
          const SizedBox(height: 4),
          _limitBar(theme, 'Secondary', limit['secondary']),
        ],
      ),
    );
  }

  Widget _limitBar(ThemeData theme, String label, dynamic raw) {
    if (raw is! Map) return const SizedBox.shrink();
    final data = Map<String, dynamic>.from(raw);
    final pct = (data['usedPercent'] as num?)?.toDouble();
    final value = pct == null ? 0.0 : (pct / 100).clamp(0.0, 1.0);
    final reset = data['resetLabel']?.toString() ?? '';
    final window = data['window']?.toString() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '$label ${pct?.round() ?? 0}%',
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            Flexible(
              child: Text(
                [window, if (reset.isNotEmpty) 'resets $reset'].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 10,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: value,
            minHeight: 6,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(
              value >= 0.85
                  ? theme.colorScheme.error
                  : theme.colorScheme.tertiary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMcpPayload(Map<String, dynamic> payload, ThemeData theme) {
    final servers = payload['servers'] as List;
    if (servers.isEmpty) {
      return Text(
        'No MCP servers configured.',
        style: TextStyle(
          fontSize: 12,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Column(
      children: servers.map((server) {
        final s = Map<String, dynamic>.from(server as Map);
        return _kvRow(
          theme,
          s['name']?.toString() ?? 'server',
          '${s['authStatus']} · ${s['toolCount']} tools',
        );
      }).toList(),
    );
  }

  Widget _buildModelPayload(Map<String, dynamic> payload, ThemeData theme) {
    final models = payload['models'] as List;
    return Column(
      children: models.map((model) {
        final m = Map<String, dynamic>.from(model as Map);
        final suffix = m['current'] == true
            ? 'current'
            : (m['description']?.toString() ?? '');
        return _kvRow(
          theme,
          m['displayName']?.toString() ?? m['id'].toString(),
          suffix,
        );
      }).toList(),
    );
  }

  Widget _metricPill(ThemeData theme, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 11,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _kvRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTokens(dynamic value) {
    final n = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    if (n == null || n.isNaN) return 'unknown';
    if (n >= 1000000000) return '${(n / 1000000000).toStringAsFixed(1)}B';
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return n.round().toString();
  }
}
