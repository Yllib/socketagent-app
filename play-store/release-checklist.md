# SocketAgent Google Play release checklist

Updated September 6, 2026. The September 6 notes supersede the September 5 audit and archived
August 29 checklist, which contains outdated permission and release information.

## September 6 user validation and submission preparation

- The earlier credential-isolation blocker has been addressed for the tested
  paths. The personal login was removed. The service now uses the dedicated
  free review account, with enforced AppArmor restrictions separating Codex's
  login cache from the Node server, app terminal, and agent child commands.
  Public-relay coding/resume tests and canary denial tests through the file
  manager, symlinks, terminal, and live Codex all pass. The service is active.
  See `reviewer-access.md` and the server's `scripts/review-security/README.md`
  for exact scope and the native archive-indexing limitation. Monitor free
  account quota during review. Production remains unsubmitted.

- The owner reports that the Play-installed build works in their current testing.
  This is completed user validation, not an untested build. No specific unreported
  purchase-lifecycle scenario is inferred from that general confirmation.
- The earlier Android emulator failure is a test-environment issue, not an
  observed SocketAgent failure. It must not be used to discount owner testing.
- Production publication is not needed to validate the existing internal build.
- Updated full listing saved as a Play Console draft. It explicitly describes
  receiving APK builds and user-confirmed Android installation.
- Recorded and inspected actual APK transfer/install on the recovered emulator.
  The final recording is `evidence/apk-install-final.mp4`, 84.6 seconds. It uses
  a locally built Play flavor 1.0.250+252, not the Play-installed internal artifact.
- The benign test APK is present in the hosted review workspace. Signature,
  zero requested permissions, HTTP transfer hash, Android installation access,
  package confirmation, and opening the installed demo all passed.
- Fixed the hosted deterministic backend's missing-CLI availability check and
  model catalog. The model is explicitly labeled Review demo. A focused
  regression test passes; a fresh Codex session and simulated tool result
  passed on the emulator after updating only the isolated reviewer service.
- Reviewers can use the hosted test computer and private App access pairing
  credentials. They do not need their own computer. On September 6 at 8:27 PM
  Eastern, the owner authorized Codex through device login and the isolated
  service switched to real AI execution. A fresh client verified the saved
  reviewer entitlement, public relay pairing/encryption, real shell execution,
  file creation/readback, and session resume. Account-connected apps are
  disabled. Play Console sign-in instructions now describe the live backend.
  This supersedes the earlier simulated-backend limitation. An Android UI
  walkthrough of this new live configuration was not part of that protocol test.
- Advertising ID declaration saved as No on September 6. Source/dependency
  searches found no Advertising ID use or ad SDK, and the built Play APK
  manifest has no AD_ID permission. The owner confirms ads are not part of
  the current monetization plan.
- Removed broad photo/video/audio permissions from both local app flavors.
  Downloaded files now open through per-file Android URI grants. The Play APK
  passed Android 14 emulator checks for opening a downloaded PNG, playing a
  downloaded MP4, opening it from its notification, and attaching a selected
  photo. Nine file-opening tests and targeted static analysis pass. Both APK
  manifests were checked. See `media-permission-validation.md` for evidence.
  Uploaded and released Play 1.0.251+253 to internal testing on September 6
  at 4:37 PM Eastern. Console confirms Available to internal testers, with
  no loss of supported devices. The final bundle manifest also passed checks
  for removed media permissions and retained Play Billing/APK installation.
  AAB SHA-256: `08dfcd6afce62fde50ee2d92db0028e8586bc804dc0eb4c0d9a0c4831ba669b3`.
  Production remains unpublished. Server and Direct app were not deployed.
  After release, App content's Need attention tab reports "You're all caught up."
  The photo/video declaration warning has cleared.
- APK permission declaration saved in Console with the verified public video
  link. Review-video-only website deployment completed at `3884d34`.
  See `apk-install-declaration.md` for details. No production
  submission, app rollout, or public server/app repository push has occurred.

## September 5 deployment and audit

- Server 1.1.32 published on master, release commit `5776405`.
- Direct app 1.0.250+252 published as GitHub release `v1.0.250`.
- Play app 1.0.250+252 is available to internal testers. Console confirmed
  release 252 active. This is not production publication or policy approval.
- Package `com.socketagent.app`, minimum API 24, target API 36.
- Play AAB SHA-256:
  `9cdfdf5458bead624ece8ef9fab9b4e3a43466544f17704260c6fb0186070d84`.
- Bundle archive, signature, three native ABIs, and stripped native libraries
  passed validation. Google accepted it with no supported-device loss.
- Automated checks: 367 server tests, 366 app tests, 20 relay tests passed.
- Local restart recovery was tested before publication. The development server
  has auto-update disabled; publishing does not prove every server restarted.
- Play excludes self-updating, exact-alarm permission, and overlay permission.
  It intentionally retains `REQUEST_INSTALL_PACKAGES` for user-initiated APK
  installation. The August 29 description below is no longer correct.
- Play uses Google Play Billing for new subscriptions; Direct supports Stripe.
  Owner access and existing Stripe subscriptions remain supported.
- Console product `socketagent_relay` has active base plan `monthly` and active
  offer `seven-day-trial`, available in 174 regions. US monthly price is USD 4.99.
  Automatic account hold is enabled, shown as 53 days. Resubscribe is allowed.
  No billing settings changed in this audit.
- A Play test-card purchase and relay reconnection succeeded August 30. Full
  purchase restoration and lifecycle tests on build 252 remain pending.
- The privacy URL returns HTTP 200. The reporting endpoint is reachable and
  rejects invalid report IDs. Valid report storage was not exercised this time.
- Reviewer service is active. It currently returns deterministic responses and
  simulated tools, not real agent execution or APK transfer/install demonstrations.
- Console has saved listing, privacy URL, adults-only audience, Data Safety,
  content rating, ads, health, government and financial declarations, category,
  and app-access instructions. These are not production approval.
- Production is inactive. Worldwide country changes and other declarations
  remain unsubmitted. Managed publishing is off. No production submission made.

### September 5 production gates, superseded where noted above

1. Verify and complete the APK-install permissions declaration and video demo.
   Accurately and prominently describe the core APK transfer and user-initiated
   installation workflow in the listing. Current local copy only mentions file
   transfer. Eligibility is Google's decision, not guaranteed by internal testing.
   See [permission policy](https://support.google.com/googleplay/android-developer/answer/12085295)
   and [declaration instructions](https://support.google.com/googleplay/android-developer/answer/9214102).
2. Give reviewers access to the actual relevant functionality, including APK
   transfer/install, while preserving isolation from publisher files and secrets.
3. Walk through Play-installed build 252: purchase restoration, app restart,
   direct/relay connections, history, questions, browser sessions, file opening,
   notifications, and response reporting. The remote Android 14 emulator reported
   a missing package service; a fresh device walkthrough was not counted as passed.
4. Review a current pre-launch report. No passing build-252 report was verified.
5. Reconcile declarations with the final artifact, verify reviewer access end to
   end, and explicitly approve production submission and rollout.

### Next requested app UI change

Implemented locally September 5: the active browser-session strip now sits
below the model and other session-control buttons and matches the task/plan
strip styling. This was not included in the published build 252. A test APK
is being prepared; deployment remains a separate action.

The follow-up local UI revision replaces the long More popup with a bounded,
scrollable session-actions sheet. Files, Terminal, and active Browser access
are at the top; Project tools, Plans & progress, Voice & notifications, and
Session settings contain the remaining actions. Browser and Codex-plan strips
can be hidden without stopping the browser or deleting the plan, and restored
under Session settings. Visibility preferences persist per computer and session.
All 381 app tests pass; targeted static analysis is clean. This revision remains
unpublished pending user testing and deployment approval.

The next local refinement uses one shared progress-panel layout for blue Tasks
and purple Plan cards, aligning status icons, padding, row heights, typography,
and dismiss controls. Settings toggles and mode selections now update in place
without closing the session-actions sheet. All 385 app tests pass, including
exact row-alignment and repeated-toggle regression tests. Not deployed.

Hide now uses an eye-with-slash icon for Tasks, Plan, and Browser. A five-second
replacement notice explains More → Session settings and offers Cancel before
committing the hidden preference. Tasks now has its own persistent visibility
toggle there. Completed-task removal still uses × but requires confirmation;
confirmation does not remove a task that became active in the meantime.
Pending hide timers are isolated by computer/session/panel and canceled when
the session screen is disposed. This refinement is local and not deployed.

Latest local spacing fix: browser Hide is anchored at the right edge across
screen widths, the normal browser strip is 32 logical pixels tall, and Cancel
sits beside the hide-notice text. Plan/task header Hide buttons are also the
rightmost controls. Geometry and enlarged-text regression tests pass; the full
app suite passes 392 tests. Still not deployed.

Latest local control consistency update: Activity now has the same cancellable
five-second Hide flow and session-settings restore toggle as Browser, Plan,
and Tasks. Finished background jobs, agents, workflows, and completed plan
steps support confirmed Dismiss. Supported running jobs have a separate Stop
button with confirmation. Display dismissals keep history and never send stop
commands. New dismissal preferences are scoped by computer, session, panel,
and plan identity; reopened items reappear. Plan progress counts retain the
full plan even when finished steps are dismissed. Confirmation checks reject
stale session targets and items that resumed running. All 399 app tests pass,
and targeted static analysis is clean. Not deployed.

## Archived August 29 checklist

The following is historical only. Use the current audit above for release decisions.

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
