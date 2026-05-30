import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/server_config.dart';
import '../../services/chat_provider.dart';
import '../../services/connection_manager.dart';

class SkillEditScreen extends StatefulWidget {
  final String baseUrl;
  final String token;
  final Map<String, dynamic>? existing;
  final String? projectCwd;
  final ServerConfig? serverConfig;

  const SkillEditScreen({
    super.key,
    required this.baseUrl,
    required this.token,
    this.existing,
    this.projectCwd,
    this.serverConfig,
  });

  @override
  State<SkillEditScreen> createState() => _SkillEditScreenState();
}

class _SkillEditScreenState extends State<SkillEditScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _allowedToolsController;
  late final TextEditingController _argumentHintController;
  late final TextEditingController _bodyController;
  String _scope = 'user';
  String _format = 'command';
  String _agent = 'claude';
  bool _saving = false;
  bool _isNew = true;
  bool _isPlugin = false;
  StreamSubscription<ServerMessage>? _msgSub;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _isNew = e == null;
    _isPlugin = (e?['scope'] as String?) == 'plugin';

    final fm = (e?['frontmatter'] as Map?)?.cast<String, dynamic>() ?? {};

    _nameController = TextEditingController(text: e?['name'] as String? ?? '');
    _descriptionController = TextEditingController(
      text: fm['description'] as String? ?? '',
    );
    _allowedToolsController = TextEditingController(
      text: fm['allowed-tools'] as String? ?? '',
    );
    _argumentHintController = TextEditingController(
      text: fm['argument-hint'] as String? ?? '',
    );
    _bodyController = TextEditingController(text: e?['body'] as String? ?? '');
    _scope = e?['scope'] as String? ?? 'user';
    _format = e?['format'] as String? ?? 'command';
    _agent = e?['agent'] as String? ?? 'claude';
    if (_agent == 'codex') _format = 'skill';
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _nameController.dispose();
    _descriptionController.dispose();
    _allowedToolsController.dispose();
    _argumentHintController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  String get _nameHelperText {
    final displayName = _nameController.text.isEmpty
        ? 'name'
        : _nameController.text;
    if (_agent == 'codex') {
      return 'Invoke as /$displayName in SocketAgent';
    }
    return 'Invoked as /$displayName';
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Name is required')));
      return;
    }

    setState(() => _saving = true);

    try {
      final fm = <String, String>{};
      final desc = _descriptionController.text.trim();
      final tools = _allowedToolsController.text.trim();
      final hint = _argumentHintController.text.trim();

      if (_format == 'skill') {
        fm['name'] = name;
      }
      if (desc.isNotEmpty) fm['description'] = desc;
      if (tools.isNotEmpty) fm['allowed-tools'] = tools;
      if (hint.isNotEmpty) fm['argument-hint'] = hint;

      final payload = <String, dynamic>{
        'name': name,
        'scope': _scope,
        'format': _format,
        'agent': _agent,
        'frontmatter': fm,
        'body': _bodyController.text,
      };

      if (!_isNew && widget.existing != null) {
        payload['filePath'] = widget.existing!['filePath'];
      }

      await _saveViaWebSocket(payload);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveViaWebSocket(Map<String, dynamic> payload) async {
    if (widget.serverConfig == null) {
      throw Exception('No server selected');
    }
    final connMgr = context.read<ChatProvider>().connMgr;
    final serverId = widget.serverConfig!.id;
    final completer = Completer<bool>();

    _msgSub?.cancel();
    _msgSub = connMgr.messages.listen((sm) {
      if (sm.serverId == serverId && sm.data['type'] == 'skills_save_result') {
        _msgSub?.cancel();
        if (!completer.isCompleted) {
          completer.complete(sm.data['ok'] == true);
          if (sm.data['ok'] != true && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed: ${sm.data['error'] ?? 'unknown'}'),
              ),
            );
          }
        }
      }
    });

    payload['type'] = 'skills_save';
    connMgr.sendToServer(serverId, payload);

    final ok = await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => false,
    );
    if (ok && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _isPlugin
        ? 'View Skill'
        : _isNew
        ? 'New Skill'
        : 'Edit Skill';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (!_isPlugin)
            TextButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save, size: 18),
              label: const Text('Save'),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Name
            TextField(
              controller: _nameController,
              readOnly: _isPlugin,
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: 'my-command',
                helperText: _nameHelperText,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.tag, size: 20),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),

            // Agent, Scope & Format controls
            DropdownButtonFormField<String>(
              initialValue: _agent,
              decoration: const InputDecoration(
                labelText: 'Agent',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
              ),
              items: const [
                DropdownMenuItem(value: 'claude', child: Text('Claude')),
                DropdownMenuItem(value: 'codex', child: Text('Codex')),
              ],
              onChanged: _isPlugin
                  ? null
                  : (val) {
                      if (val == null) return;
                      setState(() {
                        _agent = val;
                        if (_agent == 'codex') _format = 'skill';
                      });
                    },
            ),
            const SizedBox(height: 16),

            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _scope == 'plugin' ? 'user' : _scope,
                    decoration: const InputDecoration(
                      labelText: 'Scope',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 14,
                      ),
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: 'user',
                        child: Text('User'),
                      ),
                      if (widget.projectCwd != null)
                        const DropdownMenuItem(
                          value: 'project',
                          child: Text('Project'),
                        ),
                    ],
                    onChanged: _isPlugin
                        ? null
                        : (val) {
                            if (val != null) setState(() => _scope = val);
                          },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _format,
                    decoration: const InputDecoration(
                      labelText: 'Type',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 14,
                      ),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'command',
                        child: Text('Command'),
                      ),
                      DropdownMenuItem(value: 'skill', child: Text('Skill')),
                    ],
                    onChanged: _isPlugin || _agent == 'codex'
                        ? null
                        : (val) {
                            if (val != null) setState(() => _format = val);
                          },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Description
            TextField(
              controller: _descriptionController,
              readOnly: _isPlugin,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Description',
                hintText: 'What this skill does or when to trigger it',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.description, size: 20),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),

            // Allowed Tools
            TextField(
              controller: _allowedToolsController,
              readOnly: _isPlugin,
              decoration: const InputDecoration(
                labelText: 'Allowed Tools (optional)',
                hintText: 'Read, Write, Bash(git:*)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.build_outlined, size: 20),
              ),
            ),
            const SizedBox(height: 16),

            // Argument Hint
            if (_format == 'command') ...[
              TextField(
                controller: _argumentHintController,
                readOnly: _isPlugin,
                decoration: const InputDecoration(
                  labelText: 'Argument Hint (optional)',
                  hintText: '[file] [message]',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.input, size: 20),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Body/Instructions header
            Row(
              children: [
                Icon(
                  Icons.article_outlined,
                  size: 18,
                  color: theme.colorScheme.onSurface.withAlpha(150),
                ),
                const SizedBox(width: 8),
                Text(
                  'Instructions',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface.withAlpha(180),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Body text area
            TextField(
              controller: _bodyController,
              readOnly: _isPlugin,
              maxLines: null,
              minLines: 10,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(
                hintText: _format == 'command'
                    ? 'Instructions for Claude when this command is invoked...\n\nUse \$ARGUMENTS for user input.\nUse !`command` for bash execution.\nUse @filepath for file references.'
                    : _agent == 'codex'
                    ? 'Guidance for Codex — describe when and how to apply this skill...'
                    : 'Guidance for Claude — describe when and how to apply this skill...',
                border: const OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),

            if (_isPlugin) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withAlpha(20),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withAlpha(60)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 18,
                      color: Colors.orange.shade300,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Plugin skills are read-only. Duplicate to create an editable copy.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.orange.shade300,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }
}
