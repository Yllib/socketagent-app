import 'package:flutter/material.dart';

import '../models/composer_attachment.dart';
import '../services/chat_provider.dart';

class SecretManagerSheet extends StatefulWidget {
  const SecretManagerSheet({super.key, required this.provider});

  final ChatProvider provider;

  @override
  State<SecretManagerSheet> createState() => _SecretManagerSheetState();
}

class _SecretManagerSheetState extends State<SecretManagerSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.provider.refreshSecretInventory();
    });
  }

  Future<void> _createSecret() async {
    final input = await _showSecretEditor();
    if (input == null) return;
    try {
      await widget.provider.storeSecureInput(
        label: input.label,
        value: input.value,
        scope: input.scope,
        envHint: input.envHint,
      );
      if (mounted) _showMessage('Secret created');
    } catch (error) {
      if (mounted) _showMessage('Could not create secret: $error');
    } finally {
      input.clear();
    }
  }

  Future<void> _replaceSecret(SecretMetadata secret) async {
    final input = await _showSecretEditor(existing: secret);
    if (input == null) return;
    try {
      await widget.provider.replaceManagedSecret(
        secret: secret,
        value: input.value,
        label: input.label,
        envHint: input.envHint,
      );
      if (mounted) _showMessage('Secret replaced');
    } catch (error) {
      if (mounted) _showMessage('Could not replace secret: $error');
    } finally {
      input.clear();
    }
  }

  Future<void> _deleteSecret(SecretMetadata secret) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete secret?'),
        content: Text(
          '${secret.label} will be permanently deleted from ${_scopeLabel(secret.scope).toLowerCase()}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.provider.deleteManagedSecret(secret);
      if (mounted) _showMessage('Secret deleted');
    } catch (error) {
      if (mounted) _showMessage('Could not delete secret: $error');
    }
  }

  Future<_SecretEditorResult?> _showSecretEditor({
    SecretMetadata? existing,
  }) async {
    final labelController = TextEditingController(text: existing?.label);
    final envController = TextEditingController(text: existing?.envHint);
    final valueController = TextEditingController();
    var scope = existing?.scope ?? 'session';
    var obscure = true;
    String? validationError;
    try {
      return await showDialog<_SecretEditorResult>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(existing == null ? 'Create secret' : 'Replace secret'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (existing != null)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        'Stored values cannot be viewed. Enter a new value to replace the old one.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  TextField(
                    controller: labelController,
                    decoration: const InputDecoration(
                      labelText: 'Label',
                      hintText: 'OPENAI_API_KEY',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: envController,
                    decoration: const InputDecoration(
                      labelText: 'Environment hint',
                      hintText: 'OPENAI_API_KEY',
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: scope,
                    decoration: const InputDecoration(labelText: 'Scope'),
                    items: const [
                      DropdownMenuItem(
                        value: 'session',
                        child: Text('Current session'),
                      ),
                      DropdownMenuItem(
                        value: 'project',
                        child: Text('Current project'),
                      ),
                      DropdownMenuItem(
                        value: 'global',
                        child: Text('This server'),
                      ),
                    ],
                    onChanged: existing == null
                        ? (value) {
                            if (value != null) {
                              setDialogState(() => scope = value);
                            }
                          }
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: valueController,
                    obscureText: obscure,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: existing == null
                          ? 'Secret value'
                          : 'New secret value',
                      errorText: validationError,
                      suffixIcon: IconButton(
                        tooltip: obscure ? 'Show' : 'Hide',
                        onPressed: () {
                          setDialogState(() => obscure = !obscure);
                        },
                        icon: Icon(
                          obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final label = labelController.text.trim();
                  if (label.isEmpty || valueController.text.isEmpty) {
                    setDialogState(() {
                      validationError = 'A label and value are required';
                    });
                    return;
                  }
                  final result = _SecretEditorResult(
                    label: label,
                    envHint: envController.text.trim(),
                    scope: scope,
                    value: valueController.text,
                  );
                  valueController.clear();
                  Navigator.pop(dialogContext, result);
                },
                child: Text(existing == null ? 'Create' : 'Replace'),
              ),
            ],
          ),
        ),
      );
    } finally {
      labelController.dispose();
      envController.dispose();
      valueController.clear();
      valueController.dispose();
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  String _scopeLabel(String scope) => switch (scope) {
    'global' => 'This server',
    'project' => 'Current project',
    _ => 'Current session',
  };

  IconData _scopeIcon(String scope) => switch (scope) {
    'global' => Icons.dns_outlined,
    'project' => Icons.folder_outlined,
    _ => Icons.chat_bubble_outline,
  };

  Widget _buildScope(String scope, List<SecretMetadata> secrets) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_scopeIcon(scope), size: 18),
              const SizedBox(width: 8),
              Text(_scopeLabel(scope), style: theme.textTheme.titleSmall),
              const Spacer(),
              Text('${secrets.length}', style: theme.textTheme.labelMedium),
            ],
          ),
          const SizedBox(height: 6),
          if (secrets.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                'No secrets in this scope',
                style: theme.textTheme.bodySmall,
              ),
            )
          else
            ...secrets.map(
              (secret) => Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: const Icon(Icons.key_outlined),
                  title: Text(secret.label),
                  subtitle: Text(
                    secret.envHint.isEmpty
                        ? 'Stored value hidden'
                        : '${secret.envHint} · stored value hidden',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) {
                      switch (action) {
                        case 'attach':
                          widget.provider.attachStoredSecret(secret);
                          _showMessage('${secret.label} attached');
                          break;
                        case 'replace':
                          _replaceSecret(secret);
                          break;
                        case 'delete':
                          _deleteSecret(secret);
                          break;
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'attach',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.add_link),
                          title: Text('Attach to message'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'replace',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.sync_lock_outlined),
                          title: Text('Replace value'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.delete_outline),
                          title: Text('Delete'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.provider,
      builder: (context, _) {
        final byScope = <String, List<SecretMetadata>>{
          'session': [],
          'project': [],
          'global': [],
        };
        for (final secret in widget.provider.secretInventory) {
          (byScope[secret.scope] ??= []).add(secret);
        }
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .82,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.password_outlined),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Secrets',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              'Values stay hidden and can only be replaced.',
                              style: TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Refresh',
                        onPressed: widget.provider.refreshSecretInventory,
                        icon: const Icon(Icons.refresh),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                if (widget.provider.secretInventoryLoading)
                  const LinearProgressIndicator(minHeight: 2),
                if (widget.provider.secretInventoryError != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(widget.provider.secretInventoryError!),
                  ),
                Expanded(
                  child: ListView(
                    children: [
                      _buildScope('session', byScope['session']!),
                      _buildScope('project', byScope['project']!),
                      _buildScope('global', byScope['global']!),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _createSecret,
                      icon: const Icon(Icons.add),
                      label: const Text('Create secret'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SecretEditorResult {
  _SecretEditorResult({
    required this.label,
    required this.value,
    required this.scope,
    required this.envHint,
  });

  final String label;
  String value;
  final String scope;
  final String envHint;

  void clear() {
    value = '';
  }
}
