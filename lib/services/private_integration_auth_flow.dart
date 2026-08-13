import 'package:flutter/material.dart';

import '../models/private_integration_auth.dart';
import '../models/server_config.dart';
import '../screens/ibs_auth_screen.dart';
import '../screens/outlook_auth_screen.dart';
import 'chat_provider.dart';

Future<void> runPrivateIntegrationAuthFlow({
  required BuildContext context,
  required ChatProvider provider,
  required ServerConfig computer,
  required String integration,
}) async {
  final label = integration == 'ibs-auth' ? 'IBS' : 'Outlook';
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(content: Text('Opening $label sign-in…')));

  late final PrivateIntegrationAuthChallenge challenge;
  try {
    challenge = await provider.requestPrivateIntegrationAuth(
      serverId: computer.id,
      integration: integration,
    );
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not start $label sign-in: $error')),
    );
    return;
  }
  if (!context.mounted) {
    provider.cancelPrivateIntegrationAuth(challenge);
    return;
  }

  final startUri = Uri.tryParse(challenge.startUrl);
  final allowedOrigins = challenge.captureOrigins
      .map(Uri.tryParse)
      .whereType<Uri>()
      .where((uri) => uri.scheme == 'https' && uri.host.isNotEmpty)
      .map((uri) => uri.origin)
      .toSet();
  if (startUri == null ||
      startUri.scheme != 'https' ||
      startUri.userInfo.isNotEmpty ||
      !allowedOrigins.contains(startUri.origin) ||
      allowedOrigins.length != 1) {
    provider.cancelPrivateIntegrationAuth(challenge);
    messenger.showSnackBar(
      SnackBar(content: Text('$label returned an invalid sign-in address.')),
    );
    return;
  }

  final result = await Navigator.of(context).push<Map<String, dynamic>>(
    MaterialPageRoute(
      builder: (_) => integration == 'ibs-auth'
          ? IBSAuthScreen(
              startUrl: startUri.toString(),
              captureOrigins: allowedOrigins.toList(growable: false),
            )
          : OutlookAuthScreen(
              startUrl: startUri.toString(),
              captureOrigins: allowedOrigins.toList(growable: false),
            ),
    ),
  );
  if (result == null) {
    provider.cancelPrivateIntegrationAuth(challenge);
    return;
  }

  messenger.showSnackBar(SnackBar(content: Text('Validating $label sign-in…')));
  try {
    final outcome = await provider.completePrivateIntegrationAuth(
      challenge,
      result,
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(outcome.message),
        backgroundColor: outcome.success ? Colors.green : Colors.red,
      ),
    );
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text('$label validation failed: $error')),
    );
  }
}
