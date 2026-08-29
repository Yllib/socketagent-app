# Google Play reviewer access

SocketAgent normally connects to a companion server controlled by the user. The
Play review credentials point to a separate deterministic server that contains
no publisher files, customer history, credentials, or paid AI account.

## Review steps

1. Open SocketAgent and choose **Connect computer**.
2. Choose **Scan pairing code**, then use the edit button to paste the pairing
   code supplied in Play Console.
3. When **Relay access** opens, choose **Play reviewer access** and enter the
   review code supplied in Play Console.
4. Save the verified computer as **SocketAgent Play Review**.
5. Start a session and send any message. The isolated server returns a safe,
   deterministic response. Include the word `tool`, `command`, or `file` to see
   a simulated tool call and result.
6. Close and reopen the session to verify persisted history.
7. Long-press an assistant response and choose **Report response** to review the
   disclosure and reporting flow.

The review entitlement issued by the relay expires after 120 days. The review
code can be rotated without changing owner access, Google Play purchases, or
legacy Stripe subscriber access.
