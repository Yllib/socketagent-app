# APK-transfer demonstration app

A standalone Android test app for recording SocketAgent's user-initiated APK
transfer and installation. Its package is `com.rubano.socketagent.installdemo`.
It requests no permissions, performs no network requests, and displays a success
message. It is not SocketAgent and does not replace an installed SocketAgent app.

Build with `build-demo.ps1` on the Android build computer. The generated signing
key and build outputs stay outside the repository in the chosen output folder.
Only the APK is needed in the isolated review workspace.
