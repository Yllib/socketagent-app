import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/app_palette.dart';
import '../models/computer_access.dart';
import '../models/device_registry.dart';
import '../models/message.dart';
import '../services/chat_provider.dart';
import 'second_ticker.dart';

/// A `computer_access_request` card. An agent on one computer wants to act
/// on another; this device signs the answer so the source can't forge it.
class ComputerAccessCard extends StatefulWidget {
  const ComputerAccessCard({super.key, required this.message});

  final ChatMessage message;

  @override
  State<ComputerAccessCard> createState() => _ComputerAccessCardState();
}

class _ComputerAccessCardState extends State<ComputerAccessCard> {
  ComputerAccess? _access;
  LinkConfirm _confirm = LinkConfirm.ask;
  bool _busy = false;
  String? _error;

  ComputerAccessRequest? get _request =>
      ComputerAccessRequest.fromJson(widget.message.toolInput);

  Future<void> _answer(String decision) async {
    final request = _request;
    if (request == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<ChatProvider>().answerComputerAccess(
        request.requestId,
        decision,
        access: _access ?? request.access,
        confirm: _confirm,
      );
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is StateError
              ? error.message
              : 'Could not answer: $error',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = _request;
    if (request == null) return const SizedBox.shrink();
    final status =
        widget.message.toolInput?['status'] as String? ?? request.status;
    // A pending request counts down to its expiry once a second.
    return status == 'pending'
        ? EverySecond(
            builder: (context) => _buildCard(context, request, status),
          )
        : _buildCard(context, request, status);
  }

  Widget _buildCard(
    BuildContext context,
    ComputerAccessRequest request,
    String status,
  ) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final now = DateTime.now();
    final expired =
        status == 'expired' || (status == 'pending' && request.isExpired(now));
    final pending = status == 'pending' && !expired;
    final access = _access ?? request.access;

    final title = request.isLink
        ? '${request.sourceName} asks for access to ${request.targetName}'
        : '${request.sourceName} wants to act on ${request.targetName}';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: pending ? palette.peach : palette.border,
            width: 2,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                request.isLink ? Icons.link : Icons.devices_other,
                size: 16,
                color: pending ? palette.peach : palette.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (request.isLink) ...[
            if (request.reason.isNotEmpty)
              Text(
                request.reason,
                style: TextStyle(color: palette.textSecondary),
              ),
            if (request.hasAction) _actionSummary(request, palette),
            const SizedBox(height: 6),
            if (pending) ...[
              Wrap(
                spacing: 12,
                children: [
                  _AccessToggle(
                    label: 'Read transcripts',
                    value: access.read,
                    onChanged: _busy
                        ? null
                        : (v) => setState(
                            () => _access = access.copyWith(read: v),
                          ),
                  ),
                  _AccessToggle(
                    label: 'Run agents',
                    value: access.agents,
                    onChanged: _busy
                        ? null
                        : (v) => setState(
                            () => _access = access.copyWith(agents: v),
                          ),
                  ),
                  _AccessToggle(
                    label: 'Run commands',
                    value: access.commands,
                    onChanged: _busy
                        ? null
                        : (v) => setState(
                            () => _access = access.copyWith(commands: v),
                          ),
                  ),
                ],
              ),
              Row(
                children: [
                  Text('Confirm', style: TextStyle(color: palette.textMuted)),
                  const SizedBox(width: 12),
                  DropdownButton<LinkConfirm>(
                    value: _confirm,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final option in LinkConfirm.values)
                        DropdownMenuItem(
                          value: option,
                          child: Text(option.label),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _confirm = v ?? _confirm),
                  ),
                ],
              ),
            ] else
              Text(
                'Asked for ${request.access.label}',
                style: TextStyle(color: palette.textMuted),
              ),
          ] else
            _actionSummary(request, palette),
          const SizedBox(height: 8),
          if (pending)
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: request.isLink
                        ? [
                            if (request.hasAction)
                              FilledButton(
                                onPressed: _busy
                                    ? null
                                    : () => _answer('action'),
                                child: const Text('Allow'),
                              ),
                            OutlinedButton(
                              onPressed: _busy ? null : () => _answer('today'),
                              child: const Text('Allow for today'),
                            ),
                            OutlinedButton(
                              onPressed: _busy ? null : () => _answer('linked'),
                              child: const Text('Allow permanently'),
                            ),
                            TextButton(
                              onPressed: _busy ? null : () => _answer('deny'),
                              child: const Text('Deny'),
                            ),
                          ]
                        : [
                            FilledButton(
                              onPressed: _busy ? null : () => _answer('once'),
                              child: const Text('Allow once'),
                            ),
                            OutlinedButton(
                              onPressed: _busy ? null : () => _answer('chat'),
                              child: const Text('Allow for this chat'),
                            ),
                            TextButton(
                              onPressed: _busy ? null : () => _answer('deny'),
                              child: const Text('Deny'),
                            ),
                          ],
                  ),
                ),
                if (request.expiresAt > 0)
                  Text(
                    _expiresIn(request, now),
                    style: TextStyle(fontSize: 12, color: palette.textMuted),
                  ),
              ],
            )
          else
            Text(
              _statusLabel(status, expired),
              style: TextStyle(color: palette.textMuted),
            ),
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(error, style: TextStyle(color: palette.danger)),
            ),
        ],
      ),
    );
  }

  /// What the agent wants to do, and the exact request when the card has one.
  static Widget _actionSummary(
    ComputerAccessRequest request,
    AppPalette palette,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            request.actionLabel,
            style: TextStyle(color: palette.textSecondary),
          ),
        ),
        if (request.summary.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SelectableText(
              request.summary,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                color: palette.text,
              ),
            ),
          ),
      ],
    );
  }

  static String _expiresIn(ComputerAccessRequest request, DateTime now) {
    final left = DateTime.fromMillisecondsSinceEpoch(
      request.expiresAt,
    ).difference(now);
    if (left.inMinutes >= 1) return '${left.inMinutes} min left';
    return '${left.inSeconds.clamp(0, 59)} s left';
  }

  static String _statusLabel(String status, bool expired) {
    if (expired) return 'Expired';
    return switch (status) {
      'once' || 'action' => 'Allowed once',
      'chat' => 'Allowed for this chat',
      'deny' => 'Denied',
      'today' => 'Linked until midnight',
      'linked' => 'Linked',
      _ => status,
    };
  }
}

class _AccessToggle extends StatelessWidget {
  const _AccessToggle({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: value,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: onChanged == null ? null : (v) => onChanged!(v == true),
          ),
          Text(label),
        ],
      ),
    );
  }
}
