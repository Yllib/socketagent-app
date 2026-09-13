# Windows desktop installer

Build from the server checkout with `./build-app.sh --windows`. The build script runs desktop checks, creates the Flutter release bundle, packages the current Windows server setup helpers, and compiles Inno Setup. It produces `build/windows/packages/SocketAgent-Desktop-Setup.exe` and the existing portable ZIP in the app checkout. It does not publish either repository.

The installer is per Windows user. The default desktop directory remains `%LOCALAPPDATA%\SocketAgentDesktop`, so it can upgrade the earlier ZIP installation. Users can choose another location. Setup creates a Start menu shortcut, offers a desktop shortcut, and registers an uninstaller in Windows Settings.

## Local server step

Discovery reads the current user's installation marker, owned SocketAgent/SocketClaude startup tasks, and default installation folders. It checks the server package, configuration, pairing public key, and authenticated loopback readiness. Old servers use the authenticated restart-status endpoint if the newer health endpoint returns 404. Credentials are never included in discovery results or installer logs.

- Running: explain that the app will link automatically.
- Stopped: offer to start the existing server, initially unchecked.
- Missing: offer to install the free server, initially unchecked, with a separate server folder picker.
- Incomplete or inaccessible: explain that setup could not verify the server and allow desktop installation to continue.

Optional server setup runs after the desktop files are installed. It rechecks discovery to avoid creating a second server, rejects overlapping app/server folders, and reuses the Windows server bootstrap. Setup displays progress without recording pairing QR contents or generated tokens. Failures offer Retry or Continue without server. Agent sign-in happens afterward in the app.

The installer bundles only a fixed allowlist of Windows setup helpers from the server working checkout. It clones the server core from the normal configured repository and applies those setup helpers before installation. No `.env`, account credentials, private plugins, session data, or pairing keys are packaged. Standalone bootstrap behavior is unchanged when `SOCKETAGENT_INSTALLER_SUPPORT` is unset. Future server auto-updates continue to follow the server's existing update policy.

Upgrades ask the running desktop client to quit using its explicit native quit message. Uninstall removes the installed desktop files and shortcuts. It leaves the separate server, its startup task, pairing data, sessions, and desktop preferences intact.

The Windows profile directory is `%APPDATA%\Rubano Enterprises, LLC\SocketAgent`.
Both `path_provider_windows` and `flutter_secure_storage_windows` derive it from
the executable's `CompanyName` and `ProductName` resources. Keep those resources
fixed, including when changing branding. Use `FileDescription`, window titles,
shortcuts, and installer labels for the display name "SocketAgent Desktop".
The Windows build checks the compiled executable's storage identity before
packaging it. Upgrade validation must also compare existing profile files before
and after installation and verify saved computers and pins after launching.

## Automated installation

`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` installs the desktop without starting the app. A local server is never installed or started implicitly in silent mode.

- `/DIR="C:\Apps\SocketAgent"` chooses the desktop directory.
- `/SERVER=install /SERVERDIR="C:\Servers\SocketAgent"` explicitly requests optional server installation when none is found.
- `/SERVER=start` explicitly requests starting an existing stopped server.
- `/SERVER=none` leaves stopped/missing servers alone.

Silent setup can succeed even if optional server setup fails, because desktop installation is independent. Automation requesting a server should check authenticated readiness afterward. For lab runs, the existing server bootstrap environment overrides support a candidate repository and disabled auto-updates.

## Validation

The installer discovery tests run as part of installer compilation. Desktop Flutter tests run through the Windows build script. VM validation covers actual compiled installer behavior; see the evidence directory and validation notes for the tested build.
