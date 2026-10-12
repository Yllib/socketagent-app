import 'dart:async';

import 'package:flutter/material.dart';

import '../models/active_browser_session.dart';
import '../models/traced_error.dart';
import '../services/chat_provider.dart';
import 'error_trace_row.dart';

/// Opens a new browser on the default profile for the active session,
/// without the agent. Returns the running browser, or null after showing why
/// it did not open.
Future<ActiveBrowserSession?> openNewBrowser(
  BuildContext context,
  ChatProvider provider,
) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Opening a browser')));
  try {
    return await provider.startBrowserSession(url: 'https://www.google.com');
  } catch (error) {
    final failure = provider.traceError(
      'browser_start',
      'The browser did not open: ${_describe(error)}',
    );
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Theme.of(context).colorScheme.surface,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(failure.message),
              ErrorTraceRow(trace: failure, onReport: provider.reportError),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
    return null;
  } finally {
    messenger.hideCurrentSnackBar();
  }
}

/// Lists the computer's saved profiles for [browser]. Tapping one moves the
/// browser onto it, Save as copies the current one under a new name, and the
/// X deletes a profile no browser is using.
Future<void> showBrowserProfileSheet(
  BuildContext context,
  ChatProvider provider,
  ActiveBrowserSession browser,
) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    isScrollControlled: true,
    builder: (_) => _BrowserProfileSheet(provider: provider, browser: browser),
  );
}

String _describe(Object error) => switch (error) {
  StateError(:final message) => message,
  TimeoutException(:final message) => message ?? 'Timed out.',
  _ => '$error',
};

class _BrowserProfileSheet extends StatefulWidget {
  const _BrowserProfileSheet({required this.provider, required this.browser});

  final ChatProvider provider;
  final ActiveBrowserSession browser;

  @override
  State<_BrowserProfileSheet> createState() => _BrowserProfileSheetState();
}

class _BrowserProfileSheetState extends State<_BrowserProfileSheet> {
  /// Null while loading.
  List<BrowserProfile>? _profiles;
  TracedError? _failure;

  /// What the computer is doing, such as "Switching to bank".
  String? _busy;

  ChatProvider get _provider => widget.provider;
  String get _current => widget.browser.browserProfile;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final profiles = await _provider.requestBrowserProfiles();
      if (mounted) setState(() => _profiles = profiles);
    } catch (error) {
      _fail('browser_profiles', 'Profiles could not be listed', error);
      if (mounted) setState(() => _profiles = const []);
    }
  }

  void _fail(String kind, String what, Object error) {
    if (!mounted) return;
    setState(() {
      _busy = null;
      _failure = _provider.traceError(kind, '$what: ${_describe(error)}');
    });
  }

  Future<void> _run(
    String busy,
    String kind,
    String what,
    Future<void> Function() action,
  ) async {
    setState(() {
      _busy = busy;
      _failure = null;
    });
    try {
      await action();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      _fail(kind, what, error);
    }
  }

  Future<void> _switch(BrowserProfile profile) => _run(
    'Switching to ${profile.profile}',
    'browser_profile_switch',
    'The browser did not switch to ${profile.profile}',
    () => _provider.switchBrowserProfile(widget.browser, profile.profile),
  );

  Future<void> _saveAs() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _SaveAsDialog(
        taken: {for (final profile in _profiles ?? const []) profile.profile},
        current: _current,
      ),
    );
    if (name == null || !mounted) return;
    await _run(
      'Saving as $name',
      'browser_profile_save',
      '$_current was not saved as $name',
      () => _provider.saveBrowserProfileAs(widget.browser, name),
    );
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
      _busy = 'Deleting ${profile.profile}';
      _failure = null;
    });
    try {
      final profiles = await _provider.deleteBrowserProfile(profile.profile);
      if (mounted) {
        setState(() {
          _busy = null;
          _profiles = profiles;
        });
      }
    } catch (error) {
      _fail(
        'browser_profile_delete',
        '${profile.profile} was not deleted',
        error,
      );
    }
  }

  Widget _profileRow(BrowserProfile profile) {
    final colors = Theme.of(context).colorScheme;
    final current = profile.profile == _current;
    final idle = _busy == null;
    return InkWell(
      onTap: idle && !current ? () => _switch(profile) : null,
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: current ? const Icon(Icons.check, size: 18) : null,
            ),
            Expanded(
              child: Text(
                profile.profile,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: current
                      ? colors.onSurface
                      : colors.onSurface.withValues(alpha: 0.7),
                  fontWeight: current ? FontWeight.w600 : null,
                ),
              ),
            ),
            // A running profile has browsers that would close.
            if (!profile.running &&
                _provider.serverSupportsBrowserProfileDelete)
              IconButton(
                tooltip: 'Delete ${profile.profile}',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                onPressed: idle ? () => _delete(profile) : null,
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
    final busy = _busy;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: busy == null && profiles != null ? _saveAs : null,
              child: const SizedBox(
                height: 44,
                child: Row(
                  children: [
                    SizedBox(
                      width: 32,
                      child: Icon(Icons.save_outlined, size: 18),
                    ),
                    Text('Save as...'),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            if (profiles == null)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('Loading profiles'),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final profile in profiles) _profileRow(profile),
                  ],
                ),
              ),
            if (busy != null)
              Padding(padding: const EdgeInsets.all(12), child: Text(busy)),
            if (failure != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      failure.message,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    ErrorTraceRow(
                      trace: failure,
                      onReport: _provider.reportError,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Asks for a new profile name. Returns it, or null when cancelled.
class _SaveAsDialog extends StatefulWidget {
  const _SaveAsDialog({required this.taken, required this.current});

  final Set<String> taken;
  final String current;

  @override
  State<_SaveAsDialog> createState() => _SaveAsDialogState();
}

class _SaveAsDialogState extends State<_SaveAsDialog> {
  final _name = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim().toLowerCase();
    final error = !BrowserProfile.namePattern.hasMatch(name)
        ? 'Use lowercase letters, numbers, - and _'
        : widget.taken.contains(name)
        ? '$name already exists'
        : null;
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      title: Text('Save ${widget.current} as'),
      content: TextField(
        controller: _name,
        autofocus: true,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: 'Profile name',
          // Chrome locks a profile while it runs, so copying restarts it.
          helperText: 'Browsers on ${widget.current} restart for a moment.',
          errorText: _error,
        ),
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
