## Meshenger

Offline, end‑to‑end encrypted messenger that uses Bluetooth (and other local transports) to relay messages over a mesh, with no central server.

### About

- **Identity**: Each user is identified by a cryptographic Ed25519 keypair (public key as address). The private key is encrypted locally with a password‑derived key and stored in secure storage.
- **Offline‑first**: Devices can exchange and forward messages without internet connectivity.
- **End‑to‑end encrypted**: Messages are encrypted with an X25519 key agreement + AES‑256‑GCM and signed with the sender's Ed25519 key. Only the sender and receiver can read the content — any node in between (gateway, relay, or stranger's device) only sees ciphertext.
- **Cross‑platform**: Standard Flutter app targeting mobile, desktop, and web as transport UIs evolve.

### Current features

- **Multiple identities (Netflix-style profiles)**: the start screen lists every identity on the device with its avatar — pick one and unlock with its password, or create a new one (preset avatars + nickname). Each identity's chats, contacts, and settings are fully separate, and logging out locks all key material. **Manage profiles** on the login screen hides a tile without touching its data (restore any time); the *permanent* delete lives in Settings, requires that profile's password, and wipes every trace — keys, chats, contacts, media, layout.
- **App launcher (springboard)**: after unlock you land on an iPhone-style home screen with the built-in apps: Messages, Phone, Video Chat, Contacts, Camera, Storage, Voice Memos, Mesh Map, Network, App Store, and Settings. Long-press and everything jiggles: drag to rearrange (icons flow around the drop slot), drop one icon onto another to create a named group (mini-icon grid on the group tile, groups may nest exactly one level), drag apps out to dissolve. Red unread badges sit on app icons and **roll up onto group icons** for everything inside. Layout is saved per profile.
- **Contacts app + QR**: a standalone Contacts app manages your address book — add by QR scan or paste, rename, share your own QR, jump straight into a chat. The QR also carries your encryption key, so someone who scans it can message you end‑to‑end encrypted through any number of relays immediately — even from far beyond gossip range (this is how SF→NY first contact bootstraps).
- **Offline Bluetooth messaging (default)**: devices discover each other over Bluetooth LE — no network of any kind required. Each device advertises a Meshenger GATT service and scans for others; peers prove their identity with a signed announcement, and messages are delivered as end‑to‑end encrypted chunked GATT writes.
- **Push delivery (outbox channels)**: every node also serves an *outbox* — a notify characteristic that nearby peers subscribe to. Once subscribed, a relay or phone can **initiate delivery** the instant an envelope arrives, over the already‑open connection — no scanning round trip. This is what lets a Raspberry Pi gateway push a message to an iPhone whose app is in the background: iOS keeps the subscription alive and wakes the app to decrypt.
- **Background notifications**: messages, voicemails, and incoming calls that arrive while the app is backgrounded show a system banner (sender + kind only — content stays end‑to‑end encrypted and never appears in notifications).
- **Offline LAN messaging**: devices on the same Wi‑Fi network or hotspot discover each other automatically (signed UDP broadcast) and exchange end‑to‑end encrypted messages directly over TCP — no internet or server required.
- **Transport switch**: the Bluetooth/Wi‑Fi toggle (chats screen and Settings) switches between the two transports. Bluetooth is the default on first launch; the choice is remembered.
- **Multi‑hop mesh relay**: every device (and standalone gateway) stores and forwards *encrypted envelopes* for others. If Phone B is out of your radio range but a device in the middle can hear you both, your message hops through it — the relay only ever sees ciphertext. Envelopes carry a hop budget (1000 — distance is finite, the cap is a safety valve, not a range limit), a sliding via‑window, and an expiry (48 h); duplicates are dropped by envelope ID. The relay role can be switched off in Settings.
- **Gradient (probabilistic) routing**: nodes learn which neighbors lead toward which destinations — gossip re‑floods are stamped with the forwarding neighbor, and every envelope's via‑trail teaches the reverse path. Forwarding hands envelopes to the best‑known next hops *first*, with random epidemic spread as the fallback, so messages roll downhill toward their destination instead of blindly flooding — and delivery acks ride the learned gradient straight back to the sender.
- **Per‑node retry with path diversity**: a next hop that dies mid‑transfer doesn't poison anything — the handoff only counts when the carrier *confirms* it, other paths are tried immediately, and the failed path is retried after a 90 s backoff.
- **Mesh‑gap detection**: every outgoing message is time‑monitored. Never picked up by any carrier within 3 minutes, or no end‑to‑end ack within 30 minutes → the message is flagged red: *failed — gap in mesh network (not enough nodes)*. Background retries keep running (a late ack still flips it to delivered), and manual resends are unlimited — once someone plants a gateway in the gap, a retry gets through.
- **Standalone gateway daemon** (`relay/`): a headless pure‑Dart relay for Raspberry Pi and other Linux boxes — advertises and scans over **Bluetooth (BlueZ)** with the same GATT protocol as the app, speaks the LAN protocol simultaneously, and **bridges the two** (Bluetooth in → Wi‑Fi/Ethernet across → Bluetooth out). Integration‑tested store‑and‑forward, dedup, and gossip.
- **Delivery receipts, end to end**: a message shows *pending* → *sent* (reached the first hop) → *delivered* (the recipient itself decrypted it and sent a signed ack back through the mesh). Group messages track delivery per member.
- **Gossip discovery**: nodes periodically share signed peer announcements, so you learn about devices *beyond* your radio range — including their encryption keys, which means you can send end‑to‑end encrypted messages to someone you've never been near, through the mesh.
- **Store‑and‑forward outbox**: messages to an offline peer are stored as *pending* (with a retry action) and delivered automatically as soon as that peer appears on the network — directly or through relays.
- **Message control**: edit or delete your sent messages (synced to the peer, Telegram-style), auto-delete timers (30 s – 1 week, applied on both ends), date separators, clear-messages vs delete-chat, unread indicators.
- **Group chats**: multi-recipient compose creates a group; the creator (admin) can name it and add/remove members; members can leave.
- **Media messages**: send photos (camera or library) and files in any chat; images can be sent as **view‑once** (Snapchat‑style — the photo burns on both ends after the receiver opens it) or permanent. Large media rides the same encrypted envelopes, chunked over BLE.
- **Voice notes**: hold‑to‑record audio clips in any chat, with inline playback.
- **Calls (Phone + Video Chat apps)**: real call signaling over the mesh — ring, accept, decline, hang up — with a full‑screen incoming‑call overlay anywhere in the app. Active calls are half‑duplex push‑to‑talk (mesh radio bandwidth). Recents and per‑call outcomes are logged; missed/declined calls prompt the caller to leave a **voicemail**, which lands in the callee's Voicemail tab.
- **Camera app**: capture (mobile) or import (desktop) photos into an identity‑scoped camera roll; view, send to any contact, or delete.
- **Storage app**: identity‑scoped file library — import any file, preview images/audio, send to contacts, delete.
- **Voice Memos app**: record, play, rename‑free simple library, send any memo to a contact.
- **Mesh Map**: live graph of the mesh — devices in direct radio range (green, positioned by signal strength) *plus* devices known through relays (blue, with hop count), like Raspberry Pi gateways and neighbors‑of‑neighbors. Message or save any node directly from the map.
- **Network — the mesh's own social feed**: think Nextdoor × YikYak × Citizen, but with *no server and no geolocation* — your radio neighborhood **is** the feed. Post a photo of the accident you just walked past, a song, a heads-up; it floods the local mesh (signed by you, up to 64 hops, capped media) and anyone in that mesh sees it in a full-screen reels-style feed. Walk out of one mesh and into another and your posts walk with you; gateways carry the neighborhood's active posts and hand them to whoever wanders into range. Posts live 1 h – 1 week, delete propagates as a signed tombstone, and the feed's activity ticker shows devices joining and leaving the mesh around you — anonymous strangers included (they're labeled by short address until you know them).
- **Notification sounds + unread badges**: four built-in alert tones (pick or mute in Settings), iPhone-style red unread badges per chat and rolled up on the home screen, and an in-app banner slides down when a message arrives while you're elsewhere in the app.

### Architecture: mesh, gateways, and coverage zones

Bluetooth (and any single radio) only reaches so far. Meshenger grows its coverage zone by letting **every node relay encrypted traffic**:

```
[Phone A] ~~bluetooth~~ [Gateway 1] ~~bluetooth~~ [Gateway 2] ~~bluetooth~~ [Phone B]
                              |                        |
                         (amplifier /             (amplifier /
                          relay only)              relay only)
```

Three kinds of nodes exist today:

1. **The app** (this repo) — runs on any device: Windows, macOS, Linux, Android, iOS, or Chrome. Sends, receives, and relays for others (toggle in Settings).
2. **Standalone gateways** (`relay/` in this repo) — a headless pure‑Dart daemon for cheap dedicated boxes (Raspberry Pi or scratch‑built) that act purely as **signal amplifiers/relays**. On Linux it speaks **Bluetooth LE via BlueZ** with the exact same GATT protocol as the phones — phones see a gateway as just another mesh device — *and* the LAN protocol at the same time, **bridging between the two**: Bluetooth in one side, Wi‑Fi/Ethernet out the other. Place a chain of gateways and the coverage zone grows with each one. Gateways never need to be trusted, because they only ever handle ciphertext — without the recipient's private key there is nothing to read. See [Pi as a standalone gateway](#pi-as-a-standalone-gateway) below.
3. **Specialized devices ("mesh walkie‑talkie" phones)** — down the line, purpose‑built handsets running our own OS image (see MeshOS below) that are simultaneously a full messenger client *and* a gateway, so every device in the field automatically thickens the mesh.

How a multi‑hop delivery works, end to end:

1. Phone A encrypts the message to Phone B's key (X25519 → AES‑256‑GCM), signs it, and seals it in an envelope: `{id, to, from, ciphertext, hops, max, via[], exp}`.
2. Every node that hears the envelope checks: *is it for me?* If yes → decrypt, verify, send a signed **ack** envelope back through the mesh. If no → increment `hops`, add itself to the `via` window, spool it, and hand it onward until it expires (48 h) or the hop budget (1000) runs out.
3. Phone A shows ✓✓ *delivered* only when B's ack arrives — meaning B itself, not some middle node, has the message. No ack within the deadline → A sees *failed — gap in mesh network* and can resend without limit while background retries continue.
4. A phone in someone's pocket with the app running, or a Pi on a windowsill, is equally good as a middle node. Relays hold **no keys** and see **only ciphertext**.

Routing is **gradient‑guided epidemic**, not fixed shortest‑path. Every packet teaches: gossip arriving via neighbor N saying "Bob, 12 hops" means N leads toward Bob; an envelope's via‑trail teaches the reverse path to everyone on it. When forwarding, a node hands the envelope to its best‑known next hops toward the destination *first*, then to random carriers as insurance — so a message rolls downhill toward its target instead of blindly flooding, duplicates are dropped by ID, and the first copy to arrive wins. Dead next hops don't strand anything: handoffs only count when confirmed, alternate paths go out immediately, and failed paths retry after backoff. A cross‑town chain like `mac → pi → pi → iphone → android → windows → … → mac` needs no planning — if the chain physically exists, a copy walks it, and the ack walks the learned gradient straight back.

**Scale math (SF → NY)**: pure BLE hops reach 10–50 m, but gateways pair over Ethernet/Wi‑Fi and each bridge counts as *one hop* — a freeway chain of bridged Pi pairs covers miles per hop. Hundreds of hops, well inside the 1000 budget. Keys bootstrap by QR (which carries the encryption key), so first contact doesn't wait for gossip to cross the country; gossip (capped at 128 hops) keeps the *nearby* mesh map and key discovery fresh.

**How a gateway reaches a phone it cannot see** (push delivery): whenever two Meshenger nodes meet, each subscribes to the other's *outbox* characteristic and identifies itself with a signed hello. The connection stays open. From then on either side can push envelopes over it instantly — which turns every gateway into a true **router that initiates delivery**, including to backgrounded iPhones (iOS holds BLE subscriptions open in the background, wakes the app when the relay notifies, the app decrypts and posts a local notification banner). No Apple/Google push servers involved — the "push" is a Bluetooth packet from a $15 Pi.

Because encryption is end‑to‑end, relaying through strangers' hardware carries no confidentiality risk: only the sender and receiver hold the keys.

### MeshOS: the operating system goal

To run Meshenger on *literally any machine* — including scratch‑built gateways and custom handsets — the long‑term plan is a minimal Linux‑based OS image ("MeshOS") that boots straight into the mesh stack:

- **Base**: a stripped‑down Linux (e.g. Raspberry Pi OS Lite / Buildroot / Yocto) with Bluetooth, Wi‑Fi, and the mesh daemon preinstalled.
- **Two profiles**:
  - **Gateway profile** — headless; boots, joins the mesh, and relays encrypted frames. No UI, no stored identity, nothing to steal.
  - **Handset profile** — boots into the Meshenger UI full‑screen (the Flutter app runs natively on Linux), with an identity stored on device like any phone.
- **Hardware targets**: Raspberry Pi (Zero 2 W / 4 / 5) first because it is cheap and has built‑in Bluetooth + Wi‑Fi; any SBC or old laptop that runs Linux works too.

This is a roadmap item — today the app itself already runs on all major desktop/mobile platforms and Chrome, which covers "any machine" for the messenger client; MeshOS is what will cover dedicated gateways and custom phones.

### Prerequisites (all platforms)

- **Flutter SDK** installed and on your `PATH`.
  - Install from [flutter.dev](https://docs.flutter.dev/get-started/install).
  - macOS/Linux example: `export PATH="$HOME/develop/flutter/bin:$PATH"` in `~/.zprofile` or `~/.bashrc`.
  - Windows example: add `C:\src\flutter\bin` to your user **Path** environment variable.
- From the project root, fetch dependencies once (or after pulling changes):

```bash
flutter pub get
```

- Verify your toolchain:

```bash
flutter doctor
```

Fix any issues `flutter doctor` reports before running on a specific platform.

---

### Windows

#### Setup

1. Install [Visual Studio 2022](https://visualstudio.microsoft.com/) (Community edition is fine) with the **Desktop development with C++** workload.
2. Install [Git for Windows](https://git-scm.com/download/win) if you do not already have it.
3. Ensure Flutter is on your `PATH`, then run `flutter doctor` and confirm the **Windows** toolchain shows as available.

#### Run

From the project root in PowerShell or Command Prompt:

```powershell
flutter devices          # optional: list available targets
flutter run -d windows
```

---

### macOS

#### Setup

1. Install [Xcode](https://developer.apple.com/xcode/) from the App Store.
2. Open Xcode once and accept the license; install any requested components.
3. Install the Xcode command-line tools if prompted, or run:

```bash
xcode-select --install
```

4. Ensure Flutter is on your `PATH`, then run `flutter doctor` and confirm **macOS** (and **Xcode** for iOS) show as available.

#### Run

From the project root:

```bash
flutter devices          # optional: list available targets
flutter run -d macos
```

---

### Linux

#### Setup

1. Install Flutter’s Linux desktop dependencies. On Debian/Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev
```

Other distributions: see [Flutter Linux desktop setup](https://docs.flutter.dev/platform-integration/linux/setup).

2. Ensure Flutter is on your `PATH`, then run `flutter doctor` and confirm **Linux** shows as available.

#### Run

From the project root:

```bash
flutter devices          # optional: list available targets
flutter run -d linux
```

> **Linux Bluetooth note**: the desktop‑Linux BLE plugin is central‑only — the app can *discover and message* nearby devices over Bluetooth but cannot *be discovered* (no peripheral/advertising role). For full two‑way Bluetooth on Linux, run the relay daemon alongside the app: the daemon advertises and receives over BlueZ and bridges to the app over the loopback LAN transport. One command: `cd relay && dart run bin/relay.dart --name "My Linux Box"` (see below), then switch the app to the Wi‑Fi transport.

---

### Raspberry Pi

A Raspberry Pi is both a supported client (it is just Linux) and the reference hardware for **standalone gateways**.

#### Setup (Pi as a messenger client)

1. Use a 64‑bit Raspberry Pi (Pi 4, Pi 5, or Zero 2 W) with **Raspberry Pi OS (64‑bit)**.
2. Install the Linux desktop dependencies:

```bash
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev
```

3. Install Flutter for Linux ARM64 (via [flutter.dev](https://docs.flutter.dev/get-started/install/linux) or a community build such as `flutter-pi`), add it to your `PATH`, and run `flutter doctor`.

#### Run

```bash
flutter pub get
flutter run -d linux
```

#### Pi as a standalone gateway

The relay daemon ships in this repo at `relay/` — pure Dart, no Flutter, no GUI. It is **Bluetooth‑first**: on Linux it advertises the Meshenger GATT service and scans for phones exactly like the app does, so it drops into the BLE mesh invisibly. It simultaneously speaks the LAN protocol and **bridges the two links** — a phone's Bluetooth message can cross a house over Ethernet/Wi‑Fi between two Pis and come out as Bluetooth on the far side. It stores and forwards encrypted envelopes it cannot read, re‑floods gossip so phones on opposite sides learn about each other, **pushes spooled envelopes to phones that subscribe to its outbox** (that's how it reaches backgrounded iPhones), carries the neighborhood's active **Network posts** like a bulletin board (walk into range and the feed fills in), and shows up on everyone's Mesh Map under the name you give it.

**Recommended hardware**: Raspberry Pi Zero 2 W (~$15, built‑in BLE, tiny), Pi 4, or Pi 5, with **Raspberry Pi OS Lite (64‑bit)** flashed via Raspberry Pi Imager. A **Pi 3 Model B** also works for testing (onboard Bluetooth 4.1 + Wi‑Fi, 64‑bit OS); it is just slower. Any Linux box with BlueZ works the same (old laptops make great gateways).

**1. Install the Dart SDK (ARM64):**

```bash
sudo apt-get update && sudo apt-get install -y wget unzip bluez
wget https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-linux-arm64-release.zip
unzip dartsdk-linux-arm64-release.zip && sudo mv dart-sdk /opt/dart
export PATH="/opt/dart/bin:$PATH"    # add to ~/.bashrc to persist
```

**2. Get the relay onto the Pi** (`git clone` the repo, or `scp` just the `relay/` folder) and run it:

```bash
cd meshenger/relay
dart pub get
sudo /opt/dart/bin/dart run bin/relay.dart --name "Garden Gateway"
```

You should see:

```
[12:00:01] Meshenger relay "Garden Gateway"
[12:00:01] Address: qIBX9YZ2aJ93k0Ls…
[12:00:01] This node forwards encrypted envelopes it cannot read.
[12:00:02] BLE: GATT registered (announce + inbox + outbox characteristics)
[12:00:02] BLE: advertising Meshenger service as "Garden Gateway"
[12:00:02] BLE: scanning for Meshenger devices
[12:00:02] LAN: listening on TCP port 40123, announcing on UDP 45654
[12:00:02] Relay running with ble + lan. Ctrl-C to stop.
[12:00:15] BLE: peer online AbCdEf123456… (F4:5C:89:AA:BB:CC)
```

Open the Mesh Map on your phone — the gateway appears by name within ~30 seconds.

> **Why sudo?** Registering a GATT service with BlueZ needs D‑Bus permission. Either run the daemon as root (simplest for a dedicated gateway box) or add your user to the `bluetooth` group: `sudo usermod -aG bluetooth $USER` then re‑login. If Bluetooth fails to power on, try `sudo rfkill unblock bluetooth`.

**Flags:**

| Flag | Meaning |
| --- | --- |
| `--name "Shed"` | Public name shown on peers' Mesh Maps |
| `--no-lan` | **Strict Bluetooth‑only relay** — zero network footprint, pure radio |
| `--no-ble` | LAN‑only (also what you get automatically on macOS/Windows) |
| `--identity <path>` | Where the relay keypair persists |
| `--max-spool 512` | Envelopes carried at once (default 256, expire after 48 h) |
| `--adapter 1` | Use `hci1` instead of `hci0` (USB BLE dongle setups) |

**3. Compile to a single native binary** (starts faster, no SDK needed at runtime):

```bash
dart compile exe bin/relay.dart -o meshenger-relay
sudo ./meshenger-relay --name "Garden Gateway"
```

**4. Run it on boot** — create `/etc/systemd/system/meshenger-relay.service`:

```ini
[Unit]
Description=Meshenger mesh gateway
After=bluetooth.target network.target
Wants=bluetooth.target

[Service]
ExecStart=/home/pi/meshenger-relay --name "Garden Gateway" --identity /home/pi/relay-identity.json
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now meshenger-relay
journalctl -u meshenger-relay -f     # watch it forward envelopes
```

Notes:

- The relay keeps a persistent keypair in `relay-identity.json` so its address (and Mesh Map name) is stable across reboots. The key only signs presence announcements — the relay holds **no message keys** and can never read traffic.
- **Coverage math**: BLE reaches ~10–50 m per hop depending on walls; the hop budget is 1000, so radio range — not the protocol — is the limit. A line of window‑sill Pis spans a street; for real distance, pair Pis with Ethernet/Wi‑Fi between them — each bridge counts as one hop, so a freeway chain of bridged pairs covers miles per hop. SF→NY is hundreds of hops: expensive to build, cheap for the protocol.
- **Backgrounded iPhones**: the gateway *can* initiate delivery to an iPhone whose app is backgrounded — the phone subscribes to the gateway's outbox characteristic while in range, iOS keeps that Bluetooth subscription alive in the background, and the gateway pushes envelopes over it (the phone wakes, decrypts, and shows a notification banner). The caveat that remains: if the user **force‑quits** the app (swipes it away), iOS tears down Bluetooth entirely until the next launch.
- Placement tip: relays only help where they can hear at least two other nodes. A window sill between two houses, a hallway between apartments, a shed halfway down the street.

---

### Web (Chrome)

#### Setup

1. Install [Google Chrome](https://www.google.com/chrome/).
2. Enable web support if needed:

```bash
flutter config --enable-web
```

3. Run `flutter doctor` and confirm **Chrome** is detected.

#### Run

From the project root:

```bash
flutter devices          # optional: list available targets
flutter run -d chrome
```

> Note: the browser cannot open raw UDP/TCP sockets or act as a Bluetooth peripheral, so neither offline transport is available on web. The app runs fully (identity, contacts, QR, chats) and messages queue as *pending*; use a desktop or mobile build for actual offline delivery.

---

### Android

#### Setup

1. Install [Android Studio](https://developer.android.com/studio).
2. In Android Studio, open **SDK Manager** and install the Android SDK, platform tools, and at least one system image for an emulator.
3. Create a virtual device in **Device Manager**, or connect a physical device with USB debugging enabled.
4. Accept Android licenses:

```bash
flutter doctor --android-licenses
```

5. Run `flutter doctor` and confirm **Android toolchain** shows as available.

#### Run

Start an emulator or connect a device, then from the project root:

```bash
flutter devices          # optional: list available targets
flutter run -d android
```

#### Ship to real Android phones (no store needed)

```bash
flutter build apk --release
# APK lands at build/app/outputs/flutter-apk/app-release.apk
```

Send that file any way you like (AirDrop‑equivalent, USB, web link); recipients enable "install from unknown sources" when prompted and tap it. This is the fastest way to get testers on Android — no accounts, no review. For Google Play later, use `flutter build appbundle` and a proper signing key (`android/key.properties`).

> Android background note: the app relays while open or backgrounded briefly; Android eventually suspends background Bluetooth for battery. Keeping the app open (or the screen on in a pocket of testers) is fine for demos; a foreground service for always‑on relaying is on the roadmap.

---

### iOS

> Requires a Mac with Xcode. iOS Simulator and device builds are not supported on Windows or Linux.

#### Setup

1. Install [Xcode](https://developer.apple.com/xcode/) from the App Store.
2. Open Xcode once and accept the license; install any requested components.
3. Install CocoaPods (if `flutter doctor` reports it as missing):

```bash
sudo gem install cocoapods
```

4. Run `flutter doctor` and confirm **Xcode** and **iOS** show as available.

#### Run

Start the iOS Simulator from Xcode (**Xcode → Open Developer Tool → Simulator**) or connect a physical iPhone/iPad, then from the project root:

```bash
flutter devices          # optional: list available targets
flutter run -d ios
```

> The Simulator has no Bluetooth; use a physical iPhone to test the mesh.

#### Deploy to TestFlight (Apple Developer account required)

One‑time setup:

1. In [App Store Connect](https://appstoreconnect.apple.com) → **Apps → +** create the app. Pick a unique bundle ID (e.g. `com.yourname.meshenger`) — register it first under [Identifiers](https://developer.apple.com/account/resources/identifiers/list) if it isn't listed.
2. Point the project at your bundle ID and team: open `ios/Runner.xcworkspace` in Xcode → select the **Runner** target → **Signing & Capabilities** → set **Team** to your developer account and **Bundle Identifier** to the ID from step 1, with **Automatically manage signing** on.
3. Export compliance is already answered in code: `ITSAppUsesNonExemptEncryption=false` is set in `ios/Runner/Info.plist` (the app uses only standard, exempt encryption — AES‑GCM/X25519/Ed25519). No questionnaire on every upload. (US distribution formality: file the [annual self‑classification report](https://www.bis.doc.gov/index.php/policy-guidance/encryption) once.)

Every release:

```bash
flutter build ipa --release
# Archive lands at build/ios/archive/Runner.xcarchive
# IPA lands at    build/ios/ipa/meshenger.ipa
```

Upload the IPA with the **Transporter** app (Mac App Store — drag the `.ipa` in, press Deliver), or from Xcode: **Window → Organizer → Distribute App**. Processing takes ~5–15 minutes, then the build appears in App Store Connect → your app → **TestFlight**.

Testing tiers:

- **Internal testing** (up to 100 devices, instant, no review): add your own Apple ID under **Internal Testing**, install the TestFlight app on the iPhone, accept the invite. New uploads auto‑distribute.
- **External testing** (up to 10,000 testers, ~1‑day Beta App Review the first time): create an **External Testing** group and share the public invite link — this is the link to drop on social media.

Version bumps: raise `version:` in `pubspec.yaml` (e.g. `1.0.0+2` — the `+N` build number must increase every upload), rebuild, re‑upload.

---

### Test offline messaging: Windows laptop ↔ Mac laptop

This works today with **no network at all** — Bluetooth is the default transport, so the two machines only need to be within Bluetooth range (~10 m indoors) with Bluetooth turned on.

1. **Run the app on both machines** from the project root:
   - Windows: `flutter run -d windows`
   - Mac: `flutter run -d macos`
2. **Create an identity on each machine** (Create New Identity → password + optional nickname).
3. **Exchange addresses**: on the Mac, open **My QR** (QR icon in the chats screen) and copy the public address; on Windows, open **Contacts → Add contact** and paste it (or scan the QR if the machine has a camera). Repeat in the other direction if you want two‑way chats initiated from either side.
4. **Chat**: open the contact and press the message icon. The header shows a green **online** dot when the other laptop is discovered (Bluetooth discovery can take ~10–20 seconds). Send a message — it appears on the other machine.
5. **Test store‑and‑forward**: quit the app on the Mac, send messages from Windows (they show a ⏱ *pending* icon), then reopen the app on the Mac and unlock — the pending messages are delivered automatically and flip to ✓ *sent*.

**Switching transports**: the Bluetooth/Wi‑Fi toggle in the chats screen app bar selects the transport. LAN is faster and has more range if both machines are on the same Wi‑Fi network or phone hotspot; Bluetooth needs no infrastructure whatsoever.

How it works (Bluetooth): each device advertises a Meshenger GATT service and scans for others. On discovery, a device reads the peer's signed announcement (Ed25519‑verified), then delivers messages as chunked GATT writes — end‑to‑end encrypted (X25519 + AES‑256‑GCM) and signed. The final write is only acknowledged after the receiver verifies and decrypts, so a ✓ means real delivery.

How it works (LAN): each device broadcasts a signed UDP announcement on port 45654; peers verify the signature, then deliver messages over a direct TCP connection with the same end‑to‑end encryption. If discovery fails, check that both machines are on the same network and that your firewall allows the app to receive UDP on port 45654 (Windows shows a firewall prompt on first run — click **Allow**).

---

### Troubleshooting

- **“No supported devices connected”** — run `flutter devices` and pick a target with `-d <device-id>`, or complete the platform setup above (emulator/simulator, Visual Studio, Xcode, etc.).
- **Missing platform folder** — regenerate platform projects from the repo root with `flutter create .` (existing `lib/` code is preserved).
- **Build errors after upgrading Flutter** — try `flutter clean`, then `flutter pub get`, then run again.
- **Windows: `error C2338 … <experimental/coroutine> … STL1011` when building** — newer MSVC versions (Visual Studio 2026) removed the experimental coroutine headers that the `bluetooth_low_energy_windows` plugin's generated C++/WinRT code still uses. This repo already defines `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` in `windows/CMakeLists.txt` to restore them; if you regenerate the Windows project with `flutter create .`, re-add that definition.
- **Windows: `Transport error: The parameter is incorrect` when switching to Bluetooth** — fixed in app code: on Windows the GATT service provider already advertises when the Meshenger service is registered, so the app skips the extra `BluetoothLEAdvertisementPublisher` call that triggers this WinRT error. Pull latest and hot-restart (`R`) or re-run the app.
- **Windows never shows the Mac online** — two Windows-specific quirks, both handled in this repo:
  1. *Scan filter never matches*: macOS/iOS peripherals carry their 128-bit service UUID in the BLE scan response, which the Windows advertisement watcher's service-UUID filter does not match against — a "filtered" scan silently discovers nothing. The app therefore scans broadly on Windows and filters by the advertised UUIDs in Dart (`lib/core/transport/ble_transport_io.dart`).
  2. *Random addresses*: macOS/iOS peripherals use *random* Bluetooth addresses; the stock `bluetooth_low_energy_windows` plugin connects with `FromBluetoothAddressAsync(address)`, which assumes a *public* address and silently returns null for them. This repo ships a patched copy of the plugin in `packages/bluetooth_low_energy_windows` (wired up via `dependency_overrides` in `pubspec.yaml`) that remembers each device's address type from its advertisement and passes it when connecting. If you update the `bluetooth_low_energy` dependency, check whether upstream has fixed this before removing the override.
- **Windows logs `channel sent a message from native to Flutter on a non-platform thread`** — the stock plugin invokes pigeon callbacks and async results from WinRT thread-pool threads, which the Flutter engine flags as unsafe (replies can be lost, which manifests as connects that silently time out). The patched plugin copy in `packages/bluetooth_low_energy_windows` marshals every callback back to the platform thread via the COM apartment captured at startup, so these warnings should no longer appear.
- **Peers never show “online” (Bluetooth)** — make sure Bluetooth is turned on on both machines and they are within range. The first discovery can take ~10–20 seconds. On macOS, approve the Bluetooth permission prompt on first run (re‑enable under **System Settings → Privacy & Security → Bluetooth** if declined).
- **Peers never show “online” (LAN)** — confirm both devices are on the same network/subnet, allow the app through the OS firewall (UDP 45654 inbound), and note that some guest/public Wi‑Fi networks block device‑to‑device traffic ("client isolation"). A phone hotspot is a reliable fallback.
- **macOS: network or Bluetooth blocked** — the app sandbox needs the network client/server and Bluetooth entitlements; they are already set in `macos/Runner/*.entitlements` in this repo. If you regenerate the macOS project with `flutter create .`, re‑add them.
