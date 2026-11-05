# iOS

The iOS app is built on the Mac with Flutter 3.47.6, the same version as
Android and Windows. Every iOS command needs the iOS distribution define;
without it the app stops at startup with a StateError that says so.

```sh
flutter run --dart-define=SOCKETAGENT_DISTRIBUTION=ios
flutter build ipa --release --dart-define=SOCKETAGENT_DISTRIBUTION=ios
```

Signing is automatic: team `ULPR2WMWUG`, bundle ID `com.socketagent.app`.
Plugins come from CocoaPods (`pubspec.yaml` turns Swift Package Manager off).

## App Store IPA

`scripts/build-ios-ipa.sh` archives and exports `build/ios/ipa/SocketAgent.ipa`
with an App Store Connect API key, read from `ASC_KEY_ID`, `ASC_ISSUER_ID` and
`ASC_KEY_PATH`. The export signs manually (`ios/ExportOptions.plist`) with the
Apple Distribution certificate and the "SocketAgent App Store" profile, which
must be installed in Xcode. Automatic export does not work with this key: it
asks for cloud-managed distribution certificates, which the key may not use.

## What differs from Android

- Dictation uses Apple speech recognition through `speech_to_text`. There
  are no speech models to download.
- No assistant button, auth code overlay, APK or Play updates, or device
  credential prompt.
- No IBS or Outlook sign-in.
- Downloads go to the app's Documents folder, which the Files app shows.
- Push is off until the app has a `GoogleService-Info.plist`; Firebase is
  never initialized on iOS.
- Google sign-in reports "not set up" until there is an iOS OAuth client.
