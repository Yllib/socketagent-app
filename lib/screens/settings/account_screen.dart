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
import '../../services/window_security_service.dart';

/// The account: an encrypted vault of computers and settings shared between
/// this user's devices. Every device joins by signing in with Google, which
/// holds the key in the app's hidden Drive folder. The relay only ever
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
      if (mounted) {
        setState(
          () => _error = switch (error) {
            StateError(:final message) => message,
            FormatException(:final message) => message,
            GoogleAuthNotConfigured() => error.toString(),
            _ => 'Something went wrong: $error',
          },
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn(AccountService account) =>
      _run(account.signInWithGoogle);

  Future<void> _restore(AccountService account) => _run(() async {
    final typed = await showDialog<String>(
      context: context,
      builder: (_) => const _RecoveryKeyDialog(),
    );
    if (typed == null) return;
    final ok = await account.restoreWithRecoveryKey(typed);
    if (!ok) throw StateError('That is not a recovery key');
  });

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
      _run(() async {
        final choice = await showDialog<_DeviceRemoval>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Remove ${device.name}?'),
            content: Text(
              'Forget is for a device whose app is gone, such as after a '
              'reinstall. It drops ${device.name} from the account and your '
              'computers.\n\n'
              'Remove is for a lost device or one someone else has. It also '
              'gives the account a new key and gives every computer a new '
              'pairing token. If ${device.name} is still signed in to your '
              'Google account it can read the new account key, so also '
              'remove it from your Google account (Google Account, Security, '
              'Your devices).',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(_DeviceRemoval.forget),
                child: const Text('Forget'),
              ),
              FilledButton(
                onPressed: account.signedInWithGoogle
                    ? () => Navigator.of(ctx).pop(_DeviceRemoval.remove)
                    : null,
                child: const Text('Remove'),
              ),
            ],
          ),
        );
        switch (choice) {
          case _DeviceRemoval.forget:
            await account.forgetDevice(device.publicKey);
          case _DeviceRemoval.remove:
            await account.removeDevice(device.publicKey);
          case null:
            return;
        }
      });

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
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              if (_error case final error?)
                ListTile(
                  leading: Icon(Icons.error_outline, color: palette.danger),
                  title: Text(error),
                ),
              if (account.removedNotice case final notice?)
                ListTile(
                  leading: Icon(Icons.info_outline, color: palette.warning),
                  title: Text(notice),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: account.dismissRemovedNotice,
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
    const ListTile(
      title: Text('Sync computers, tokens and settings between your devices.'),
      subtitle: Text(
        'The key lives in your Google Drive, in a folder only this app can '
        'see. The relay stores encrypted data it cannot read.',
      ),
    ),
    ListTile(
      leading: const Icon(Icons.login),
      title: const Text('Sign in with Google'),
      subtitle: account.googleConfigured
          ? null
          : const Text('Google sign-in isn\'t set up in this build'),
      enabled: !_busy && account.googleConfigured,
      onTap: () => _signIn(account),
    ),
    ListTile(
      leading: const Icon(Icons.key_outlined),
      title: const Text('Restore with recovery key'),
      subtitle: const Text('For when you cannot use your Google account'),
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
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Text(
          'Devices',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
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
            '${device.platform} · added ${_date(device.addedAt)} · '
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
      const ListTile(
        dense: true,
        title: Text(
          'Other devices join by signing in with the same Google account.',
        ),
      ),
      ListTile(
        leading: const Icon(Icons.key_outlined),
        title: const Text('Recovery key'),
        subtitle: const Text(
          'A copy of the key outside Google. Needs the device unlock',
        ),
        enabled: !_busy,
        onTap: () => _showRecoveryKey(account),
      ),
      ListTile(
        leading: Icon(Icons.logout, color: palette.danger),
        title: Text('Sign out', style: TextStyle(color: palette.danger)),
        subtitle: const Text('Keeps the computers on this device'),
        enabled: !_busy,
        onTap: () => _signOut(account),
      ),
      ListTile(
        leading: Icon(Icons.delete_forever_outlined, color: palette.danger),
        title: Text('Delete account', style: TextStyle(color: palette.danger)),
        subtitle: const Text('Signs out every device'),
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

  static String _date(int unixMs) {
    if (unixMs <= 0) return 'unknown';
    final at = DateTime.fromMillisecondsSinceEpoch(unixMs).toLocal();
    return '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
  }
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
  void initState() {
    super.initState();
    unawaited(WindowSecurityService.enableScreenshotProtection());
  }

  @override
  void dispose() {
    unawaited(WindowSecurityService.disableScreenshotProtection());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recovery key')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'This opens the account on any device without Google. Keep it '
            'somewhere safe and never type it into a chat.',
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

enum _DeviceRemoval { forget, remove }
