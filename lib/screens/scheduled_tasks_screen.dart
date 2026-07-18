import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/chat_provider.dart';
import '../services/websocket_service.dart';
import '../widgets/folder_browser_screen.dart';
import 'home_screen.dart';

class ScheduledTasksScreen extends StatefulWidget {
  const ScheduledTasksScreen({super.key});

  @override
  State<ScheduledTasksScreen> createState() => _ScheduledTasksScreenState();
}

class _ScheduledTasksScreenState extends State<ScheduledTasksScreen> {
  final Set<String> _expandedTasks = {};

  Color _statusColor(String status) {
    switch (status) {
      case 'pending':
        return Colors.orange;
      case 'running':
        return Colors.blue;
      case 'completed':
        return Colors.green;
      case 'failed':
        return Colors.red;
      case 'cancelled':
        return Colors.grey;
      default:
        return Colors.grey;
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'pending':
        return Icons.schedule;
      case 'running':
        return Icons.play_circle_outline;
      case 'completed':
        return Icons.check_circle_outline;
      case 'failed':
        return Icons.error_outline;
      case 'cancelled':
        return Icons.cancel_outlined;
      default:
        return Icons.help_outline;
    }
  }

  String _formatTime(String? isoString) {
    if (isoString == null) return '';
    final dt = DateTime.tryParse(isoString)?.toLocal();
    if (dt == null) return isoString;
    final now = DateTime.now();
    final diff = dt.difference(now);

    if (diff.isNegative) {
      if (diff.inMinutes.abs() < 1) return 'just now';
      if (diff.inHours.abs() < 1) return '${diff.inMinutes.abs()}m ago';
      if (diff.inDays.abs() < 1) return '${diff.inHours.abs()}h ago';
      return '${diff.inDays.abs()}d ago';
    } else {
      if (diff.inMinutes < 1) return 'in < 1m';
      if (diff.inHours < 1) return 'in ${diff.inMinutes}m';
      if (diff.inDays < 1) return 'in ${diff.inHours}h';
      return 'in ${diff.inDays}d';
    }
  }

  String _formatDateTime(String? isoString) {
    if (isoString == null) return '';
    final dt = DateTime.tryParse(isoString)?.toLocal();
    if (dt == null) return isoString;
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    final min = dt.minute.toString().padLeft(2, '0');
    return '${months[dt.month - 1]} ${dt.day}, $h:$min $ampm';
  }

  String _recurrenceLabel(Map<String, dynamic>? recurrence) {
    if (recurrence == null) return 'Once';
    switch (recurrence['type'] as String? ?? 'once') {
      case 'daily':
        return 'Daily';
      case 'weekly':
        return 'Weekly';
      case 'monthly':
        return 'Monthly';
      case 'custom':
        final ms = recurrence['intervalMs'] as int? ?? 0;
        final totalMinutes = ms ~/ 60000;
        final h = totalMinutes ~/ 60;
        final m = totalMinutes % 60;
        if (h > 0 && m > 0) return 'Every ${h}h ${m}m';
        if (h > 0) return 'Every ${h}h';
        if (m > 0) return 'Every ${m}m';
        return 'Custom';
      default:
        return 'Once';
    }
  }

  String _backendLabel(String backend) {
    switch (backend) {
      case 'codex':
        return 'Codex';
      case 'claude':
      default:
        return 'Claude';
    }
  }

  IconData _backendIcon(String backend) {
    return backend == 'codex' ? Icons.terminal : Icons.auto_awesome;
  }

  List<Map<String, String>> _modelOptions(
    ChatProvider provider,
    String backend,
    String selectedModel,
  ) {
    final options = <String, String>{'': 'Provider default'};
    if (backend == 'claude') {
      options.addAll({'sonnet': 'Sonnet', 'opus': 'Opus', 'haiku': 'Haiku'});
    }
    if (provider.activeSessionBackend == backend) {
      for (final model in provider.supportedModels) {
        final value = (model['value'] ?? model['id'] ?? '').toString();
        if (value.isEmpty) continue;
        final label =
            (model['displayName'] ?? model['label'] ?? model['name'] ?? value)
                .toString();
        options[value] = label;
      }
    }
    if (selectedModel.isNotEmpty) {
      options.putIfAbsent(selectedModel, () => selectedModel);
    }
    options['__custom__'] = 'Custom model ID...';
    return options.entries
        .map((entry) => {'value': entry.key, 'label': entry.value})
        .toList();
  }

  List<String> _effortOptions(String backend) => backend == 'codex'
      ? const ['minimal', 'low', 'medium', 'high', 'max', 'xhigh', 'ultra']
      : const ['low', 'medium', 'high', 'max'];

  String _effortLabel(String effort) {
    switch (effort) {
      case 'xhigh':
        return 'Extra high';
      case 'ultra':
        return 'Ultra';
      default:
        return '${effort[0].toUpperCase()}${effort.substring(1)}';
    }
  }

  String _permissionLabel(String mode) {
    switch (mode) {
      case 'plan':
        return 'Read only';
      case 'default':
        return 'Workspace write';
      default:
        return 'Full access';
    }
  }

  Future<String?> _promptForModelId(String currentModel) async {
    final controller = TextEditingController(text: currentModel);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Custom Model'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Model ID',
            hintText: 'Provider model identifier',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) {
            final model = value.trim();
            if (model.isNotEmpty) Navigator.pop(dialogContext, model);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final model = controller.text.trim();
              if (model.isNotEmpty) Navigator.pop(dialogContext, model);
            },
            child: const Text('Use Model'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Widget _buildAgentSettings({
    required ChatProvider provider,
    required List<String> backends,
    required String selectedBackend,
    required String selectedModel,
    required String selectedEffort,
    required String selectedPermissionMode,
    required ValueChanged<String> onBackendChanged,
    required ValueChanged<String> onModelChanged,
    required ValueChanged<String> onEffortChanged,
    required ValueChanged<String> onPermissionChanged,
  }) {
    final models = _modelOptions(provider, selectedBackend, selectedModel);
    final efforts = _effortOptions(selectedBackend);
    final effectiveEffort = efforts.contains(selectedEffort)
        ? selectedEffort
        : 'high';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(
            'Agent',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Theme.of(context).colorScheme.onSurface.withAlpha(128),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DropdownButtonFormField<String>(
            key: ValueKey('provider-$selectedBackend'),
            isExpanded: true,
            initialValue: selectedBackend,
            decoration: const InputDecoration(
              labelText: 'Provider',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.hub_outlined),
              isDense: true,
            ),
            items: backends
                .map(
                  (backend) => DropdownMenuItem(
                    value: backend,
                    child: Text(_backendLabel(backend)),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value != null) onBackendChanged(value);
            },
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DropdownButtonFormField<String>(
            key: UniqueKey(),
            isExpanded: true,
            initialValue: selectedModel,
            decoration: const InputDecoration(
              labelText: 'Model',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.smart_toy_outlined),
              isDense: true,
            ),
            items: models
                .map(
                  (model) => DropdownMenuItem(
                    value: model['value'],
                    child: Text(
                      model['label']!,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) async {
              if (value == '__custom__') {
                final custom = await _promptForModelId(selectedModel);
                onModelChanged(custom ?? selectedModel);
                return;
              }
              onModelChanged(value ?? '');
            },
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey('effort-$selectedBackend-$effectiveEffort'),
                  isExpanded: true,
                  initialValue: effectiveEffort,
                  decoration: const InputDecoration(
                    labelText: 'Effort',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: efforts
                      .map(
                        (effort) => DropdownMenuItem(
                          value: effort,
                          child: Text(_effortLabel(effort)),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) onEffortChanged(value);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey('access-$selectedPermissionMode'),
                  isExpanded: true,
                  initialValue: selectedPermissionMode,
                  decoration: const InputDecoration(
                    labelText: 'Access',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'plan', child: Text('Read only')),
                    DropdownMenuItem(
                      value: 'default',
                      child: Text('Workspace write'),
                    ),
                    DropdownMenuItem(
                      value: 'bypassPermissions',
                      child: Text('Full access'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) onPermissionChanged(value);
                  },
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
          child: Text(
            selectedPermissionMode == 'plan'
                ? 'The agent can inspect files but cannot modify them.'
                : selectedPermissionMode == 'default'
                ? 'The agent can write in the workspace and may request approval.'
                : 'The agent can run unattended with read/write access.',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  String _shortenCwd(String cwd) {
    final homePattern = RegExp(r'^/home/[^/]+/');
    if (homePattern.hasMatch(cwd)) {
      return '~/${cwd.replaceFirst(homePattern, '')}';
    }
    return cwd;
  }

  List<String> _getRecentCwds(ChatProvider provider, {String? serverId}) {
    final seen = <String>{};
    final cwds = <String>[];
    for (final session in provider.sessions) {
      if (serverId != null && session.serverId != serverId) continue;
      if (seen.add(session.cwd)) {
        cwds.add(session.cwd);
      }
    }
    if (serverId == null || provider.serverConfigs.length <= 1) {
      if (seen.add(provider.defaultCwd)) {
        cwds.add(provider.defaultCwd);
      }
    }
    return cwds;
  }

  Future<String?> _showFolderBrowser(
    ChatProvider provider, {
    String? serverId,
  }) async {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            FolderBrowserScreen(provider: provider, serverId: serverId),
      ),
    );
  }

  void _showCreateDialog() {
    final provider = context.read<ChatProvider>();
    final nameController = TextEditingController();
    final promptController = TextEditingController();
    final cwdController = TextEditingController(text: provider.defaultCwd);
    DateTime selectedDate = DateTime.now().add(const Duration(hours: 1));
    String recurrenceType = 'once';
    bool reuseSession = false;
    bool quietMode = false;
    int customHours = 0;
    int customMinutes = 30;
    final hoursController = TextEditingController(text: '0');
    final minutesController = TextEditingController(text: '30');

    // Server selection
    final configs = provider.serverConfigs;
    final hasMultipleServers = configs.length > 1;
    String? selectedServerId;
    if (hasMultipleServers) {
      final connected = configs
          .where(
            (c) =>
                provider.connMgr.statusOf(c.id) == ConnectionStatus.connected,
          )
          .toList();
      selectedServerId = connected.isNotEmpty
          ? connected.first.id
          : configs.first.id;
    }
    String selectedBackend = provider.preferredBackendForServer(
      selectedServerId,
    );
    String selectedModel = '';
    String selectedEffort = 'high';
    String selectedPermissionMode = 'bypassPermissions';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final recentCwds = _getRecentCwds(
              provider,
              serverId: selectedServerId,
            );
            final backends = provider.backendsForServer(selectedServerId);
            if (!backends.contains(selectedBackend)) {
              selectedBackend = backends.first;
            }

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        'Schedule Task',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),

                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: nameController,
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          hintText: 'Short label, e.g. Nightly backup check',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.label_outline),
                        ),
                        maxLength: 100,
                        autofocus: true,
                      ),
                    ),
                    const SizedBox(height: 8),

                    // Prompt
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: promptController,
                        decoration: const InputDecoration(
                          labelText: 'Prompt',
                          hintText: 'What should the agent do?',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.chat_outlined),
                        ),
                        maxLines: 4,
                        minLines: 2,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Server picker (only if multiple servers)
                    if (hasMultipleServers) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: SizedBox(
                          width: double.infinity,
                          child: SegmentedButton<String>(
                            segments: configs.map((config) {
                              final isConnected =
                                  provider.connMgr.statusOf(config.id) ==
                                  ConnectionStatus.connected;
                              return ButtonSegment(
                                value: config.id,
                                label: Text(
                                  config.name,
                                  style: const TextStyle(fontSize: 12),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                icon: Icon(
                                  isConnected
                                      ? Icons.cloud_done
                                      : Icons.cloud_off,
                                  size: 14,
                                  color: isConnected
                                      ? Colors.green
                                      : Colors.grey,
                                ),
                              );
                            }).toList(),
                            selected: {
                              if (selectedServerId != null) selectedServerId!,
                            },
                            onSelectionChanged: (v) {
                              setSheetState(() {
                                selectedServerId = v.first;
                                selectedBackend = provider
                                    .preferredBackendForServer(
                                      selectedServerId,
                                    );
                                selectedModel = '';
                                selectedEffort = 'high';
                                selectedPermissionMode = 'bypassPermissions';
                              });
                            },
                            style: const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],

                    _buildAgentSettings(
                      provider: provider,
                      backends: backends,
                      selectedBackend: selectedBackend,
                      selectedModel: selectedModel,
                      selectedEffort: selectedEffort,
                      selectedPermissionMode: selectedPermissionMode,
                      onBackendChanged: (value) => setSheetState(() {
                        selectedBackend = value;
                        selectedModel = '';
                        selectedEffort = 'high';
                        selectedPermissionMode = 'bypassPermissions';
                      }),
                      onModelChanged: (value) =>
                          setSheetState(() => selectedModel = value),
                      onEffortChanged: (value) =>
                          setSheetState(() => selectedEffort = value),
                      onPermissionChanged: (value) =>
                          setSheetState(() => selectedPermissionMode = value),
                    ),

                    const Divider(height: 1),

                    // Working Directory section
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        'Working Directory',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(128),
                        ),
                      ),
                    ),

                    // Recent CWDs
                    if (recentCwds.isNotEmpty) ...[
                      ...recentCwds
                          .take(5)
                          .map(
                            (cwd) => ListTile(
                              dense: true,
                              leading: Icon(
                                Icons.folder_outlined,
                                size: 20,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              title: Text(
                                _shortenCwd(cwd),
                                style: const TextStyle(fontSize: 14),
                              ),
                              trailing: cwdController.text == cwd
                                  ? Icon(
                                      Icons.check,
                                      size: 18,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    )
                                  : null,
                              onTap: () {
                                cwdController.text = cwd;
                                setSheetState(() {});
                              },
                            ),
                          ),
                      const Divider(height: 1),
                    ],

                    // Browse button
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final picked = await _showFolderBrowser(
                              provider,
                              serverId: selectedServerId,
                            );
                            if (picked != null && ctx.mounted) {
                              cwdController.text = picked;
                              setSheetState(() {});
                            }
                          },
                          icon: const Icon(Icons.folder_open, size: 18),
                          label: const Text('Browse Server'),
                        ),
                      ),
                    ),

                    // Manual path input
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Text(
                        'Or type a path',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(128),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: TextField(
                        controller: cwdController,
                        decoration: InputDecoration(
                          hintText: '/path/to/project',
                          filled: true,
                          fillColor: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          isDense: true,
                        ),
                        style: const TextStyle(fontSize: 14),
                        onChanged: (_) => setSheetState(() {}),
                      ),
                    ),

                    const Divider(height: 1),

                    // Date/time picker
                    ListTile(
                      leading: const Icon(Icons.calendar_today),
                      title: Text(
                        _formatDateTime(selectedDate.toIso8601String()),
                      ),
                      subtitle: Text(
                        _formatTime(selectedDate.toIso8601String()),
                      ),
                      onTap: () async {
                        final date = await showDatePicker(
                          context: ctx,
                          initialDate: selectedDate,
                          firstDate: DateTime.now(),
                          lastDate: DateTime.now().add(
                            const Duration(days: 365),
                          ),
                        );
                        if (date == null) return;
                        if (!ctx.mounted) return;
                        final time = await showTimePicker(
                          context: ctx,
                          initialTime: TimeOfDay.fromDateTime(selectedDate),
                        );
                        if (time == null) return;
                        setSheetState(() {
                          selectedDate = DateTime(
                            date.year,
                            date.month,
                            date.day,
                            time.hour,
                            time.minute,
                          );
                        });
                      },
                    ),

                    // Recurrence picker
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: DropdownButtonFormField<String>(
                        initialValue: recurrenceType,
                        decoration: const InputDecoration(
                          labelText: 'Repeat',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.repeat),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(value: 'once', child: Text('Once')),
                          DropdownMenuItem(
                            value: 'daily',
                            child: Text('Daily'),
                          ),
                          DropdownMenuItem(
                            value: 'weekly',
                            child: Text('Weekly'),
                          ),
                          DropdownMenuItem(
                            value: 'monthly',
                            child: Text('Monthly'),
                          ),
                          DropdownMenuItem(
                            value: 'custom',
                            child: Text('Custom interval'),
                          ),
                        ],
                        onChanged: (v) {
                          setSheetState(() {
                            recurrenceType = v ?? 'once';
                            if (recurrenceType != 'once') {
                              reuseSession = true;
                            }
                          });
                        },
                      ),
                    ),

                    // Custom interval (only for custom)
                    if (recurrenceType == 'custom') ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                        child: Row(
                          children: [
                            const Text('Every  '),
                            SizedBox(
                              width: 52,
                              child: TextField(
                                keyboardType: TextInputType.number,
                                textAlign: TextAlign.center,
                                decoration: const InputDecoration(
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 8,
                                  ),
                                  border: OutlineInputBorder(),
                                ),
                                controller: hoursController,
                                onChanged: (v) {
                                  customHours = int.tryParse(v) ?? 0;
                                  setSheetState(() {});
                                },
                              ),
                            ),
                            const Text('h  '),
                            SizedBox(
                              width: 52,
                              child: TextField(
                                keyboardType: TextInputType.number,
                                textAlign: TextAlign.center,
                                decoration: const InputDecoration(
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 8,
                                  ),
                                  border: OutlineInputBorder(),
                                ),
                                controller: minutesController,
                                onChanged: (v) {
                                  final raw = int.tryParse(v) ?? 0;
                                  if (raw >= 60) {
                                    // Auto-normalize: overflow minutes into hours
                                    customHours += raw ~/ 60;
                                    customMinutes = raw % 60;
                                    hoursController.text = customHours
                                        .toString();
                                    minutesController.text = customMinutes
                                        .toString();
                                    minutesController
                                        .selection = TextSelection.fromPosition(
                                      TextPosition(
                                        offset: minutesController.text.length,
                                      ),
                                    );
                                  } else {
                                    customMinutes = raw;
                                  }
                                  setSheetState(() {});
                                },
                              ),
                            ),
                            const Text('m'),
                          ],
                        ),
                      ),
                      // Warning for frequent intervals
                      if ((customHours * 60 + customMinutes) > 0 &&
                          (customHours * 60 + customMinutes) < 30)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                          child: Row(
                            children: [
                              Icon(
                                Icons.warning_amber_rounded,
                                size: 14,
                                color: Colors.orange.shade300,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Intervals under 30 minutes may incur high API usage and costs.',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.orange.shade300,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 4),
                    ],

                    // Reuse session toggle (only for recurring)
                    if (recurrenceType != 'once') ...[
                      SwitchListTile(
                        title: const Text(
                          'Reuse same session',
                          style: TextStyle(fontSize: 14),
                        ),
                        subtitle: const Text(
                          'Continue in the same session across runs',
                          style: TextStyle(fontSize: 11),
                        ),
                        value: reuseSession,
                        onChanged: (v) => setSheetState(() => reuseSession = v),
                      ),
                    ],

                    SwitchListTile(
                      title: const Text(
                        'Quiet mode',
                        style: TextStyle(fontSize: 14),
                      ),
                      subtitle: const Text(
                        'Only notify when the agent calls NotifyUser',
                        style: TextStyle(fontSize: 11),
                      ),
                      value: quietMode,
                      onChanged: (v) => setSheetState(() => quietMode = v),
                    ),

                    // Schedule button
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () {
                            final prompt = promptController.text.trim();
                            final cwd = cwdController.text.trim();
                            if (prompt.isEmpty || cwd.isEmpty) return;
                            provider.scheduleTask(
                              name: nameController.text.trim(),
                              prompt: prompt,
                              cwd: cwd,
                              backend: selectedBackend,
                              model: selectedModel.isEmpty
                                  ? null
                                  : selectedModel,
                              effort: selectedEffort,
                              permissionMode: selectedPermissionMode,
                              scheduledTime: selectedDate
                                  .toUtc()
                                  .toIso8601String(),
                              recurrenceType: recurrenceType != 'once'
                                  ? recurrenceType
                                  : null,
                              customIntervalMs: recurrenceType == 'custom'
                                  ? (customHours * 3600000 +
                                        customMinutes * 60000)
                                  : null,
                              reuseSession: reuseSession,
                              notificationMode: quietMode
                                  ? 'quiet'
                                  : 'completion',
                              serverId: selectedServerId,
                            );
                            Navigator.pop(ctx);
                          },
                          icon: const Icon(Icons.schedule_send),
                          label: const Text('Schedule'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).then((_) {
      nameController.dispose();
      promptController.dispose();
      cwdController.dispose();
      hoursController.dispose();
      minutesController.dispose();
    });
  }

  void _showTaskActions(Map<String, dynamic> task) {
    final provider = context.read<ChatProvider>();
    final taskServerId = task['_serverId'] as String?;
    final status = task['status'] as String? ?? '';
    final sessionId = task['sessionId'] as String?;
    final isRecurring = task['recurrence'] != null;
    final canEdit =
        status == 'pending' ||
        status == 'running' ||
        status == 'cancelled' ||
        status == 'completed' ||
        status == 'failed';

    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (status != 'running')
                ListTile(
                  leading: const Icon(Icons.play_arrow),
                  title: const Text('Execute Now'),
                  onTap: () {
                    Navigator.pop(ctx);
                    provider.executeScheduledTask(task['id'] as String);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Task run requested')),
                    );
                  },
                ),
              if (canEdit)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Edit Task'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showEditDialog(task);
                  },
                ),
              if (sessionId != null && sessionId.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.open_in_new),
                  title: const Text('View Latest Session'),
                  onTap: () {
                    Navigator.pop(ctx);
                    provider.resumeSession(sessionId, serverId: taskServerId);
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const HomeScreen()),
                    );
                  },
                ),
              if (status == 'pending')
                ListTile(
                  leading: Icon(Icons.cancel, color: Colors.orange.shade300),
                  title: Text(
                    isRecurring ? 'Stop Recurring Task' : 'Cancel Task',
                    style: TextStyle(color: Colors.orange.shade300),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    provider.cancelScheduledTask(task['id'] as String);
                  },
                ),
              if (status != 'running')
                ListTile(
                  leading: Icon(Icons.delete, color: Colors.red.shade300),
                  title: Text(
                    'Delete Task',
                    style: TextStyle(color: Colors.red.shade300),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    provider.deleteScheduledTask(task['id'] as String);
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  void _showEditDialog(Map<String, dynamic> task) {
    final provider = context.read<ChatProvider>();
    final taskId = task['id'] as String;
    final nameController = TextEditingController(
      text: task['name'] as String? ?? '',
    );
    final promptController = TextEditingController(
      text: task['prompt'] as String? ?? '',
    );
    final cwdController = TextEditingController(
      text: task['cwd'] as String? ?? '',
    );

    // Parse existing scheduled time
    DateTime selectedDate =
        DateTime.tryParse(task['scheduledTime'] as String? ?? '')?.toLocal() ??
        DateTime.now().add(const Duration(hours: 1));
    // If in the past, default to 1 hour from now
    if (selectedDate.isBefore(DateTime.now())) {
      selectedDate = DateTime.now().add(const Duration(hours: 1));
    }

    // Parse existing recurrence
    final existingRecurrence = task['recurrence'] as Map<String, dynamic>?;
    String recurrenceType = existingRecurrence?['type'] as String? ?? 'once';
    bool reuseSession = task['reuseSession'] as bool? ?? false;
    bool quietMode = task['notificationMode'] == 'quiet';
    String selectedBackend = task['backend'] as String? ?? 'claude';
    String selectedModel = task['model'] as String? ?? '';
    String selectedEffort = task['effort'] as String? ?? 'high';
    if (!_effortOptions(selectedBackend).contains(selectedEffort)) {
      selectedEffort = 'high';
    }
    final storedPermissionMode = task['permissionMode'] as String?;
    String selectedPermissionMode =
        storedPermissionMode == 'plan' || storedPermissionMode == 'default'
        ? storedPermissionMode!
        : 'bypassPermissions';
    final taskServerId = task['_serverId'] as String?;

    // Parse custom interval
    final existingIntervalMs =
        existingRecurrence?['intervalMs'] as int? ?? 1800000;
    int customHours = existingIntervalMs ~/ 3600000;
    int customMinutes = (existingIntervalMs % 3600000) ~/ 60000;
    final hoursController = TextEditingController(text: customHours.toString());
    final minutesController = TextEditingController(
      text: customMinutes.toString(),
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final recentCwds = _getRecentCwds(provider);
            final availableBackends = provider.backendsForServer(
              taskServerId != null && taskServerId.isNotEmpty
                  ? taskServerId
                  : null,
            );
            final backends = availableBackends.contains(selectedBackend)
                ? availableBackends
                : [
                    selectedBackend,
                    ...availableBackends.where((b) => b != selectedBackend),
                  ];

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        'Edit Task',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),

                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: nameController,
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          hintText: 'Short label for lists and notifications',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.label_outline),
                        ),
                        maxLength: 100,
                      ),
                    ),
                    const SizedBox(height: 8),

                    // Prompt
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: promptController,
                        decoration: const InputDecoration(
                          labelText: 'Prompt',
                          hintText: 'What should the agent do?',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.chat_outlined),
                        ),
                        maxLines: 4,
                        minLines: 2,
                      ),
                    ),
                    const SizedBox(height: 12),

                    _buildAgentSettings(
                      provider: provider,
                      backends: backends,
                      selectedBackend: selectedBackend,
                      selectedModel: selectedModel,
                      selectedEffort: selectedEffort,
                      selectedPermissionMode: selectedPermissionMode,
                      onBackendChanged: (value) => setSheetState(() {
                        selectedBackend = value;
                        selectedModel = '';
                        selectedEffort = 'high';
                        selectedPermissionMode = 'bypassPermissions';
                      }),
                      onModelChanged: (value) =>
                          setSheetState(() => selectedModel = value),
                      onEffortChanged: (value) =>
                          setSheetState(() => selectedEffort = value),
                      onPermissionChanged: (value) =>
                          setSheetState(() => selectedPermissionMode = value),
                    ),

                    const Divider(height: 1),

                    // Working Directory section
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        'Working Directory',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(128),
                        ),
                      ),
                    ),

                    // Recent CWDs
                    if (recentCwds.isNotEmpty) ...[
                      ...recentCwds
                          .take(5)
                          .map(
                            (cwd) => ListTile(
                              dense: true,
                              leading: Icon(
                                Icons.folder_outlined,
                                size: 20,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              title: Text(
                                _shortenCwd(cwd),
                                style: const TextStyle(fontSize: 14),
                              ),
                              trailing: cwdController.text == cwd
                                  ? Icon(
                                      Icons.check,
                                      size: 18,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    )
                                  : null,
                              onTap: () {
                                cwdController.text = cwd;
                                setSheetState(() {});
                              },
                            ),
                          ),
                      const Divider(height: 1),
                    ],

                    // Browse button
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final picked = await _showFolderBrowser(provider);
                            if (picked != null && ctx.mounted) {
                              cwdController.text = picked;
                              setSheetState(() {});
                            }
                          },
                          icon: const Icon(Icons.folder_open, size: 18),
                          label: const Text('Browse Server'),
                        ),
                      ),
                    ),

                    // Manual path input
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Text(
                        'Or type a path',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(128),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: TextField(
                        controller: cwdController,
                        decoration: InputDecoration(
                          hintText: '/path/to/project',
                          filled: true,
                          fillColor: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          isDense: true,
                        ),
                        style: const TextStyle(fontSize: 14),
                        onChanged: (_) => setSheetState(() {}),
                      ),
                    ),

                    const Divider(height: 1),

                    // Date/time picker
                    ListTile(
                      leading: const Icon(Icons.calendar_today),
                      title: Text(
                        _formatDateTime(selectedDate.toIso8601String()),
                      ),
                      subtitle: Text(
                        _formatTime(selectedDate.toIso8601String()),
                      ),
                      onTap: () async {
                        final date = await showDatePicker(
                          context: ctx,
                          initialDate: selectedDate,
                          firstDate: DateTime.now(),
                          lastDate: DateTime.now().add(
                            const Duration(days: 365),
                          ),
                        );
                        if (date == null) return;
                        if (!ctx.mounted) return;
                        final time = await showTimePicker(
                          context: ctx,
                          initialTime: TimeOfDay.fromDateTime(selectedDate),
                        );
                        if (time == null) return;
                        setSheetState(() {
                          selectedDate = DateTime(
                            date.year,
                            date.month,
                            date.day,
                            time.hour,
                            time.minute,
                          );
                        });
                      },
                    ),

                    // Recurrence picker
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: DropdownButtonFormField<String>(
                        initialValue: recurrenceType,
                        decoration: const InputDecoration(
                          labelText: 'Repeat',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.repeat),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(value: 'once', child: Text('Once')),
                          DropdownMenuItem(
                            value: 'daily',
                            child: Text('Daily'),
                          ),
                          DropdownMenuItem(
                            value: 'weekly',
                            child: Text('Weekly'),
                          ),
                          DropdownMenuItem(
                            value: 'monthly',
                            child: Text('Monthly'),
                          ),
                          DropdownMenuItem(
                            value: 'custom',
                            child: Text('Custom interval'),
                          ),
                        ],
                        onChanged: (v) {
                          setSheetState(() {
                            recurrenceType = v ?? 'once';
                            if (recurrenceType != 'once') {
                              reuseSession = true;
                            }
                          });
                        },
                      ),
                    ),

                    // Custom interval
                    if (recurrenceType == 'custom') ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                        child: Row(
                          children: [
                            const Text('Every  '),
                            SizedBox(
                              width: 52,
                              child: TextField(
                                keyboardType: TextInputType.number,
                                textAlign: TextAlign.center,
                                decoration: const InputDecoration(
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 8,
                                  ),
                                  border: OutlineInputBorder(),
                                ),
                                controller: hoursController,
                                onChanged: (v) {
                                  customHours = int.tryParse(v) ?? 0;
                                  setSheetState(() {});
                                },
                              ),
                            ),
                            const Text('h  '),
                            SizedBox(
                              width: 52,
                              child: TextField(
                                keyboardType: TextInputType.number,
                                textAlign: TextAlign.center,
                                decoration: const InputDecoration(
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 8,
                                  ),
                                  border: OutlineInputBorder(),
                                ),
                                controller: minutesController,
                                onChanged: (v) {
                                  final raw = int.tryParse(v) ?? 0;
                                  if (raw >= 60) {
                                    customHours += raw ~/ 60;
                                    customMinutes = raw % 60;
                                    hoursController.text = customHours
                                        .toString();
                                    minutesController.text = customMinutes
                                        .toString();
                                    minutesController
                                        .selection = TextSelection.fromPosition(
                                      TextPosition(
                                        offset: minutesController.text.length,
                                      ),
                                    );
                                  } else {
                                    customMinutes = raw;
                                  }
                                  setSheetState(() {});
                                },
                              ),
                            ),
                            const Text('m'),
                          ],
                        ),
                      ),
                      if ((customHours * 60 + customMinutes) > 0 &&
                          (customHours * 60 + customMinutes) < 30)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                          child: Row(
                            children: [
                              Icon(
                                Icons.warning_amber_rounded,
                                size: 14,
                                color: Colors.orange.shade300,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Intervals under 30 minutes may incur high API usage and costs.',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.orange.shade300,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 4),
                    ],

                    // Reuse session toggle
                    if (recurrenceType != 'once') ...[
                      SwitchListTile(
                        title: const Text(
                          'Reuse same session',
                          style: TextStyle(fontSize: 14),
                        ),
                        subtitle: const Text(
                          'Continue in the same session across runs',
                          style: TextStyle(fontSize: 11),
                        ),
                        value: reuseSession,
                        onChanged: (v) => setSheetState(() => reuseSession = v),
                      ),
                    ],

                    SwitchListTile(
                      title: const Text(
                        'Quiet mode',
                        style: TextStyle(fontSize: 14),
                      ),
                      subtitle: const Text(
                        'Only notify when the agent calls NotifyUser',
                        style: TextStyle(fontSize: 11),
                      ),
                      value: quietMode,
                      onChanged: (v) => setSheetState(() => quietMode = v),
                    ),

                    // Save button
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () {
                            final prompt = promptController.text.trim();
                            final cwd = cwdController.text.trim();
                            if (prompt.isEmpty || cwd.isEmpty) return;
                            provider.updateScheduledTask(
                              taskId: taskId,
                              name: nameController.text.trim(),
                              prompt: prompt,
                              cwd: cwd,
                              backend: selectedBackend,
                              model: selectedModel,
                              effort: selectedEffort,
                              permissionMode: selectedPermissionMode,
                              scheduledTime: selectedDate
                                  .toUtc()
                                  .toIso8601String(),
                              recurrenceType: recurrenceType,
                              customIntervalMs: recurrenceType == 'custom'
                                  ? (customHours * 3600000 +
                                        customMinutes * 60000)
                                  : null,
                              reuseSession: reuseSession,
                              notificationMode: quietMode
                                  ? 'quiet'
                                  : 'completion',
                            );
                            Navigator.pop(ctx);
                          },
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('Save Changes'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).then((_) {
      nameController.dispose();
      promptController.dispose();
      cwdController.dispose();
      hoursController.dispose();
      minutesController.dispose();
    });
  }

  void _viewRunSession(String sessionId, String? serverId) {
    final provider = context.read<ChatProvider>();
    provider.resumeSession(sessionId, serverId: serverId);
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const HomeScreen()));
  }

  Widget _buildRunHistory(Map<String, dynamic> task) {
    final runs = (task['runs'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (runs.isEmpty) return const SizedBox.shrink();
    final taskServerId = task['_serverId'] as String?;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 16),
        Padding(
          padding: const EdgeInsets.only(left: 36, bottom: 4),
          child: Text(
            'Run History (${runs.length})',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface.withAlpha(160),
            ),
          ),
        ),
        ...runs.reversed.map((run) {
          final runStatus = run['status'] as String? ?? 'running';
          final runSessionId = run['sessionId'] as String? ?? '';
          final startedAt = run['startedAt'] as String?;
          final summary = run['resultSummary'] as String?;
          final runError = run['error'] as String?;

          return InkWell(
            onTap: runSessionId.isNotEmpty
                ? () => _viewRunSession(runSessionId, taskServerId)
                : null,
            child: Padding(
              padding: const EdgeInsets.only(
                left: 36,
                right: 12,
                top: 4,
                bottom: 4,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _statusIcon(runStatus),
                    size: 16,
                    color: _statusColor(runStatus).withAlpha(180),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _formatDateTime(startedAt),
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withAlpha(160),
                          ),
                        ),
                        if (summary != null && summary.isNotEmpty)
                          Text(
                            summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.green.shade300,
                            ),
                          ),
                        if (runError != null && runError.isNotEmpty)
                          Text(
                            runError,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.red.shade300,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (runSessionId.isNotEmpty)
                    Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withAlpha(80),
                    ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final tasks = provider.scheduledTasks;
        return Scaffold(
          appBar: AppBar(title: const Text('Scheduled Tasks')),
          floatingActionButton: FloatingActionButton(
            onPressed: _showCreateDialog,
            child: const Icon(Icons.add),
          ),
          body: tasks.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.schedule,
                        size: 64,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No scheduled tasks',
                        style: TextStyle(
                          fontSize: 18,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Tap + to schedule a task, or ask your agent\nto schedule one for you',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(
                            context,
                          ).colorScheme.outline.withAlpha(178),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(
                    top: 8,
                    bottom: 80,
                    left: 8,
                    right: 8,
                  ),
                  itemCount: tasks.length,
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    final taskId = task['id'] as String? ?? '';
                    final status = task['status'] as String? ?? 'pending';
                    final prompt = task['prompt'] as String? ?? '';
                    final name = (task['name'] as String? ?? '').trim();
                    final displayName = name.isNotEmpty ? name : prompt;
                    final cwd = task['cwd'] as String? ?? '';
                    final scheduledTime = task['scheduledTime'] as String?;
                    final resultSummary = task['resultSummary'] as String?;
                    final error = task['error'] as String?;
                    final recurrence =
                        task['recurrence'] as Map<String, dynamic>?;
                    final runCount = task['runCount'] as int? ?? 0;
                    final runs = (task['runs'] as List?) ?? [];
                    final backend = task['backend'] as String? ?? 'claude';
                    final model = task['model'] as String?;
                    final effort = task['effort'] as String?;
                    final permissionMode = task['permissionMode'] as String?;
                    final isRecurring = recurrence != null;
                    final isQuiet = task['notificationMode'] == 'quiet';
                    final isExpanded = _expandedTasks.contains(taskId);

                    return Card(
                      child: Column(
                        children: [
                          InkWell(
                            onTap: runs.isNotEmpty
                                ? () {
                                    setState(() {
                                      if (isExpanded) {
                                        _expandedTasks.remove(taskId);
                                      } else {
                                        _expandedTasks.add(taskId);
                                      }
                                    });
                                  }
                                : null,
                            onLongPress: () => _showTaskActions(task),
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Status icon
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      top: 2,
                                      right: 12,
                                    ),
                                    child: status == 'running'
                                        ? SizedBox(
                                            width: 24,
                                            height: 24,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: _statusColor(status),
                                            ),
                                          )
                                        : Icon(
                                            _statusIcon(status),
                                            color: _statusColor(status),
                                            size: 24,
                                          ),
                                  ),
                                  // Content
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        // Human-readable task label
                                        Text(
                                          displayName,
                                          maxLines: name.isNotEmpty ? 1 : 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        if (name.isNotEmpty &&
                                            prompt.isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            prompt,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 4),
                                        // Recurrence + run count badge
                                        if (isRecurring) ...[
                                          Row(
                                            children: [
                                              Icon(
                                                Icons.repeat,
                                                size: 12,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .primary
                                                    .withAlpha(180),
                                              ),
                                              const SizedBox(width: 4),
                                              Text(
                                                _recurrenceLabel(recurrence),
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary
                                                      .withAlpha(180),
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                              if (runCount > 0) ...[
                                                const SizedBox(width: 8),
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 6,
                                                        vertical: 1,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .primary
                                                        .withAlpha(30),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          8,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    '$runCount run${runCount == 1 ? '' : 's'}',
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .primary
                                                          .withAlpha(200),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                              if (task['reuseSession'] ==
                                                  true) ...[
                                                const SizedBox(width: 6),
                                                Icon(
                                                  Icons.link,
                                                  size: 11,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withAlpha(100),
                                                ),
                                              ],
                                            ],
                                          ),
                                          const SizedBox(height: 2),
                                        ],
                                        Row(
                                          children: [
                                            Icon(
                                              _backendIcon(backend),
                                              size: 12,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurface
                                                  .withAlpha(128),
                                            ),
                                            const SizedBox(width: 4),
                                            Expanded(
                                              child: Text(
                                                [
                                                  _backendLabel(backend),
                                                  model == null || model.isEmpty
                                                      ? 'Default model'
                                                      : model,
                                                  effort == null
                                                      ? 'Default effort'
                                                      : _effortLabel(effort),
                                                  permissionMode == null
                                                      ? 'Inherited access'
                                                      : _permissionLabel(
                                                          permissionMode,
                                                        ),
                                                  if (isQuiet) 'Quiet',
                                                ].join(' · '),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withAlpha(128),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        // CWD
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.folder_outlined,
                                              size: 12,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurface
                                                  .withAlpha(128),
                                            ),
                                            const SizedBox(width: 4),
                                            Expanded(
                                              child: Text(
                                                _shortenCwd(cwd),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withAlpha(128),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        // Scheduled time
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.schedule,
                                              size: 12,
                                              color: _statusColor(
                                                status,
                                              ).withAlpha(180),
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              isRecurring && status == 'pending'
                                                  ? 'Next: ${_formatDateTime(scheduledTime)} (${_formatTime(scheduledTime)})'
                                                  : '${_formatDateTime(scheduledTime)} (${_formatTime(scheduledTime)})',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: _statusColor(
                                                  status,
                                                ).withAlpha(180),
                                              ),
                                            ),
                                          ],
                                        ),
                                        // Result or error
                                        if (resultSummary != null &&
                                            resultSummary.isNotEmpty) ...[
                                          const SizedBox(height: 4),
                                          Text(
                                            resultSummary,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.green.shade300,
                                            ),
                                          ),
                                        ],
                                        if (error != null &&
                                            error.isNotEmpty) ...[
                                          const SizedBox(height: 4),
                                          Text(
                                            error,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.red.shade300,
                                            ),
                                          ),
                                        ],
                                        // Expand hint for runs
                                        if (runs.isNotEmpty && !isExpanded) ...[
                                          const SizedBox(height: 4),
                                          Row(
                                            children: [
                                              Icon(
                                                Icons.expand_more,
                                                size: 14,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurface
                                                    .withAlpha(80),
                                              ),
                                              const SizedBox(width: 2),
                                              Text(
                                                'Long-press to show ${runs.length} run${runs.length == 1 ? '' : 's'}',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withAlpha(80),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          // Expanded run history
                          if (isExpanded) _buildRunHistory(task),
                        ],
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}
