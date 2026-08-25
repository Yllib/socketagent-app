import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/push_delivery_capabilities.dart';

void main() {
  test('parses detailed server push capabilities', () {
    final capabilities = PushDeliveryCapabilities.fromServerValue({
      'version': 2,
      'directFcmConfigured': false,
      'directFcmIssue': 'unreadable',
      'relayConfigured': true,
    });

    expect(capabilities.hasDetailedStatus, isTrue);
    expect(capabilities.directFcmConfigured, isFalse);
    expect(capabilities.directFcmIssue, DirectFcmIssue.unreadable);
    expect(capabilities.relayConfigured, isTrue);
  });

  test('requires a server update when detailed status is unavailable', () {
    final state = PushDeliveryRouteState.evaluate(
      capabilities: PushDeliveryCapabilities.fromServerValue({
        'configured': true,
      }),
      relayPaired: false,
      hasSubscriberToken: false,
      hasRelayAccess: false,
    );

    expect(state.kind, PushDeliveryRouteKind.serverUpdateRequired);
    expect(state.isReady, isFalse);
  });

  test('uses relay without requiring relay chat transport', () {
    const capabilities = PushDeliveryCapabilities(
      version: 2,
      directFcmConfigured: false,
      directFcmIssue: DirectFcmIssue.missing,
      relayConfigured: true,
    );
    final state = PushDeliveryRouteState.evaluate(
      capabilities: capabilities,
      relayPaired: true,
      hasSubscriberToken: true,
      hasRelayAccess: true,
    );

    expect(state.kind, PushDeliveryRouteKind.relay);
    expect(state.isReady, isTrue);
  });

  test('reports relay pairing, sign-in, and subscription separately', () {
    const capabilities = PushDeliveryCapabilities(
      version: 2,
      directFcmConfigured: false,
      relayConfigured: true,
    );

    expect(
      PushDeliveryRouteState.evaluate(
        capabilities: capabilities,
        relayPaired: false,
        hasSubscriberToken: false,
        hasRelayAccess: false,
      ).kind,
      PushDeliveryRouteKind.relayPairingRequired,
    );
    expect(
      PushDeliveryRouteState.evaluate(
        capabilities: capabilities,
        relayPaired: true,
        hasSubscriberToken: false,
        hasRelayAccess: false,
      ).kind,
      PushDeliveryRouteKind.relaySignInRequired,
    );
    expect(
      PushDeliveryRouteState.evaluate(
        capabilities: capabilities,
        relayPaired: true,
        hasSubscriberToken: true,
        hasRelayAccess: false,
      ).kind,
      PushDeliveryRouteKind.relaySubscriptionRequired,
    );
  });

  test('reports each direct Firebase setup failure', () {
    PushDeliveryRouteState evaluate(DirectFcmIssue issue) {
      return PushDeliveryRouteState.evaluate(
        capabilities: PushDeliveryCapabilities(
          version: 2,
          directFcmConfigured: false,
          directFcmIssue: issue,
          relayConfigured: false,
        ),
        relayPaired: false,
        hasSubscriberToken: false,
        hasRelayAccess: false,
      );
    }

    expect(
      evaluate(DirectFcmIssue.missing).kind,
      PushDeliveryRouteKind.firebaseMissing,
    );
    expect(
      evaluate(DirectFcmIssue.invalid).kind,
      PushDeliveryRouteKind.firebaseInvalid,
    );
    expect(
      evaluate(DirectFcmIssue.unreadable).kind,
      PushDeliveryRouteKind.firebaseUnreadable,
    );
  });

  test('falls back to direct Firebase when relay access is unavailable', () {
    const capabilities = PushDeliveryCapabilities(
      version: 2,
      directFcmConfigured: true,
      relayConfigured: true,
    );
    final state = PushDeliveryRouteState.evaluate(
      capabilities: capabilities,
      relayPaired: true,
      hasSubscriberToken: false,
      hasRelayAccess: false,
    );

    expect(state.kind, PushDeliveryRouteKind.directFirebase);
    expect(state.isReady, isTrue);
  });
}
