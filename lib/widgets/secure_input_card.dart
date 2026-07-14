import 'package:flutter/material.dart';
import '../models/message.dart';

class SecureInputCard extends StatefulWidget {
  final ChatMessage message;
  final void Function(String requestId, String value) onSubmit;
  final void Function(String requestId) onCancel;

  const SecureInputCard({
    super.key,
    required this.message,
    required this.onSubmit,
    required this.onCancel,
  });

  @override
  State<SecureInputCard> createState() => _SecureInputCardState();
}

class _SecureInputCardState extends State<SecureInputCard> {
  final TextEditingController _controller = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _requestId => widget.message.questionId ?? '';
  String get _label =>
      widget.message.toolInput?['label'] as String? ?? 'Secure input';
  String get _reason => widget.message.textContent.trim();
  String get _envHint => widget.message.toolInput?['envHint'] as String? ?? '';
  String get _scope =>
      widget.message.toolInput?['scope'] as String? ?? 'session';
  String get _status =>
      widget.message.toolInput?['status'] as String? ??
      (widget.message.answered ? 'saved' : 'pending');

  String get _statusTitle => switch (_status) {
    'saved' => 'Secure input saved',
    'cancelled' => 'Secure input cancelled',
    'expired' => 'Secure input expired',
    'interrupted' => 'Secure input interrupted',
    _ => 'Secure input',
  };

  void _submit() {
    final value = _controller.text;
    if (_requestId.isEmpty || value.isEmpty) return;
    widget.onSubmit(_requestId, value);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final answered = widget.message.answered;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Card(
        color: answered
            ? theme.colorScheme.surfaceContainerHighest.withAlpha(128)
            : theme.colorScheme.primaryContainer,
        elevation: answered ? 0 : 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    answered ? Icons.lock_outline : Icons.lock_person_outlined,
                    size: 20,
                    color: answered
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _statusTitle,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: answered
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  if (_status == 'saved')
                    Icon(
                      Icons.check_circle,
                      size: 18,
                      color: Colors.green.shade400,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(_label, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (_reason.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(_reason, style: const TextStyle(fontSize: 13)),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _metaChip(context, 'scope: $_scope'),
                  if (_envHint.isNotEmpty) _metaChip(context, _envHint),
                ],
              ),
              if (!answered) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _controller,
                  obscureText: _obscure,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Secret value',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: _obscure ? 'Show' : 'Hide',
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _requestId.isEmpty
                          ? null
                          : () => widget.onCancel(_requestId),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _submit,
                      icon: const Icon(Icons.lock_outline, size: 18),
                      label: const Text('Save'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _metaChip(BuildContext context, String label) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: theme.colorScheme.surface.withAlpha(170),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11)),
    );
  }
}
