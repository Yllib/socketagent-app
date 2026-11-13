import 'dart:convert';
import 'dart:typed_data';

import '../models/account_vault.dart';
import 'account_crypto.dart';

/// A change to the account that this device started and has not finished.
/// It is saved in the device record before the first request goes out, so a
/// start after the app died knows what was under way.
sealed class PendingChange {
  const PendingChange();

  Map<String, Object?> toJson();

  /// Null for no pending change, or one this build cannot read.
  static PendingChange? fromJson(Object? raw) {
    if (raw is! Map) return null;
    switch (raw['type']) {
      case 'create':
        return const PendingCreate();
      case 'pin':
        final pin = VaultAccountPin.fromJson(raw['pin']);
        return pin == null ? null : PendingPin(pin);
      case 'key':
        final masterKey = raw['newMasterKey'];
        final from = raw['fromAccount'];
        final stage = KeyChangeStage.values.asNameMap()[raw['stage']];
        if (masterKey is! String || from is! String || stage == null) {
          return null;
        }
        final removed = raw['removed'];
        return PendingKeyChange(
          newMasterKey: base64Decode(masterKey),
          fromAccount: from,
          removed: [
            if (removed is List)
              for (final key in removed)
                if (key is String) key,
          ],
          newPin: VaultAccountPin.fromJson(raw['newPin']),
          commitVersion: (raw['commitVersion'] as num?)?.toInt(),
          stage: stage,
        );
    }
    return null;
  }
}

/// First account: the new master key is on this device and the relay may
/// not hold the account yet. If the relay turns out not to, the key is
/// dropped.
final class PendingCreate extends PendingChange {
  const PendingCreate();

  @override
  Map<String, Object?> toJson() => {'type': 'create'};
}

/// Set new PIN: the public values of the PIN being set. Once the relay
/// reports [pin]'s id, the PIN write landed and the vault and the Drive
/// file follow. If it reports another id, the PIN was not changed.
final class PendingPin extends PendingChange {
  const PendingPin(this.pin);

  final VaultAccountPin pin;

  @override
  Map<String, Object?> toJson() => {'type': 'pin', 'pin': pin.toJson()};
}

/// How far a change of master key has got.
enum KeyChangeStage {
  /// The commit may or may not have landed. Only the relay's answer about
  /// the old account says which.
  started,

  /// The relay showed the commit cannot land. The new account still has to
  /// be deleted.
  undoing,

  /// Another device moved the account first. The new account still has to
  /// be deleted, and this device still has to follow the real move. The
  /// change is kept until both are done, because the move is refused when a
  /// device this change was removing made it.
  lost,

  /// The commit landed and this device is on the new key. What is left can
  /// be repeated.
  committed,
}

/// A change of master key: the first PIN on an account, Remove, or Remove
/// and set new PIN.
final class PendingKeyChange extends PendingChange {
  const PendingKeyChange({
    required this.newMasterKey,
    required this.fromAccount,
    required this.removed,
    required this.newPin,
    this.commitVersion,
    this.stage = KeyChangeStage.started,
  });

  final Uint8List newMasterKey;

  /// The account being left.
  final String fromAccount;

  /// Public keys of the devices this change removes. A handover box sealed
  /// by one of them is refused while the change is pending.
  final List<String> removed;

  /// The public values of the PIN the change sets, or null when it keeps
  /// the PIN the account has.
  final VaultAccountPin? newPin;

  /// The old account's version the commit named, saved before the commit is
  /// sent. Null means the commit was never sent.
  final int? commitVersion;
  final KeyChangeStage stage;

  AccountKeys get newKeys => AccountKeys.fromMasterKey(newMasterKey);

  PendingKeyChange copyWith({int? commitVersion, KeyChangeStage? stage}) =>
      PendingKeyChange(
        newMasterKey: newMasterKey,
        fromAccount: fromAccount,
        removed: removed,
        newPin: newPin,
        commitVersion: commitVersion ?? this.commitVersion,
        stage: stage ?? this.stage,
      );

  /// The same change with no commit sent, for after the relay refused one.
  PendingKeyChange withoutCommit() => PendingKeyChange(
    newMasterKey: newMasterKey,
    fromAccount: fromAccount,
    removed: removed,
    newPin: newPin,
  );

  @override
  Map<String, Object?> toJson() => {
    'type': 'key',
    'newMasterKey': base64Encode(newMasterKey),
    'fromAccount': fromAccount,
    'removed': removed,
    if (newPin case final pin?) 'newPin': pin.toJson(),
    'commitVersion': ?commitVersion,
    'stage': stage.name,
  };
}
