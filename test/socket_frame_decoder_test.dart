import 'dart:async';
import 'dart:convert';
import 'package:app/services/socket_frame_decoder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';
import 'file_download_frame_test.dart' show buildFrame;

void main() {
  final client = PrivateKey.generate();
  final server = PrivateKey.generate();
  final sender = Box(myPrivateKey: server, theirPublicKey: client.publicKey);
  final receiver = Box(myPrivateKey: client, theirPublicKey: server.publicKey);
  final history = {'type': 'session_history', 'text': '日本語🔧' * 12000};

  String envelope(Map<String, dynamic> message) {
    final encrypted = sender.encrypt(
      Uint8List.fromList(utf8.encode(jsonEncode(message))),
    );
    return jsonEncode({
      'n': base64Encode(encrypted.nonce),
      'c': base64Encode(encrypted.cipherText),
    });
  }

  test(
    'large binary downloads retain payload bytes and resume offsets',
    () async {
      final payload = Uint8List.fromList(List.generate(65536, (i) => i % 256));
      final plain = buildFrame(payload: payload);
      final encrypted = sender.encrypt(plain);
      for (final useEncryption in [false, true]) {
        final frame = useEncryption
            ? Uint8List.fromList([...encrypted.nonce, ...encrypted.cipherText])
            : plain;
        final decoded = await decodeSocketFrame(
          frame,
          box: receiver,
          encryptedBinary: useEncryption,
        );
        expect(decoded?.message['binaryData'], orderedEquals(payload));
        expect(decoded?.message['offsetBytes'], 5000000000);
        expect(decoded?.encrypted, useEncryption);
      }
    },
  );

  test(
    'large encrypted JSON decodes without occupying the caller isolate',
    () async {
      final frame = envelope(history);
      var eventLoopRan = false;
      Timer.run(() => eventLoopRan = true);
      final decoded = await decodeSocketFrame(frame, box: receiver);
      expect(eventLoopRan, isTrue);
      expect(decoded?.message, history);
      expect(decoded?.encrypted, isTrue);
    },
  );

  test(
    'binary JSON uses the same worker and wire marker as the server',
    () async {
      final encrypted = sender.encrypt(
        Uint8List.fromList([0x4A, ...utf8.encode(jsonEncode(history))]),
      );
      final frame = Uint8List.fromList([
        ...encrypted.nonce,
        ...encrypted.cipherText,
      ]);
      expect(
        (await decodeSocketFrame(
          frame,
          box: receiver,
          encryptedBinary: true,
        ))?.message,
        history,
      );
      frame[frame.length - 1] ^= 1;
      await expectLater(
        decodeSocketFrame(frame, box: receiver, encryptedBinary: true),
        throwsA(contains('forged')),
      );
    },
  );

  test(
    'legacy plaintext and key exchange remain supported without keys',
    () async {
      expect((await decodeSocketFrame(jsonEncode(history)))?.message, history);
      expect(
        (await decodeSocketFrame('{"type":"key_exchange_ack"}'))?.encrypted,
        isFalse,
      );
      await expectLater(decodeSocketFrame(envelope(history)), throwsStateError);
      await expectLater(
        decodeSocketFrame(Uint8List(32), encryptedBinary: true),
        throwsStateError,
      );
    },
  );
}
