# SocketAgent Google Play release checklist

Updated August 29, 2026.

## Ready locally

- Play and direct distributions use package `com.socketagent.app` and target API 36.
- The Play distribution is signed with certificate SHA-256 `ffce847792875fd4e48ef57ce70171fb3a674b4ccb11666bc24daf8a31ff9bc9`.
- The Play distribution excludes self-updating, package-install, exact-alarm, and display-over-other-apps permissions.
- Google Play Billing is used for new Play subscriptions. Owner access and existing signed Stripe subscriber tokens remain supported by the relay.
- Users can report an AI response with explicit consent and a selected reason.
- A SocketAgent-specific privacy policy is prepared in HTML and Markdown.
- App icon and feature graphic meet Play's required dimensions.
- Four 1080 × 2400 phone screenshots are prepared in `play-store/screenshots/`.
- Store listing copy is recorded in `play-store/listing.md` and saved as a Play Console draft.
- Play bundle `1.0.246+248` is built at `build/app/outputs/bundle/playRelease/app-play-release.aab`.
- Bundle SHA-256: `b36be9e08144a4c0f0a39edf9888708a36264d341c6e3e1a43b41ce3b6e13666`.
- The corrected Play APK was verified on a clean Android emulator. Startup requests notification permission only and no longer opens an exact-alarm settings screen.
- The SocketAgent privacy policy is live at `https://rubanoenterprises.com/socketagent/privacy.html`.
- A dedicated review entitlement and isolated deterministic review server are live. They expose no publisher files, personal sessions, credentials, or paid AI account.
- Reusable review steps are recorded in `play-store/reviewer-access.md`; the credentials are kept outside the repository.
- All 338 Flutter tests pass. Server tests pass 311 of 311. Relay tests pass 14 of 14.

## Play Console already complete

- App package claimed.
- Play App Signing configured with the existing upload key.
- Ads declaration.
- Content rating questionnaire, rated 3+.
- Government-app declaration.
- Financial-features declaration.
- Health declaration.
- App category and contact details.
- Draft Data Safety answers for email address, purchase history, reported AI response content, and device identifiers.
- App icon and feature graphic uploaded.

## Required before review

1. Add the live privacy-policy URL in Play Console.
2. Complete App access with the reusable reviewer instructions and private credentials.
3. Set the target audience to adults 18 and older.
4. Submit the completed Data Safety questionnaire.
5. Upload the four prepared phone screenshots.
6. Replace the stale internal-testing bundle `1.0.245+247` with the current `1.0.246+248` bundle.
7. Create and select a SocketAgent-specific internal tester list, then roll out the internal release.
8. Verify the Play subscription product, base plan, price, grace period, and account-hold settings before production.
9. Review the pre-launch report and resolve any policy or device failures before a production rollout.

Production submission and rollout remain separate explicit actions.
