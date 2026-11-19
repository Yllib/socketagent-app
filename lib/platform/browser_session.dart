import 'browser_session_native.dart'
    if (dart.library.js_interop) 'browser_session_web.dart'
    as impl;

/// What the web app keeps in the browser, and for how long. Native builds
/// keep everything and these do nothing.
///
/// A browser forgets the account after [idleLimit] unused. One told not to
/// remember keeps its keys in session storage and wipes everything else when
/// a new browser session opens it, so closing the browser signs it out.
abstract final class BrowserSession {
  static const idleLimit = Duration(days: 30);

  /// Call first in main(), before anything reads storage.
  static void start() => impl.start(idleLimit);

  /// False when the user chose "Don't remember this browser".
  static bool get remember => impl.remember();

  /// Wipes what the app stored, saves the choice and reloads the page.
  /// Offered only before sign-in, when there is nothing to lose.
  static void setRemember(bool value) => impl.setRemember(value);
}
