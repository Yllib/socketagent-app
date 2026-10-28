/// What a linked computer may do on another. Stored and enforced by the
/// target; the source only keeps a copy for display.
class ComputerAccess {
  const ComputerAccess({
    this.read = true,
    this.agents = true,
    this.commands = true,
  });

  final bool read;
  final bool agents;
  final bool commands;

  Map<String, bool> toJson() => {
    'read': read,
    'agents': agents,
    'commands': commands,
  };

  static ComputerAccess fromJson(Object? raw) => raw is Map
      ? ComputerAccess(
          read: raw['read'] == true,
          agents: raw['agents'] == true,
          commands: raw['commands'] == true,
        )
      : const ComputerAccess();

  ComputerAccess copyWith({bool? read, bool? agents, bool? commands}) =>
      ComputerAccess(
        read: read ?? this.read,
        agents: agents ?? this.agents,
        commands: commands ?? this.commands,
      );

  /// "read, agents, commands" or "nothing".
  String get label {
    final parts = [
      if (read) 'read',
      if (agents) 'agents',
      if (commands) 'commands',
    ];
    return parts.isEmpty ? 'nothing' : parts.join(', ');
  }
}

/// Whether a linked computer's actions need the user's approval. An approval
/// card can allow one action or the rest of that chat.
enum LinkConfirm {
  ask('ask', 'Ask'),
  never('never', 'Never ask');

  const LinkConfirm(this.wire, this.label);

  final String wire;
  final String label;

  /// Older servers send `every_time` or `per_chat`; both mean ask.
  static LinkConfirm fromWire(Object? raw) =>
      raw == 'never' ? LinkConfirm.never : LinkConfirm.ask;
}

/// One entry in a computer's `devices.json`.
class RegisteredDevice {
  const RegisteredDevice({
    required this.publicKey,
    required this.kind,
    required this.name,
    required this.platform,
    required this.addedAt,
    required this.lastSeenAt,
    required this.via,
    this.access,
    this.confirm,
    this.expiresAt,
    this.online = false,
  });

  final String publicKey;

  /// `device` for a phone or desktop app, `computer` for a linked computer,
  /// `connector` for an AI client signed in through the AI connector.
  final String kind;
  final String name;
  final String platform;
  final DateTime? addedAt;
  final DateTime? lastSeenAt;
  final String via;
  final ComputerAccess? access;
  final LinkConfirm? confirm;

  /// When a computer link ends. Null lasts until removed.
  final DateTime? expiresAt;
  final bool online;

  bool get isComputer => kind == 'computer';
  bool get isConnector => kind == 'connector';

  /// Computers and AI clients both carry access boxes and a confirm mode.
  bool get hasAccess => isComputer || isConnector;

  static RegisteredDevice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final publicKey = raw['publicKey'];
    if (publicKey is! String || publicKey.isEmpty) return null;
    final kind = raw['kind'] as String? ?? 'device';
    return RegisteredDevice(
      publicKey: publicKey,
      kind: kind,
      name: raw['name'] as String? ?? '',
      platform: raw['platform'] as String? ?? '',
      addedAt: _time(raw['addedAt']),
      lastSeenAt: _time(raw['lastSeenAt']),
      via: raw['via'] as String? ?? '',
      access: kind == 'computer' || kind == 'connector'
          ? ComputerAccess.fromJson(raw['access'])
          : null,
      confirm: kind == 'computer' || kind == 'connector'
          ? LinkConfirm.fromWire(raw['confirm'])
          : null,
      expiresAt: _time(raw['expiresAt']),
      online: raw['online'] == true,
    );
  }

  static DateTime? _time(Object? raw) {
    if (raw is String) return DateTime.tryParse(raw)?.toLocal();
    if (raw is num) {
      return DateTime.fromMillisecondsSinceEpoch(raw.toInt()).toLocal();
    }
    return null;
  }
}

/// A `device_list_result`.
class DeviceRegistry {
  const DeviceRegistry({
    required this.mode,
    required this.devices,
    required this.self,
    this.pending = const [],
  });

  /// `learning` or `enforced`.
  final String mode;
  final List<RegisteredDevice> devices;

  /// This device's public key as the computer sees it.
  final String self;

  /// Keys held at the handshake, waiting for an approval.
  final List<PendingDevice> pending;

  bool get learning => mode == 'learning';

  Iterable<RegisteredDevice> get phones =>
      devices.where((d) => !d.isComputer && !d.isConnector);
  Iterable<RegisteredDevice> get computers =>
      devices.where((d) => d.isComputer);
  Iterable<RegisteredDevice> get connectors =>
      devices.where((d) => d.isConnector);

  /// [serverId] tags the pending entries with the computer they wait on.
  static DeviceRegistry fromJson(
    Map<String, dynamic> raw, {
    String serverId = '',
  }) => DeviceRegistry(
    mode: raw['mode'] as String? ?? 'learning',
    devices: [
      if (raw['devices'] is List)
        for (final item in raw['devices'] as List)
          ?RegisteredDevice.fromJson(item),
    ],
    self: raw['self'] as String? ?? '',
    pending: [
      if (raw['pending'] is List)
        for (final item in raw['pending'] as List)
          if (item is Map)
            ?PendingDevice.fromJson(Map<String, dynamic>.from(item), serverId),
    ],
  );
}

/// A `device_pending` notice: a device waiting for approval on a computer.
class PendingDevice {
  const PendingDevice({
    required this.serverId,
    required this.publicKey,
    required this.name,
    required this.platform,
    required this.code,
  });

  final String serverId;
  final String publicKey;
  final String name;
  final String platform;
  final String code;

  static PendingDevice? fromJson(Map<String, dynamic> raw, String serverId) {
    final publicKey = raw['publicKey'];
    if (publicKey is! String || publicKey.isEmpty) return null;
    final code = raw['code'];
    return PendingDevice(
      serverId: serverId,
      publicKey: publicKey,
      name: raw['name'] as String? ?? 'Unknown device',
      platform: raw['platform'] as String? ?? '',
      code: code is String
          ? code
          : code is num
          ? code.toInt().toString()
          : '',
    );
  }
}

/// An outgoing link as the source computer lists it.
class ComputerLink {
  const ComputerLink({
    required this.name,
    required this.targetPubkey,
    required this.online,
    required this.access,
    required this.confirm,
    required this.ticketExpiresAt,
    this.expiresAt,
    this.relayUrl = '',
    this.linkRoom = '',
  });

  final String name;
  final String targetPubkey;
  final bool online;
  final ComputerAccess access;
  final LinkConfirm confirm;
  final DateTime? ticketExpiresAt;

  /// When the link ends. Null lasts until removed.
  final DateTime? expiresAt;

  /// Present when the source includes them; otherwise the app asks the
  /// target for `link_room_info` when it refreshes the ticket.
  final String relayUrl;
  final String linkRoom;

  static ComputerLink? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final target = raw['targetPubkey'];
    if (target is! String || target.isEmpty) return null;
    final expires = raw['ticketExpiresAt'];
    final ends = raw['expiresAt'];
    return ComputerLink(
      name: raw['name'] as String? ?? '',
      targetPubkey: target,
      online: raw['online'] == true,
      access: ComputerAccess.fromJson(raw['access']),
      confirm: LinkConfirm.fromWire(raw['confirm']),
      ticketExpiresAt: expires is num
          ? DateTime.fromMillisecondsSinceEpoch(expires.toInt())
          : expires is String
          ? DateTime.tryParse(expires)
          : null,
      expiresAt: ends is num
          ? DateTime.fromMillisecondsSinceEpoch(ends.toInt())
          : null,
      relayUrl: raw['relayUrl'] as String? ?? '',
      linkRoom: raw['linkRoom'] as String? ?? '',
    );
  }

  /// Whether the phone should fetch a new ticket: none, or under 7 days left.
  bool needsTicketRefresh(DateTime now) {
    final expires = ticketExpiresAt;
    return expires == null || expires.difference(now) < const Duration(days: 7);
  }
}

/// "14:30" for a time today, else "2026-10-28 14:30", for when a client
/// signed in or was last seen.
String deviceTimeLabel(DateTime at, DateTime now) {
  final local = at.toLocal();
  final time =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return time;
  }
  final date =
      '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  return '$date $time';
}

/// The next local midnight, when an "Allow for today" link ends.
DateTime nextLocalMidnight(DateTime now) =>
    DateTime(now.year, now.month, now.day + 1);

/// "until midnight", "until 14:30" or "until 2026-10-23 14:30" for a link
/// that ends at [expiresAt].
String linkExpiryLabel(DateTime expiresAt, DateTime now) {
  final local = expiresAt.toLocal();
  if (local == nextLocalMidnight(now)) return 'until midnight';
  final time =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return 'until $time';
  }
  final date =
      '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  return 'until $date $time';
}
