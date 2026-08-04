import 'dart:async';

import '../models/server_config.dart';
import 'crypto_service.dart';
import 'websocket_service.dart';

enum ServerProbeFailureKind {
  invalidPublicKey,
  subscriptionRequired,
  authenticationFailed,
  unreachable,
  timedOut,
  rejected,
}

class ServerProbeResult {
  const ServerProbeResult._({
    required this.success,
    this.failureKind,
    this.message,
    this.capabilities = const {},
  });

  const ServerProbeResult.success(Map<String, dynamic> capabilities)
    : this._(success: true, capabilities: capabilities);

  const ServerProbeResult.failure(
    ServerProbeFailureKind failureKind,
    String message,
  ) : this._(success: false, failureKind: failureKind, message: message);

  final bool success;
  final ServerProbeFailureKind? failureKind;
  final String? message;
  final Map<String, dynamic> capabilities;

  String? get suggestedServerName {
    final identity = capabilities['serverIdentity'];
    if (identity is! Map) return null;
    final hostname = identity['hostname']?.toString().trim() ?? '';
    return hostname.isEmpty ? null : hostname;
  }

  String? get platform {
    final identity = capabilities['serverIdentity'];
    final value = identity is Map
        ? identity['platform']?.toString()
        : capabilities['platform']?.toString();
    return value == null || value.trim().isEmpty ? null : value.trim();
  }

  String? get serverVersion {
    final value = capabilities['serverReleaseVersion']?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  List<String> get backends {
    final value = capabilities['backends'];
    if (value is List) {
      return value.map((item) => item.toString()).toList(growable: false);
    }
    return const [];
  }
}

class ServerConnectionProbe {
  const ServerConnectionProbe();

  Future<ServerProbeResult> verify(
    ServerConfig config, {
    required String subscriberToken,
    Duration timeout = const Duration(seconds: 18),
  }) async {
    final crypto = CryptoService();
    try {
      await crypto.ensureKeyPair();
      crypto.setServerPublicKey(config.serverPubkey);
    } catch (_) {
      return const ServerProbeResult.failure(
        ServerProbeFailureKind.invalidPublicKey,
        'The computer public key is invalid. Copy it again from the SocketAgent pairing output.',
      );
    }

    final socket = WebSocketService(manageBulkLane: false);
    final result = Completer<ServerProbeResult>();
    Timer? terminalStatusTimer;
    late final StreamSubscription<Map<String, dynamic>> messageSub;
    late final StreamSubscription<ConnectionStatus> statusSub;

    void complete(ServerProbeResult value) {
      if (!result.isCompleted) result.complete(value);
    }

    messageSub = socket.messages.listen((message) {
      final type = message['type']?.toString() ?? '';
      if (type == 'server_capabilities') {
        terminalStatusTimer?.cancel();
        complete(ServerProbeResult.success(Map<String, dynamic>.from(message)));
        return;
      }
      if (type == 'subscription_required') {
        complete(
          const ServerProbeResult.failure(
            ServerProbeFailureKind.subscriptionRequired,
            'Relay sign-in is required before this computer can connect.',
          ),
        );
        return;
      }
      if (type == 'error') {
        final raw = message['message']?.toString() ?? 'Connection rejected';
        final unauthorized =
            raw.toLowerCase().contains('unauthorized') ||
            raw.toLowerCase().contains('authentication');
        complete(
          ServerProbeResult.failure(
            unauthorized
                ? ServerProbeFailureKind.authenticationFailed
                : ServerProbeFailureKind.rejected,
            unauthorized
                ? 'The authentication token was not accepted.'
                : 'SocketAgent rejected the connection: $raw',
          ),
        );
      }
    });

    statusSub = socket.statusStream.listen((status) {
      if (status != ConnectionStatus.error &&
          status != ConnectionStatus.disconnected) {
        terminalStatusTimer?.cancel();
        return;
      }
      // An encrypted error frame can arrive immediately before the socket
      // closes. Give it a brief chance to provide the actionable reason.
      terminalStatusTimer?.cancel();
      terminalStatusTimer = Timer(const Duration(milliseconds: 350), () {
        complete(
          ServerProbeResult.failure(
            ServerProbeFailureKind.unreachable,
            config.useRelay
                ? 'The relay is reachable, but this computer is not online yet.'
                : 'The phone could not reach that address and port. Check the forwarding, firewall, or VPN route.',
          ),
        );
      });
    });

    if (config.useRelay) {
      socket.configureRelay(
        relayUrl: config.relayUrl,
        pairingToken: config.pairingToken,
        cryptoService: crypto,
        subscriberToken: subscriberToken,
      );
      socket.setMode(ConnectionMode.relay);
    } else {
      socket.configure(
        host: config.host,
        port: config.port,
        token: config.token,
        cryptoService: crypto,
      );
      socket.setMode(ConnectionMode.direct);
    }

    socket.connect();

    try {
      return await result.future.timeout(
        timeout,
        onTimeout: () => ServerProbeResult.failure(
          ServerProbeFailureKind.timedOut,
          config.useRelay
              ? 'Timed out waiting for the computer. Make sure SocketAgent is running, then try again.'
              : 'Timed out reaching that address. Check the forwarded port, firewall, or VPN route.',
        ),
      );
    } finally {
      terminalStatusTimer?.cancel();
      await messageSub.cancel();
      await statusSub.cancel();
      socket.dispose();
    }
  }
}
