import 'server_config.dart';

/// The plaintext inside the account vault's secretbox. Only the app reads
/// it. Every list merges per item, keyed by [VaultComputer.key], a device's
/// public key, a chat ID or a project ID, with the newer `updatedAt` winning
/// and tombstones winning ties.
class AccountVault {
  const AccountVault({
    this.updatedAt = 0,
    this.updatedBy = '',
    this.computers = const [],
    this.removedComputers = const [],
    this.subscription,
    this.devices = const [],
    this.revokedDevices = const [],
    this.pinnedSessions = const [],
    this.unpinnedSessions = const [],
    this.projects = const [],
    this.removedProjects = const [],
    this.projectMembers = const [],
    this.removedProjectMembers = const [],
    this.preferences = const {},
    this.unknownFields = const {},
  });

  /// Raised to 2 with pinned chats and projects. Builds that only know 1 refuse a newer
  /// vault and write nothing, so they can't drop fields they don't know.
  /// From 2 on, top-level fields this build doesn't know are kept and written
  /// back, so adding one doesn't need another bump.
  static const version = 2;

  /// Unix ms of the newest change folded in.
  final int updatedAt;
  final String updatedBy;
  final List<VaultComputer> computers;
  final List<VaultTombstone> removedComputers;
  final VaultSubscription? subscription;
  final List<VaultDevice> devices;
  final List<VaultTombstone> revokedDevices;

  /// Pinned chats by session ID. Chat IDs are unique across computers.
  final List<VaultPin> pinnedSessions;
  final List<VaultTombstone> unpinnedSessions;

  /// The user's named groups of chats in the session list.
  final List<VaultProject> projects;
  final List<VaultTombstone> removedProjects;

  /// Which project each grouped chat is in, keyed by session ID.
  final List<VaultProjectMember> projectMembers;
  final List<VaultTombstone> removedProjectMembers;
  final Map<String, Object?> preferences;

  /// Top-level fields from a newer build, carried through unchanged.
  final Map<String, Object?> unknownFields;

  static const _knownFields = {
    'v',
    'updatedAt',
    'updatedBy',
    'computers',
    'removedComputers',
    'subscription',
    'devices',
    'revokedDevices',
    'pinnedSessions',
    'unpinnedSessions',
    'projects',
    'removedProjects',
    'projectMembers',
    'removedProjectMembers',
    'preferences',
  };

  Map<String, Object?> toJson() => {
    ...unknownFields,
    'v': version,
    'updatedAt': updatedAt,
    'updatedBy': updatedBy,
    'computers': [for (final c in computers) c.toJson()],
    'removedComputers': [for (final t in removedComputers) t.toJson()],
    if (subscription case final s?) 'subscription': s.toJson(),
    'devices': [for (final d in devices) d.toJson()],
    'revokedDevices': [for (final t in revokedDevices) t.toJson()],
    'pinnedSessions': [for (final p in pinnedSessions) p.toJson()],
    'unpinnedSessions': [for (final t in unpinnedSessions) t.toJson()],
    'projects': [for (final p in projects) p.toJson()],
    'removedProjects': [for (final t in removedProjects) t.toJson()],
    'projectMembers': [for (final m in projectMembers) m.toJson()],
    'removedProjectMembers': [
      for (final t in removedProjectMembers) t.toJson(),
    ],
    'preferences': preferences,
  };

  /// Reads format 1 or 2. Throws [FormatException] for anything else.
  static AccountVault fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('Unsupported vault format');
    final v = raw['v'];
    if (v is int && v > version) {
      throw const FormatException(
        'A newer SocketAgent wrote this account. Update the app to keep '
        'syncing.',
      );
    }
    if (v != 1 && v != version) {
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
      pinnedSessions: list(raw['pinnedSessions'], VaultPin.fromJson),
      unpinnedSessions: list(raw['unpinnedSessions'], VaultTombstone.fromJson),
      projects: list(raw['projects'], VaultProject.fromJson),
      removedProjects: list(raw['removedProjects'], VaultTombstone.fromJson),
      projectMembers: list(raw['projectMembers'], VaultProjectMember.fromJson),
      removedProjectMembers: list(
        raw['removedProjectMembers'],
        VaultTombstone.fromJson,
      ),
      preferences: preferences is Map
          ? Map<String, Object?>.from(preferences)
          : const {},
      unknownFields: {
        for (final entry in raw.entries)
          if (entry.key is String && !_knownFields.contains(entry.key))
            entry.key as String: entry.value,
      },
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
    List<VaultPin>? pinnedSessions,
    List<VaultTombstone>? unpinnedSessions,
    List<VaultProject>? projects,
    List<VaultTombstone>? removedProjects,
    List<VaultProjectMember>? projectMembers,
    List<VaultTombstone>? removedProjectMembers,
    Map<String, Object?>? preferences,
  }) => AccountVault(
    updatedAt: updatedAt ?? this.updatedAt,
    updatedBy: updatedBy ?? this.updatedBy,
    computers: computers ?? this.computers,
    removedComputers: removedComputers ?? this.removedComputers,
    subscription: clearSubscription ? null : subscription ?? this.subscription,
    devices: devices ?? this.devices,
    revokedDevices: revokedDevices ?? this.revokedDevices,
    pinnedSessions: pinnedSessions ?? this.pinnedSessions,
    unpinnedSessions: unpinnedSessions ?? this.unpinnedSessions,
    projects: projects ?? this.projects,
    removedProjects: removedProjects ?? this.removedProjects,
    projectMembers: projectMembers ?? this.projectMembers,
    removedProjectMembers: removedProjectMembers ?? this.removedProjectMembers,
    preferences: preferences ?? this.preferences,
    unknownFields: unknownFields,
  );

  bool isRevoked(String publicKey) =>
      revokedDevices.any((t) => t.key == publicKey);

  /// Revoked by Forget rather than Remove, so computers drop the key
  /// without changing their pairing token.
  bool isForgotten(String publicKey) =>
      revokedDevices.any((t) => t.key == publicKey && t.forgotten);
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

/// A pinned chat, pinned at [at] (unix ms).
class VaultPin {
  const VaultPin({required this.sessionId, required this.at});

  final String sessionId;
  final int at;

  Map<String, Object?> toJson() => {'sessionId': sessionId, 'at': at};

  static VaultPin? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['sessionId'];
    if (id is! String || id.isEmpty) return null;
    return VaultPin(sessionId: id, at: (raw['at'] as num?)?.toInt() ?? 0);
  }
}

/// A named group of chats, created or renamed at [at] (unix ms).
class VaultProject {
  const VaultProject({required this.id, required this.name, required this.at});

  final String id;
  final String name;
  final int at;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'at': at};

  static VaultProject? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    return VaultProject(
      id: id,
      name: name,
      at: (raw['at'] as num?)?.toInt() ?? 0,
    );
  }
}

/// A chat placed in a project at [at] (unix ms).
class VaultProjectMember {
  const VaultProjectMember({
    required this.sessionId,
    required this.projectId,
    required this.at,
  });

  final String sessionId;
  final String projectId;
  final int at;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'projectId': projectId,
    'at': at,
  };

  static VaultProjectMember? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final sessionId = raw['sessionId'];
    final projectId = raw['projectId'];
    if (sessionId is! String || sessionId.isEmpty) return null;
    if (projectId is! String || projectId.isEmpty) return null;
    return VaultProjectMember(
      sessionId: sessionId,
      projectId: projectId,
      at: (raw['at'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Marks an item as removed at [at] (unix ms). An item written after that
/// moment comes back; one written before stays gone.
class VaultTombstone {
  const VaultTombstone({
    required this.key,
    required this.at,
    this.forgotten = false,
  });

  final String key;
  final int at;

  /// For a device: forgotten because its app is gone, not removed because
  /// it may still be in someone's hands.
  final bool forgotten;

  Map<String, Object?> toJson() => {
    'key': key,
    'at': at,
    if (forgotten) 'forgotten': true,
  };

  static VaultTombstone? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    if (key is! String || key.isEmpty) return null;
    return VaultTombstone(
      key: key,
      at: (raw['at'] as num?)?.toInt() ?? 0,
      forgotten: raw['forgotten'] == true,
    );
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
  final pins = _mergeItems<VaultPin>(
    a.pinnedSessions,
    b.pinnedSessions,
    a.unpinnedSessions,
    b.unpinnedSessions,
    key: (p) => p.sessionId,
    at: (p) => p.at,
  );
  final projects = _mergeItems<VaultProject>(
    a.projects,
    b.projects,
    a.removedProjects,
    b.removedProjects,
    key: (p) => p.id,
    at: (p) => p.at,
  );
  final members = _mergeItems<VaultProjectMember>(
    a.projectMembers,
    b.projectMembers,
    a.removedProjectMembers,
    b.removedProjectMembers,
    key: (m) => m.sessionId,
    at: (m) => m.at,
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
    pinnedSessions: pins.items,
    unpinnedSessions: pins.tombstones,
    projects: projects.items,
    removedProjects: projects.tombstones,
    projectMembers: members.items,
    removedProjectMembers: members.tombstones,
    preferences: newer.preferences.isEmpty
        ? (newer == a ? b : a).preferences
        : newer.preferences,
    unknownFields: {
      ...(newer == a ? b : a).unknownFields,
      ...newer.unknownFields,
    },
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
