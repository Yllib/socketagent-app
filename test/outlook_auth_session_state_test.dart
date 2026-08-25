import 'dart:convert';

import 'package:app/services/outlook_auth_session_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses Android and iOS JavaScript result shapes', () {
    const payload = {'interactiveSignIn': true, 'signingOut': false};

    expect(
      OutlookAuthPageProbe.parse(jsonEncode(payload)).interactiveSignIn,
      isTrue,
    );
    expect(
      OutlookAuthPageProbe.parse(
        jsonEncode(jsonEncode(payload)),
      ).interactiveSignIn,
      isTrue,
    );
  });

  test('resets only after the browser proves sign-in is no longer valid', () {
    const interactive = OutlookAuthPageProbe(
      interactiveSignIn: true,
      signingOut: false,
    );
    const signedOut = OutlookAuthPageProbe(
      interactiveSignIn: false,
      signingOut: true,
    );
    const valid = OutlookAuthPageProbe(
      interactiveSignIn: false,
      signingOut: false,
    );

    expect(
      shouldResetExpiredOutlookBrowserState(
        pageIsApprovedMailbox: false,
        pageUrlIsSignOut: false,
        resetAttempted: false,
        probe: interactive,
      ),
      isTrue,
    );
    expect(
      shouldResetExpiredOutlookBrowserState(
        pageIsApprovedMailbox: false,
        pageUrlIsSignOut: true,
        resetAttempted: false,
        probe: signedOut,
      ),
      isTrue,
    );
    expect(
      shouldResetExpiredOutlookBrowserState(
        pageIsApprovedMailbox: false,
        pageUrlIsSignOut: false,
        resetAttempted: false,
        probe: valid,
      ),
      isFalse,
    );
    expect(
      shouldResetExpiredOutlookBrowserState(
        pageIsApprovedMailbox: true,
        pageUrlIsSignOut: false,
        resetAttempted: false,
        probe: interactive,
      ),
      isFalse,
    );
    expect(
      shouldResetExpiredOutlookBrowserState(
        pageIsApprovedMailbox: true,
        pageUrlIsSignOut: true,
        resetAttempted: false,
        probe: signedOut,
      ),
      isTrue,
    );
    expect(
      shouldResetExpiredOutlookBrowserState(
        pageIsApprovedMailbox: false,
        pageUrlIsSignOut: false,
        resetAttempted: true,
        probe: interactive,
      ),
      isFalse,
    );
  });

  test('recognizes common Outlook and Microsoft sign-out paths', () {
    expect(
      isOutlookSignOutUri(Uri.parse('https://mail.test/owa/logoff.owa')),
      isTrue,
    );
    expect(
      isOutlookSignOutUri(
        Uri.parse('https://login.microsoftonline.com/common/oauth2/logout'),
      ),
      isTrue,
    );
    expect(
      isOutlookSignOutUri(Uri.parse('https://mail.test/mail/inbox')),
      isFalse,
    );
  });
}
