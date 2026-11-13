import 'package:flutter/material.dart';

import '../../models/server_config.dart';
import '../../services/chat_provider.dart';
import '../pair_screen.dart';
import '../paywall_screen.dart';

/// True once the phone may use the relay, after the paywall if needed.
Future<bool> ensureRelayAccess(
  BuildContext context,
  ChatProvider provider,
) async {
  if (provider.hasCachedRelayAccess) {
    provider.refreshSubscriptionStatusIfStale();
    return true;
  }

  if (provider.subscriberToken.isNotEmpty) {
    final active = await provider.checkSubscriptionStatus();
    if (!context.mounted) return false;
    if (active) return true;
  }

  final signedIn = await Navigator.of(
    context,
  ).push<bool>(MaterialPageRoute(builder: (_) => const PaywallScreen()));
  if (!context.mounted) return false;

  if (signedIn != true) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Sign up for relay before scanning a QR.')),
    );
    return false;
  }
  return true;
}

/// Scans the computer QR and saves the relay pairing on [config].
Future<void> pairServerRelay(
  BuildContext context,
  ChatProvider provider,
  ServerConfig config, {
  bool requireRelayAccess = true,
}) async {
  if (requireRelayAccess) {
    final hasRelayAccess = await ensureRelayAccess(context, provider);
    if (!context.mounted || !hasRelayAccess) return;
  }

  final result = await Navigator.of(context).push<PairingResult>(
    MaterialPageRoute(
      builder: (_) => PairScreen(
        cryptoService: provider.connMgr.getCrypto(config.id) ?? provider.crypto,
      ),
    ),
  );
  if (!context.mounted || result == null) return;

  await provider.pairServerRelay(
    config.id,
    relayUrl: result.relayUrl,
    pairingToken: result.pairingToken,
    serverPubkey: result.serverPubkey,
    pairingSecret: result.pairingSecret,
  );
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('Relay paired for ${config.name}')));
}
