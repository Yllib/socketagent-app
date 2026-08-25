enum DirectFcmIssue { missing, invalid, unreadable }

class PushDeliveryCapabilities {
  const PushDeliveryCapabilities({
    required this.version,
    required this.directFcmConfigured,
    required this.relayConfigured,
    this.directFcmIssue,
  });

  final int version;
  final bool directFcmConfigured;
  final DirectFcmIssue? directFcmIssue;
  final bool relayConfigured;

  bool get hasDetailedStatus => version >= 2;

  factory PushDeliveryCapabilities.fromServerValue(Object? value) {
    if (value is! Map) {
      return const PushDeliveryCapabilities(
        version: 0,
        directFcmConfigured: false,
        relayConfigured: false,
      );
    }
    return PushDeliveryCapabilities(
      version: (value['version'] as num?)?.toInt() ?? 0,
      directFcmConfigured: value['directFcmConfigured'] == true,
      directFcmIssue: switch (value['directFcmIssue']) {
        'missing' => DirectFcmIssue.missing,
        'invalid' => DirectFcmIssue.invalid,
        'unreadable' => DirectFcmIssue.unreadable,
        _ => null,
      },
      relayConfigured: value['relayConfigured'] == true,
    );
  }
}

enum PushDeliveryRouteKind {
  checking,
  serverUpdateRequired,
  relay,
  directFirebase,
  relayPairingRequired,
  relaySignInRequired,
  relaySubscriptionRequired,
  firebaseMissing,
  firebaseInvalid,
  firebaseUnreadable,
}

class PushDeliveryRouteState {
  const PushDeliveryRouteState(this.kind);

  final PushDeliveryRouteKind kind;

  bool get isReady =>
      kind == PushDeliveryRouteKind.relay ||
      kind == PushDeliveryRouteKind.directFirebase;

  static PushDeliveryRouteState evaluate({
    required PushDeliveryCapabilities? capabilities,
    required bool relayPaired,
    required bool hasSubscriberToken,
    required bool hasRelayAccess,
  }) {
    if (capabilities == null) {
      return const PushDeliveryRouteState(PushDeliveryRouteKind.checking);
    }
    if (!capabilities.hasDetailedStatus) {
      return const PushDeliveryRouteState(
        PushDeliveryRouteKind.serverUpdateRequired,
      );
    }
    if (capabilities.relayConfigured &&
        relayPaired &&
        hasRelayAccess) {
      return const PushDeliveryRouteState(PushDeliveryRouteKind.relay);
    }
    if (capabilities.directFcmConfigured) {
      return const PushDeliveryRouteState(
        PushDeliveryRouteKind.directFirebase,
      );
    }
    if (capabilities.relayConfigured && !relayPaired) {
      return const PushDeliveryRouteState(
        PushDeliveryRouteKind.relayPairingRequired,
      );
    }
    if (capabilities.relayConfigured && !hasSubscriberToken) {
      return const PushDeliveryRouteState(
        PushDeliveryRouteKind.relaySignInRequired,
      );
    }
    if (capabilities.relayConfigured && !hasRelayAccess) {
      return const PushDeliveryRouteState(
        PushDeliveryRouteKind.relaySubscriptionRequired,
      );
    }
    return PushDeliveryRouteState(
      switch (capabilities.directFcmIssue) {
        DirectFcmIssue.invalid => PushDeliveryRouteKind.firebaseInvalid,
        DirectFcmIssue.unreadable => PushDeliveryRouteKind.firebaseUnreadable,
        _ => PushDeliveryRouteKind.firebaseMissing,
      },
    );
  }
}
