# How Meshenger works

This is the technical tour: identities, encryption, the Bluetooth transport, multi-hop routing, and the features built on top. For building and running the code, see [CONTRIBUTING.md](CONTRIBUTING.md).

## The big picture

Bluetooth only reaches so far, so Meshenger grows its coverage by letting **every node relay encrypted traffic** for everyone else:

```
[Phone A] ~~bluetooth~~ [Relay 1] ~~bluetooth~~ [Relay 2] ~~bluetooth~~ [Phone B]
```

There are two kinds of nodes:

1. **The app** (`lib/`) on iPhone, iPad, Android, macOS, Windows and Linux. It sends, receives, and relays for others (Settings → Relay messages for the mesh).
2. **The relay daemon** (`relay/`): a headless pure-Dart program for a Raspberry Pi or any Linux box with BlueZ. It speaks the same GATT protocol as the app, so phones see it as just another device. See [RASPBERRY_PI.md](RASPBERRY_PI.md).

Relays never need to be trusted: they only ever handle ciphertext, and without the recipient's private key there's nothing to read.

## Identity

- Each identity is an **Ed25519 keypair**. The public key (base64) is the identity's address.
- The private key is encrypted with a key derived from the user's password and kept in the platform's secure storage. There's no recovery: a forgotten password means a lost identity.
- Each identity also has an **X25519** key for encryption, published in its signed announcements.
- One device can hold several identities, each with completely separate chats, contacts, settings and files. Logging out locks all key material. Deleting an identity permanently requires its password and wipes keys, chats, contacts, media and layout.
- A contact QR code is `meshenger:<address>:<x25519 key>`. Because it carries the encryption key, someone who scans it can send end-to-end encrypted messages right away, through any number of relays, without waiting for gossip to deliver the key.

## Encryption

- Messages are encrypted with an **X25519 key agreement and AES-256-GCM**, and signed with the sender's Ed25519 key.
- Only the sender and the recipient can read the content. Relays, gateways and strangers' devices see only ciphertext, plus the sender and recipient addresses they need for routing.
- Notifications show only who sent something and what kind it is (message, voicemail, call), never the content.

## Bluetooth transport

`lib/core/transport/ble_transport_io.dart` (the app) and `relay/lib/src/ble.dart` (the relay).

- Each device advertises a Meshenger **GATT service** and scans for others. The service has three characteristics:
  - **announce** (read): the device's signed announcement. Peers verify the Ed25519 signature before trusting anything else.
  - **inbox** (write, write without response): where peers deliver packets.
  - **outbox** (notify): where this device pushes packets to peers that subscribed.
- Packets are split into chunks that fill each radio packet, with a flag byte marking first and last chunks. They're sent without per-chunk acknowledgments but with flow control, so nothing is dropped.
- **Push delivery.** When two nodes meet, each subscribes to the other's outbox and identifies itself with a signed hello. The connection stays open, and either side can push envelopes over it instantly. That makes every relay a router that *initiates* delivery, including to iPhones with the app in the background: iOS keeps the subscription alive, wakes the app when the relay notifies, and the app decrypts and posts a local notification. No Apple or Google push servers are involved; the "push" is a Bluetooth packet.
- **Speed.** File bytes travel raw rather than as base64 between current versions, and devices ask for their fastest connection interval while a transfer runs. Expect tens of KB/s between a Mac and a PC. Bluetooth LE tops out around 150 KB/s, so a 100 MB video still takes tens of minutes.
- **Platform quirks** are handled in patched copies of the Bluetooth plugins (`packages/`, listed in [CONTRIBUTING.md](CONTRIBUTING.md#patched-bluetooth-plugins)): Windows can't connect to random addresses out of the box, stops advertising on its own, and wedges links when two laptops dial each other at once; CoreBluetooth silently drops writes without response when its queue is full.
- **Linux** runs central-only: the app's Bluetooth library can't advertise on Linux, so a Linux device finds others but can't be found. Running the relay daemon alongside covers the peripheral role.
- **Invisible mode** stops advertising and announcing. The device vanishes from other people's Mesh Maps and presence lists, but can still see everyone, send, and receive over the connections it opens.

## Envelopes and multi-hop delivery

Every message travels in an **envelope**: `{id, to, from, ciphertext, hops, max, via[], exp}`.

1. Phone A encrypts the message to B's key, signs it, and seals it in an envelope.
2. Every node that receives the envelope checks whether it's the recipient. If it is, it decrypts, verifies, and sends a signed **ack** envelope back through the mesh. If not, it increments `hops`, adds itself to the `via` window, stores the envelope, and hands it on, until it expires (48 hours) or runs out of hops (budget 1000; distance is finite, so the cap is a safety valve, not a range limit).
3. Duplicates are dropped by envelope ID, and the first copy to arrive wins.
4. A shows ✓✓ **delivered** only when B's ack arrives, meaning B itself has the message.

Message states are **pending** (not picked up yet), **sent** (a first hop took it), and **delivered** (the recipient acknowledged it). Groups track delivery per member.

**Store and forward.** A message to someone who isn't reachable waits as pending and goes out automatically as soon as a path appears, directly or through relays. A handoff only counts once the carrier confirms it; if a next hop dies mid-transfer, other paths are tried right away and the failed one is retried after a 90-second backoff.

**Mesh-gap detection.** If no carrier picks a message up within 3 minutes, or no end-to-end ack arrives within 30 minutes, it's flagged *failed: gap in mesh network*. Background retries continue (a late ack still flips it to delivered), and manual resends are unlimited.

## Routing

Routing is **gradient-guided epidemic**, not fixed shortest path. Every packet teaches something:

- Gossip arriving through neighbor N that says "Bob, 12 hops" means N leads toward Bob.
- An envelope's `via` trail teaches everyone on it the path back to the sender.

When forwarding, a node hands the envelope to its best-known next hops toward the destination first, then to a few random carriers as insurance. Messages roll downhill toward their destination instead of flooding blindly, and delivery acks follow the learned gradient straight back. A chain like `mac → pi → pi → iphone → android → windows → mac` needs no planning: if it physically exists, a copy walks it.

One hop reaches 10–50 m, so the 1000-hop budget spans tens of kilometers of relays. Keys bootstrap through QR codes, so first contact doesn't have to wait for gossip to cross the whole chain.

## Gossip discovery

Nodes periodically share **signed peer announcements**, re-flooded up to 128 hops. That's how a device learns about others beyond radio range, including their encryption keys, so it can message someone it has never been near. Gossip also drives the Mesh Map, presence, nicknames and (when shared) location.

## File transfer

One-to-one chats send all but tiny files peer to peer:

- The file streams disk to disk in end-to-end encrypted chunks: AES-256-GCM per chunk, with the chunk index as the nonce, so replayed, reordered or forged chunks fail authentication.
- Both sides show a live card with speed and time left.
- Files from contacts up to 100 MB download automatically; larger ones, and anything from strangers, wait for **Accept**.
- Offers and accepts travel the reliable store-and-forward path. The bulk chunks go directly, or through one live pass-through node (a phone or relay in the middle forwards them without storing them).
- The receiver's confirmed watermark is saved, so a transfer **resumes where it left off**, even after an app restart, the next time the two devices meet. A watchdog notices stalls; the card offers Resume.

Photos, voice notes, tiny files and group files up to 8 MB ride inside regular envelopes instead, so relays carry them.

## Media

- **Songs** (MP3, M4A/AAC, FLAC, WAV…) show cover art, title, artist, album and length, read from the file's tags (ID3v2.2–2.4, ID3v1, iTunes atoms, FLAC comments). They start playing while they download once the rest will arrive in time, and seeking stays within what has arrived.
- **Videos** (MP4, MOV, MKV, WebM, AVI and more) play inline with media_kit and libmpv. A video with its index at the front starts while it downloads when the link keeps up.
- **View-once photos** burn on both ends after the recipient opens them.

## Calls

- Call signaling (ring, accept, decline, hang up) travels over the mesh, with a full-screen incoming-call overlay anywhere in the app.
- Audio is **half-duplex push-to-talk**, because mesh bandwidth can't carry live two-way audio. Each clip is sent as a signal with a 60-second time to live, played on the other side, and never stored, like a phone call.
- Chats show call lines ("Phone call started at 8:12 PM", "Missed video chat at 9:03 PM"), and call history lists calls and voicemail. Clearing history also removes the lines from chats.
- Missed and declined calls offer to leave a voicemail.

## Network: the mesh web

There's no server and no internet: your radio neighborhood is the web.

- **Global** is a public square, laid out like a group chat for everyone your mesh reaches.
- **Every public key is a website.** Pages are written in a safe HTML subset (headings, links, inline images, colors) at `<key>` and paths like `<key>/blog`, with a live preview editor. [`examples/creator_home.html`](examples/creator_home.html) is a sample home page. Pages render with no scripts and no network fetches.
- Posts go to Global or to your site. Site posts and pages can be private (kept on your device) and published later.
- **Attachments of any size.** A post only describes its file (name, size, SHA-256, a song's tags and a small cover), so it spreads instantly. Tapping it asks nearby devices who has the file, downloads it in chunks from one of them, and checks the hash. Bad bytes are discarded and that device isn't asked again; from then on, your device shares it too. New posts also sign a **piece list** (a hash per chunk), so each chunk is checked as it lands, a bad source is dropped after one chunk, and media can play while downloading. Files up to 512 KB ride inside the post.
- Everything is signed by its author and floods the local mesh up to 64 hops (pages up to 96 KB). Content travels with people between meshes, and relays carry it like a bulletin board. Edits and deletions spread as signed replacements and tombstones.

## Mesh Map and location

- **Radar** shows devices in direct range (positioned by signal strength) and devices known through relays (with hop counts). Any node can be messaged or saved from the map.
- **Globe**: a 3D globe drawn offline from bundled [Natural Earth](https://www.naturalearthdata.com) outlines (public domain), built by `tool/build_world_geo.dart` into `assets/geo/world.bin`. Devices that share their location sit where they are, links arc between them, and recent messages animate their route, including copies that took another path. Delivery acks carry the route back to the sender.
- **Location is off by default.** There are two separate settings: approximate (snapped to a 0.01° grid, about 1 km) and exact. The location rides in gossip with its **own signature**, separate from the announcement's, so no relay can move anyone and older versions simply ignore it. Locations older than 24 hours are never shown, and invisible mode shares nothing. Devices without a location sensor can pin their spot by long-pressing the globe.

## Safety

App stores require user-generated-content apps to let people block and report, and there's no server to moderate. So:

- The [Terms of Use](TERMS.md) are accepted once per device, before anything else.
- **Block** works from chats, sites, posts and the Mesh Map. A blocked person's messages, calls and file offers are dropped on arrival, and their posts and site are hidden. Their posts still relay for others.
- **Hide** removes a post or page from your own view.
- **Report** opens a pre-filled email with the reason, the full public key and the post. It never includes chat contents.
- Identities confirmed as abusive can be blocked for everyone in an app update (`SafetyService.builtInBlocked`).

## Compatibility

Meshes mix versions, so protocol changes have to keep working with older builds: new fields are optional and ignored by old versions (the location signature is separate for this reason), and new formats fall back to old ones when the other side doesn't advertise support (file bytes travel as base64 to older builds).

## Roadmap

- **Identity backup and restore.** Today a lost device or forgotten password means a lost identity.
- **Always-on Android relaying** with a foreground service. Android currently suspends background Bluetooth after a while.
- **Peripheral role on Linux**, so the app can be found without the relay daemon.
- **MeshOS**: a minimal Linux image (Raspberry Pi OS Lite, Buildroot or Yocto) that boots straight into the mesh, with a headless **gateway profile** (relay only, no identity, nothing to steal) and a **handset profile** that boots into the Meshenger app full screen. Raspberry Pi Zero 2 W, 4 and 5 first.
