import 'dart:convert';

import 'package:app/services/crypto_service.dart';
import 'package:app/services/nacl_cipher.dart';
import 'package:app/services/socket_frame_decoder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';

// Made by server/src/relay-crypto.ts: acceptKeyExchange answered an offer
// built from these phone keys, then its channel sealed two frames.
const _phoneSecret = 'AQgPFh0kKzI5QEdOVVxjanF4f4aNlJuiqbC3vsXM09o=';
const _serverSecret = 'AgkQFx4lLDM6QUhPVl1ka3J5gIeOlZyjqrG4v8bN1Ns=';
const _ephemeralSecret = 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw=';
const _ack = {
  'type': 'key_exchange_ack',
  'device': 'approved',
  'session': {
    'v': 1,
    'key': 'W7GiHpufDx3uyCoBi8ryGaxVJHGXJkcxd8VeC3FyDxE=',
    'proof':
        'HQ8T2gORSDb6jfZKpcN/GmUVrpBnGSjvfDB3U51eeeycjx86avCUVSfgxK/ZIj8s/n2c'
        '9+LZZgO9+zNiEauX6zsBbV2nEVxNDmJJt90i4B/eDMsMIUxzIXlKWiEcxevSG4xJ8Ugo'
        'bJ5Axouq/wdCBEi7EWLrlHKUm4Q3d55CHsS8qq39wQ==',
  },
};
const _textFrame =
    '{"n":"AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB",'
    '"c":"1hKQI5DnH44KxYY+DqOsiuXLAvJezKWP/G/+JzQk+6SfxUK4/D1RGG6+y7NNdEK4RQ=="}';
const _binaryFrame =
    'AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC6wr1d75/gsCQJ536gA29UiHE6ZVWJ1bUCgX8jY7E'
    'y5eM5tqohwxGN1Qb4mTVyvXtnc5/';

void main() {
  final phone = PrivateKey(base64Decode(_phoneSecret));
  final server = PrivateKey(base64Decode(_serverSecret));
  final staticCipher = NaclCipher(
    Box(myPrivateKey: phone, theirPublicKey: server.publicKey),
    native: false,
  );
  final phoneKey = base64Encode(phone.publicKey.asTypedList);

  SessionOffer offer({PrivateKey? ephemeral}) => SessionOffer(
    staticCipher,
    phoneKey,
    ephemeral: ephemeral ?? PrivateKey(base64Decode(_ephemeralSecret)),
  );

  /// Opens [frame] on [channel] the way WebSocketService does.
  Future<String> receive(PeerChannel channel, Object frame) async {
    final decoded = await decodeSocketFrame(
      frame,
      cipher: channel.cipher,
      encryptedBinary: true,
    );
    channel.accept(decoded!.nonce);
    return decoded.message['content'] as String;
  }

  test('a session from the server opens its frames once each', () async {
    final channel = offer().accept(_ack, required: false);
    expect(channel.sessionKeyed, isTrue);

    expect(await receive(channel, _textFrame), 'first');
    expect(await receive(channel, base64Decode(_binaryFrame)), 'second');
    await expectLater(receive(channel, _textFrame), throwsStateError);
    await expectLater(
      receive(channel, base64Decode(_binaryFrame)),
      throwsStateError,
    );
  });

  test('a frame older than the last one is refused', () async {
    final channel = offer().accept(_ack, required: false);
    expect(await receive(channel, base64Decode(_binaryFrame)), 'second');
    await expectLater(receive(channel, _textFrame), throwsStateError);
  });

  test('an answer to a different offer is refused', () {
    expect(
      () =>
          offer(ephemeral: PrivateKey.generate()).accept(_ack, required: false),
      throwsFormatException,
    );
  });

  test(
    'a server without session keys keeps the static box until it has used them',
    () {
      final ack = {'type': 'key_exchange_ack', 'device': 'approved'};
      expect(offer().accept(ack, required: false).sessionKeyed, isFalse);
      expect(
        () => offer().accept(ack, required: true),
        throwsA(isA<SessionKeyRequired>()),
      );
    },
  );

  test('the offer proves its key under the static box', () {
    final message = offer().message();
    expect(message['pubkey'], phoneKey);
    final session = message['session']! as Map<String, Object>;
    final proof = base64Decode(session['proof']! as String);
    final serverBox = Box(
      myPrivateKey: server,
      theirPublicKey: phone.publicKey,
    );
    final opened = serverBox.decrypt(
      ByteList(proof.sublist(24)),
      nonce: proof.sublist(0, 24),
    );
    expect(opened, [
      ...utf8.encode('socketagent session offer v1'),
      ...base64Decode(session['key']! as String),
    ]);
  });

  test('sealed frames number their nonces from the phone', () {
    final channel = offer().accept(_ack, required: false);
    final first = base64Decode(channel.sealText('{}')['n']!);
    final second = channel.sealBinary(Uint8List.fromList([0x4A]));
    expect(first[0], 1);
    expect(first[23], 1);
    expect(second[0], 1);
    expect(second[23], 2);
  });
}
