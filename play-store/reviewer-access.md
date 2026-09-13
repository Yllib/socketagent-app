# Google Play reviewer access

## Current status: dedicated free account with enforced command restrictions

The service is active using the review-only `contact@rubanoenterprises.com`
account. Codex reports plan `free`; its available default model is
`gpt-5.6-terra`. The personal account was logged out and its login cache removal
verified before the new account was authorized. No paid plan was added.

AppArmor blocks the Node server, app terminal, and Codex child commands from
reading or writing the review user's `.codex` directory. The trusted native
Codex process can use its login cache. File manager access is limited to the
review workspace. Public-relay tests passed for real file creation/readback,
session resume, and credential-directory denials through the file manager,
symlinks, terminal, and real Codex commands. Denial tests used a harmless canary,
not credential contents. See the server's `scripts/review-security/README.md`
for the exact profiles, verification, and native archive-indexing limitation.

SocketAgent normally connects to a companion server controlled by the user.
The Play review credentials point to a separate Linux service account and
workspace. Since September 6, the server runs real Codex, authenticated using the
dedicated account through OpenAI device login. Reviewers need only the saved pairing and
review codes, not their own computer or AI account. Provider credentials remain
on the review computer with AppArmor access restrictions. Account-connected
apps are disabled in this Codex configuration. The service cannot access the
publisher's home directory and contains no customer session history.

## Review steps

1. Open SocketAgent and choose **Connect computer**.
2. Choose **Scan pairing code**, then use the edit button to paste the pairing
   code supplied in Play Console.
3. When **Relay access** opens, choose **Play reviewer access** and enter the
   review code supplied in Play Console.
4. Save the verified computer as **SocketAgent Play Review**.
5. Start a **new Codex session**, select the default workspace, and send a message.
   Responses and tool execution are live. Try: "Create hello.txt containing
   Hello from SocketAgent, then read it back." Existing historical demo sessions
   came from the earlier simulated backend and should not be resumed for review.
6. Close and reopen the session to verify persisted history.
7. Long-press an assistant response and choose **Report response** to review the
   disclosure and reporting flow.

The review entitlement issued by the relay expires after 120 days. The review
code can be rotated without changing owner access, Google Play purchases, or
legacy Stripe subscriber access.

## APK transfer and installation

In a session, open **More > Files**. The default workspace contains
`socketagent-install-demo.apk`. Use the file menu to download it, then tap the
file and choose **Open downloaded file**. If Android requests installation
access, open Settings, enable **Allow from this source** for SocketAgent, and
return. Confirm **Install**, then **Open** to see the demo's success screen.
This is a real download and Android package installation. The test app has its
own package ID, requests no permissions, and does not access the network.

Verified September 6 on the test Android emulator using a locally built Play
flavor, with an encrypted direct connection to the hosted reviewer service.
This verification is separate from the owner's Play-installed build testing.
On September 6 at 8:27 PM Eastern, a fresh protocol client used the saved review
code at the public relay API, obtained the review entitlement, paired using the
saved server key, and established an encrypted relay connection. A real Codex
turn ran a shell command, wrote a unique marker to `review-live-check.txt`, and
read it back. Session resume and a second shell read both passed. This verifies
the public relay and live backend; it is separate from an Android UI walkthrough.

Codex CLI version: 0.153.2. Service: `socketagent-review.service`.
Simulation is disabled with `SOCKETAGENT_PLAY_REVIEW_MODE=0`.
The sign-in instructions in Play Console were updated to describe live AI,
real commands, new-session creation, and APK installation. Pairing and review
credentials were preserved. Production submission remains a separate action.
