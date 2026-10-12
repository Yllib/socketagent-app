import 'dart:async';

import 'package:flutter/material.dart';

import '../models/active_browser_session.dart';
import '../models/traced_error.dart';
import '../services/chat_provider.dart';
import 'error_trace_row.dart';

/// Asks for an address and a profile, then opens a browser for the active
/// session without the agent. Saved profiles can be picked or deleted from
/// the list. Returns the running browser, or null when the user cancels.
/// Failures stay in the dialog with a traceable ID.
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

  /// The profile being deleted, while the computer works on it.
  String? _deleting;

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
      setState(() => _show(all));
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

  /// Lists the profiles that are not open. An empty name gets the first
  /// saved profile, or a fresh name when none are free.
  void _show(List<BrowserProfile> all) {
    final taken = {for (final profile in all) profile.profile};
    var fresh = 'browser';
    for (var n = 2; taken.contains(fresh); n++) {
      fresh = 'browser-$n';
    }
    final available = all.where((profile) => !profile.running).toList();
    if (_profile.text.trim().isEmpty) {
      _profile.text = available.isEmpty ? fresh : available.first.profile;
    }
    _profiles = available;
  }

  Future<void> _delete(BrowserProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text('Delete ${profile.profile}?'),
        content: const Text('Its sign-ins and browsing data are removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _deleting = profile.profile;
      _failure = null;
    });
    try {
      final all = await widget.provider.deleteBrowserProfile(profile.profile);
      if (!mounted) return;
      setState(() {
        _deleting = null;
        if (_profile.text.trim() == profile.profile) _profile.clear();
        _show(all);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _deleting = null;
        _failure = widget.provider.traceError(
          'browser_profile_delete',
          '${profile.profile} was not deleted: ${_describe(error)}',
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

  Widget _profileRow(BrowserProfile profile) {
    final colors = Theme.of(context).colorScheme;
    final selected = _profile.text.trim() == profile.profile;
    final busy = _opening || _deleting != null;
    return InkWell(
      onTap: busy ? null : () => _profile.text = profile.profile,
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            Expanded(
              child: Text(
                profile.profile,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected
                      ? colors.onSurface
                      : colors.onSurface.withValues(alpha: 0.6),
                  fontWeight: selected ? FontWeight.w600 : null,
                ),
              ),
            ),
            if (_deleting == profile.profile)
              const Text('Deleting')
            else if (widget.provider.serverSupportsBrowserProfileDelete)
              IconButton(
                tooltip: 'Delete ${profile.profile}',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                onPressed: busy ? null : () => _delete(profile),
                icon: const Icon(Icons.close),
              ),
          ],
        ),
      ),
    );
  }

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
            TextField(
              controller: _profile,
              enabled: !_opening && profiles != null,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Profile',
                helperText:
                    'Keeps its own sign-ins. Type a name for a new one.',
                errorText: _profileError,
              ),
              onSubmitted: (_) => _open(),
            ),
            if (profiles == null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Loading saved browsers'),
              )
            else if (profiles.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: ListenableBuilder(
                  listenable: _profile,
                  builder: (context, _) => ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(top: 8),
                    children: [
                      for (final profile in profiles) _profileRow(profile),
                    ],
                  ),
                ),
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
