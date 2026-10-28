import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../services/notification_service.dart';
import 'device_registry.dart';

/// Action IDs on a device approval notification. Both bring the app forward,
/// where the answer goes through the same path as the dialog's buttons.
const deviceAllowActionId = 'device_allow';
const deviceDenyActionId = 'device_deny';

/// What a `device_pending` push carries, as the notification payload
/// `device_pending:<serverId>?publicKey=..&code=..&name=..&platform=..`.
/// Servers that only send the kind leave `publicKey` empty; the code from
/// the notification text then identifies the request.
class DeviceApprovalPayload {
  const DeviceApprovalPayload({
    required this.serverId,
    this.publicKey = '',
    this.code = '',
    this.name = '',
    this.platform = '',
  });

  static const _prefix = 'device_pending:';

  final String serverId;
  final String publicKey;
  final String code;
  final String name;
  final String platform;

  /// The push data as the server sends it. `title` and `body` fill in the
  /// name and code when the data does not name them.
  static DeviceApprovalPayload? fromPushData(
    Map<String, dynamic> data, {
    String title = '',
    String body = '',
  }) {
    if (data['kind'] != 'device_pending') return null;
    final serverId = data['serverId']?.toString() ?? '';
    if (serverId.isEmpty) return null;
    final code = _digits(data['code']?.toString() ?? '');
    final name = (data['name']?.toString() ?? '').trim();
    return DeviceApprovalPayload(
      serverId: serverId,
      publicKey: data['publicKey']?.toString() ?? '',
      code: code.isNotEmpty ? code : codeInText(body),
      name: name.isNotEmpty ? name : nameInTitle(title),
      platform: data['platform']?.toString() ?? '',
    );
  }

  static DeviceApprovalPayload? parse(String payload) {
    if (!payload.startsWith(_prefix)) return null;
    final rest = payload.substring(_prefix.length);
    final queryIndex = rest.indexOf('?');
    final serverId = Uri.decodeComponent(
      queryIndex < 0 ? rest : rest.substring(0, queryIndex),
    );
    if (serverId.isEmpty) return null;
    Map<String, String> query = const {};
    if (queryIndex >= 0) {
      try {
        query = Uri.splitQueryString(rest.substring(queryIndex + 1));
      } catch (_) {
        query = const {};
      }
    }
    return DeviceApprovalPayload(
      serverId: serverId,
      publicKey: query['publicKey'] ?? '',
      code: query['code'] ?? '',
      name: query['name'] ?? '',
      platform: query['platform'] ?? '',
    );
  }

  String encode() {
    final query = {
      if (publicKey.isNotEmpty) 'publicKey': publicKey,
      if (code.isNotEmpty) 'code': code,
      if (name.isNotEmpty) 'name': name,
      if (platform.isNotEmpty) 'platform': platform,
    };
    final base = '$_prefix${Uri.encodeComponent(serverId)}';
    return query.isEmpty ? base : '$base?${Uri(queryParameters: query).query}';
  }

  /// Whether [pending] is the request this notification was about.
  bool matches(PendingDevice pending) {
    if (pending.serverId != serverId) return false;
    if (publicKey.isNotEmpty) return pending.publicKey == publicKey;
    return code.isNotEmpty && pending.code == code;
  }

  /// A six digit code in text such as "Code 123 456. Approve it".
  static String codeInText(String text) {
    final match = RegExp(r'\b(\d{3})\s?(\d{3})\b').firstMatch(text);
    return match == null ? '' : '${match[1]}${match[2]}';
  }

  /// "Claude" from "Claude wants to use your computers".
  static String nameInTitle(String title) {
    final index = title.indexOf(' wants');
    return (index < 0 ? '' : title.substring(0, index)).trim();
  }

  static String _digits(String value) =>
      RegExp(r'^\d{6}$').hasMatch(value) ? value : '';
}

/// Notification IDs a pending device may be showing under: one keyed by its
/// key, one by its code for pushes that carry only the code. Cancel both.
List<int> deviceApprovalNotificationIds({
  required String serverId,
  String publicKey = '',
  String code = '',
}) => [
  if (publicKey.isNotEmpty)
    NotificationService.stableId('device_pending:$serverId:key:$publicKey'),
  if (code.isNotEmpty)
    NotificationService.stableId('device_pending:$serverId:code:$code'),
];

/// The ID a push shows under: by key when the server sent one, else by code.
int deviceApprovalNotificationId(DeviceApprovalPayload payload) {
  final ids = deviceApprovalNotificationIds(
    serverId: payload.serverId,
    publicKey: payload.publicKey,
    code: payload.code,
  );
  return ids.isEmpty
      ? NotificationService.stableId('device_pending:${payload.serverId}')
      : ids.first;
}

List<AndroidNotificationAction> deviceApprovalActions() => const [
  AndroidNotificationAction(
    deviceAllowActionId,
    'Allow',
    showsUserInterface: true,
    cancelNotification: true,
  ),
  AndroidNotificationAction(
    deviceDenyActionId,
    'Deny',
    showsUserInterface: true,
    cancelNotification: true,
  ),
];

/// Body text that always shows the code, so the user can match it against
/// the browser or the other device before tapping Allow.
String deviceApprovalBody(DeviceApprovalPayload payload, String body) {
  if (payload.code.isEmpty ||
      DeviceApprovalPayload.codeInText(body) == payload.code) {
    return body;
  }
  final code = '${payload.code.substring(0, 3)} ${payload.code.substring(3)}';
  return body.isEmpty ? 'Code $code' : 'Code $code. $body';
}
