import 'dart:async';
import 'dart:io';

import 'package:app/config/app_theme.dart';
import 'package:app/models/account_vault.dart';
import 'package:app/screens/settings/account_pin_dialogs.dart';
import 'package:app/screens/settings/account_screen.dart';
import 'package:app/services/account_key_file.dart';
import 'package:app/services/account_pin.dart';
import 'package:app/services/account_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_fakes.dart';

// The account PIN's dialogs: the words each one shows and what each button
// does. Where a dialog leads to an account change, the change runs against
// the fake relay and Drive of the account tests.

const _lastLine =
    'If you forget the PIN, a signed-in device can set a new one. With none, '
    'only the recovery key works. Write it down.';

/// Pumps an empty screen and returns a context under the navigator.
/// [host] puts the prompt host for that account on the screen.
Future<BuildContext> _pump(
  WidgetTester tester, {
  Size size = const Size(412, 915),
  AccountService? host,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late BuildContext context;
  final body = Builder(
    builder: (ctx) {
      context = ctx;
      return const SizedBox.expand();
    },
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(),
      home: Scaffold(
        // A new account object gets a new host.
        body: host == null
            ? body
            : AccountPromptHost(
                key: ObjectKey(host),
                account: host,
                child: body,
              ),
      ),
    ),
  );
  return context;
}

/// Roboto from the Flutter cache, so text is as wide as on a device. The
/// test font's glyphs are squares.
Future<void> _loadRoboto() async {
  final home = Platform.environment['HOME'] ?? '';
  final dir = '$home/flutter/bin/cache/artifacts/material_fonts';
  Future<ByteData> bytes(String name) async =>
      ByteData.sublistView(await File('$dir/$name').readAsBytes());
  final roboto = FontLoader('Roboto')
    ..addFont(bytes('Roboto-Regular.ttf'))
    ..addFont(bytes('Roboto-Medium.ttf'))
    ..addFont(bytes('Roboto-Bold.ttf'));
  await roboto.load();
}

Finder _field(String label) => find.widgetWithText(TextField, label);

Finder _button(String label) => find.widgetWithText(FilledButton, label);

Future<void> _typePin(WidgetTester tester, String pin, {String? again}) async {
  await tester.enterText(_field('PIN'), pin);
  await tester.enterText(_field('Again'), again ?? pin);
}

/// Whether every one of [labels] sits on the same row.
bool _oneRow(WidgetTester tester, List<String> labels) =>
    {
      for (final label in labels) tester.getCenter(find.text(label)).dy,
    }.length ==
    1;

void main() {
  group('the first-run prompt', () {
    testWidgets('shows once after a sync, and Later changes nothing', (
      tester,
    ) async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      final b = Device('Laptop', cloud);
      final keys = await plantPlainAccount(cloud, [a, b]);
      await _pump(tester, host: a.service);
      await tester.pumpAndSettle();
      // Not before this run has synced the account.
      expect(find.text('Protect your account with a PIN'), findsNothing);

      await a.sync();
      await tester.pumpAndSettle();
      expect(find.text('Protect your account with a PIN'), findsOneWidget);
      expect(
        find.text(
          'Your saved computers are stored with your Google account. A PIN '
          'keeps them locked if someone gets into it. You only enter it '
          'when you sign in on a new device.',
        ),
        findsOneWidget,
      );
      expect(_button('Set PIN'), findsOneWidget);
      final relay = [...cloud.relayLog];
      final drive = [...cloud.driveLog];
      final files = {...cloud.driveFiles};
      final vault = cloud.accounts[keys.accountId]!.ciphertext;

      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(cloud.relayLog, relay);
      expect(cloud.driveLog, drive);
      expect(cloud.driveFiles, files);
      expect(a.service.accountId, keys.accountId);
      expect(a.service.pinState, AccountPinState.none);
      expect(a.service.pending, isNull);

      // It syncs as before and is not asked again, in this run or the next.
      expect(await a.sync(), AccountSyncOutcome.synced);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(cloud.accounts[keys.accountId]!.ciphertext, vault);
      await a.restart();
      await _pump(tester, host: a.service);
      expect(await a.sync(), AccountSyncOutcome.synced);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      // The other device has not been asked yet.
      expect(b.service.shouldAskForPin, isFalse);
      await b.sync();
      expect(b.service.shouldAskForPin, isTrue);
    });

    testWidgets('Set PIN opens the dialog with the device ticks', (
      tester,
    ) async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      final b = Device('Laptop', cloud, platform: 'windows');
      final c = Device('Tablet', cloud);
      final keys = await plantPlainAccount(cloud, [a, b, c]);
      await _pump(tester, host: a.service);
      await a.sync();
      await tester.pumpAndSettle();

      await tester.tap(_button('Set PIN'));
      await tester.pumpAndSettle();
      expect(find.text('Set account PIN'), findsOneWidget);
      expect(
        find.text('Devices on this account. Untick any you do not know.'),
        findsOneWidget,
      );
      final added = accountDate(cloud.now);
      expect(find.text('Laptop'), findsOneWidget);
      expect(find.text('windows, added $added'), findsOneWidget);
      expect(find.text('Tablet'), findsOneWidget);
      expect(find.text('android, added $added'), findsOneWidget);
      // This device is not in the list.
      expect(find.text('Pixel'), findsNothing);
      expect(
        find.text(
          'Devices that have not updated SocketAgent are signed out until '
          'they do. Your old recovery key stops working.',
        ),
        findsOneWidget,
      );
      expect(find.text(_lastLine), findsOneWidget);
      expect(
        tester.widgetList<Checkbox>(find.byType(Checkbox)).map((c) => c.value),
        [true, true],
      );

      await tester.tap(find.text('Tablet'));
      await _typePin(tester, goodPin);
      await tester.tap(_button('Set PIN'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(a.service.pinState, AccountPinState.set);
      expect(a.service.accountId, isNot(keys.accountId));
      expect(a.service.devices.map((device) => device.name).toSet(), {
        'Pixel',
        'Laptop',
      });
      expect(a.removedKeys, [c.publicKey]);
      expect(await b.sync(), AccountSyncOutcome.synced);
      expect(b.service.accountId, a.service.accountId);
      expect(await c.sync(), AccountSyncOutcome.noAccount);
    });
  });

  group('Set PIN', () {
    Future<List<String>> open(
      WidgetTester tester, {
      Future<void> Function(String pin)? onSet,
    }) async {
      final context = await _pump(tester);
      final set = <String>[];
      unawaited(
        showDialog<bool>(
          context: context,
          builder: (_) => SetPinDialog(
            title: 'Set new PIN',
            intro: 'Replaces the PIN on every device.',
            onSet: (pin, _) async {
              set.add(pin);
              await onSet?.call(pin);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      return set;
    }

    testWidgets('refuses a PIN with the reason under the field', (
      tester,
    ) async {
      final set = await open(tester);
      expect(find.text('Set new PIN'), findsOneWidget);
      expect(find.text('Replaces the PIN on every device.'), findsOneWidget);
      expect(find.text(_lastLine), findsOneWidget);

      for (final (pin, again, words) in [
        ('12345', '12345', 'At least 6 characters'),
        ('123456', '123456', 'Too easy to guess'),
        (
          'pässword',
          'pässword',
          'Use English letters, digits and symbols only',
        ),
        (goodPin, otherPin, 'PINs do not match'),
      ]) {
        await _typePin(tester, pin, again: again);
        await tester.tap(_button('Set PIN'));
        await tester.pump();
        expect(find.text(words), findsOneWidget);
      }
      expect(set, isEmpty);
      // Typing clears the reason.
      await tester.enterText(_field('Again'), goodPin);
      await tester.pump();
      expect(find.text('PINs do not match'), findsNothing);
    });

    testWidgets('reads Setting while it works and closes when done', (
      tester,
    ) async {
      final working = Completer<void>();
      final set = await open(tester, onSet: (_) => working.future);
      await _typePin(tester, goodPin);
      await tester.tap(_button('Set PIN'));
      await tester.pump();

      expect(set, [goodPin]);
      expect(tester.widget<FilledButton>(_button('Setting')).onPressed, isNull);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
            .onPressed,
        isNull,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);

      working.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('stays open with the message when the change fails', (
      tester,
    ) async {
      await open(
        tester,
        onSet: (_) async =>
            throw StateError('Another device just set a new PIN.'),
      );
      await _typePin(tester, goodPin);
      await tester.tap(_button('Set PIN'));
      await tester.pumpAndSettle();
      expect(find.text('Another device just set a new PIN.'), findsOneWidget);
      expect(_button('Set PIN'), findsOneWidget);
    });

    testWidgets('has the number pad until Use letters', (tester) async {
      await open(tester);
      TextInputType? keyboard() =>
          tester.widget<TextField>(_field('PIN')).keyboardType;
      expect(keyboard(), TextInputType.number);
      await tester.tap(find.text('Use letters'));
      await tester.pump();
      expect(keyboard(), TextInputType.visiblePassword);
      expect(find.text('Use letters'), findsNothing);
    });
  });

  group('the PIN entry on a new device', () {
    Future<List<String>> open(
      WidgetTester tester,
      Future<JoinResult> Function(String pin) onTry,
    ) async {
      final context = await _pump(tester);
      final results = <String>[];
      unawaited(
        showDialog<PinEntryResult>(
          context: context,
          builder: (_) =>
              AccountPinDialog(email: 'billy@example.com', onTry: onTry),
        ).then((result) => results.add('$result')),
      );
      await tester.pumpAndSettle();
      return results;
    }

    testWidgets('says what each answer means', (tester) async {
      final retryAt = DateTime(2031, 1, 2, 3, 4).millisecondsSinceEpoch;
      final answers = <(Object, String)>[
        (const JoinWrongPin(3), 'Wrong PIN. 3 tries left.'),
        (const JoinWrongPin(1), 'Wrong PIN. 1 try left.'),
        (
          JoinLocked(retryAt),
          'No tries left. Try again on 2031-01-02 at 03:04. If that was not '
              'you, open SocketAgent on a signed-in device.',
        ),
        (
          const JoinChanged(),
          'The account just changed. Try again in a minute.',
        ),
        (
          const JoinNoPin(),
          'The PIN has to be set again. Open SocketAgent on a signed-in '
              'device.',
        ),
        (
          const JoinDamaged(),
          'The key in Google Drive is damaged. Open SocketAgent on a '
              'signed-in device, then try again.',
        ),
        (const PinStretchUnavailable(), 'This device cannot check the PIN.'),
        (StateError('Could not reach the relay'), 'Could not reach the relay'),
      ];
      var next = 0;
      final results = await open(tester, (_) async {
        final answer = answers[next].$1;
        if (answer is JoinResult) return answer;
        throw answer;
      });
      expect(find.text('Account PIN'), findsOneWidget);
      expect(find.text('Enter the PIN for billy@example.com.'), findsOneWidget);

      for (; next < answers.length; next++) {
        await tester.enterText(_field('PIN'), goodPin);
        await tester.tap(_button('Continue'));
        await tester.pumpAndSettle();
        expect(find.text(answers[next].$2), findsOneWidget);
      }
      expect(results, isEmpty);
    });

    testWidgets('reads Checking while it works, and a string that is no PIN '
        'costs no try', (tester) async {
      final working = Completer<JoinResult>();
      var tries = 0;
      final results = await open(tester, (_) {
        tries++;
        return working.future;
      });

      await tester.enterText(_field('PIN'), '123');
      await tester.tap(_button('Continue'));
      await tester.pump();
      expect(find.text('At least 6 characters'), findsOneWidget);
      expect(tries, 0);

      await tester.enterText(_field('PIN'), goodPin);
      await tester.tap(_button('Continue'));
      await tester.pump();
      expect(tries, 1);
      expect(
        tester.widget<FilledButton>(_button('Checking')).onPressed,
        isNull,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);

      working.complete(const Joined());
      await tester.pumpAndSettle();
      expect(results, ['${PinEntryResult.joined}']);
    });

    testWidgets('counts the tries down, locks, and joins with the right '
        'PIN', (tester) async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      await a.createAccount(goodPin);
      final b = Device('Laptop', cloud);
      final context = await _pump(tester);
      final signIn = signInToAccount(context, b.service);
      await tester.pumpAndSettle();
      expect(find.text('Enter the PIN for billy@example.com.'), findsOneWidget);

      await tester.enterText(_field('PIN'), otherPin);
      await tester.tap(_button('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Wrong PIN. 9 tries left.'), findsOneWidget);

      cloud.pins[a.service.accountId]!.tries = 0;
      await tester.tap(_button('Continue'));
      await tester.pumpAndSettle();
      final retry = accountWhen(cloud.pins[a.service.accountId]!.refillAt);
      expect(
        find.text(
          'No tries left. Try again $retry. If that was not you, open '
          'SocketAgent on a signed-in device.',
        ),
        findsOneWidget,
      );
      expect(b.service.hasAccount, isFalse);

      cloud.pins[a.service.accountId]!.tries = 10;
      await tester.enterText(_field('PIN'), goodPin);
      await tester.tap(_button('Continue'));
      await tester.pumpAndSettle();
      await signIn;
      expect(find.byType(AlertDialog), findsNothing);
      expect(b.service.accountId, a.service.accountId);
      expect(b.google.signOuts, 0);
    });

    testWidgets('Cancel signs out of Google and keeps nothing', (tester) async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      await a.createAccount(goodPin);
      final b = Device('Laptop', cloud);
      final context = await _pump(tester);
      final signIn = signInToAccount(context, b.service);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await signIn;
      expect(b.service.hasAccount, isFalse);
      expect(b.service.signInEmail, isNull);
      expect(b.google.signOuts, 1);
      expect(b.storage.record, isNull);
    });
  });

  group('Cannot join', () {
    const always = [
      'On a signed-in device, update SocketAgent and set a PIN in Settings, '
          'Account.',
      'Or use Restore with recovery key.',
      'Or start over with a new empty account and pair your computers again.',
    ];
    const noPin = [
      'This account has no PIN yet, so a new device cannot join.',
      'If you already set a PIN, do not start over. Open SocketAgent on a '
          'signed-in device.',
    ];

    testWidgets('has a title for each reason and the same ways on', (
      tester,
    ) async {
      final context = await _pump(tester);
      for (final (reason, title) in [
        (CannotJoinReason.forgotPin, 'Forgot PIN'),
        (CannotJoinReason.noPin, 'No PIN on this account'),
        (CannotJoinReason.damaged, 'Key in Google Drive is damaged'),
        (
          CannotJoinReason.severalAccounts,
          'More than one account in Google Drive',
        ),
      ]) {
        final answer = showCannotJoinDialog(context, reason);
        await tester.pumpAndSettle();
        expect(find.text(title), findsOneWidget);
        final lines = [
          if (reason == CannotJoinReason.noPin) ...noPin,
          ...always,
        ];
        expect(find.text(lines.join('\n\n')), findsOneWidget);
        expect(_button('Start over'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(await answer, isFalse);
      }
      expect(
        CannotJoinReason.forStop(SignInStop.noPin),
        CannotJoinReason.noPin,
      );
      expect(
        CannotJoinReason.forStop(SignInStop.damaged),
        CannotJoinReason.damaged,
      );
      expect(
        CannotJoinReason.forStop(SignInStop.severalAccounts),
        CannotJoinReason.severalAccounts,
      );
    });

    testWidgets('stops a new device on an account with no PIN, and Start '
        'over makes an empty one', (tester) async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      final plain = await plantPlainAccount(cloud, [a]);
      final vault = cloud.accounts[plain.accountId]!.ciphertext;
      final b = Device('Laptop', cloud);
      final context = await _pump(tester);
      var signIn = signInToAccount(context, b.service);
      await tester.pumpAndSettle();
      expect(find.text('No PIN on this account'), findsOneWidget);

      // Cancel makes nothing.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await signIn;
      expect(b.service.hasAccount, isFalse);
      expect(b.google.signOuts, 1);
      expect(cloud.keyFiles.single, isA<PlainKeyFile>());

      signIn = signInToAccount(context, b.service);
      await tester.pumpAndSettle();
      await tester.tap(_button('Start over'));
      await tester.pumpAndSettle();
      expect(find.text('Set account PIN'), findsOneWidget);
      expect(
        find.text(
          'This makes a new empty account for billy@example.com. You enter '
          'the PIN when you sign in on a new device.',
        ),
        findsOneWidget,
      );
      await _typePin(tester, goodPin);
      await tester.tap(_button('Set PIN'));
      await tester.pumpAndSettle();
      await signIn;

      expect(b.service.accountId, isNot(plain.accountId));
      expect(b.service.pinState, AccountPinState.set);
      expect(
        cloud.keyFiles.single,
        isA<PinKeyFile>().having(
          (file) => file.account,
          'account',
          b.service.accountId,
        ),
      );
      // The old account is still on the relay as it was.
      expect(cloud.accounts[plain.accountId]!.ciphertext, vault);
    });

    testWidgets('Forgot PIN leads here, and the first account says no '
        'account was found', (tester) async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      final context = await _pump(tester);
      var signIn = signInToAccount(context, a.service);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'No account found for billy@example.com. This makes a new one. '
          'You enter the PIN when you sign in on a new device.',
        ),
        findsOneWidget,
      );
      await _typePin(tester, goodPin);
      await tester.tap(_button('Set PIN'));
      await tester.pumpAndSettle();
      await signIn;
      expect(a.service.pinState, AccountPinState.set);

      final b = Device('Laptop', cloud);
      signIn = signInToAccount(context, b.service);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forgot PIN'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, 'Forgot PIN'), findsOneWidget);
      expect(find.text(always.join('\n\n')), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await signIn;
      expect(b.service.hasAccount, isFalse);
      expect(b.google.signOuts, 1);
      expect(cloud.pins[a.service.accountId]!.wrongTotal, 0);
    });
  });

  group('the notices', () {
    testWidgets('wrong tries show once, and It was me gives the tries back', (
      tester,
    ) async {
      final cloud = FakeCloud();
      final [a] = await pinAccount(cloud, ['Pixel']);
      final stranger = Device('Stranger', cloud);
      expect(await stranger.service.signInWithGoogle(), isA<JoinAccount>());
      await stranger.service.joinWithPin('555000');
      await stranger.service.joinWithPin('555001');
      await _pump(tester, host: a.service);
      await a.sync();
      await tester.pumpAndSettle();

      expect(find.text('2 wrong PIN tries'), findsOneWidget);
      expect(
        find.text(
          'Someone tried the account PIN on a new device and got it wrong, '
          'last ${accountWhen(cloud.now)}. If that was not you, change your '
          'Google password and set a new PIN.',
        ),
        findsOneWidget,
      );
      expect(_button('Set new PIN'), findsOneWidget);
      expect(cloud.pins[a.service.accountId]!.tries, 8);

      await tester.tap(find.text('It was me'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(cloud.relayLog.last, 'POST /api/account/pin/reset 204');
      expect(cloud.pins[a.service.accountId]!.tries, 10);
      await a.sync();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      // One more wrong try is one more notice, for that try alone.
      await stranger.service.joinWithPin('555002');
      await a.sync();
      await tester.pumpAndSettle();
      expect(find.text('1 wrong PIN try'), findsOneWidget);
    });

    testWidgets('a new PIN shows once, and Set new PIN sets one', (
      tester,
    ) async {
      final cloud = FakeCloud();
      final [a, b] = await pinAccount(cloud, ['Pixel', 'Laptop']);
      cloud.now += 5000;
      await a.service.setNewPin(otherPin);
      final theirs = a.service.vault!.pin!.id;
      await _pump(tester, host: b.service);
      await b.sync();
      await tester.pumpAndSettle();

      expect(find.text('New account PIN'), findsOneWidget);
      expect(
        find.text(
          'The account PIN changed on ${accountDate(cloud.now)}. The account '
          'says Pixel did it. If that was not you, remove any device you do '
          'not know and set a new PIN.',
        ),
        findsOneWidget,
      );
      expect(find.text('It was me'), findsOneWidget);

      await tester.tap(_button('Set new PIN'));
      await tester.pumpAndSettle();
      expect(b.service.newPinNotice, isNull);
      // Off Android a dialog asks first, since no old PIN is asked for.
      expect(find.text('Set new PIN?'), findsOneWidget);
      await tester.tap(_button('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Replaces the PIN on every device.'), findsOneWidget);
      await _typePin(tester, '602817');
      await tester.tap(_button('Set PIN'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(b.service.vault!.pin!.id, isNot(theirs));
      expect(b.service.pinState, AccountPinState.set);
      expect(b.service.newPinNotice, isNull);
    });

    testWidgets('a PIN record written again under the same id says no '
        'device', (tester) async {
      final cloud = FakeCloud();
      final [a, b] = await pinAccount(cloud, ['Pixel', 'Laptop']);
      cloud.now += 5000;
      await rewritePinUnderItsId(cloud, a);
      await _pump(tester, host: b.service);
      await b.sync();
      await tester.pumpAndSettle();

      expect(find.text('New account PIN'), findsOneWidget);
      expect(
        find.text(
          'The account PIN changed on ${accountDate(cloud.now)}. The account '
          'does not say which device did it. If that was not you, remove any '
          'device you do not know and set a new PIN.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('It was me'));
      await tester.pumpAndSettle();
      expect(b.service.newPinNotice, isNull);
    });

    testWidgets('It was me on a new PIN changes nothing', (tester) async {
      final cloud = FakeCloud();
      final [a, b] = await pinAccount(cloud, ['Pixel', 'Laptop']);
      await a.service.setNewPin(otherPin);
      await _pump(tester, host: b.service);
      await b.sync();
      await tester.pumpAndSettle();
      final relay = [...cloud.relayLog];

      await tester.tap(find.text('It was me'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(cloud.relayLog, relay);
      expect(b.service.newPinNotice, isNull);
      await b.restart();
      await _pump(tester, host: b.service);
      await b.sync();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('Remove', () {
    VaultDevice named(Device device) => device.service.devices.firstWhere(
      (entry) => entry.publicKey == device.publicKey,
    );

    testWidgets('offers Forget and Remove, then asks about the PIN', (
      tester,
    ) async {
      final context = await _pump(tester);
      const tablet = VaultDevice(
        publicKey: 'key',
        name: 'Tablet',
        platform: 'android',
        addedAt: 1,
      );
      Future<DeviceRemoval?> ask({bool canRemove = true, bool hasPin = true}) {
        return showRemoveDeviceDialog(
          context,
          device: tablet,
          canRemove: canRemove,
          hasPin: hasPin,
        );
      }

      var answer = ask();
      await tester.pumpAndSettle();
      expect(find.text('Remove Tablet?'), findsOneWidget);
      expect(
        find.text(
          'Forget is for a device whose app is gone, such as after a '
          'reinstall. It drops Tablet from the account and your computers.'
          '\n\n'
          'Remove is for a lost device or one someone else has. It also '
          'gives the account a new key and every computer a new pairing '
          'token.',
        ),
        findsOneWidget,
      );
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.text('Forget'));
      await tester.pumpAndSettle();
      expect(await answer, DeviceRemoval.forget);

      // Remove on an account with a PIN asks about the PIN next.
      for (final (button, choice) in [
        ('Keep PIN', DeviceRemoval.remove),
        ('Set new PIN', DeviceRemoval.removeAndSetNewPin),
      ]) {
        answer = ask();
        await tester.pumpAndSettle();
        await tester.tap(_button('Remove'));
        await tester.pumpAndSettle();
        expect(find.text('Set a new PIN too?'), findsOneWidget);
        expect(
          find.text('If whoever has Tablet may know your PIN, set a new one.'),
          findsOneWidget,
        );
        await tester.tap(find.text(button));
        await tester.pumpAndSettle();
        expect(await answer, choice);
      }

      // With no PIN there is nothing to ask.
      answer = ask(hasPin: false);
      await tester.pumpAndSettle();
      await tester.tap(_button('Remove'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(await answer, DeviceRemoval.remove);

      // Remove needs the Google session.
      answer = ask(canRemove: false);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(_button('Remove')).onPressed, isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await answer, isNull);
    });

    testWidgets('Keep PIN changes the key, and Set new PIN the PIN as well', (
      tester,
    ) async {
      final cloud = FakeCloud();
      final [a, b, c] = await pinAccount(cloud, ['Pixel', 'Laptop', 'Tablet']);
      final context = await _pump(tester);
      final firstAccount = a.service.accountId;
      final firstPin = a.service.vault!.pin!.id;

      var removal = removeAccountDevice(context, a.service, named(c));
      await tester.pumpAndSettle();
      await tester.tap(_button('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep PIN'));
      await tester.pumpAndSettle();
      await removal;
      expect(a.service.accountId, isNot(firstAccount));
      expect(a.service.vault!.pin!.id, firstPin);
      expect(a.removedKeys, [c.publicKey]);

      final secondAccount = a.service.accountId;
      removal = removeAccountDevice(context, a.service, named(b));
      await tester.pumpAndSettle();
      await tester.tap(_button('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(_button('Set new PIN'));
      await tester.pumpAndSettle();
      await tester.tap(_button('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Set new PIN'), findsOneWidget);
      expect(find.text('Removes Laptop and sets a new PIN.'), findsOneWidget);
      expect(find.text(_lastLine), findsOneWidget);
      await _typePin(tester, otherPin);
      await tester.tap(_button('Set PIN'));
      await tester.pumpAndSettle();
      await removal;
      expect(a.service.accountId, isNot(secondAccount));
      expect(a.service.vault!.pin!.id, isNot(firstPin));
      expect(a.removedKeys, [c.publicKey, b.publicKey]);
      expect(a.service.devices.map((device) => device.name), ['Pixel']);
    });

    testWidgets('Forget drops the device and keeps the key', (tester) async {
      final cloud = FakeCloud();
      final [a, b] = await pinAccount(cloud, ['Pixel', 'Laptop']);
      final context = await _pump(tester);
      final account = a.service.accountId;

      final removal = removeAccountDevice(context, a.service, named(b));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget'));
      await tester.pumpAndSettle();
      await removal;
      expect(a.service.accountId, account);
      expect(a.forgottenKeys, [b.publicKey]);
      expect(a.removedKeys, isEmpty);
    });

    testWidgets('on an account with no PIN opens Set PIN with that device '
        'unticked', (tester) async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      final b = Device('Laptop', cloud);
      final c = Device('Tablet', cloud);
      final keys = await plantPlainAccount(cloud, [a, b, c]);
      await a.sync();
      final context = await _pump(tester);

      final removal = removeAccountDevice(context, a.service, named(c));
      await tester.pumpAndSettle();
      await tester.tap(_button('Remove'));
      await tester.pumpAndSettle();
      expect(find.text('Set account PIN'), findsOneWidget);
      bool? ticked(String name) => tester
          .widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, name))
          .value;
      expect(ticked('Laptop'), isTrue);
      expect(ticked('Tablet'), isFalse);

      // Cancel leaves the account as it was.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await removal;
      expect(a.service.accountId, keys.accountId);
      expect(a.service.pinState, AccountPinState.none);
      expect(a.removedKeys, isEmpty);
    });
  });

  testWidgets('the buttons of each new dialog fit one row on a narrow '
      'phone', (tester) async {
    await tester.runAsync(_loadRoboto);
    final context = await _pump(tester, size: const Size(360, 640));
    const tablet = VaultDevice(
      publicKey: 'key',
      name: 'Tablet',
      platform: 'android',
      addedAt: 1,
    );
    Future<void> check(
      List<String> labels,
      Future<void> Function() open,
    ) async {
      unawaited(open());
      await tester.pumpAndSettle();
      expect(_oneRow(tester, labels), isTrue, reason: '$labels');
      Navigator.of(context, rootNavigator: true).pop();
      await tester.pumpAndSettle();
    }

    await check(['Later', 'Set PIN'], () => showPinPromptDialog(context));
    await check([
      'Cancel',
      'Start over',
    ], () => showCannotJoinDialog(context, CannotJoinReason.severalAccounts));
    await check([
      'It was me',
      'Set new PIN',
    ], () => showWrongTriesDialog(context, count: 12, lastWrongAt: 1));
    await check([
      'It was me',
      'Set new PIN',
    ], () => showNewPinDialog(context, setAt: 1, deviceName: 'Pixel'));
    await check(
      ['Cancel', 'Set PIN'],
      () => showDialog<bool>(
        context: context,
        builder: (_) => SetPinDialog(
          title: 'Set account PIN',
          intro: 'Devices on this account. Untick any you do not know.',
          devices: const [tablet],
          afterDevices:
              'Devices that have not updated SocketAgent are signed out '
              'until they do. Your old recovery key stops working.',
          onSet: (_, _) async {},
        ),
      ),
    );
    await check(
      ['Cancel', 'Continue'],
      () => showDialog<PinEntryResult>(
        context: context,
        builder: (_) => AccountPinDialog(
          email: 'billy@example.com',
          onTry: (_) async => const Joined(),
        ),
      ),
    );
    // The question after Remove. Four buttons in the first dialog would
    // take four rows at any phone width.
    unawaited(
      showRemoveDeviceDialog(
        context,
        device: tablet,
        canRemove: true,
        hasPin: true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_button('Remove'));
    await tester.pumpAndSettle();
    expect(_oneRow(tester, ['Keep PIN', 'Set new PIN']), isTrue);
  });

  test(
    'the Account PIN row says when it was set and how it was used',
    () async {
      final cloud = FakeCloud();
      final [a, b] = await pinAccount(cloud, ['Pixel', 'Laptop']);
      final day = accountDate(cloud.now);
      await a.sync();
      expect(
        accountPinSummary(a.service),
        'Set $day on Pixel. Last used $day. 0 wrong tries.',
      );

      final stranger = Device('Stranger', cloud);
      expect(await stranger.service.signInWithGoogle(), isA<JoinAccount>());
      await stranger.service.joinWithPin('555000');
      await b.sync();
      expect(
        accountPinSummary(b.service),
        'Set $day on Pixel. Last used $day. 1 wrong try.',
      );

      final alone = FakeCloud();
      final c = Device('Pixel', alone);
      await c.createAccount(goodPin);
      expect(
        accountPinSummary(c.service),
        'Set $day on Pixel. Not used yet. 0 wrong tries.',
      );

      // A relay that names no time for the PIN gets no date printed. The
      // vault's own date is whatever its writer chose.
      alone.sendsSetAt = false;
      await c.sync();
      expect(
        accountPinSummary(c.service),
        'Set on Pixel. Not used yet. 0 wrong tries.',
      );
    },
  );
}
