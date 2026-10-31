import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/message.dart';
import '../../services/window_security_service.dart';
import '../state/ui_c_store.dart';
import '../theme/ui_c_theme.dart';
import 'primitives.dart';

/// The one place a secret value is typed. Screenshots are blocked while it
/// is open on Android, the field is obscured, and the value goes straight to
/// the store. Matching stored secrets can be reused without retyping.
Future<void> showSecureEntry(BuildContext context, ChatMessage message) async {
  final store = context.read<UiCStore>();
  final requestId = message.questionId;
  if (requestId == null) return;
  if (Platform.isAndroid) {
    await WindowSecurityService.enableScreenshotProtection();
  }
  if (!context.mounted) return;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Provider<UiCStore>.value(
        value: store,
        child: _SecureDialog(message: message, requestId: requestId),
      ),
    );
  } finally {
    if (Platform.isAndroid) {
      await WindowSecurityService.disableScreenshotProtection();
    }
  }
}

class _SecureDialog extends StatefulWidget {
  const _SecureDialog({required this.message, required this.requestId});
  final ChatMessage message;
  final String requestId;

  @override
  State<_SecureDialog> createState() => _SecureDialogState();
}

class _SecureDialogState extends State<_SecureDialog> {
  final _controller = TextEditingController();
  bool _reveal = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.read<UiCStore>();
    final input = widget.message.toolInput ?? const {};
    final label = input['label']?.toString() ?? 'Secret';
    final reason = input['reason']?.toString() ?? widget.message.textContent;
    final envHint = input['envHint']?.toString() ?? '';
    final scope = input['scope']?.toString() ?? 'session';
    final multiline = input['multiline'] == true;
    final matches = store.secrets.where((s) {
      final name = s.label.toLowerCase();
      return name == label.toLowerCase() ||
          (envHint.isNotEmpty && s.envHint == envHint);
    }).toList();
    final canSend = _controller.text.isNotEmpty;

    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: c.warn),
      ),
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.lock_outline, size: 14, color: c.warn),
                  const SizedBox(width: 6),
                  Text(
                    'SECURE ENTRY',
                    style: UiCFonts.condensed(
                      size: 11,
                      weight: FontWeight.w700,
                      color: c.warn,
                      letterSpacing: 1,
                    ),
                  ),
                  const Spacer(),
                  Tag(scope.toUpperCase(), color: c.textDim),
                  if (envHint.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Tag(envHint, color: c.textDim, mono: true),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: UiCFonts.prose(
                  size: 15,
                  weight: FontWeight.w600,
                  color: c.text,
                ),
              ),
              if (reason.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    reason,
                    style: UiCFonts.prose(size: 12.5, color: c.textDim),
                  ),
                ),
              const SizedBox(height: 6),
              Text(
                'The agent receives a file path on the computer. The value never enters the chat or the model.',
                style: UiCFonts.condensed(size: 11.5, color: c.textFaint),
              ),
              if (matches.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  'STORED',
                  style: UiCFonts.condensed(
                    size: 10.5,
                    weight: FontWeight.w700,
                    color: c.textDim,
                    letterSpacing: 1,
                  ),
                ),
                for (final secret in matches)
                  HairRow(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    onTap: () {
                      store.useStoredSecret(widget.requestId, secret);
                      Navigator.of(context).pop();
                    },
                    child: Row(
                      children: [
                        Icon(Icons.key_outlined, size: 13, color: c.textDim),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            secret.label,
                            style: UiCFonts.prose(size: 13, color: c.text),
                          ),
                        ),
                        Tag(secret.scope.toUpperCase(), color: c.textFaint),
                        const SizedBox(width: 8),
                        Text(
                          'USE',
                          style: UiCFonts.condensed(
                            size: 11,
                            weight: FontWeight.w700,
                            color: c.accent,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: c.bg,
                  border: Border.all(color: c.lineStrong),
                  borderRadius: BorderRadius.circular(3),
                ),
                padding: const EdgeInsets.fromLTRB(8, 0, 2, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        autofocus: true,
                        obscureText: !_reveal && !multiline,
                        enableSuggestions: false,
                        autocorrect: false,
                        maxLines: multiline ? 6 : 1,
                        minLines: multiline ? 3 : 1,
                        style: UiCFonts.mono(size: 13, color: c.text),
                        decoration: InputDecoration(
                          hintText: multiline ? 'Paste the value' : 'Value',
                          border: InputBorder.none,
                        ),
                        onChanged: (_) => setState(() {}),
                        onSubmitted: multiline || !canSend
                            ? null
                            : (_) => _send(store),
                      ),
                    ),
                    if (!multiline)
                      IconTap(
                        _reveal
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 16,
                        color: c.textDim,
                        onTap: () => setState(() => _reveal = !_reveal),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  CButton(
                    'Decline',
                    dense: true,
                    onTap: () {
                      store.cancelSecret(widget.requestId);
                      Navigator.of(context).pop();
                    },
                  ),
                  const Spacer(),
                  CButton(
                    'Close',
                    dense: true,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 6),
                  CButton(
                    'Save and send',
                    primary: true,
                    dense: true,
                    onTap: canSend ? () => _send(store) : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _send(UiCStore store) {
    store.submitSecret(widget.requestId, _controller.text);
    Navigator.of(context).pop();
  }
}

/// Picks a stored secret to attach to the next prompt as a file path.
Future<void> showStoredSecretPicker(BuildContext context) async {
  final store = context.read<UiCStore>();
  final c = context.c;
  final secrets = store.secrets;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: c.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHead('Attach a stored secret'),
          if (secrets.isEmpty)
            const EmptyLine('No stored secrets on the connected computers'),
          for (final secret in secrets)
            HairRow(
              onTap: () {
                store.attachSecret(secret);
                Navigator.of(sheetContext).pop();
              },
              child: Row(
                children: [
                  Icon(Icons.key_outlined, size: 14, color: c.textDim),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      secret.label,
                      style: UiCFonts.prose(size: 13.5, color: c.text),
                    ),
                  ),
                  if (secret.envHint.isNotEmpty) ...[
                    Tag(secret.envHint, color: c.textFaint, mono: true),
                    const SizedBox(width: 4),
                  ],
                  Tag(secret.scope.toUpperCase(), color: c.textFaint),
                ],
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
