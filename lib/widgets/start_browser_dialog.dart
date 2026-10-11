import 'dart:async';

import 'package:flutter/material.dart';

import '../models/active_browser_session.dart';
import '../models/traced_error.dart';
import '../services/chat_provider.dart';
import 'error_trace_row.dart';

/// Asks for an address and a profile, then opens a browser for the active
/// session without the agent. Returns the running browser, or null when the
/// user cancels. Failures stay in the dialog with a traceable ID.
Future<ActiveBrowserSession?> showStartBrowserDialog(
  BuildContext context,
  ChatProvider provider,
) {
  return showDialog<ActiveBrowserSession>(
    context: context,
    builder: (_) => _StartBrowserDialog(provider: provider),
  );
}

class _StartBrowserDialog extends StatefulWidget {
  const _StartBrowserDialog({required this.provider});

  final ChatProvider provider;

  @override
  State<_StartBrowserDialog> createState() => _StartBrowserDialogState();
}

class _StartBrowserDialogState extends State<_StartBrowserDialog> {
  final _url = TextEditingController();
  final _profile = TextEditingController();

  /// Saved profiles that are not already open. Null while loading.
  List<BrowserProfile>? _profiles;
  String? _profileError;
  TracedError? _failure;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadProfiles());
  }

  @override
  void dispose() {
    _url.dispose();
    _profile.dispose();
    super.dispose();
  }

  Future<void> _loadProfiles() async {
    try {
      final all = await widget.provider.requestBrowserProfiles();
      if (!mounted) return;
      final taken = {for (final profile in all) profile.profile};
      var fresh = 'browser';
      for (var n = 2; taken.contains(fresh); n++) {
        fresh = 'browser-$n';
      }
      final available = all.where((profile) => !profile.running).toList();
      setState(() {
        _profiles = available;
        _profile.text = available.isEmpty ? fresh : available.first.profile;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _profiles = const [];
        _profile.text = 'browser';
        _failure = widget.provider.traceError(
          'browser_profiles',
          'Saved browsers could not be listed: ${_describe(error)}',
        );
      });
    }
  }

  Future<void> _open() async {
    final profile = _profile.text.trim().toLowerCase();
    if (!BrowserProfile.namePattern.hasMatch(profile)) {
      setState(() => _profileError = 'Use lowercase letters, numbers, - and _');
      return;
    }
    var url = _url.text.trim();
    if (url.isEmpty) url = 'https://www.google.com';
    if (!url.contains('://')) url = 'https://$url';
    setState(() {
      _profileError = null;
      _failure = null;
      _opening = true;
    });
    try {
      final browser = await widget.provider.startBrowserSession(
        profile: profile,
        url: url,
      );
      if (mounted) Navigator.of(context).pop(browser);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _failure = widget.provider.traceError(
          'browser_start',
          'The browser did not open: ${_describe(error)}',
        );
      });
    }
  }

  static String _describe(Object error) => switch (error) {
    StateError(:final message) => message,
    TimeoutException(:final message) => message ?? 'Timed out.',
    _ => '$error',
  };

  @override
  Widget build(BuildContext context) {
    final profiles = _profiles;
    final failure = _failure;
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      title: const Text('New browser'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _url,
              autofocus: true,
              enabled: !_opening,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Address',
                hintText: 'www.google.com',
              ),
              onSubmitted: (_) => _open(),
            ),
            const SizedBox(height: 12),
            if (profiles == null)
              const Text('Loading saved browsers')
            else
              DropdownMenu<String>(
                controller: _profile,
                enabled: !_opening,
                expandedInsets: EdgeInsets.zero,
                label: const Text('Profile'),
                helperText:
                    'Keeps its own sign-ins. Type a name for a new one.',
                errorText: _profileError,
                requestFocusOnTap: true,
                dropdownMenuEntries: [
                  for (final profile in profiles)
                    DropdownMenuEntry(
                      value: profile.profile,
                      label: profile.profile,
                    ),
                ],
              ),
            if (failure != null) ...[
              const SizedBox(height: 12),
              Text(
                failure.message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              ErrorTraceRow(
                trace: failure,
                onReport: widget.provider.reportError,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _opening ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _opening || profiles == null ? null : _open,
          child: Text(_opening ? 'Opening' : 'Open'),
        ),
      ],
    );
  }
}
