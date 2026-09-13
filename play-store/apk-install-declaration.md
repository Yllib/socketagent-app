# APK-install permission declaration

Prepared and saved in Play Console September 6, 2026. Console confirmed
"Your changes have been saved". This is not Google policy approval or a
production submission. Check against the final Play bundle before submission.

## Requested permission and use

`android.permission.REQUEST_INSTALL_PACKAGES`

Permitted-use category to select if offered: file sharing, transfer or management.

SocketAgent is a phone client for a companion server on a computer controlled by
the user. Its remote development workflow includes transferring generated files,
including Android APK builds, from that computer to the phone for testing. The
user chooses an APK attachment or workspace file, downloads it, and explicitly
opens it. SocketAgent passes that APK to Android's system installer. Android
requires the user to grant installation access for SocketAgent when necessary
and to confirm installation of the selected package.

The permission supports installing the user's transferred Android builds on the
phone as part of this development and file-transfer workflow. SocketAgent does
not install APKs silently or automatically. The Google Play distribution uses
Google Play for SocketAgent's own updates and disables its direct-download
self-update feature.

## Reviewer demonstration

Use the normal Play build and a publisher-hosted test computer. Provide reusable
pairing and relay-review credentials privately in App access. The reviewer does
not need a personal computer, a paid SocketAgent subscription, or publisher
credentials to perform the transfer/install check.

Provide a small, benign test APK with its own package ID and no sensitive
permissions. Demonstrate a real transfer and the normal Android installation
confirmation. Do not represent canned agent responses as live AI execution.

## Video shot list

1. Show SocketAgent's version and its connection to the isolated test computer.
2. Open the test workspace or a received file card containing the test APK.
3. Download the APK through SocketAgent.
4. Tap the downloaded APK to open it.
5. If Android has not granted install access, show the installation-access prompt,
   open Android's install-unknown-apps settings, and grant access for SocketAgent.
6. Return to SocketAgent and open the same APK again.
7. Show Android's package-install confirmation and choose Install.
8. Open the installed test app and show its successful-installation screen.

Record the actual screen continuously through the permission and install steps.
Keep private pairing and review codes out of a publicly accessible recording;
supply those credentials in Console App access. Publish an accessible MP4 or
unlisted video link only after inspecting the recorded file.

Final recording completed and inspected September 6:
`evidence/apk-install-final.mp4`, 84.6 seconds, 1080 x 2400.
SHA-256: `9f7e1f793ab0ce59d2c48e1095b55000498e64e79232e8f82ff10de57414f87a`.
The recording uses locally built Play flavor 1.0.250+252, not a Play Store
installation. It shows opening SocketAgent, a real workspace download, Android
installation-access settings, package confirmation, and the installed benign
application. The earlier 119.7-second recording is retained as supporting evidence.

Video URL: https://rubanoenterprises.com/socketagent/review/apk-install-demo-2026-09-06.mp4

The website deployment completed at commit `3884d34`. Public download succeeded
and its SHA-256 matches the inspected local recording.

## Listing alignment

The full listing and feature list in `listing.md` describe APK transfer and
user-initiated installation. This must match the submitted build's behavior.
There is no guarantee that a declaration alone establishes eligibility; Google
reviews whether this use is part of the app's core functionality.

## Official requirements

- https://support.google.com/googleplay/android-developer/answer/12085295
- https://support.google.com/googleplay/android-developer/answer/9214102
- https://support.google.com/googleplay/android-developer/answer/9859455

## Console values saved

- Core purpose: file sharing, transfer or management.
- Usage: App functionality.
- Feature explanation: user-initiated APK transfer from the paired computer,
  followed by Android's installation-access and per-package confirmations.
- Video: the public URL above.

The updated full listing is separately saved as a Console draft.
