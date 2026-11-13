import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../config/app_palette.dart';
import '../../models/account_vault.dart';
import '../../services/account_crypto.dart';
import '../../services/account_service.dart';
import '../../services/chat_provider.dart';
import '../../services/device_unlock.dart';
import '../../services/google_auth.dart';
import 'account_pin_dialogs.dart';
import 'settings_v2_screen.dart';

/// Asks for a recovery key and opens the account with it. Throws a
/// [StateError] when the key is not accepted.
Future<void> restoreAccountWithRecoveryKey(
  BuildContext context,
  AccountService account,
) async {
  final typed = await showDialog<String>(
    context: context,
    builder: (_) => const _RecoveryKeyDialog(),
  );
  if (typed == null) return;
  final ok = await account.restoreWithRecoveryKey(typed);
  if (!ok) throw StateError('That is not a recovery key');
}

/// Runs a sign-in or restore from a screen without its own error row. A
/// cancelled Google sign-in is silent; anything else goes to a snackbar.
Future<void> runAccountAction(
  BuildContext context,
  Future<void> Function() action,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
  } on GoogleAuthCanceled {
    // The user closed the sign-in. Nothing to report.
  } catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(accountErrorText(error))));
  }
}

/// The account: an encrypted vault of computers and settings shared between
/// this user's devices. A new device joins by signing in with Google and
/// typing the account PIN: the app's hidden Drive folder holds the key
/// sealed to the PIN, and the relay checks the PIN. The relay only ever
/// stores ciphertext.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final account = context.read<ChatProvider>().account;
    if (account.hasAccount) unawaited(account.sync());
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on GoogleAuthCanceled {
      // The user closed the sign-in. Nothing to report.
    } catch (error) {
      if (mounted) setState(() => _error = accountErrorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn(AccountService account) =>
      _run(() => signInToAccount(context, account));

  Future<void> _setFirstPin(AccountService account) =>
      _run(() => setFirstAccountPin(context, account));

  Future<void> _setNewPin(AccountService account) =>
      _run(() => setNewAccountPin(context, account));

  Future<void> _restore(AccountService account) =>
      _run(() => restoreAccountWithRecoveryKey(context, account));

  Future<void> _showRecoveryKey(AccountService account) => _run(() async {
    final key = account.recoveryKey;
    if (key == null) return;
    const unlock = DeviceUnlock();
    if (unlock.isSupported) {
      final ok = await unlock.confirm(
        title: 'Show recovery key',
        description: 'Unlock to show the SocketAgent account recovery key.',
      );
      if (!ok) return;
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Show recovery key?'),
          content: const Text(
            'Anyone with this key can open the account. Make sure nobody '
            'is looking at the screen.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Show'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecoveryKeyScreen(recoveryKey: key),
      ),
    );
  });

  Future<void> _removeDevice(AccountService account, VaultDevice device) =>
      _run(() => removeAccountDevice(context, account, device));

  Future<void> _signOut(AccountService account) => _run(() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'This device keeps its computers but stops syncing. Signing in '
          'again picks the account back up. To stop this device for good, '
          'remove it from another device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await account.signOut();
  });

  Future<void> _deleteAccount(AccountService account) => _run(() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'Deletes the synced list of computers on the relay and the account '
          'key in your Google Drive. Every device signs out of the account. '
          'Computers stay saved on each device. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ctx.palette.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await account.deleteAccount();
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final account = provider.account;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Account'),
            actions: [
              if (account.hasAccount)
                IconButton(
                  tooltip: 'Sync now',
                  icon: const Icon(Icons.sync),
                  onPressed: account.syncing ? null : () => account.sync(),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              if (_error case final error?)
                ListTile(
                  leading: Icon(Icons.error_outline, color: palette.danger),
                  title: Text(error),
                ),
              if (account.notice case final notice?)
                ListTile(
                  leading: Icon(Icons.info_outline, color: palette.warning),
                  title: Text(notice),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: account.dismissNotice,
                  ),
                ),
              if (!account.hasAccount)
                ..._noAccount(account)
              else
                ..._withAccount(provider, account),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _noAccount(AccountService account) => [
    ListTile(
      leading: const Icon(Icons.login),
      title: const Text('Sign in with Google'),
      subtitle: Text(
        account.googleConfigured
            ? 'Syncs computers, tokens and settings between your devices'
            : 'Google sign-in is not set up in this build',
      ),
      enabled: !_busy && account.googleConfigured,
      onTap: () => _signIn(account),
    ),
    ListTile(
      leading: const Icon(Icons.key_outlined),
      title: const Text('Restore with recovery key'),
      enabled: !_busy,
      onTap: () => _restore(account),
    ),
  ];

  List<Widget> _withAccount(ChatProvider provider, AccountService account) {
    final palette = context.palette;
    final vault = account.vault;
    final synced = account.lastSyncedAt;
    final computers = vault?.computers.length ?? 0;
    return [
      ListTile(
        leading: Icon(
          account.signedInWithGoogle
              ? Icons.account_circle
              : Icons.account_circle_outlined,
          color: account.signedInWithGoogle ? palette.success : palette.warning,
        ),
        title: Text(account.googleEmail ?? 'Restored with the recovery key'),
        subtitle: Text(
          account.signedInWithGoogle
              ? 'Signed in with Google'
              : account.googleEmail != null
              ? 'Signed out of Google. Sign in to keep syncing'
              : 'Sign in with Google so other devices can join',
        ),
        trailing: account.signedInWithGoogle
            ? null
            : TextButton(
                onPressed: _busy || !account.googleConfigured
                    ? null
                    : () => _signIn(account),
                child: const Text('Sign in'),
              ),
      ),
      ListTile(
        leading: Icon(
          account.syncing ? Icons.sync : Icons.cloud_done_outlined,
          color: account.lastError == null ? palette.success : palette.warning,
        ),
        title: Text(
          account.syncing
              ? 'Syncing'
              : synced == null
              ? 'Not synced yet'
              : 'Synced ${_ago(synced)}',
        ),
        subtitle: Text(
          account.lastError ??
              'Vault version ${account.lastVersion} · '
                  '$computers computer${computers == 1 ? '' : 's'} · '
                  'account ${account.accountId!.substring(0, 8)}',
        ),
      ),
      ..._pinRows(account),
      const SettingsGroupLabel('Devices'),
      for (final device in account.devices)
        ListTile(
          leading: Icon(
            device.platform == 'windows'
                ? Icons.desktop_windows_outlined
                : Icons.smartphone,
            color: device.publicKey == provider.devicePublicKey
                ? palette.success
                : null,
          ),
          title: Text(
            device.publicKey == provider.devicePublicKey
                ? '${device.name} (this device)'
                : device.name,
          ),
          subtitle: Text(
            '${device.platform} · added ${accountDate(device.addedAt)} · '
            'code ${formatFingerprintCode(deviceFingerprintCode(device.publicKey))}',
          ),
          trailing: device.publicKey == provider.devicePublicKey
              ? null
              : IconButton(
                  tooltip: 'Remove',
                  icon: Icon(Icons.delete_outline, color: palette.danger),
                  onPressed: _busy
                      ? null
                      : () => _removeDevice(account, device),
                ),
        ),
      const Divider(height: 1, indent: 16, endIndent: 16),
      ListTile(
        leading: const Icon(Icons.key_outlined),
        title: const Text('Show recovery key'),
        enabled: !_busy,
        onTap: () => _showRecoveryKey(account),
      ),
      ListTile(
        leading: Icon(Icons.logout, color: palette.danger),
        title: Text('Sign out', style: TextStyle(color: palette.danger)),
        enabled: !_busy,
        onTap: () => _signOut(account),
      ),
      ListTile(
        leading: Icon(Icons.delete_forever_outlined, color: palette.danger),
        title: Text('Delete account', style: TextStyle(color: palette.danger)),
        enabled: !_busy,
        onTap: () => _deleteAccount(account),
      ),
    ];
  }

  static String _ago(DateTime at) {
    final diff = DateTime.now().difference(at);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes} min ago';
    if (diff.inDays < 1) return '${diff.inHours} h ago';
    return '${diff.inDays} d ago';
  }

  /// Where the account's PIN stands, and the Drive notice.
  List<Widget> _pinRows(AccountService account) {
    final palette = context.palette;
    final warning = Icon(Icons.info_outline, color: palette.warning);
    return [
      switch (account.pinState) {
        AccountPinState.none => ListTile(
          leading: warning,
          title: const Text('No account PIN'),
          subtitle: const Text('New devices cannot join until you set one'),
          enabled: !_busy,
          onTap: () => _setFirstPin(account),
        ),
        AccountPinState.mustSetAgain => ListTile(
          leading: warning,
          title: const Text('PIN must be set again'),
          subtitle: const Text('New devices cannot join until then'),
          enabled: !_busy,
          onTap: () => _setNewPin(account),
        ),
        AccountPinState.set => ListTile(
          leading: const Icon(Icons.pin_outlined),
          title: const Text('Account PIN'),
          subtitle: Text(accountPinSummary(account)),
          enabled: !_busy,
          onTap: () => _setNewPin(account),
        ),
      },
      if (account.driveHoldsUnknownKey)
        ListTile(
          leading: warning,
          title: const Text(
            'Google Drive holds a key this device does not know',
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'New devices would join another account. Someone may have '
                'changed your Google Drive data.',
              ),
              TextButton(
                onPressed: _busy ? null : () => _run(account.putDriveFileBack),
                child: const Text('Put this one back'),
              ),
            ],
          ),
        ),
    ];
  }
}

/// When and where the PIN was set, and how new devices have used it. The
/// use and the wrong tries come from the relay, so they wait for a sync.
String accountPinSummary(AccountService account) {
  final pin = account.vault?.pin;
  if (pin == null) return '';
  final device = account.deviceNameOf(pin.setBy);
  final relay = account.relayPin;
  final wrong = relay?.wrongTotal ?? 0;
  return [
    'Set ${accountDate(pin.setAt)}${device == null ? '' : ' on $device'}.',
    if (relay != null) ...[
      relay.lastUnlockAt == 0
          ? 'Not used yet.'
          : 'Last used ${accountDate(relay.lastUnlockAt)}.',
      wrong == 1 ? '1 wrong try.' : '$wrong wrong tries.',
    ],
  ].join(' ');
}

/// Shows the recovery key with screenshots blocked.
class RecoveryKeyScreen extends StatefulWidget {
  const RecoveryKeyScreen({super.key, required this.recoveryKey});

  final String recoveryKey;

  @override
  State<RecoveryKeyScreen> createState() => _RecoveryKeyScreenState();
}

class _RecoveryKeyScreenState extends State<RecoveryKeyScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recovery key')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'This opens the account on any device without Google or the '
            'PIN. Keep it somewhere safe and never type it into a chat.',
          ),
          const SizedBox(height: 12),
          SelectableText(
            widget.recoveryKey,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 16,
              height: 1.6,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy'),
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: widget.recoveryKey),
                );
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Copied. Clear the clipboard after pasting.'),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RecoveryKeyDialog extends StatefulWidget {
  const _RecoveryKeyDialog();

  @override
  State<_RecoveryKeyDialog> createState() => _RecoveryKeyDialogState();
}

class _RecoveryKeyDialogState extends State<_RecoveryKeyDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Recovery key'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        maxLines: 3,
        decoration: const InputDecoration(hintText: 'SAR1-XXXX-XXXX-...'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Restore'),
        ),
      ],
    );
  }
}
