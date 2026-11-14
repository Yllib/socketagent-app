import 'dart:async';

import 'package:flutter/material.dart';

import '../../config/app_palette.dart';
import '../../models/account_vault.dart';
import '../../services/account_key_file.dart';
import '../../services/account_pin.dart';
import '../../services/account_service.dart';
import '../../services/device_unlock.dart';
import '../../services/google_auth.dart';

// The account PIN's dialogs and the flows that string them together: the
// sign-in on a device with no account, the first PIN, Set new PIN, Remove,
// and the prompt and notices shown when the app opens.

const _lastLine =
    'If you forget the PIN, a signed-in device can set a new one. With none, '
    'only the recovery key works. Write it down.';
const _cannotCheckWords = 'This device cannot check the PIN.';

/// The message shown for a failed account action.
String accountErrorText(Object error) => switch (error) {
  StateError(:final message) => message,
  FormatException(:final message) => message,
  GoogleAuthNotConfigured() => error.toString(),
  PinStretchUnavailable() => _cannotCheckWords,
  _ => 'Something went wrong: $error',
};

/// A day as the account screens write it.
String accountDate(int unixMs) {
  if (unixMs <= 0) return 'unknown';
  final at = DateTime.fromMillisecondsSinceEpoch(unixMs).toLocal();
  return '${at.year}-${_two(at.month)}-${_two(at.day)}';
}

/// A moment as the PIN dialogs write it: `today at 14:05`, or
/// `on 2026-11-14 at 14:05` for any other day.
String accountWhen(int unixMs, {DateTime? now}) {
  final at = DateTime.fromMillisecondsSinceEpoch(unixMs).toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final time = '${_two(at.hour)}:${_two(at.minute)}';
  final sameDay =
      at.year == today.year && at.month == today.month && at.day == today.day;
  return sameDay ? 'today at $time' : 'on ${accountDate(unixMs)} at $time';
}

String _two(int value) => value.toString().padLeft(2, '0');

/// `1 try`, `3 tries`.
String _tries(int count) => count == 1 ? '1 try' : '$count tries';

String? _pinProblemWords(PinProblem? problem) => switch (problem) {
  null => null,
  PinProblem.badCharacter => 'Use English letters, digits and symbols only',
  PinProblem.tooShort => 'At least 6 characters',
  PinProblem.tooLong => 'At most 64 characters',
  PinProblem.tooEasy => 'Too easy to guess',
};

// ────────── The first-run prompt ──────────

/// The one-time prompt on an account with no PIN. Resolves true for
/// "Set PIN" and false for "Later" or a dismissal.
Future<bool> showPinPromptDialog(BuildContext context) async {
  final set = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Protect your account with a PIN'),
      content: const Text(
        'Your saved computers are stored with your Google account. A PIN '
        'keeps them locked if someone gets into it. You only enter it when '
        'you sign in on a new device.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Later'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Set PIN'),
        ),
      ],
    ),
  );
  return set == true;
}

// ────────── Set PIN ──────────

/// Asks for a new PIN twice and hands it to [onSet]. One dialog for the
/// first account, the first PIN on an existing account, Set new PIN, and
/// Remove and set new PIN. Pops true once [onSet] returns. While [onSet]
/// runs the buttons are off and the label reads "Setting". When it throws,
/// the dialog stays open and shows the message.
class SetPinDialog extends StatefulWidget {
  const SetPinDialog({
    super.key,
    required this.title,
    required this.onSet,
    this.intro,
    this.devices = const [],
    this.unticked = const {},
    this.afterDevices,
  });

  final String title;

  /// The first lines, above the device rows.
  final String? intro;

  /// The account's other devices, each with a tick. Only the first PIN on
  /// an existing account lists them.
  final List<VaultDevice> devices;

  /// Public keys of the [devices] whose tick starts off.
  final Set<String> unticked;

  /// The line under the device rows.
  final String? afterDevices;

  /// Sets the PIN. `remove` holds the public keys of the unticked devices.
  final Future<void> Function(String pin, Set<String> remove) onSet;

  @override
  State<SetPinDialog> createState() => _SetPinDialogState();
}

class _SetPinDialogState extends State<SetPinDialog> {
  final _pin = TextEditingController();
  final _again = TextEditingController();
  late final Set<String> _unticked = {...widget.unticked};
  bool _letters = false;
  bool _working = false;
  String? _pinError;
  String? _againError;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _again.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _pin.text;
    final problem = _pinProblemWords(newPinProblem(pin));
    final mismatch = problem == null && _again.text != pin;
    setState(() {
      _pinError = problem;
      _againError = mismatch ? 'PINs do not match' : null;
      _error = null;
    });
    if (problem != null || mismatch) return;
    setState(() => _working = true);
    try {
      await widget.onSet(pin, {..._unticked});
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = accountErrorText(error);
      });
    }
  }

  Widget _field(
    TextEditingController controller,
    String label,
    String? error, {
    bool autofocus = false,
  }) => TextField(
    controller: controller,
    autofocus: autofocus,
    enabled: !_working,
    obscureText: true,
    autocorrect: false,
    enableSuggestions: false,
    maxLength: pinMaxLength,
    // The number pad unless "Use a password instead" is on, since most PINs
    // are digits. The button switches back and forth and keeps what is typed.
    keyboardType: _letters
        ? TextInputType.visiblePassword
        : TextInputType.number,
    decoration: InputDecoration(
      labelText: label,
      errorText: error,
      counterText: '',
    ),
    onChanged: (_) {
      if (_pinError == null && _againError == null) return;
      setState(() {
        _pinError = null;
        _againError = null;
      });
    },
    onSubmitted: (_) => _submit(),
  );

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_working,
      child: AlertDialog(
        scrollable: true,
        title: Text(widget.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.intro case final intro?) ...[
              Text(intro),
              const SizedBox(height: 8),
            ],
            for (final device in widget.devices)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: !_unticked.contains(device.publicKey),
                onChanged: _working
                    ? null
                    : (ticked) => setState(() {
                        if (ticked == true) {
                          _unticked.remove(device.publicKey);
                        } else {
                          _unticked.add(device.publicKey);
                        }
                      }),
                title: Text(device.name),
                subtitle: Text(
                  '${device.platform}, added ${accountDate(device.addedAt)}',
                ),
              ),
            if (widget.afterDevices case final after?) ...[
              Text(after),
              const SizedBox(height: 8),
            ],
            const Text(_lastLine),
            _field(_pin, 'PIN', _pinError, autofocus: true),
            _field(_again, 'Again', _againError),
            TextButton(
              onPressed: _working
                  ? null
                  : () => setState(() => _letters = !_letters),
              child: Text(
                _letters ? 'Use a PIN instead' : 'Use a password instead',
              ),
            ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error,
                  style: TextStyle(color: context.palette.danger),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _working ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _working ? null : _submit,
            child: Text(_working ? 'Setting' : 'Set PIN'),
          ),
        ],
      ),
    );
  }
}

Future<bool> _showSetPin(BuildContext context, SetPinDialog dialog) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => dialog,
    ) ==
    true;

// ────────── Account PIN, on a new device ──────────

/// How the PIN entry on a new device ended.
enum PinEntryResult { joined, forgot }

/// Asks a new device for the account's PIN and hands each try to [onTry].
/// Pops [PinEntryResult.joined] when the PIN opened the account and
/// [PinEntryResult.forgot] for "Forgot PIN". Every other answer stays in
/// the dialog as a line of text.
class AccountPinDialog extends StatefulWidget {
  const AccountPinDialog({super.key, required this.email, required this.onTry});

  final String email;
  final Future<JoinResult> Function(String pin) onTry;

  @override
  State<AccountPinDialog> createState() => _AccountPinDialogState();
}

class _AccountPinDialogState extends State<AccountPinDialog> {
  final _pin = TextEditingController();
  bool _working = false;
  String? _fieldError;
  String? _message;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _pin.text;
    // A string that cannot be a PIN is stopped here, so it costs no try.
    final problem = _pinProblemWords(pinShapeProblem(pin));
    setState(() {
      _fieldError = problem;
      _message = null;
    });
    if (problem != null) return;
    setState(() => _working = true);
    String message;
    try {
      final result = await widget.onTry(pin);
      if (!mounted) return;
      switch (result) {
        case Joined():
          Navigator.of(context).pop(PinEntryResult.joined);
          return;
        case JoinWrongPin(:final triesLeft):
          message = 'Wrong PIN. ${_tries(triesLeft)} left.';
        case JoinLocked(:final retryAt):
          message =
              'No tries left. Try again ${accountWhen(retryAt)}. If that '
              'was not you, open SocketAgent on a signed-in device.';
        case JoinChanged():
          message =
              'The account just changed. Open SocketAgent on a signed-in '
              'device, or use Forgot PIN.';
        case JoinNoPin():
          message =
              'The PIN has to be set again. Open SocketAgent on a signed-in '
              'device.';
        case JoinDamaged():
          message =
              'The key in Google Drive is damaged. Open SocketAgent on a '
              'signed-in device, then try again.';
      }
    } catch (error) {
      if (!mounted) return;
      message = accountErrorText(error);
    }
    setState(() {
      _working = false;
      _message = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_working,
      child: AlertDialog(
        scrollable: true,
        title: const Text('Account PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Enter the PIN for ${widget.email}.'),
            TextField(
              controller: _pin,
              autofocus: true,
              enabled: !_working,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              maxLength: pinMaxLength,
              keyboardType: TextInputType.visiblePassword,
              decoration: InputDecoration(
                labelText: 'PIN',
                errorText: _fieldError,
                counterText: '',
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (_message case final message?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  message,
                  style: TextStyle(color: context.palette.danger),
                ),
              ),
            TextButton(
              onPressed: _working
                  ? null
                  : () => Navigator.of(context).pop(PinEntryResult.forgot),
              child: const Text('Forgot PIN'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _working ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _working ? null : _submit,
            child: Text(_working ? 'Checking' : 'Continue'),
          ),
        ],
      ),
    );
  }
}

// ────────── Cannot join ──────────

/// Why a device with no account cannot join the one in Google Drive.
enum CannotJoinReason {
  forgotPin('Forgot PIN'),
  noPin('No PIN on this account'),
  damaged('Key in Google Drive is damaged'),
  severalAccounts('More than one account in Google Drive');

  const CannotJoinReason(this.title);

  final String title;

  static CannotJoinReason forStop(SignInStop stop) => switch (stop) {
    SignInStop.noPin => noPin,
    SignInStop.damaged => damaged,
    SignInStop.severalAccounts => severalAccounts,
  };
}

/// Says why this device cannot join and what else works. Resolves true for
/// "Start over".
Future<bool> showCannotJoinDialog(
  BuildContext context,
  CannotJoinReason reason,
) async {
  final startOver = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Text(reason.title),
      content: Text(
        [
          if (reason == CannotJoinReason.noPin) ...[
            'This account has no PIN yet, so a new device cannot join.',
            'If you already set a PIN, do not start over. Open SocketAgent '
                'on a signed-in device.',
          ],
          'On a signed-in device, update SocketAgent and set a PIN in '
              'Settings, Account.',
          'Or use Restore with recovery key.',
          'Or start over with a new empty account and pair your computers '
              'again.',
        ].join('\n\n'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Start over'),
        ),
      ],
    ),
  );
  return startOver == true;
}

// ────────── Signing in ──────────

/// Signs in with Google and carries the sign-in through to an account. A
/// device that holds an account only links the session. A device with none
/// makes the first account, types the PIN of the one in Drive, or is told
/// why it cannot join. Backing out of any dialog signs out of Google and
/// makes nothing. Throws what [AccountService.signInWithGoogle] throws.
Future<void> signInToAccount(
  BuildContext context,
  AccountService account,
) async {
  final decision = await account.signInWithGoogle();
  if (decision == null) return;
  final done =
      context.mounted && await _finishSignIn(context, account, decision);
  if (!done) await account.cancelSignIn();
}

Future<bool> _finishSignIn(
  BuildContext context,
  AccountService account,
  SignInDecision decision,
) => switch (decision) {
  FirstAccount() => _firstAccount(context, account),
  JoinAccount() => _join(context, account),
  SignInStopped(:final reason) => _startOver(
    context,
    account,
    CannotJoinReason.forStop(reason),
  ),
};

Future<bool> _firstAccount(
  BuildContext context,
  AccountService account, {
  bool startOver = false,
}) {
  final email = account.signInEmail ?? 'this Google account';
  return _showSetPin(
    context,
    SetPinDialog(
      title: 'Set account PIN',
      intro: startOver
          ? 'This makes a new empty account for $email. You enter the PIN '
                'when you sign in on a new device.'
          : 'No account found for $email. This makes a new one. You enter '
                'the PIN when you sign in on a new device.',
      onSet: (pin, _) => account.createAccount(pin, startOver: startOver),
    ),
  );
}

Future<bool> _join(BuildContext context, AccountService account) async {
  final result = await showDialog<PinEntryResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AccountPinDialog(
      email: account.signInEmail ?? 'this Google account',
      onTry: account.joinWithPin,
    ),
  );
  if (result == PinEntryResult.joined) return true;
  if (result != PinEntryResult.forgot || !context.mounted) return false;
  return _startOver(context, account, CannotJoinReason.forgotPin);
}

Future<bool> _startOver(
  BuildContext context,
  AccountService account,
  CannotJoinReason reason,
) async {
  if (!await showCannotJoinDialog(context, reason)) return false;
  if (!context.mounted) return false;
  return _firstAccount(context, account, startOver: true);
}

// ────────── The first PIN and Set new PIN ──────────

/// The first PIN on an account that has none. Lists the account's other
/// devices with a tick each, [untick] off, and removes the unticked ones
/// with the change. Resolves true once the PIN is set.
Future<bool> setFirstAccountPin(
  BuildContext context,
  AccountService account, {
  String? untick,
}) {
  final others = [
    for (final device in account.devices)
      if (device.publicKey != account.devicePublicKey) device,
  ];
  return _showSetPin(
    context,
    SetPinDialog(
      title: 'Set account PIN',
      intro: others.isEmpty
          ? null
          : 'Devices on this account. Untick any you do not know.',
      devices: others,
      unticked: {?untick},
      afterDevices:
          'Devices that have not updated SocketAgent are signed out until '
          'they do. Your old recovery key stops working.',
      onSet: (pin, remove) => account.setFirstPin(pin, remove: remove),
    ),
  );
}

/// Set new PIN: a changed PIN, a forgotten one, and "PIN must be set
/// again". It does not ask for the old PIN, so it sits behind the device
/// unlock on Android and a confirm dialog elsewhere. Resolves true once
/// the PIN is set.
Future<bool> setNewAccountPin(
  BuildContext context,
  AccountService account,
) async {
  if (!await _confirmNewPin(context) || !context.mounted) return false;
  return _showSetPin(
    context,
    SetPinDialog(
      title: 'Set new PIN',
      intro: 'Replaces the PIN on every device.',
      onSet: (pin, _) => account.setNewPin(pin),
    ),
  );
}

/// Checks that the person setting a PIN without the old one is the
/// device's owner, as "Show recovery key" does.
Future<bool> _confirmNewPin(BuildContext context) async {
  const unlock = DeviceUnlock();
  if (unlock.isSupported) {
    return unlock.confirm(
      title: 'Set new PIN',
      description: 'Unlock to set a new SocketAgent account PIN.',
    );
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Set new PIN?'),
      content: const Text(
        'This replaces the account PIN without asking for the old one.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  return ok == true;
}

// ────────── Remove device ──────────

/// What the user chose for a device in the list.
enum DeviceRemoval { forget, remove, removeAndSetNewPin }

/// Asks what to do with [device]. Four buttons do not fit one dialog on a
/// phone, so on an account with a PIN ([hasPin]) "Remove" leads to a second
/// dialog that asks whether to set a new PIN too. [canRemove] is false
/// without a Google session, which Remove needs.
Future<DeviceRemoval?> showRemoveDeviceDialog(
  BuildContext context, {
  required VaultDevice device,
  required bool canRemove,
  required bool hasPin,
}) async {
  final choice = await showDialog<DeviceRemoval>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Text('Remove ${device.name}?'),
      content: Text(
        'Forget is for a device whose app is gone, such as after a '
        'reinstall. It drops ${device.name} from the account and your '
        'computers.\n\n'
        'Remove is for a lost device or one someone else has. It also '
        'gives the account a new key and every computer a new pairing '
        'token.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(DeviceRemoval.forget),
          child: const Text('Forget'),
        ),
        FilledButton(
          onPressed: canRemove
              ? () => Navigator.of(ctx).pop(DeviceRemoval.remove)
              : null,
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (choice != DeviceRemoval.remove || !hasPin || !context.mounted) {
    return choice;
  }
  return showDialog<DeviceRemoval>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Set a new PIN too?'),
      content: Text(
        'If whoever has ${device.name} may know your PIN, set a new one.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(DeviceRemoval.remove),
          child: const Text('Keep PIN'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(ctx).pop(DeviceRemoval.removeAndSetNewPin),
          child: const Text('Set new PIN'),
        ),
      ],
    ),
  );
}

/// Asks about [device] and does what the user chose. Forget drops it from
/// the device list. Remove gives the account a new key. On an account with
/// no PIN, Remove opens the first-PIN dialog with [device] unticked,
/// because that change removes it too. Throws [StateError] with a message
/// to show when Forget or Remove fails.
Future<void> removeAccountDevice(
  BuildContext context,
  AccountService account,
  VaultDevice device,
) async {
  final hasPin = account.pinState != AccountPinState.none;
  final choice = await showRemoveDeviceDialog(
    context,
    device: device,
    canRemove: account.signedInWithGoogle,
    hasPin: hasPin,
  );
  switch (choice) {
    case null:
      return;
    case DeviceRemoval.forget:
      await account.forgetDevice(device.publicKey);
    case DeviceRemoval.remove when !hasPin:
      if (!context.mounted) return;
      await setFirstAccountPin(context, account, untick: device.publicKey);
    case DeviceRemoval.remove:
      await account.removeDevice(device.publicKey);
    case DeviceRemoval.removeAndSetNewPin:
      if (!context.mounted) return;
      if (!await _confirmNewPin(context) || !context.mounted) return;
      await _showSetPin(
        context,
        SetPinDialog(
          title: 'Set new PIN',
          intro: 'Removes ${device.name} and sets a new PIN.',
          onSet: (pin, _) =>
              account.removeDevice(device.publicKey, newPin: pin),
        ),
      );
  }
}

// ────────── Notices ──────────

/// What the user answered to a notice.
enum PinNoticeChoice { itWasMe, setNewPin }

Future<PinNoticeChoice?> _showNotice(
  BuildContext context, {
  required String title,
  required String text,
}) => showDialog<PinNoticeChoice>(
  context: context,
  barrierDismissible: false,
  builder: (ctx) => AlertDialog(
    scrollable: true,
    title: Text(title),
    content: Text(text),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(ctx).pop(PinNoticeChoice.itWasMe),
        child: const Text('It was me'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(ctx).pop(PinNoticeChoice.setNewPin),
        child: const Text('Set new PIN'),
      ),
    ],
  ),
);

/// Someone got the PIN wrong on a new device [count] times since this
/// device last said so.
Future<PinNoticeChoice?> showWrongTriesDialog(
  BuildContext context, {
  required int count,
  required int lastWrongAt,
}) => _showNotice(
  context,
  title: count == 1 ? '1 wrong PIN try' : '$count wrong PIN tries',
  text:
      'Someone tried the account PIN on a new device and got it wrong, last '
      '${accountWhen(lastWrongAt)}. If that was not you, change your Google '
      'password and set a new PIN.',
);

/// The account has a PIN this device did not know. [deviceName] is what
/// the vault says set it, or null when it names no device in the list.
/// [setAt] is the relay's time for the PIN, or null when it gave none, and
/// then the notice prints no date.
Future<PinNoticeChoice?> showNewPinDialog(
  BuildContext context, {
  required int? setAt,
  required String? deviceName,
}) => _showNotice(
  context,
  title: 'New account PIN',
  text:
      'The account PIN changed${setAt == null ? '' : ' on ${accountDate(setAt)}'}. '
      '${deviceName == null ? 'The account does not say which device did it.' : 'The account says $deviceName did it.'} '
      'If that was not you, remove any device you do not know and set a new '
      'PIN.',
);

/// Shows the account's one-time prompt and its two notices over [child],
/// each once: when the app opens, and whenever a sync brings one. Sits
/// below the app's navigator.
class AccountPromptHost extends StatefulWidget {
  const AccountPromptHost({
    super.key,
    required this.account,
    required this.child,
  });

  final AccountService account;
  final Widget child;

  @override
  State<AccountPromptHost> createState() => _AccountPromptHostState();
}

class _AccountPromptHostState extends State<AccountPromptHost> {
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    widget.account.addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    widget.account.removeListener(_check);
    super.dispose();
  }

  /// Shows the first thing that is due. The account notifies in the middle
  /// of builds and syncs, so the dialog opens on the next frame.
  void _check() {
    final account = widget.account;
    if (_showing || !mounted) return;
    if (account.wrongTriesNotice == null &&
        account.newPinNotice == null &&
        !account.shouldAskForPin) {
      return;
    }
    _showing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (mounted) await _show(account);
      } finally {
        _showing = false;
      }
      _check();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _show(AccountService account) async {
    if (account.wrongTriesNotice case (:final count, :final lastWrongAt)) {
      final choice = await showWrongTriesDialog(
        context,
        count: count,
        lastWrongAt: lastWrongAt,
      );
      // "It was me" gives a new device its tries back.
      await account.acknowledgeWrongTries(
        reset: choice == PinNoticeChoice.itWasMe,
      );
      if (choice == PinNoticeChoice.setNewPin && mounted) {
        await setNewAccountPin(context, account);
      }
    } else if (account.newPinNotice case (:final setAt, :final deviceName)) {
      final choice = await showNewPinDialog(
        context,
        setAt: setAt,
        deviceName: deviceName,
      );
      await account.acknowledgeNewPin();
      if (choice == PinNoticeChoice.setNewPin && mounted) {
        await setNewAccountPin(context, account);
      }
    } else if (account.shouldAskForPin) {
      final set = await showPinPromptDialog(context);
      // Asked once, whatever the answer. "Later" changes nothing else.
      await account.markPinAsked();
      if (set && mounted) await setFirstAccountPin(context, account);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
