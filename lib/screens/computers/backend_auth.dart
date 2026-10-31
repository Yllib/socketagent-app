import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/app_distribution.dart';
import '../../services/chat_provider.dart';
import '../../services/codex_sign_in_callback.dart';
import '../../services/notification_service.dart';

// Sign-in and repair flows for one backend (Claude or Codex) on one
// computer: the device-code dialog, the auth code overlay and the progress
// dialog for a running install or repair.

const MethodChannel _nativeChannel = MethodChannel(
  'com.socketagent.app/intent',
);

Future<bool?> confirmBackendReauth(
  BuildContext context, {
  required String backendName,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('$backendName is already signed in'),
      content: Text(
        'You can keep the current sign-in, or start a new $backendName sign-in and replace the existing authentication on this computer.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Keep Current'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Sign In Again'),
        ),
      ],
    ),
  );
}

Future<void> _openBackendAuthPage(
  BuildContext context, {
  required String authUrl,
  required String? authCode,
  required String overlayTitle,
}) async {
  final hasCode = authCode != null && authCode.isNotEmpty;
  if (authCode != null && authCode.isNotEmpty) {
    await Clipboard.setData(ClipboardData(text: authCode));
  }
  if (!context.mounted) return;
  final uri = Uri.tryParse(authUrl);
  if (uri == null) return;

  if (hasCode) {
    if (AppBuild.supportsSystemOverlays) {
      final overlayReady = await _ensureAuthCodeOverlayPermission(context);
      if (!context.mounted || !overlayReady) return;
      final shown = await _showAuthCodeOverlay(
        title: overlayTitle,
        code: authCode,
      );
      if (!context.mounted) return;
      if (!shown) {
        final openAnyway = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Code overlay did not appear'),
            content: const Text(
              'The code was copied, but Android did not allow SocketAgent to draw the overlay. You can open the browser anyway and paste the copied code.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Open Browser Anyway'),
              ),
            ],
          ),
        );
        if (!context.mounted || openAnyway != true) return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            shown
                ? 'Code copied and shown over browser'
                : 'Code copied, but overlay could not be shown',
          ),
        ),
      );
    } else {
      final shown = await NotificationService().showInstant(
        id: NotificationService.stableId('auth-code:$overlayTitle'),
        title: '$overlayTitle code',
        body:
            '$authCode\nCopied to clipboard. Return to SocketAgent when sign-in finishes.',
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            shown
                ? 'Code copied and shown in a notification'
                : 'Code copied to clipboard',
          ),
        ),
      );
    }
  }
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

Future<bool> _ensureAuthCodeOverlayPermission(BuildContext context) async {
  bool allowed = false;
  try {
    allowed =
        await _nativeChannel.invokeMethod<bool>('canDrawOverlays') ?? false;
  } catch (_) {}
  if (allowed) return true;

  if (!context.mounted) return false;
  final openSettings = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Allow code overlay?'),
      content: const Text(
        'SocketAgent needs Display over other apps permission to keep the device code visible while your browser is open.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Not Now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Open Settings'),
        ),
      ],
    ),
  );
  if (!context.mounted || openSettings != true) return false;
  try {
    await _nativeChannel.invokeMethod('requestOverlayPermission');
  } catch (_) {}
  return false;
}

Future<void> _requestAuthCodeOverlayPermission(BuildContext context) async {
  final allowed = await _ensureAuthCodeOverlayPermission(context);
  if (!context.mounted) return;
  if (allowed) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Code overlay is already enabled')),
    );
  }
}

Future<bool> _showAuthCodeOverlay({
  required String title,
  required String code,
}) async {
  try {
    return await _nativeChannel.invokeMethod<bool>('showAuthCodeOverlay', {
          'title': title,
          'code': code,
          'timeoutSeconds': 900,
        }) ??
        false;
  } catch (_) {
    return false;
  }
}

Widget _buildBackendDeviceAuthCard(
  BuildContext context, {
  required String backend,
  required String backendName,
  required String? authUrl,
  required String? authCode,
  bool browserSignIn = false,
  VoidCallback? onOpenBrowser,
}) {
  final theme = Theme.of(context);
  final hasCode = authCode != null && authCode.isNotEmpty;
  final hasUrl = authUrl != null && authUrl.isNotEmpty;
  final waitingForCodexCode =
      backend == 'codex' && !browserSignIn && hasUrl && !hasCode;

  return DecoratedBox(
    decoration: BoxDecoration(
      border: Border.all(color: theme.colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            backend == 'claude' || browserSignIn
                ? '$backendName sign-in'
                : 'Device sign-in',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          if (hasCode) ...[
            Text(
              'Code',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      authCode,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy code',
                    icon: const Icon(Icons.copy, size: 20),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: authCode));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Code copied')),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ] else if (waitingForCodexCode) ...[
            Text(
              'Waiting for Codex to print the device code...',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (hasUrl)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: waitingForCodexCode
                    ? null
                    : onOpenBrowser ??
                          () => _openBackendAuthPage(
                            context,
                            authUrl: authUrl,
                            authCode: authCode,
                            overlayTitle: '$backendName sign-in',
                          ),
                icon: const Icon(Icons.open_in_browser),
                label: Text(
                  waitingForCodexCode
                      ? 'Waiting for Device Code'
                      : hasCode
                      ? AppBuild.supportsSystemOverlays
                            ? 'Show Code & Open Browser'
                            : 'Copy Code & Open Browser'
                      : 'Open Browser',
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

Widget _buildBackendOutputBlock(BuildContext context, List<String> output) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Output', style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(height: 6),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SingleChildScrollView(
            reverse: true,
            padding: const EdgeInsets.all(10),
            child: SelectableText(
              output.join('\n'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
      ),
    ],
  );
}

Future<void> showBackendSignIn(
  BuildContext context,
  ChatProvider provider,
  String serverId,
  String backend, {
  bool force = false,
}) async {
  if (provider.backendInstallState(serverId, backend)?.running == true) {
    showBackendOperationDialog(
      context,
      provider,
      serverId,
      backend,
      fallbackOperation: 'auth',
    );
    return;
  }
  var method = 'device';
  if (backend == 'codex') {
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign in to ChatGPT'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Use your ChatGPT account for Codex.'),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.open_in_browser),
              label: const Text('Sign in with browser'),
              onPressed: () => Navigator.pop(dialogContext, 'browser'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.pin_outlined),
              label: const Text('Use a device code'),
              onPressed: () => Navigator.pop(dialogContext, 'device'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    method = selected;
  }
  provider.authenticateBackend(
    serverId,
    backend: backend,
    // A deliberate sign-in choice must not be skipped by cached login status.
    force: backend == 'codex' || force,
    authMethod: method,
  );
  showBackendOperationDialog(
    context,
    provider,
    serverId,
    backend,
    fallbackOperation: 'auth',
  );
}

void showBackendOperationDialog(
  BuildContext context,
  ChatProvider provider,
  String serverId,
  String backend, {
  required String fallbackOperation,
}) {
  final rootContext = context;
  final backendName = backend == 'codex' ? 'Codex' : 'Claude';
  final claudeAuthCodeCtrl = TextEditingController();
  CodexSignInCallback? codexCallback;
  String? callbackRequestId;

  provider.requestServerSettings(serverId: serverId);
  final pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
    provider.requestServerSettings(serverId: serverId);
  });

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => Consumer<ChatProvider>(
      builder: (context, currentProvider, _) {
        final state = currentProvider.backendInstallState(serverId, backend);
        final running = state?.running == true;
        final failed = state?.status == 'failed';
        final cancelled = state?.status == 'cancelled';
        final alreadyRunningConflict =
            failed &&
            (state?.message.toLowerCase().contains('already running') ?? false);
        final completed =
            state?.running == false && state?.status == 'completed';
        final authUrl = state?.authUrl;
        final output = state?.output ?? const <String>[];
        final authCode = state?.authCode;
        final operation = state?.operation ?? fallbackOperation;
        final isAuthOperation = operation == 'auth';
        final hasAuthUrl = authUrl != null && authUrl.isNotEmpty;
        final hasAuthCode = authCode != null && authCode.isNotEmpty;
        final showDeviceAuthCard =
            isAuthOperation && running && (hasAuthUrl || hasAuthCode);
        if (!running && codexCallback != null) {
          unawaited(codexCallback!.close());
          codexCallback = null;
          callbackRequestId = null;
        }
        if (completed || failed || cancelled) pollTimer.cancel();
        final title = isAuthOperation
            ? completed
                  ? '$backendName sign-in complete'
                  : failed
                  ? 'Could not sign in to $backendName'
                  : cancelled
                  ? '$backendName sign-in cancelled'
                  : '$backendName sign-in'
            : '$backendName reinstall';

        return AlertDialog(
          title: Row(
            children: [
              Icon(
                failed || cancelled
                    ? Icons.error_outline
                    : running
                    ? Icons.sync
                    : Icons.check_circle_outline,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(title)),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    completed && isAuthOperation
                        ? 'Signed in successfully. You can now use $backendName on this computer.'
                        : cancelled && isAuthOperation
                        ? 'You can sign in again whenever you are ready.'
                        : showDeviceAuthCard
                        ? 'Finish $backendName sign-in in your browser, then return to SocketAgent.'
                        : state?.message ??
                              (isAuthOperation
                                  ? 'Starting sign-in...'
                                  : 'Starting reinstall...'),
                  ),
                  if (showDeviceAuthCard) ...[
                    const SizedBox(height: 12),
                    _buildBackendDeviceAuthCard(
                      context,
                      backend: backend,
                      backendName: backendName,
                      authUrl: authUrl,
                      authCode: authCode,
                      browserSignIn: state?.authMethod == 'browser',
                      onOpenBrowser: state?.authMethod == 'browser'
                          ? () async {
                              try {
                                final uri = Uri.parse(authUrl!);
                                if (callbackRequestId != state!.requestId) {
                                  await codexCallback?.close();
                                  codexCallback = CodexSignInCallback();
                                  await codexCallback!.start(
                                    authUrl: uri,
                                    serverIsLocal: provider
                                        .backendServerIsLocal(serverId),
                                    forward: (url) =>
                                        provider.completeCodexBrowserSignIn(
                                          serverId,
                                          state.requestId,
                                          url,
                                        ),
                                  );
                                  callbackRequestId = state.requestId;
                                }
                                if (!dialogContext.mounted) return;
                                if (!await launchUrl(
                                  uri,
                                  mode: LaunchMode.externalApplication,
                                )) {
                                  throw StateError('Browser could not open');
                                }
                              } catch (_) {
                                if (dialogContext.mounted) {
                                  await showDialog<void>(
                                    context: dialogContext,
                                    builder: (errorContext) => AlertDialog(
                                      title: const Text(
                                        'Could not open sign-in',
                                      ),
                                      content: const Text(
                                        'Try opening your browser again, or cancel this sign-in and use a device code.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(errorContext),
                                          child: const Text('OK'),
                                        ),
                                      ],
                                    ),
                                  );
                                }
                              }
                            }
                          : null,
                    ),
                  ],
                  if (isAuthOperation &&
                      running &&
                      state?.authMethod != 'browser' &&
                      AppBuild.supportsSystemOverlays) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.picture_in_picture_alt_outlined),
                        label: const Text('Enable Code Overlay'),
                        onPressed: () {
                          _requestAuthCodeOverlayPermission(context);
                        },
                      ),
                    ),
                  ],
                  if (backend == 'claude' &&
                      isAuthOperation &&
                      running &&
                      hasAuthUrl) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: claudeAuthCodeCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Claude auth code',
                        hintText: 'Paste copied code',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      minLines: 1,
                      maxLines: 3,
                      onSubmitted: (_) => _submitClaudeAuthCode(
                        currentProvider,
                        serverId,
                        state?.requestId,
                        claudeAuthCodeCtrl.text,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.check),
                        label: const Text('Submit Code'),
                        onPressed: () => _submitClaudeAuthCode(
                          currentProvider,
                          serverId,
                          state?.requestId,
                          claudeAuthCodeCtrl.text,
                        ),
                      ),
                    ),
                  ],
                  if (output.isNotEmpty && !isAuthOperation) ...[
                    const SizedBox(height: 12),
                    _buildBackendOutputBlock(context, output),
                  ],
                  if (output.isNotEmpty && isAuthOperation && !completed) ...[
                    const SizedBox(height: 8),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('Details'),
                      children: [_buildBackendOutputBlock(context, output)],
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (!isAuthOperation || !running)
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(completed || cancelled ? 'Done' : 'Close'),
              ),
            if (running || alreadyRunningConflict)
              TextButton(
                onPressed: () {
                  currentProvider.cancelBackendOperation(
                    serverId,
                    backend: backend,
                    force: alreadyRunningConflict,
                  );
                },
                child: Text(isAuthOperation ? 'Cancel sign-in' : 'Force Stop'),
              ),
            if ((failed || cancelled) &&
                isAuthOperation &&
                backend == 'codex' &&
                state?.authMethod == 'browser')
              TextButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  currentProvider.authenticateBackend(
                    serverId,
                    backend: backend,
                    force: true,
                    authMethod: 'device',
                  );
                  showBackendOperationDialog(
                    rootContext,
                    currentProvider,
                    serverId,
                    backend,
                    fallbackOperation: 'auth',
                  );
                },
                child: const Text('Use a device code'),
              ),
            if (failed || cancelled)
              FilledButton(
                onPressed: () {
                  if (isAuthOperation) {
                    Navigator.of(dialogContext).pop();
                    unawaited(
                      showBackendSignIn(
                        rootContext,
                        currentProvider,
                        serverId,
                        backend,
                        force: true,
                      ),
                    );
                  } else {
                    currentProvider.repairBackend(
                      serverId,
                      backend: backend,
                      reinstall: true,
                    );
                  }
                },
                child: const Text('Try again'),
              ),
          ],
        );
      },
    ),
  ).whenComplete(() {
    pollTimer.cancel();
    unawaited(codexCallback?.close());
    claudeAuthCodeCtrl.dispose();
  });
}

void _submitClaudeAuthCode(
  ChatProvider provider,
  String serverId,
  String? requestId,
  String rawCode,
) {
  final code = rawCode.trim();
  if (code.isEmpty || requestId == null || requestId.isEmpty) return;
  provider.submitAuthCode(code, serverId: serverId, authRequestId: requestId);
}
