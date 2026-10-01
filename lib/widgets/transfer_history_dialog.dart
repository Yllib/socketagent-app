import 'package:flutter/material.dart';
import '../services/transfer_history.dart';

class TransferHistoryDialog extends StatefulWidget {
  const TransferHistoryDialog({
    super.key,
    required this.load,
    required this.itemBuilder,
  });

  final Future<TransferHistory> Function() load;
  final Widget Function(BuildContext, Map<String, dynamic>) itemBuilder;

  @override
  State<TransferHistoryDialog> createState() => _TransferHistoryDialogState();
}

class _TransferHistoryDialogState extends State<TransferHistoryDialog> {
  late Future<TransferHistory> _history;

  @override
  void initState() {
    super.initState();
    _history = _load();
  }

  Future<TransferHistory> _load() => Future<TransferHistory>.sync(
    widget.load,
  ).timeout(const Duration(seconds: 20));

  @override
  Widget build(BuildContext context) => FutureBuilder<TransferHistory>(
    future: _history,
    builder: (context, snapshot) {
      final loading = snapshot.connectionState != ConnectionState.done;
      final history = snapshot.data;
      final failed =
          snapshot.hasError || (history?.problems.isNotEmpty ?? false);
      return AlertDialog(
        title: const Text('Transfers'),
        content: SizedBox(
          width: 480,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .6,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (loading)
                    const Text('Loading transfers…')
                  else if (snapshot.hasError)
                    const Text('Could not load transfers. Try again.')
                  else if (history != null) ...[
                    if (history.jobs.isEmpty && history.problems.isEmpty)
                      const Text('No transfers on connected computers.'),
                    for (final problem in history.problems)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(problem),
                      ),
                    for (final job in history.jobs.reversed)
                      widget.itemBuilder(context, job),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: loading
                ? null
                : () => setState(() {
                    _history = _load();
                  }),
            child: Text(failed ? 'Retry' : 'Refresh'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
