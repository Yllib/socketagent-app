#!/bin/sh
# Builds a signed App Store Connect IPA in build/ios/ipa.
# Signs with an App Store Connect API key instead of Xcode's account:
#   ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (path to the .p8 file).
set -eu

: "${ASC_KEY_ID:?Set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?Set ASC_KEY_PATH}"

cd "$(dirname "$0")/.."
archive=build/ios/archive/Runner.xcarchive

# Writes the release Generated.xcconfig, including the iOS distribution define.
flutter build ios --config-only --release \
  --dart-define=SOCKETAGENT_DISTRIBUTION=ios

xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -destination generic/platform=iOS \
  -archivePath "$archive" archive \
  -allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"

rm -f build/ios/ipa/*.ipa
xcodebuild -exportArchive -archivePath "$archive" \
  -exportOptionsPlist ios/ExportOptions.plist -exportPath build/ios/ipa \
  -allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"

ls -l build/ios/ipa/*.ipa
