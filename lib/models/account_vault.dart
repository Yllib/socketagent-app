import 'server_config.dart';

/// The plaintext inside the account vault's secretbox. Only the app reads
/// it. Every list merges per item, keyed by [VaultComputer.key] or a device's
/// public key, with the newer `updatedAt` winning and tombstones winning ties.
class AccountVault {
  const AccountVault({
    this.updatedAt = 0,
    this.updatedBy = '',
    this.computers = const [],
    this.removedComputers = const [],
    this.subscription,
    this.devices = const [],
    this.revokedDevices = const [],
    this.preferences = const {},
  });

  static const version = 1;

  /// Unix ms of the newest change folded in.
  final int updatedAt;
  final String updatedBy;
  final List<VaultComputer> computers;
  final List<VaultTombstone> removedComputers;
  final VaultSubscription? subscription;
  final List<VaultDevice> devices;
  final List<VaultTombstone> revokedDevices;
  final Map<String, Object?> preferences;

  Map<String, Object?> toJson() => {
    'v': version,
    'updatedAt': updatedAt,
    'updatedBy': updatedBy,
    'computers': [for (final c in computers) c.toJson()],
    'removedComputers': [for (final t in removedComputers) t.toJson()],
    if (subscription case final s?) 'subscription': s.toJson(),
    'devices': [for (final d in devices) d.toJson()],
    'revokedDevices': [for (final t in revokedDevices) t.toJson()],
    'preferences': preferences,
  };

  /// Throws [FormatException] for anything that isn't a version 1 vault.
  static AccountVault fromJson(Object? raw) {
    if (raw is! Map || raw['v'] != version) {
      throw const FormatException('Unsupported vault format');
    }
    List<T> list<T>(Object? value, T? Function(Object?) parse) => [
      if (value is List)
        for (final item in value) ?parse(item),
    ];
    final preferences = raw['preferences'];
    return AccountVault(
      updatedAt: (raw['updatedAt'] as num?)?.toInt() ?? 0,
      updatedBy: raw['updatedBy'] as String? ?? '',
      computers: list(raw['computers'], VaultComputer.fromJson),
      removedComputers: list(raw['removedComputers'], VaultTombstone.fromJson),
      subscription: VaultSubscription.fromJson(raw['subscription']),
      devices: list(raw['devices'], VaultDevice.fromJson),
      revokedDevices: list(raw['revokedDevices'], VaultTombstone.fromJson),
      preferences: preferences is Map
          ? Map<String, Object?>.from(preferences)
          : const {},
    );
  }

  AccountVault copyWith({
    int? updatedAt,
    String? updatedBy,
    List<VaultComputer>? computers,
    List<VaultTombstone>? removedComputers,
    VaultSubscription? subscription,
    bool clearSubscription = false,
    List<VaultDevice>? devices,
    List<VaultTombstone>? revokedDevices,
    Map<String, Object?>? preferences,
  }) => AccountVault(
    updatedAt: updatedAt ?? this.updatedAt,
    updatedBy: updatedBy ?? this.updatedBy,
    computers: computers ?? this.computers,
    removedComputers: removedComputers ?? this.removedComputers,
    subscription: clearSubscription ? null : subscription ?? this.subscription,
    devices: devices ?? this.devices,
    revokedDevices: revokedDevices ?? this.revokedDevices,
    preferences: preferences ?? this.preferences,
  );

  bool isRevoked(String publicKey) =>
      revokedDevices.any((t) => t.key == publicKey);
}

/// A computer as shared between devices: [ServerConfig.toJson] minus the
/// fields that only mean something on one device (`id`, `useRelay`,
/// `sortOrder`).
class VaultComputer {
  const VaultComputer({
    required this.key,
    required this.updatedAt,
    required this.fields,
  });

  /// The server's public key, or the connection identity for an old direct
  /// computer that never sent one.
  final String key;
  final int updatedAt;
  final Map<String, Object?> fields;

  static const localOnlyFields = {'id', 'useRelay', 'sortOrder'};

  static String keyFor(ServerConfig config) => config.serverPubkey.isNotEmpty
      ? config.serverPubkey
      : config.connectionIdentity;

  static Map<String, Object?> sharedFields(ServerConfig config) => {
    for (final entry in config.toJson().entries)
      if (!localOnlyFields.contains(entry.key)) entry.key: entry.value,
  };

  factory VaultComputer.fromConfig(ServerConfig config, {required int now}) =>
      VaultComputer(
        key: keyFor(config),
        updatedAt: now,
        fields: sharedFields(config),
      );

  String get name => fields['name'] as String? ?? '';
  String get token => fields['token'] as String? ?? '';
  String get serverPubkey => fields['serverPubkey'] as String? ?? '';

  bool sameFieldsAs(Map<String, Object?> other) => _mapsEqual(fields, other);

  Map<String, Object?> toJson() => {
    'key': key,
    'updatedAt': updatedAt,
    ...fields,
  };

  static VaultComputer? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    if (key is! String || key.isEmpty) return null;
    final fields = Map<String, Object?>.from(raw)
      ..remove('key')
      ..remove('updatedAt');
    return VaultComputer(
      key: key,
      updatedAt: (raw['updatedAt'] as num?)?.toInt() ?? 0,
      fields: fields,
    );
  }
}

class VaultDevice {
  const VaultDevice({
    required this.publicKey,
    required this.name,
    required this.platform,
    required this.addedAt,
  });

  final String publicKey;
  final String name;
  final String platform;

  /// Unix ms. Doubles as the item's `updatedAt` for merging.
  final int addedAt;

  Map<String, Object?> toJson() => {
    'publicKey': publicKey,
    'name': name,
    'platform': platform,
    'addedAt': addedAt,
  };

  static VaultDevice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['publicKey'];
    if (key is! String || key.isEmpty) return null;
    return VaultDevice(
      publicKey: key,
      name: raw['name'] as String? ?? '',
      platform: raw['platform'] as String? ?? '',
      addedAt: (raw['addedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Marks an item as removed at [at] (unix ms). An item written after that
/// moment comes back; one written before stays gone.
class VaultTombstone {
  const VaultTombstone({required this.key, required this.at});

  final String key;
  final int at;

  Map<String, Object?> toJson() => {'key': key, 'at': at};

  static VaultTombstone? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    if (key is! String || key.isEmpty) return null;
    return VaultTombstone(key: key, at: (raw['at'] as num?)?.toInt() ?? 0);
  }
}

class VaultSubscription {
  const VaultSubscription({
    required this.token,
    required this.email,
    required this.updatedAt,
  });

  final String token;
  final String email;
  final int updatedAt;

  Map<String, Object?> toJson() => {
    'token': token,
    'email': email,
    'updatedAt': updatedAt,
  };

  static VaultSubscription? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final token = raw['token'];
    if (token is! String || token.isEmpty) return null;
    return VaultSubscription(
      token: token,
      email: raw['email'] as String? ?? '',
      updatedAt: (raw['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Folds two vaults into one. Per key, the newer write wins; a tombstone at
/// the same instant as a write wins; a write after a tombstone revives the
/// item and drops the tombstone. Neither input is changed.
AccountVault mergeVaults(AccountVault a, AccountVault b) {
  final computers = _mergeItems<VaultComputer>(
    a.computers,
    b.computers,
    a.removedComputers,
    b.removedComputers,
    key: (c) => c.key,
    at: (c) => c.updatedAt,
  );
  final devices = _mergeItems<VaultDevice>(
    a.devices,
    b.devices,
    a.revokedDevices,
    b.revokedDevices,
    key: (d) => d.publicKey,
    at: (d) => d.addedAt,
  );
  final subscription = switch ((a.subscription, b.subscription)) {
    (null, final s) => s,
    (final s, null) => s,
    (final x?, final y?) => y.updatedAt > x.updatedAt ? y : x,
  };
  final newer = b.updatedAt > a.updatedAt ? b : a;
  return AccountVault(
    updatedAt: newer.updatedAt,
    updatedBy: newer.updatedBy,
    computers: computers.items,
    removedComputers: computers.tombstones,
    subscription: subscription,
    devices: devices.items,
    revokedDevices: devices.tombstones,
    preferences: newer.preferences.isEmpty
        ? (newer == a ? b : a).preferences
        : newer.preferences,
  );
}

({List<T> items, List<VaultTombstone> tombstones}) _mergeItems<T>(
  List<T> itemsA,
  List<T> itemsB,
  List<VaultTombstone> stonesA,
  List<VaultTombstone> stonesB, {
  required String Function(T) key,
  required int Function(T) at,
}) {
  final items = <String, T>{};
  for (final item in [...itemsA, ...itemsB]) {
    final existing = items[key(item)];
    if (existing == null || at(item) > at(existing)) items[key(item)] = item;
  }
  final stones = <String, VaultTombstone>{};
  for (final stone in [...stonesA, ...stonesB]) {
    final existing = stones[stone.key];
    if (existing == null || stone.at > existing.at) stones[stone.key] = stone;
  }
  for (final stone in stones.values.toList()) {
    final item = items[stone.key];
    if (item == null) continue;
    if (at(item) > stone.at) {
      stones.remove(stone.key);
    } else {
      items.remove(stone.key);
    }
  }
  // Sorted by key so two devices that hold the same vault encode it the
  // same way, whatever order they learned about the items in.
  final sortedItems = items.values.toList()
    ..sort((x, y) => key(x).compareTo(key(y)));
  final sortedStones = stones.values.toList()
    ..sort((x, y) => x.key.compareTo(y.key));
  return (items: sortedItems, tombstones: sortedStones);
}

bool _mapsEqual(Map<String, Object?> a, Map<String, Object?> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
}
