# Media permission removal validation

September 6, 2026. Device verification used local version 1.0.250+252.
The same changes were subsequently built as Play 1.0.251+253 and released
to internal testers at 4:37 PM Eastern. No production release was made.

Both flavors remove READ_MEDIA_IMAGES, READ_MEDIA_VIDEO, and READ_MEDIA_AUDIO
in manifest merging. Non-APK Android file opening uses the app's FileProvider
and grants the viewer read access to the selected content URI. APK installation
retains its existing permission and confirmation flow. The system picker
continues to provide selected photo attachments.

## Verification

- Nine file-opening tests pass, including photo/video/audio routing and native
  missing-file/missing-viewer errors. Targeted Flutter analysis reports no issues.
- Both canonical build-script runs succeed. Both APK manifests have no broad
  READ_MEDIA permissions and retain REQUEST_INSTALL_PACKAGES.
- Installed the local Play APK on the SocketAgentStore Android 14/API 34 emulator.
  Downloaded a generated PNG and a three-second MP4 from the isolated review
  server. Google Photos displayed the PNG and played the MP4.
- The MP4 download notification's Open file action also launches playback.
  Activity inspection confirms ACTION_VIEW, video/mp4, a FileProvider content
  URI for that download, and FLAG_GRANT_READ_URI_PERMISSION.
- Selected a benign test screenshot through Photos and confirmed it appears
  as an attachment in the prompt composer. No broad media permission was needed.
- Evidence: `evidence/media-permissions-photo-open.png`,
  `evidence/media-permissions-video-open.png`,
  `evidence/media-permissions-notification-video.png`, and
  `evidence/media-permissions-photo-attachment.png`.

Older Android versions were not exercised in this check. Legacy external-storage
permission remains capped at API 32. Play Console confirms internal release
253 is available to testers and excludes the previous permission-bearing 252.
The final AAB manifest was inspected with bundletool. Version, removed media
permissions, retained APK installation/Play Billing, and absent exact-alarm and
overlay permissions passed. Archive, signature, all three ABIs, and stripped
native libraries passed the canonical build script's verification.

## APK SHA-256

Play: `dcdfdb19b5593e13c0645e48c576a8338b7d73cfb686d0b1b9e9761d7131bce0`

Direct: `4a26aa6625f2a989b51d38d0597658c9b8d4588631387f727d3815679bf85657`

Play AAB 1.0.251+253: `08dfcd6afce62fde50ee2d92db0028e8586bc804dc0eb4c0d9a0c4831ba669b3`
