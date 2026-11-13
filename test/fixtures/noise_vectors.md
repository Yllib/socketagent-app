# Noise test vectors

Fixtures for the `test/noise_*_test.dart` files.

The two published files feed `test/noise_ikpsk1_test.dart`. Each holds only
the entries named `Noise_IKpsk1_25519_ChaChaPoly_SHA256`, copied unchanged
from a public file. Fetched 2026-11-12.

## noise_ikpsk1_cacophony.json

The one entry with this protocol name in cacophony's vector file, in the
[Noise wiki test vector format](https://github.com/noiseprotocol/noise_wiki/wiki/Test-vectors),
wrapped in a `vectors` array as upstream has it.

- Source: `vectors/cacophony.txt` in
  <https://github.com/haskell-cryptography/cacophony>, at commit `8ee9d41e`.
  The file last changed in `18b7348c` (2018-12-16).
- SHA-256 of the upstream file:
  `3bde7c09a6f349ee11c825c50fcc02649f8f02a47c857a459206b357f9386cae`
- Licence: public domain (the Unlicense).
- snow ships the same file, byte for byte, as `tests/vectors/cacophony.txt`
  (<https://github.com/mcginty/snow>, commit `8ac60f51`). snow's own
  `snow.txt` has no entry with this name.

This entry carries a handshake hash. It has a prologue and payloads in both
handshake messages, then four transport messages.

## noise_ikpsk1_flynn.txt

The four entries with this protocol name in flynn/noise's vector file, in that
project's own `key=value` format, blank line between entries.

- Source: `vectors.txt` in <https://github.com/flynn/noise>, at commit
  `4d9f71cd`. The file last changed in `fc3a9f3b` (2017-09-27).
- SHA-256 of the upstream file:
  `0b8a1305176c95952802b114baa4aa2a3d6e7c33fdf2035b60b8c92058a50d9c`
- Licence: BSD 3-clause. `noise_flynn_LICENSE` is the project's licence file,
  kept beside the copy as it requires.

The four cover empty and non-empty handshake payloads, each with and without a
prologue. They carry no handshake hash. The initiator's copy of the
responder's public key is not listed; it is the public half of `resp_static`.

## What the vectors do not list

Neither format lists the two transport keys. Each entry instead has transport
messages sealed with them under Noise's own transport rules (ChaCha20-Poly1305,
a counter nonce from zero per direction, no associated data). The test seals
the same payloads with the keys the handshake returned and compares, which
only matches if both keys are right.

## noise_ikpsk1_vectors.json

The cross-language file, read by `test/noise_cross_language_test.dart`. The
server's TypeScript handshake wrote it, and the Dart handshake must print the
same bytes from the inputs alone.

- Source: `server/test/fixtures/noise-ikpsk1-vectors.json` in the socketagent
  repository, copied unchanged at commit `3bca04b`.
- `server/scripts/generate-noise-vectors.js` there writes the file and
  documents its layout. Every key in it is a SHA-256 of a label, so none is a
  real secret.
- When the server's file changes, copy it here again and update the commit
  above. Do not edit this copy by hand.
