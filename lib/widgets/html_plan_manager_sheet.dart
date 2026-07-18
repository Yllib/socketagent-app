import 'package:flutter/material.dart';

import '../models/html_plan.dart';
import '../screens/html_plan_viewer_screen.dart';
import '../services/chat_provider.dart';

class HtmlPlanManagerSheet extends StatefulWidget {
  const HtmlPlanManagerSheet({super.key, required this.provider});

  final ChatProvider provider;

  @override
  State<HtmlPlanManagerSheet> createState() => _HtmlPlanManagerSheetState();
}

class _HtmlPlanManagerSheetState extends State<HtmlPlanManagerSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.provider.refreshHtmlPlans(),
    );
  }

  Future<void> _rename(HtmlPlan plan) async {
    final controller = TextEditingController(text: plan.title);
    try {
      final title = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Rename plan'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 160,
            decoration: const InputDecoration(labelText: 'Title'),
            onSubmitted: (value) => Navigator.pop(context, value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Rename'),
            ),
          ],
        ),
      );
      if (title == null || title.isEmpty || title == plan.title) return;
      await widget.provider.renameHtmlPlan(plan, title);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not rename plan: $error')),
        );
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _delete(HtmlPlan plan) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete plan?'),
        content: Text(
          '“${plan.title}” will be permanently removed from this session.',
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
      await widget.provider.deleteHtmlPlan(plan);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete plan: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.provider,
      builder: (context, _) {
        final plans = widget.provider.htmlPlans;
        return DraggableScrollableSheet(
          initialChildSize: 0.72,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) => Column(
            children: [
              ListTile(
                leading: const Icon(Icons.view_quilt_outlined),
                title: const Text('HTML plans'),
                subtitle: const Text('Saved with this session'),
                trailing: IconButton(
                  tooltip: 'Refresh',
                  onPressed: widget.provider.htmlPlansLoading
                      ? null
                      : widget.provider.refreshHtmlPlans,
                  icon: const Icon(Icons.refresh),
                ),
              ),
              const Divider(height: 1),
              if (widget.provider.htmlPlansLoading)
                const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: widget.provider.htmlPlansError != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            widget.provider.htmlPlansError!,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : plans.isEmpty && !widget.provider.htmlPlansLoading
                    ? const Center(
                        child: Text('No HTML plans in this session yet.'),
                      )
                    : ListView.separated(
                        controller: scrollController,
                        itemCount: plans.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final plan = plans[index];
                          return ListTile(
                            leading: const Icon(Icons.description_outlined),
                            title: Text(plan.title),
                            subtitle: Text(
                              'Updated ${_formatDate(plan.updatedAt)}',
                            ),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    HtmlPlanViewerScreen(plan: plan),
                              ),
                            ),
                            trailing: PopupMenuButton<String>(
                              onSelected: (value) {
                                if (value == 'rename') _rename(plan);
                                if (value == 'delete') _delete(plan);
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'rename',
                                  child: Text('Rename'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Delete'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatDate(DateTime value) {
    final local = value.toLocal();
    return '${local.month}/${local.day}/${local.year} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}
