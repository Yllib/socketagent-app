import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/server_config.dart';

/// mDNS service type every SocketAgent server advertises on its LAN.
const lanServiceType = '_socketagent._tcp';

/// The ID a server advertises over mDNS, derived from its public key. Matches
/// `localRouteId` in the server's local-network.ts.
String localRouteId(String serverPubkey) => sha256
    .convert(utf8.encode(serverPubkey.trim()))
    .toString()
    .substring(0, 16);

/// Finds a LAN address where [ServerConfig] answers: the stored host, plus
/// whatever the server is advertising over mDNS when [searchLan] is set.
/// Returns the first address that accepts a TCP connection, or null.
///
/// The defaults touch the network; tests pass their own [discover] and
/// [reachable].
class LocalRouteFinder {
  const LocalRouteFinder({
    this.discover = discoverLanHosts,
    this.reachable = tcpReachable,
  });

  final Stream<String> Function(String routeId) discover;
  final Future<bool> Function(String host, int port) reachable;

  Future<String?> find(
    ServerConfig config, {
    required bool searchLan,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final found = Completer<String?>();
    final tried = <String>{};
    var pending = 0;
    var discovering = searchLan;
    StreamSubscription<String>? discovery;

    void finishIfExhausted() {
      if (!found.isCompleted && pending == 0 && !discovering) {
        found.complete(null);
      }
    }

    void tryHost(String host) {
      if (found.isCompleted || host.isEmpty || !tried.add(host)) return;
      pending++;
      unawaited(
        reachable(host, config.port).then((ok) {
          pending--;
          if (ok && !found.isCompleted) found.complete(host);
          finishIfExhausted();
        }),
      );
    }

    tryHost(config.host);
    if (searchLan && config.serverPubkey.isNotEmpty) {
      discovery = discover(localRouteId(config.serverPubkey)).listen(
        tryHost,
        onError: (Object _) {},
        onDone: () {
          discovering = false;
          finishIfExhausted();
        },
      );
    } else {
      discovering = false;
    }
    finishIfExhausted();

    final timer = Timer(timeout, () {
      if (!found.isCompleted) found.complete(null);
    });
    final host = await found.future;
    timer.cancel();
    await discovery?.cancel();
    return host;
  }
}

/// The first of [hosts] that accepts a TCP connection on [port], all tried
/// at once, or null when none do.
Future<String?> firstReachable(
  List<String> hosts,
  int port, {
  Future<bool> Function(String host, int port) reachable = tcpReachable,
}) {
  final found = Completer<String?>();
  var pending = hosts.length;
  if (pending == 0) return Future.value();
  for (final host in hosts) {
    unawaited(
      reachable(host, port).then((ok) {
        pending--;
        if (found.isCompleted) return;
        if (ok) {
          found.complete(host);
        } else if (pending == 0) {
          found.complete(null);
        }
      }),
    );
  }
  return found.future;
}

/// Whether something accepts TCP connections at [host]:[port].
Future<bool> tcpReachable(String host, int port) async {
  try {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(milliseconds: 1500),
    );
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Addresses advertised by the server whose mDNS ID is [routeId], best first.
/// Runs until cancelled. Ends at once where mDNS isn't available.
Stream<String> discoverLanHosts(String routeId) {
  late final StreamController<String> controller;
  BonsoirDiscovery? discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? events;

  Future<void> start() async {
    try {
      final active = BonsoirDiscovery(type: lanServiceType, printLogs: false);
      discovery = active;
      await active.initialize();
      events = active.eventStream?.listen((event) {
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent():
            unawaited(event.service.resolve(active.serviceResolver));
          case BonsoirDiscoveryServiceResolvedEvent() ||
              BonsoirDiscoveryServiceUpdatedEvent():
            final service = event.service;
            if (service == null || service.attributes['id'] != routeId) return;
            for (final host in advertisedHosts(service)) {
              if (!controller.isClosed) controller.add(host);
            }
          default:
        }
      });
      await active.start();
    } catch (error) {
      // No mDNS on this platform or network. Direct still works by address.
      debugPrint('[LocalRoute] mDNS unavailable: ${error.runtimeType}');
      if (!controller.isClosed) await controller.close();
    }
  }

  controller = StreamController<String>(
    onListen: () => unawaited(start()),
    onCancel: () async {
      await events?.cancel();
      try {
        await discovery?.stop();
      } catch (_) {}
    },
  );
  return controller.stream;
}

/// The server's ranked LAN addresses from its TXT record, then any other IPv4
/// address the platform resolved. The TXT list leaves out container bridges.
@visibleForTesting
List<String> advertisedHosts(BonsoirService service) {
  final listed = (service.attributes['hosts'] ?? '')
      .split(',')
      .map((host) => host.trim())
      .where((host) => host.isNotEmpty);
  final resolved = service.hostAddresses.where(
    (address) =>
        InternetAddress.tryParse(address)?.type == InternetAddressType.IPv4,
  );
  return {...listed, ...resolved}.toList();
}
