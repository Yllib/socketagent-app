# SocketAgent privacy policy

Effective October 12, 2026

SocketAgent is published by Rubano Enterprises, LLC. This policy explains what the SocketAgent Android app, companion server, and optional relay service process.

## Data SocketAgent processes

SocketAgent may process the following data when you use the related feature:

- A Firebase installation ID, Firebase Cloud Messaging token, app version, and basic device or app metadata used to deliver notifications.
- Google Play purchase records, including the product ID, purchase token, subscription status, and expiration or cancellation state, used to verify relay access and prevent purchase fraud.
- For users who bought a SocketAgent subscription through Stripe before Google Play billing was introduced, an email address contained in the existing signed subscriber token. The relay uses this email to verify the existing subscription. SocketAgent does not create a new Stripe customer or accept new Stripe purchases in the Google Play version.
- Text sent to ElevenLabs when you choose ElevenLabs as the text-to-speech provider. This feature uses an ElevenLabs API key that you supply. ElevenLabs processes the submitted text under the terms and privacy settings of your ElevenLabs account.
- Connection metadata and random pairing identifiers needed to connect the app, companion server, and relay and to protect those connections from unauthorized access.
- When you choose **Report response**, the reported AI response, your selected reason, app version, app distribution, agent backend, and a random report identifier. SocketAgent shows what will be sent before you submit the report.
- If you sign in with Google, an encrypted account vault and a random account ID, as described under "Account and Google sign-in".

## Chats, files, and voice input

Messages, tool activity, and files sent through the SocketAgent relay are end-to-end encrypted between your Android device and your companion server. Rubano Enterprises and the relay cannot read that content unless you explicitly submit an AI response through the in-app reporting feature.

Your companion server and agent provider may store session history on the computer you control. Claude Code and OpenAI Codex process prompts and responses under the terms of the account you use with those services.

Voice input uses on-device speech recognition. SocketAgent does not send microphone recordings to Rubano Enterprises. If you choose an optional third-party speech feature, the app identifies that provider before you enable it.

## Account and Google sign-in

Signing in with Google is optional. It lets your devices share saved computers and settings without pairing each one by hand.

When you sign in, SocketAgent asks Google for:

- your email address and basic profile, to show which account is signed in;
- access to SocketAgent's own hidden app folder in your Google Drive. SocketAgent cannot see or change any other file in your Drive.

The app saves one file in that folder: a random account key. Each device you sign in reads the key from there. Your email address and Google sign-in tokens stay on your devices and with Google. SocketAgent does not send them to Rubano Enterprises or the relay.

Your devices use the account key to encrypt an account vault before uploading it. The vault holds your saved computers and their connection details, the list of devices on your account, your subscription token if you have one, and app preferences. The relay stores only the encrypted vault, a random account ID derived from the key, and when the vault was created and last updated. Rubano Enterprises cannot read the vault.

When you link two of your computers, the relay forwards encrypted traffic between them the same way it does between your device and a computer. It cannot read commands, output, or transcripts sent over a link.

SocketAgent's use and transfer of information received from Google APIs will adhere to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.

## How data is used

SocketAgent uses the data described above only to:

- operate direct and relay connections;
- deliver notifications;
- verify purchases and existing subscriptions;
- sync your saved computers, devices, and settings across your signed-in devices;
- provide features you choose, such as ElevenLabs text-to-speech;
- prevent abuse and protect the service.
- review reports of offensive, unsafe, misleading, or deceptive AI responses.

SocketAgent does not sell personal data. It does not use personal data for advertising, marketing profiles, or analytics.

## Service providers

SocketAgent uses Google Play Billing for purchases, Firebase Cloud Messaging for notifications, and ElevenLabs only when you enable its text-to-speech option with your own API key. It uses Google Sign-In and Google Drive when you choose to sign in with Google. Existing pre-Google Play subscribers may still be verified through Stripe. These companies process data under their own terms and privacy policies.

## Retention and deletion

Notification registration data remains on the relay until you unenroll the device, replace the registration, or the data is removed as part of service maintenance. Purchase records remain while needed to provide access, reconcile purchases, prevent fraud, and meet legal obligations. Legacy subscriber emails are decoded from signed tokens when access is checked and are not stored in the relay entitlement database. Submitted AI response reports remain only as long as needed to review the report, address abuse, and document the action taken.

You can remove local SocketAgent data by deleting sessions, servers, and settings in the app or by clearing the app's storage. You control the data stored by the companion server and agent tools on your computer. To request removal of relay registration, entitlement data, or a submitted AI response report, contact us using the address below. We may need purchase, pairing, or report information to locate the record.

The encrypted account vault stays on the relay until you delete your account. **Delete account** in Settings > Account removes the vault from the relay and the account key from your Google Drive, and signs every device out of the account. Saved computers stay on each device. Removing a device from your account creates a new account key and deletes the old vault. You can also delete the key yourself in Google Drive under Settings > Manage apps > SocketAgent > Delete hidden app data.

## Security

SocketAgent encrypts data in transit. Relay chat and file content uses end-to-end encryption. No system can guarantee absolute security, but SocketAgent limits collected data to what its features require.

## Age restriction

SocketAgent is intended for adults age 18 and older. It is not directed to children.

## Changes

We may update this policy when SocketAgent's features or data practices change. The effective date at the top identifies the current version.

## Contact

Rubano Enterprises, LLC  
[google@rubanoenterprises.com](mailto:google@rubanoenterprises.com)
