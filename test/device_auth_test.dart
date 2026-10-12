import 'package:app/services/device_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an ack without a device field, or approved, opens the peer', () {
    final old = DeviceAuthHandshake();
    expect(old.onKeyExchangeAck(null), DeviceAuthAction.open);
    expect(old.state, DeviceAuthState.approved);
    final fresh = DeviceAuthHandshake();
    expect(fresh.onKeyExchangeAck('approved'), DeviceAuthAction.open);
    expect(fresh.state.phase, DeviceAuthPhase.approved);
  });

  test('pending sends device_auth, then a good token opens the peer', () {
    final handshake = DeviceAuthHandshake();
    expect(handshake.onKeyExchangeAck('pending'), DeviceAuthAction.sendAuth);
    expect(handshake.state, DeviceAuthState.authenticating);
    expect(handshake.onAuthResult({'ok': true}), DeviceAuthAction.open);
    expect(handshake.state, DeviceAuthState.approved);
  });

  test('a missing or wrong token waits for approval with the code', () {
    final handshake = DeviceAuthHandshake();
    handshake.onKeyExchangeAck('pending');
    expect(
      handshake.onAuthResult({
        'ok': false,
        'reason': 'approval_required',
        'code': '042517',
      }),
      DeviceAuthAction.wait,
    );
    expect(handshake.state.awaitingApproval, isTrue);
    expect(handshake.state.code, '042517');
    // Replies to messages sent too early change nothing.
    expect(
      handshake.onAuthResult({'ok': false, 'reason': 'not_approved'}),
      DeviceAuthAction.none,
    );
    expect(handshake.state.awaitingApproval, isTrue);
    // Another device approved: the server opens the held peer in place.
    expect(handshake.onAuthResult({'ok': true}), DeviceAuthAction.open);
    expect(handshake.state, DeviceAuthState.approved);
  });

  test('results after approval or before any ack are ignored', () {
    final handshake = DeviceAuthHandshake();
    expect(handshake.onAuthResult({'ok': false}), DeviceAuthAction.none);
    handshake.onKeyExchangeAck('approved');
    expect(
      handshake.onAuthResult({'ok': false, 'reason': 'approval_required'}),
      DeviceAuthAction.none,
    );
    expect(handshake.state, DeviceAuthState.approved);
  });

  test('a dropped socket resets to idle', () {
    final handshake = DeviceAuthHandshake();
    handshake.onKeyExchangeAck('pending');
    handshake.onAuthResult({
      'ok': false,
      'reason': 'approval_required',
      'code': 1,
    });
    expect(handshake.state.code, '1');
    handshake.reset();
    expect(handshake.state, DeviceAuthState.idle);
  });

  test('device_auth carries the token only when the app has one', () {
    expect(
      deviceAuthMessage(token: 'secret', name: 'Pixel', platform: 'android'),
      {
        'type': 'device_auth',
        'token': 'secret',
        'name': 'Pixel',
        'platform': 'android',
      },
    );
    expect(
      deviceAuthMessage(
        token: '',
        name: 'Pixel',
        platform: 'android',
      ).containsKey('token'),
      isFalse,
    );
  });
}
