import 'dart:convert';

class OutlookAuthPageProbe {
  const OutlookAuthPageProbe({
    required this.interactiveSignIn,
    required this.signingOut,
  });

  final bool interactiveSignIn;
  final bool signingOut;

  static OutlookAuthPageProbe parse(Object? raw) {
    dynamic decoded = raw;
    for (var attempt = 0; attempt < 2 && decoded is String; attempt++) {
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        break;
      }
    }
    if (decoded is! Map) {
      return const OutlookAuthPageProbe(
        interactiveSignIn: false,
        signingOut: false,
      );
    }
    return OutlookAuthPageProbe(
      interactiveSignIn: decoded['interactiveSignIn'] == true,
      signingOut: decoded['signingOut'] == true,
    );
  }
}

bool shouldResetExpiredOutlookBrowserState({
  required bool pageIsApprovedMailbox,
  required bool pageUrlIsSignOut,
  required bool resetAttempted,
  required OutlookAuthPageProbe probe,
}) {
  if (resetAttempted) return false;
  if (!pageIsApprovedMailbox) {
    return probe.interactiveSignIn || probe.signingOut;
  }
  return pageUrlIsSignOut && probe.signingOut;
}

bool isOutlookSignOutUri(Uri uri) {
  final location = '${uri.path}?${uri.query}'.toLowerCase();
  return location.contains('logout') ||
      location.contains('logoff') ||
      location.contains('signout') ||
      location.contains('wsignout');
}
