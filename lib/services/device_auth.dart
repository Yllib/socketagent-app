/// Where this device stands with a computer's device registry on one relay
/// lane. Old servers never send a `device` field and count as approved.
enum DeviceAuthPhase {
  /// No handshake has finished yet.
  idle,

  /// The computer opened the peer.
  approved,

  /// The computer held the peer and the app has sent `device_auth`.
  authenticating,

  /// The token was missing or wrong; another device has to approve this one.
  awaitingApproval,
}

class DeviceAuthState {
  const DeviceAuthState._(this.phase, {this.code = ''});

  final DeviceAuthPhase phase;

  /// The six-digit fingerprint the computer sent, only while awaiting.
  final String code;

  static const idle = DeviceAuthState._(DeviceAuthPhase.idle);
  static const approved = DeviceAuthState._(DeviceAuthPhase.approved);
  static const authenticating = DeviceAuthState._(
    DeviceAuthPhase.authenticating,
  );

  bool get awaitingApproval => phase == DeviceAuthPhase.awaitingApproval;

  @override
  bool operator ==(Object other) =>
      other is DeviceAuthState && other.phase == phase && other.code == code;

  @override
  int get hashCode => Object.hash(phase, code);

  @override
  String toString() => 'DeviceAuthState($phase${code.isEmpty ? '' : ' $code'})';
}

/// What the socket should do after a handshake message.
enum DeviceAuthAction {
  /// Treat the peer as open: announce capabilities and go connected.
  open,

  /// Send `device_auth` inside the box and keep waiting.
  sendAuth,

  /// Stay held. The state carries the code to show.
  wait,

  /// Nothing to do.
  none,
}

/// The pending-device handshake from section 1 of the accounts design, kept
/// free of sockets so it can be tested on its own. One instance per lane.
class DeviceAuthHandshake {
  DeviceAuthState _state = DeviceAuthState.idle;

  DeviceAuthState get state => _state;

  /// The plaintext `key_exchange_ack`. [device] is its `device` field.
  DeviceAuthAction onKeyExchangeAck(Object? device) {
    if (device == 'pending') {
      _state = DeviceAuthState.authenticating;
      return DeviceAuthAction.sendAuth;
    }
    _state = DeviceAuthState.approved;
    return DeviceAuthAction.open;
  }

  /// An encrypted `device_auth_result`. Results that arrive once approved
  /// (from the listing refresh) change nothing.
  DeviceAuthAction onAuthResult(Map<String, dynamic> msg) {
    if (_state.phase == DeviceAuthPhase.approved ||
        _state.phase == DeviceAuthPhase.idle) {
      return DeviceAuthAction.none;
    }
    if (msg['ok'] == true) {
      _state = DeviceAuthState.approved;
      return DeviceAuthAction.open;
    }
    if (msg['reason'] == 'approval_required') {
      final code = msg['code'];
      _state = DeviceAuthState._(
        DeviceAuthPhase.awaitingApproval,
        code: code is String
            ? code
            : code is num
            ? code.toInt().toString()
            : '',
      );
      return DeviceAuthAction.wait;
    }
    // `not_approved` answers a message sent too early; keep waiting.
    return DeviceAuthAction.none;
  }

  /// The socket closed. A reconnect starts the handshake over, but the
  /// socket remembers it was waiting so it retries slowly.
  void reset() {
    _state = DeviceAuthState.idle;
  }
}

/// The `device_auth` message for a held peer. The token travels only inside
/// the encrypted box; callers must send this through the cipher.
Map<String, dynamic> deviceAuthMessage({
  required String token,
  required String name,
  required String platform,
}) => {
  'type': 'device_auth',
  if (token.isNotEmpty) 'token': token,
  'name': name,
  'platform': platform,
};
