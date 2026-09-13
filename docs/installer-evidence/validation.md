# Installer validation, September 13, 2026

Build: SocketAgent 1.0.252, Inno Setup 6.7.3, Windows x64.

Final installer SHA-256: `1ff44e87b09291cdf1752f06c994bd0f8151e75f15ee9d55fa5b780a14780aca`.

- Canonical `build-app.sh --windows`: Flutter build passed, 43 desktop tests passed. Analysis completed with five existing findings.
- PowerShell discovery fixtures: missing/unrelated server, incomplete config, stopped server, custom port and quoted token, custom folder marker, legacy task/folder, invalid port, credential-free output passed.
- Node health probe: rejects unrelated responses, failed authentication, unavailable server and malformed legacy responses; accepts current and legacy authenticated readiness.
- User desktop: actual wizard detected the existing `SocketClaude` server; upgraded earlier ZIP installation, cleanly closed/relaunched the desktop client. Server PID remained 16180. No server reinstall or restart.
- Windows 11 VM: custom desktop folder installation, upgrade, and uninstall passed. Server PID and `.env` hash remained unchanged. Stopped server stayed stopped when skipped; explicit Start brought the same installation back without changing its configuration.
- Fresh Windows 10 VM: desktop-only installation passed without installing or starting a server. Optional server installation also passed as a limited interactive user, with separate desktop/server directories and the ordinary dependency elevation prompts. Git, Node.js, Claude Code, Codex, compiled server, startup task, readiness, and discovery marker were verified.

- Windows 10 GUI failure recovery: deliberately disabled the test server task. Continue without server preserved the desktop and left the server stopped. Enabling the task and choosing Retry started the existing server. Final-page text correctly reported the successful local link.
- Final artifact: reinstalled successfully after the animated progress-bar change, authenticated local readiness passed, and the server PID stayed unchanged.

The Windows 10 overlay was reset from its sealed template for the fresh-install test. The Windows 11 overlay retained its existing test server for upgrade/start tests. Golden templates were not modified. Only one lab VM runs at a time.

## Desktop naming and copy revision

The later review revision names the Windows client SocketAgent Desktop in its title bar, tray menu, splash screen, notifications, executable metadata, installer, and shortcuts. The optional-server explanation now reads: "A local server is optional. You can add other computers via their pairing codes without installing a server on this computer."

Artifact: `SocketAgent-Desktop-Setup.exe`, SHA-256 `a7f9c796d6b49ae56b80a011c52d2a02510a17a024e205a0584e5a3c22b5ea1e`. Canonical Windows build and all 43 desktop tests passed; installer helper syntax and executable product metadata were checked. This revision was copied to the user's desktop for manual setup review, without installing it for them. The VM lifecycle evidence above belongs to the earlier installer revision.

## Desktop composer and wheel scrolling

Shift+Enter now uses EditableText's replacement action, which reveals the caret on empty new lines and scrolls it into view after the field reaches its maximum height. Transcript AUTO recognizes user scroll-direction notifications from the mouse wheel as well as touch drags, and ignores nested tool-output scrolling.

Both new regression cases failed before the fix. Afterward, all 28 composer/history tests passed locally and all 69 selected desktop tests passed in the canonical Windows build. The targeted composer analysis passed. Updated installer SHA-256: `47f08135c0a981241e680583fd6d9bb0d13383eed3084227135d830ffdfdc68b`. It was copied to the user's desktop for them to install.

### Profile identity recovery, 2026-09-13

Renaming the executable ProductName to SocketAgent Desktop redirected both
preferences and encrypted credentials into a new Roaming profile. The original
SocketAgent profile remained intact. Restored the stable ProductName and added a
compiled executable identity check before Windows packaging; visible branding
remains SocketAgent Desktop. Fixed PowerShell FindWindow lookup to pass
[NullString]::Value instead of $null, which was coerced to an empty title.

- Canonical Windows build: 69 tests passed; five existing analyzer infos.
- Backed up both profiles on the user's desktop before recovery.
- Actual silent installer upgrade while the client was running: exit 0 after
  graceful quit. All nine original profile files matched their preinstall hashes.
- Relaunched installed client: 13 saved computer configurations, 14 stored pins;
  screenshot confirmed connected servers and populated pinned session list.
- Existing local server PID 16180 remained running.
- Corrected installer also copied to the user's desktop.
- Installer SHA-256: f71c84aad510246832d99d9459285a5580636a07f6f782833c036df2951d32e6.
