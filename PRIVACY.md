# Meshenger privacy policy

_Last updated: October 30, 2026_

Meshenger is a messenger that works over Bluetooth, device to device, with no internet connection and no servers. This policy explains what that means for your data.

## The short version

- **We don't collect anything.** There are no accounts, no servers, no analytics, no ads and no trackers. Nothing you do in Meshenger is sent to us.
- **Your data stays on your devices.** Messages, contacts, photos, files and settings are stored on the device you use.
- **Messages are end-to-end encrypted.** Only you and the person you're talking to can read them. Devices that relay a message for you can't.
- **Some things are public by design.** Your nickname and public key are visible to people nearby. So are posts and pages you publish in the Network app.

## What's stored on your device

When you create an identity, Meshenger generates a cryptographic key pair. Your **public key** is your address. Your **private key** is encrypted with a key derived from your password and kept in your operating system's secure storage. It never leaves your device.

Your chats, contacts, media, voice memos, files, Network posts and pages, bookmarks and settings are stored locally, separately for each identity. Deleting an identity in Settings erases its data from that device. Uninstalling the app removes the app's data as your operating system allows.

## What other people's devices can see

Meshenger works by devices talking to each other directly. To do that, some information has to be shared with devices around you:

| What | Who can see it |
| --- | --- |
| That a Meshenger device is nearby, your **public key**, your **encryption public key** and your **nickname** | Anyone nearby running Meshenger, and devices further away that learn about you from nearby devices ("gossip") |
| The **content** of your messages, photos, voice notes, files and calls | Only you and the recipients (end-to-end encrypted with X25519 and AES-256-GCM, signed with Ed25519) |
| The **envelope** of a message: sender and recipient public keys, size, hop count and expiry time | Devices and relays that carry the message for you. They store and forward it but can't read it |
| **Global posts**, and **site posts and pages** you publish | Everyone your mesh reaches. They're signed with your key and copied from device to device |

**Invisible mode** stops your device from advertising itself and announcing you to others. You disappear from other people's Mesh Maps and activity lists. You can still send and receive.

**Private site posts and pages** stay on your device and aren't published until you make them public.

**Deleting a published post or page** sends a signed removal through the mesh, and devices that receive it delete their copy. Devices that never receive the removal may keep a copy, so treat anything you publish as public.

## Permissions

Meshenger asks only for what its features need:

- **Bluetooth**, to find nearby devices and exchange messages. Required.
- **Microphone**, for voice notes, voice memos, voicemail and calls.
- **Camera**, for photos and scanning contact QR codes.
- **Photos and files**, for attachments you choose to send.
- **Notifications**, to tell you about new messages and calls.

Meshenger never reads your location. On Android 12 and newer, Bluetooth scanning is declared as not deriving location. On Android 11 and older, the system won't let apps scan for Bluetooth devices without the location permission, so Meshenger asks for it there, only for scanning.

## Gateways and relays

Anyone can run a Meshenger relay, for example the Raspberry Pi gateway in this project, to extend the mesh. Relays only handle encrypted envelopes and public announcements, as described above. They don't hold keys that could decrypt your messages.

## Children

Meshenger isn't directed at children under 13, and we don't knowingly let them use it.

## Security

Meshenger uses standard, well-known cryptography, and the code is available for anyone to review. It hasn't had an independent security audit yet. Don't rely on it in situations where your safety depends on it.

## Changes

If this policy changes, the new version will be published here with a new date.

## Contact

Questions, or reports of abuse: **george.meshenger@gmail.com**
