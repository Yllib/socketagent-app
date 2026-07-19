class AdbPairingInput {
  const AdbPairingInput({
    required this.pairPort,
    required this.code,
    this.connectPort,
  });

  final int pairPort;
  final String code;
  final int? connectPort;
}

AdbPairingInput? parseAdbPairingInput(String value) {
  final text = value.trim();
  final match = RegExp(
    r'^(?:(\[[^\]]+\]|[0-9A-Za-z._-]+):)?(\d{1,5})\s+(\d{4,12})(?:\s+(\d{1,5}))?$',
  ).firstMatch(text);
  if (match == null) return null;

  final pairPort = int.tryParse(match.group(2) ?? '');
  final connectPort = int.tryParse(match.group(4) ?? '');
  if (!_validPort(pairPort) ||
      (connectPort != null && !_validPort(connectPort))) {
    return null;
  }
  return AdbPairingInput(
    pairPort: pairPort!,
    code: match.group(3)!,
    connectPort: connectPort,
  );
}

bool _validPort(int? port) => port != null && port > 0 && port <= 65535;
