# Play update 254

Published to internal testing and submitted for production review on September
13, 2026, with the user's instruction to push the update to Google. The user
uses the Play build and is enrolled in internal testing; use that distribution
for their Android updates.

- Package: `com.socketagent.app`
- Version: `1.0.252+254`
- Internal testing: Console confirmed **Available to internal testers**, released
  September 13 at 2:05 PM America/New_York. Console says changes usually appear
  on Play within one hour, occasionally longer.
- Production: promoted the same bundle, replacing 253, with a 100% rollout to
  existing targeted countries. Console reported **Ready to release**, with no
  supported devices lost.
- Confirmed **Send changes for review** for exactly one change, production 254.
  Publishing overview now shows **Changes in review**. Quick checks were still
  running with up to 14 minutes remaining; successful checks proceed to review
  automatically. Managed publishing remains off.
- No listing, declarations, countries, subscriptions, or public GitHub releases
  were changed. No server deployment or Git push was performed.

## Artifact and validation

Built with `build-app.sh --flavor play --bundle`.
AAB: `build/app/outputs/bundle/playRelease/app-play-release.aab`.
SHA-256: `05f91b3f3a5dc96311659bc9e967fffcaa8ec881d9b3b34c0ef8be1ee60af047`.
Upload certificate SHA-256:
`ffce847792875fd4e48ef57ce70171fb3a674b4ccb11666bc24daf8a31ff9bc9`.

Bundletool validation, signature, archive integrity, all three ABIs, and stripped
Dart libraries passed. The canonical script handled Flutter's known native-symbol
check false failure and independently checked the bundle. Manifest inspection
confirmed build/version, Play Billing and user-initiated APK installation,
absence of READ_MEDIA permissions, exact alarms, overlays, and advertising ID.
Legacy READ_EXTERNAL_STORAGE remains capped at API 32, as in the existing app.

All 437 applicable tests passed with the Play distribution define. Six direct
updater tests are now explicitly direct-only; a store-distribution test checks
that updater controls remain absent in every update state. The direct settings
tests also passed separately. The system `socketagent-review.service` was active.

## Release notes

Usage warnings now appear at the top of the session, above the browser banner
and session controls.

## Console

https://play.google.com/console/u/0/developers/5717181024688416917/app/4975092855067454238/publishing
