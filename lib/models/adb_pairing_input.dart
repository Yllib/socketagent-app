class AdbPairingInput {
  const AdbPairingInput({required this.pairPort, required this.code});

  final int pairPort;
  final String code;
}

AdbPairingInput? parseAdbPairingInput(String value) {
  final text = value.trim();
  final match = RegExp(r'^(\d{1,5})\s+(\d{4,12})$').firstMatch(text);
  if (match == null) return null;

  final pairPort = int.tryParse(match.group(1) ?? '');
  if (!_validPort(pairPort)) return null;
  return AdbPairingInput(pairPort: pairPort!, code: match.group(2)!);
}

bool _validPort(int? port) => port != null && port > 0 && port <= 65535;
