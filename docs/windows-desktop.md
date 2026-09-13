# Windows desktop preview

Build from the sibling server checkout using `./build-app.sh --windows`.
The script syncs source to the configured Windows build host, resolves packages,
analyzes Dart, runs desktop tests, and builds a release ZIP. It does not publish,
change the app version, or deploy a server. The Windows host needs Flutter 3.41+
and Visual Studio 2022 C++ build tools, including ATL and a Windows SDK.
NuGet is downloaded from Microsoft and its Authenticode signature is verified.

Extract the ZIP and launch `socketagent.exe`. The optional `.cmd` installer adds
per-user shortcuts and copies the complete bundle into LocalAppData. Runtime DLLs
are bundled; no Flutter installation is needed on a test user's computer.

## Implemented

- Native Flutter Windows runner with app branding, a custom title bar, and navigation rail.
- Tray hide/open/quit, single-instance shortcut activation, and persisted native
  window placement including maximize/restore. Windows recovers off-screen placement.
- Persistent session sidebar with saved resize width, selected-session styling,
  compact filters/search, and a bounded conversation/composer width. Narrow windows
  show one pane and retain drafts while switching back to the session list.
- Current-user local server discovery using the installer marker or legacy/default
  installation folders. Credentials come from the local installation; a pinned,
  encrypted authentication probe must succeed before adding the computer.
- Existing multi-computer connections and Android-compatible encrypted transfers.
  Import a PNG/JPEG QR image or paste the transfer text, then unlock and confirm.
- Windows secure credential storage, file dialogs, file opening, audio plugins,
  embedded WebView2 support, and capture protection on credential screens.
- Live completion notifications while the desktop client is running.
- Android push, Play billing, APK updates, overlays, and distribution checks remain
  separate from the Windows build.

## Preview limits

- QR webcam scanning, code signing, MSIX packaging, and desktop automatic
  updates are future work.
- Closing the window hides the client to its tray icon. Explicit Quit exits only
  the desktop client; it does not stop any SocketAgent server.
- Windows toast history/clearing and activation after exit need packaged-app testing.
- Embedded WebViews render above Flutter content; dialogs, menus, and nested routes
  over a WebView need further desktop UI testing before a public release.
- Speech, provider sign-in, billing, and all server tools have not yet had full
  end-to-end desktop acceptance testing.

The first desktop development build is intentionally separate from Android/Play
release artifacts. Do not publish this ZIP as an Android update.

## Validation on 2026-09-13

Built and launched on the owner's Windows desktop (i9-10900K, 64 GB RAM).
The full Flutter test suite passed: 421 tests. The final build also passed
analysis (three pre-existing informational diagnostics) and the 11 focused
desktop/configuration tests, including 12 randomized encrypted QR round trips.
Verified the real local server was discovered without typing credentials,
connected with encrypted control/bulk transports, loaded 34 sessions, and opened
an existing Codex conversation. The per-user installer created both shortcuts
and launched the installed executable successfully.

Preview ZIP SHA-256:
`454669848995bcf798764e2bc330c9ba3a15f1e3181b70d4cd05d55f8d633a8a`.


## Desktop layout pass, 2026-09-13

The full suite now passes 426 tests, including desktop pane resizing, saved width
bounds, draft retention across resizing/collapse, and session links returning to
the desktop workspace instead of stacking full-screen chats. Live desktop checks
covered two real sessions, selected-row highlighting, and switching between the
session list and conversation in an 850-pixel window. Installed the updated ZIP
on the owner's desktop. Android retains its full-screen session navigation.

Layout preview ZIP SHA-256:
`49ae1a5952f052b1eeda80d7c57ae5146d016efda6858bc735a127ad1eade5b9`.

## Relay import repair, 2026-09-13

Computer imports now restore the subscriber credential before opening new
connections, including when every computer is already listed. Import completion
refreshes the relay's subscription status. Replacing a credential clears cached
account metadata after reconfiguring existing connections, so an earlier
rejection cannot leave the replacement marked inactive during that transition.
The relay sign-up screen checks saved access and offers Windows users an import
from their phone. Import confirmation states whether relay access is included.

Validation: 432 Flutter tests passed on Windows. Regression tests cover the
credential on the first imported WebSocket connection, duplicate-only imports
after rejection, exports without subscriber credentials, inactive entitlements,
and dismissing a stale sign-up screen after a successful status check. The native
release build passed analysis with the same three existing informational items.

Relay repair ZIP SHA-256:
`00fbb59b149c127e666f329e81d8db7953990cf1a6a7c1acd1196363357c1742`.

Installed this build on the owner's desktop and verified Settings reports
"Relay access: Ready" with 12 relay computers configured and 9 computers online.
The existing imported credential was retained; no new import or purchase was
needed. Delivered the ZIP through SendFile. No repository push or public release.

## Desktop window and tray, 2026-09-13

The title bar is drawn in Flutter above the Navigator, with app menu, minimize,
maximize/restore, and hide-to-tray controls. Native hit testing preserves dragging,
double-click maximize and edge resizing. Close/Alt-F4 hides the client; explicit
Quit is available from the tray and app menus. Launching the shortcut restores
the existing process. The installer sends an explicit quit request to the exact
installed client before replacing its files.

Window placement is stored under HKCU Software/Rubano Enterprises/SocketAgent/Desktop,
using GetWindowPlacement/SetWindowPlacement rather than mixing workspace and screen
coordinates. Maximized and normal restore bounds survive quitting. See Microsoft's
[window placement documentation](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowplacement)
and [custom frame documentation](https://learn.microsoft.com/en-us/windows/win32/dwm/customframe).
Tray registration uses Shell_NotifyIcon and recovers after TaskbarCreated. A failed
tray registration falls back to minimizing, so the client cannot become inaccessible.

Dart startup waits for native channel registration, which can complete after Dart
starts executing. Live startup exposed this race; the retry has a regression test.
Ongoing desktop work/download notifications and group summaries are suppressed;
completion and instant event notifications remain enabled. Notification activation
also asks the native shell to reveal the window.

Validation: 436 Flutter tests passed on Windows, plus 18 native desktop checks.
Live checks covered native caption removal, tray registration, hit testing,
custom buttons, close-to-tray, same-process shortcut activation, explicit Quit,
normal/maximized placement restoration, and recovery of an off-screen saved window.
The installed app was left visible with its original placement restored.

Window/tray preview ZIP SHA-256:
`528318c0386188e16de2325d6a97ff097d21a16c72e03f576cbf8d2dbbb259dc`.

## Desktop input and layout polish, 2026-09-13

The conversation and composer fill the available pane. The session header gives
remaining width to the computer name and path, keeping usage at the right edge.
Windows Enter sends with the same queue priority as the send button; Shift+Enter
inserts a newline or replaces selected text. Held Enter cannot submit repeatedly,
and composing text is left to the input method.

Session actions open beneath the three-dot button or at the right-click pointer.
Thread/session tools retain that anchor. Flutter keeps these menus within the
window and supports Escape dismissal. Android retains its action sheets.

The native runner handles both NCCALCSIZE forms and suppresses stock nonclient
painting during activation and movement. Validation: 440 Flutter tests passed on
Windows. Live drags from normal and maximized states passed 34 geometry/style
assertions, with screenshots captured during movement. Live screenshots also
verified both menu entry points and full-width maximized conversation/header.

Installed preview ZIP SHA-256:
`3a8d1dc83fa2f7ea8f30e01d3cd63feeaa15296df39887a1f976bbe78f51559c`.

The conversation's More button now opens its grouped actions at the Windows
pointer, clamped inside the window. Keyboard activation anchors to the button.
The same live settings and group navigation remain available; Android keeps its
bottom sheet. All 43 focused desktop/action-menu tests passed, and the installed
client's More popup was verified on the desktop.
More-menu preview ZIP SHA-256:
`9e9b07b992adc3d0b512a675e7679cc1af39bc4514fda29ce137fb4bbe25362c`.
