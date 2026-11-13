import 'dart:io';
import '../widgets/desktop_qr_import_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/server_config.dart';
import '../services/crypto_service.dart';
import '../services/transport_v2.dart';
import '../config/app_palette.dart';

/// A scanned pairing code. Every code pairs the relay; newer servers also
/// include [local], the details for connecting directly on the same network.
class PairingResult {
  final String relayUrl;

  /// The computer's relay room ID.
  final String pairingToken;
  final String serverPubkey;

  /// Base64 of the pairing secret from an `SA3` code. Empty for an old code,
  /// which pairs on the old transport.
  final String pairingSecret;
  final LocalPairing? local;
  PairingResult({
    required this.relayUrl,
    required this.pairingToken,
    required this.serverPubkey,
    this.pairingSecret = '',
    this.local,
  });

  /// Whether this came from an `SA3` code. Such a computer is on transport
  /// v2 from its first connection and never on the old one.
  bool get isV2 => pairingSecret.isNotEmpty;
}

/// How to reach the computer directly. [hosts] are its LAN addresses,
/// likeliest first. The direct connection uses the same public key. [token]
/// is empty for an `SA3` code, which carries no AUTH_TOKEN.
class LocalPairing {
  final List<String> hosts;
  final int port;
  final String token;
  LocalPairing({required this.hosts, required this.port, required this.token});
}

const _notACode = FormatException(
  'That is not a SocketAgent pairing code. Show a new code on the computer and try again.',
);
const _incompleteCode = FormatException(
  'That pairing code is incomplete. Show a new code on the computer and try again.',
);

/// Reads the three kinds of pairing code:
///
///     SA3|<room ID>|<public key>|<secret>|<port>|<host>,<host>[|<relay URL>]
///     SA|<pairing token>|<public key>|<port>|<auth token>|<host>,<host>
///     SA|<pairing token>|<public key>
///
/// SC is accepted for servers that kept the original SocketClaude marker.
/// Throws a [FormatException] with a message for the user when the code is
/// unusable.
PairingResult parsePairingCode(String rawData) {
  final parts = rawData.trim().split('|');
  if (parts[0] == 'SA3') return _parseV2Code(parts);
  if ((parts.length != 3 && parts.length != 6) ||
      (parts[0] != 'SA' && parts[0] != 'SC')) {
    throw _notACode;
  }
  if (parts[1].isEmpty || parts[2].isEmpty) throw _incompleteCode;
  return PairingResult(
    relayUrl: PairScreen.relayUrl,
    pairingToken: parts[1],
    serverPubkey: parts[2],
    local: parts.length == 6 ? _localPairing(parts) : null,
  );
}

/// An `SA3` code, wire spec section 6. Every part has to follow its rule: a
/// code that breaks one is refused whole, and never read as an old code.
PairingResult _parseV2Code(List<String> parts) {
  if (parts.length != 6 && parts.length != 7) throw _notACode;
  final [_, roomId, computerKey, secret, portText, hostList, ...rest] = parts;
  final port = RegExp(r'^[0-9]{1,5}$').hasMatch(portText)
      ? int.parse(portText)
      : 0;
  final relay = rest.isEmpty ? null : Uri.tryParse(rest.single);
  if (!isValidRoomId(roomId) ||
      decodeKey32(computerKey) == null ||
      decodeKey32(secret) == null ||
      port < 1 ||
      port > 65535 ||
      (rest.isNotEmpty &&
          (!rest.single.startsWith('wss://') ||
              relay == null ||
              relay.host.isEmpty))) {
    throw _incompleteCode;
  }
  final hosts = hostList
      .split(',')
      .map((host) => host.trim())
      .where((host) => host.isNotEmpty)
      .toList();
  return PairingResult(
    relayUrl: rest.isEmpty ? PairScreen.relayUrl : rest.single,
    pairingToken: roomId,
    serverPubkey: computerKey,
    pairingSecret: secret,
    local: hosts.isEmpty
        ? null
        : LocalPairing(hosts: hosts, port: port, token: ''),
  );
}

/// The direct details, or null when the computer found no usable address.
LocalPairing? _localPairing(List<String> parts) {
  final port = int.tryParse(parts[3]);
  final hosts = parts[5]
      .split(',')
      .map((host) => host.trim())
      .where((host) => host.isNotEmpty)
      .toList();
  if (port == null || port < 1 || port > 65535) return null;
  if (parts[4].isEmpty || hosts.isEmpty) return null;
  return LocalPairing(hosts: hosts, port: port, token: parts[4]);
}

/// Asks before a pairing code's own relay is used. True at once for a code
/// on the app's relay, which is every old code and every `SA3` code with no
/// relay part. For any other relay the user is shown its host and has to
/// choose Continue. Until then nothing is sent to that relay.
Future<bool> confirmCodeRelay(
  BuildContext context,
  PairingResult pairing,
) async {
  final host = otherRelayHost(pairing.relayUrl);
  if (host == null) return true;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Use this relay?'),
      content: Text(
        "This code connects through $host, not SocketAgent's relay. "
        'Your relay access will be sent to it.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// The scanner for a computer's pairing code, with a field to paste one
/// instead. It hands back the code it read, and only after
/// [confirmCodeRelay]: a code whose relay the user turns down is handed to
/// nobody, and the screen closes with nothing.
class PairScreen extends StatefulWidget {
  static const String relayUrl = defaultRelayUrl;

  /// Whether this is the desktop app, which has no camera to scan with and
  /// opens on the paste field. Tests turn it on to reach that field.
  @visibleForTesting
  static bool desktop = Platform.isWindows;
  final CryptoService cryptoService;

  const PairScreen({super.key, required this.cryptoService});

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final MobileScannerController _controller = MobileScannerController();
  final TextEditingController _pasteController = TextEditingController();
  bool _processing = false;
  String? _error;
  bool _showManualInput = PairScreen.desktop;

  @override
  void dispose() {
    if (!PairScreen.desktop) _controller.dispose();
    _pasteController.dispose();
    super.dispose();
  }

  Future<void> _processPairingData(String rawData) async {
    if (_processing) return;

    setState(() {
      _processing = true;
      _error = null;
    });

    try {
      final pairing = parsePairingCode(rawData);
      // Asked before anything is done with the code. A scanner left open
      // would read the same code again, so a no closes the screen.
      if (!await confirmCodeRelay(context, pairing)) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      await widget.cryptoService.ensureKeyPair();
      widget.cryptoService.setServerPublicKey(pairing.serverPubkey);
      if (mounted) Navigator.of(context).pop(pairing);
    } on FormatException catch (e) {
      setState(() {
        _error = e.message;
        _processing = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _processing = false;
      });
    }
  }

  Future<void> _handleBarcode(BarcodeCapture capture) async {
    final barcode = capture.barcodes.firstOrNull;
    if (barcode == null || barcode.rawValue == null) return;
    await _processPairingData(barcode.rawValue!);
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      _pasteController.text = data.text!;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _showManualInput ? 'Paste Pairing Data' : 'Scan Pairing QR',
        ),
        actions: [
          if (!PairScreen.desktop)
            IconButton(
              icon: Icon(_showManualInput ? Icons.qr_code_scanner : Icons.edit),
              tooltip: _showManualInput ? 'Scan QR' : 'Paste manually',
              onPressed: () =>
                  setState(() => _showManualInput = !_showManualInput),
            ),
        ],
      ),
      body: Column(
        children: [
          if (!_showManualInput)
            Expanded(
              child: MobileScanner(
                controller: _controller,
                onDetect: _handleBarcode,
              ),
            ),
          if (_showManualInput)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Paste the pairing code shown by SocketAgent on the computer:',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (PairScreen.desktop) ...[
                      const SizedBox(height: 12),
                      DesktopQrImportButton(onDecoded: _processPairingData),
                    ],
                    const SizedBox(height: 12),
                    Expanded(
                      child: TextField(
                        controller: _pasteController,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: InputDecoration(
                          hintText: 'SA|…',
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.paste),
                            tooltip: 'Paste from clipboard',
                            onPressed: _pasteFromClipboard,
                          ),
                        ),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _processing
                          ? null
                          : () => _processPairingData(
                              _pasteController.text.trim(),
                            ),
                      child: _processing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Pair'),
                    ),
                  ],
                ),
              ),
            ),
          if (_error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: context.palette.shade(Colors.red, 100),
              child: Text(
                _error!,
                style: TextStyle(color: Colors.red.shade900),
                textAlign: TextAlign.center,
              ),
            ),
          if (_processing && !_showManualInput)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Pairing...'),
                ],
              ),
            ),
          if (!_showManualInput)
            Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Point your camera at the QR code, or tap the edit icon to paste manually',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
