import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// A relay ticket that lets the source computer join the target's link room
/// without a subscriber token of its own.
class ComputerLinkTicket {
  const ComputerLinkTicket({required this.ticket, required this.expiresAt});

  final String ticket;

  /// Unix ms.
  final int expiresAt;
}

/// The relay refused to issue a ticket because this phone has no active
/// subscription.
class ComputerLinkSubscriptionRequired implements Exception {
  const ComputerLinkSubscriptionRequired();
}

/// `POST /api/computer-link`. Both computers must use this relay.
Future<ComputerLinkTicket> requestComputerLinkTicket({
  required String relayHttpUrl,
  required String subscriberToken,
  required String linkRoom,
  http.Client? client,
}) async {
  final owned = client == null;
  final http.Client c = client ?? http.Client();
  try {
    final response = await c
        .post(
          Uri.parse('$relayHttpUrl/api/computer-link'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'subscriberToken': subscriberToken,
            'linkRoom': linkRoom,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 403) {
      throw const ComputerLinkSubscriptionRequired();
    }
    if (response.statusCode != 200) {
      throw HttpException('Relay answered ${response.statusCode}');
    }
    final body = jsonDecode(response.body);
    final ticket = body is Map ? body['ticket'] : null;
    final expiresAt = body is Map ? body['expiresAt'] : null;
    if (ticket is! String || expiresAt is! num) {
      throw const FormatException('Relay sent no ticket');
    }
    return ComputerLinkTicket(ticket: ticket, expiresAt: expiresAt.toInt());
  } finally {
    if (owned) c.close();
  }
}
