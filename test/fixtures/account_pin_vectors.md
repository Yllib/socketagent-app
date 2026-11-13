# Account PIN vectors

`account_pin_vectors.json` fixes the bytes of the account PIN design: the
stretch, the key pair, the two boxes, the Drive file, the PIN rule, the
requests and the relay's count. The relay keeps a copy, byte for byte, and
both suites pin its SHA-256.

    9e64cf93c522b6540af413b285244ab37c81c94bd6b35b219c2625f7a9bd8e81

Every key, salt, nonce and id is the SHA-256 of a label starting
`account-pin-vectors/`, cut to length. The PINs are made up. None is a real
secret.

The vectors are not frozen yet. The stretch settings wait for a timing test
on the slowest phone, and a change there changes this file.

## How it was made

`test/account_pin_vectors_test.dart` is the generator. Its `_build` makes the
whole file from the labels and the app's own code. Run with
`--dart-define=WRITE_PIN_VECTORS=true` it writes the file. Run without, it
checks that it still prints the committed bytes.

Written 2026-11-13 on the build machine with Flutter 3.47.6 and `sodium`
4.1.1+2.

## The second implementation

`check_account_pin_vectors.py` recomputes the file with code the app does
not use. Run 2026-11-13 on Ubuntu 24.04, it reproduced 56 values and found
no mismatch.

| Part | The app uses | The check uses |
|---|---|---|
| Argon2id | the libsodium bundled by `sodium` | libargon2 `0~20190702`, the reference library, and again the system libsodium 1.0.18 |
| HMAC-SHA256, SHA-256, SHA-512 | Dart `crypto` | Python `hmac` and `hashlib` |
| X25519 public keys | pinenacl | `cryptography` 41.0.7 (OpenSSL) |
| The box | pinenacl | system libsodium `crypto_box_easy` and `crypto_box_open_easy` |
| Ed25519 | pinenacl | `cryptography` 41.0.7 (OpenSSL) |

What it reproduced:

- `kdf`: `stretched` for all three PINs, by both libraries, then `authKey`
  and `wrapSeed`.
- `pinKey`: `pinPrivate` and `pinPublic` for all three.
- `box`: both boxes sealed to the same bytes and opened to the same payload,
  and the account each master key leads to.
- `driveFile`: the body, the signature and the whole file text.
- `refused`: the first file's signature does not verify and the second's
  does, libsodium refuses both bad sender keys, and each other box opens to
  a payload with the fault its name says.
- `requests`: the signed message and the signature of each request.
- `counter.accounts`: each account ID from its master key.

PyNaCl is not on that machine. The script loads the two C libraries through
`ctypes` and installs nothing.

It does not check `weak` or `counter.events`. Those hold rules, not crypto.

## Layout

Raw bytes are hex. A value that travels as base64 is given as it travels.

- `kdf`. `pin` and `salt` in, `stretched` out, then `authKey` and
  `wrapSeed`. The PINs are six digits, letters with symbols, and 64
  characters.
- `pinKey`. `wrapSeed` and `relayKey` in, the X25519 pair out. Entry `n`
  continues `kdf` entry `n`.
- `box.key`. The key box: `payload` sealed from `senderPrivate` to the first
  PIN key with `nonce`. `account` is the account `masterKey` leads to.
- `box.handover`. A handover box between two device keys, leaving
  `fromAccount` for `account`.
- `driveFile`. `body` is the signed text, `sig` its signature, `file` the
  whole file. Its box is `box.key` and its salt is the first `kdf` salt, so
  the first PIN and the first `relayKey` open it.
- `weak`. PINs with what the app says when one is set: `null` for a PIN it
  takes, else `badCharacter`, `tooShort`, `tooLong` or `tooEasy`.
- `refused`. Inputs the app must refuse. `kind` says what to do with one.
  A `file` is read and must come out as `reads` says: `invalid`, or `plain`
  for a version 1 file. When `paddedToBytes` is there, spaces are added to
  the text up to that many bytes first. A `keyBox` is opened with
  `pinPrivate` for `account`. A `handoverBox` is opened with
  `recipientPrivate` by a device leaving `fromAccount`.
- `requests.signed`. PIN route requests signed by the account named `first`
  in `counter.accounts`, at the time in `X-SA-Time`. `message` is the text
  that was signed.
- `requests.unlock`. The body of the route nobody signs.
- `counter.accounts`. The accounts the events name, with the Ed25519 seed
  each signs with.
- `counter.events`. What the relay must answer, in order. `at` is the
  relay's clock in milliseconds. `records` is every PIN record after the
  event, by account name.

  | `op` | Request |
  |---|---|
  | `create` | Setup. `account` gets a live vault. |
  | `move` | Setup. `account` is frozen with a rotation record naming `to`. |
  | `delete` | `DELETE /api/account` |
  | `vault.get` | `GET /api/account/vault`. `reply` gives only `pin`. |
  | `pin.put` | `PUT /api/account/pin` with `body` |
  | `pin.reset` | `POST /api/account/pin/reset` |
  | `pin.claim` | `POST /api/account/pin/claim` with `body`, signed by `account` |
  | `pin.unlock` | `POST /api/account/pin/unlock` with `body`. `account` names the account the body carries. |

  `status` and `reply` are the answer. A `204` has a `null` reply.
