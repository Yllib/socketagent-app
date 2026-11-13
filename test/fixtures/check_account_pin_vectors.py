#!/usr/bin/env python3
"""Recomputes account_pin_vectors.json with code the app does not use.

The app makes the vectors with the libsodium it bundles (Argon2id), the Dart
`crypto` package (HMAC, SHA) and pinenacl (X25519, the box, Ed25519). This
script reaches the same bytes with:

  - libargon2, the Argon2 reference library, for the stretch
  - the system libsodium, for the stretch a second time and for the box
  - Python's hmac and hashlib
  - the `cryptography` package (OpenSSL) for X25519 and Ed25519

Usage: check_account_pin_vectors.py [path to the fixture]
Needs libargon2.so.1, libsodium.so.23 and python3-cryptography. It installs
nothing and exits non-zero on the first mismatch.
"""

import base64
import ctypes
import hashlib
import hmac
import json
import pathlib
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

PASSES = 3
MEMORY_BYTES = 67108864
ARGON2ID13 = 2

argon2 = ctypes.CDLL("libargon2.so.1")
sodium = ctypes.CDLL("libsodium.so.23")
if sodium.sodium_init() < 0:
    sys.exit("libsodium did not start")
sodium.sodium_version_string.restype = ctypes.c_char_p

checked = 0


def same(what, got, want):
    global checked
    if got != want:
        sys.exit(f"MISMATCH {what}\n  got  {got!r}\n  want {want!r}")
    checked += 1


def stretch_argon2(pin, salt):
    out = ctypes.create_string_buffer(32)
    result = argon2.argon2id_hash_raw(
        ctypes.c_uint32(PASSES),
        ctypes.c_uint32(MEMORY_BYTES // 1024),
        ctypes.c_uint32(1),
        pin,
        ctypes.c_size_t(len(pin)),
        salt,
        ctypes.c_size_t(len(salt)),
        out,
        ctypes.c_size_t(32),
    )
    if result != 0:
        sys.exit(f"libargon2 failed with {result}")
    return out.raw


def stretch_sodium(pin, salt):
    out = ctypes.create_string_buffer(32)
    result = sodium.crypto_pwhash(
        out,
        ctypes.c_ulonglong(32),
        pin,
        ctypes.c_ulonglong(len(pin)),
        salt,
        ctypes.c_ulonglong(PASSES),
        ctypes.c_size_t(MEMORY_BYTES),
        ctypes.c_int(ARGON2ID13),
    )
    if result != 0:
        sys.exit("libsodium crypto_pwhash failed")
    return out.raw


def hmac256(key, message):
    return hmac.new(key, message, hashlib.sha256).digest()


def x25519_public(private):
    return (
        X25519PrivateKey.from_private_bytes(private)
        .public_key()
        .public_bytes(Encoding.Raw, PublicFormat.Raw)
    )


def box_seal(payload, nonce, recipient_public, sender_private):
    out = ctypes.create_string_buffer(len(payload) + 16)
    result = sodium.crypto_box_easy(
        out, payload, ctypes.c_ulonglong(len(payload)), nonce, recipient_public, sender_private
    )
    if result != 0:
        sys.exit("libsodium crypto_box_easy failed")
    return out.raw


def box_open(sealed, nonce, sender_public, recipient_private):
    """The payload, or None when libsodium refuses the key or the tag."""
    out = ctypes.create_string_buffer(max(len(sealed) - 16, 1))
    result = sodium.crypto_box_open_easy(
        out, sealed, ctypes.c_ulonglong(len(sealed)), nonce, sender_public, recipient_private
    )
    return out.raw[: len(sealed) - 16] if result == 0 else None


def signing_key(master_key):
    seed = hashlib.sha512(b"socketagent-account-auth-v1" + master_key).digest()[:32]
    return Ed25519PrivateKey.from_private_bytes(seed)


def account_id(key):
    raw = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def verifies(account, signature, message):
    padded = account + "=" * (-len(account) % 4)
    key = Ed25519PublicKey.from_public_bytes(base64.urlsafe_b64decode(padded))
    try:
        key.verify(signature, message)
        return True
    except InvalidSignature:
        return False


def check_box(name, entry):
    sender_private = bytes.fromhex(entry["senderPrivate"])
    recipient_private = bytes.fromhex(entry["recipientPrivate"])
    nonce = bytes.fromhex(entry["nonce"])
    payload = entry["payload"].encode()
    sender_public = x25519_public(sender_private)
    recipient_public = x25519_public(recipient_private)
    box = base64.b64decode(entry["box"])
    same(
        f"box.{name} sealed",
        sender_public + nonce + box_seal(payload, nonce, recipient_public, sender_private),
        box,
    )
    same(
        f"box.{name} opened",
        box_open(box[56:], box[32:56], box[:32], recipient_private),
        payload,
    )
    fields = json.loads(payload)
    same(f"box.{name} master key", base64.b64decode(fields["masterKey"]).hex(), entry["masterKey"])
    same(
        f"box.{name} account",
        account_id(signing_key(bytes.fromhex(entry["masterKey"]))),
        entry["account"],
    )


def main():
    here = pathlib.Path(__file__).parent
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else here / "account_pin_vectors.json"
    data = path.read_bytes()
    vectors = json.loads(data)

    for index, entry in enumerate(vectors["kdf"]):
        pin = entry["pin"].encode()
        salt = bytes.fromhex(entry["salt"])
        stretched = stretch_argon2(pin, salt)
        same(f"kdf[{index}] stretched, libargon2", stretched.hex(), entry["stretched"])
        same(f"kdf[{index}] stretched, libsodium", stretch_sodium(pin, salt).hex(), entry["stretched"])
        same(
            f"kdf[{index}] authKey",
            hmac256(stretched, b"socketagent-pin-auth-v1").hex(),
            entry["authKey"],
        )
        same(
            f"kdf[{index}] wrapSeed",
            hmac256(stretched, b"socketagent-pin-wrap-v1").hex(),
            entry["wrapSeed"],
        )

    for index, entry in enumerate(vectors["pinKey"]):
        same(f"pinKey[{index}] wrapSeed", entry["wrapSeed"], vectors["kdf"][index]["wrapSeed"])
        private = hmac256(
            bytes.fromhex(entry["wrapSeed"]),
            b"socketagent-pin-key-v1" + bytes.fromhex(entry["relayKey"]),
        )
        same(f"pinKey[{index}] pinPrivate", private.hex(), entry["pinPrivate"])
        same(f"pinKey[{index}] pinPublic", x25519_public(private).hex(), entry["pinPublic"])

    key_box = vectors["box"]["key"]
    same("box.key recipient", key_box["recipientPrivate"], vectors["pinKey"][0]["pinPrivate"])
    check_box("key", key_box)
    handover = vectors["box"]["handover"]
    check_box("handover", handover)
    same("box.handover from", json.loads(handover["payload"])["from"], handover["fromAccount"])
    same(
        "box.handover sender",
        base64.b64encode(x25519_public(bytes.fromhex(handover["senderPrivate"]))).decode(),
        handover["senderPublic"],
    )

    drive = vectors["driveFile"]
    key = signing_key(bytes.fromhex(drive["masterKey"]))
    same("driveFile account", account_id(key), drive["account"])
    body = json.dumps(
        {
            "account": drive["account"],
            "pinId": drive["pinId"],
            "salt": drive["salt"],
            "box": drive["box"],
        },
        separators=(",", ":"),
    )
    same("driveFile body", body, drive["body"])
    signature = key.sign(b"socketagent-drive-file-v2\n" + body.encode())
    same("driveFile sig", base64.b64encode(signature).decode(), drive["sig"])
    same(
        "driveFile file",
        json.dumps(
            {"v": 2, "body": base64.b64encode(body.encode()).decode(), "sig": drive["sig"]},
            separators=(",", ":"),
        ),
        drive["file"],
    )

    for entry in vectors["refused"]:
        name = entry["name"]
        if entry["kind"] == "file":
            file = json.loads(entry["file"])
            if file["v"] != 2 or "paddedToBytes" in entry:
                continue
            body = base64.b64decode(file["body"])
            good = verifies(
                json.loads(body)["account"],
                base64.b64decode(file["sig"]),
                b"socketagent-drive-file-v2\n" + body,
            )
            # Only the first case has a bad signature. The extra field is
            # signed properly and refused for its shape.
            same(f"refused: {name}, signature verifies", good, len(json.loads(body)) != 4)
            continue
        private_field = "pinPrivate" if entry["kind"] == "keyBox" else "recipientPrivate"
        box = base64.b64decode(entry["box"])
        opened = box_open(box[56:], box[32:56], box[:32], bytes.fromhex(entry[private_field]))
        if "sender key" in name:
            same(f"refused: {name}, libsodium refuses the key", opened, None)
            continue
        fields = json.loads(opened)
        wanted = "socketagent-pin-box-v1" if entry["kind"] == "keyBox" else "socketagent-handover-v1"
        account = account_id(signing_key(base64.b64decode(fields["masterKey"])))
        if entry["kind"] == "keyBox":
            wrong = fields["t"] != wanted or account != entry["account"]
        else:
            wrong = (
                fields["t"] != wanted
                or fields.get("from") != entry["fromAccount"]
                or account == entry["fromAccount"]
            )
        same(f"refused: {name}, the payload is wrong", wrong, True)

    signed = vectors["requests"]["signed"]
    seeds = {entry["accountId"]: entry for entry in vectors["counter"]["accounts"]}
    for entry in signed:
        headers = entry["headers"]
        message = "\n".join(
            [
                "socketagent-account-v1",
                entry["method"],
                entry["path"],
                headers["X-SA-Time"],
                hashlib.sha256(entry["body"].encode()).hexdigest(),
            ]
        )
        same(f"requests {entry['path']} message", message, entry["message"])
        key = Ed25519PrivateKey.from_private_bytes(
            bytes.fromhex(seeds[headers["X-SA-Account"]]["signingSeed"])
        )
        same(
            f"requests {entry['path']} signature",
            base64.b64encode(key.sign(message.encode())).decode(),
            headers["X-SA-Signature"],
        )

    for entry in vectors["counter"]["accounts"]:
        key = signing_key(bytes.fromhex(entry["masterKey"]))
        same(f"counter account {entry['name']}", account_id(key), entry["accountId"])

    print(f"{path.name}  SHA-256 {hashlib.sha256(data).hexdigest()}")
    print(f"libsodium {sodium.sodium_version_string().decode()}, libargon2.so.1, cryptography (OpenSSL)")
    print(f"{checked} values reproduced")


main()
