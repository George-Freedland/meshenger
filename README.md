## Meshenger

Offline, end‑to‑end encrypted messenger that uses Bluetooth (and other local transports) to relay messages over a mesh, with no central server.

### About

- **Identity**: Each user is identified by a cryptographic Ed25519 keypair (public key as address). The private key is encrypted locally with a password‑derived key and stored in secure storage.
- **Offline‑first**: Devices can exchange and forward messages without internet connectivity.
- **End‑to‑end encrypted**: Messages are encrypted with an X25519 key agreement + AES‑256‑GCM and signed with the sender's Ed25519 key. Only the sender and receiver can read the content — any node in between (gateway, relay, or stranger's device) only sees ciphertext.
- **Cross‑platform**: Standard Flutter app targeting mobile, desktop, and web as transport UIs evolve.

### Current features

- **Identity onboarding**: create a new identity (password with strength meter + optional nickname) or unlock an existing one. The start screen shows just the two choices and fades to the relevant form.
- **Contacts via QR**: share your public address as a QR code; add contacts by scanning or pasting an address.
- **Offline Bluetooth messaging (default)**: devices discover each other over Bluetooth LE — no network of any kind required. Each device advertises a Meshenger GATT service and scans for others; peers prove their identity with a signed announcement, and messages are delivered as end‑to‑end encrypted chunked GATT writes.
- **Offline LAN messaging**: devices on the same Wi‑Fi network or hotspot discover each other automatically (signed UDP broadcast) and exchange end‑to‑end encrypted messages directly over TCP — no internet or server required.
- **Transport switch**: the Bluetooth/Wi‑Fi toggle in the chats screen switches between the two transports. Bluetooth is the default on first launch; the choice is remembered.
- **Store‑and‑forward outbox**: messages to an offline peer are stored as *pending* and delivered automatically as soon as that peer appears on the network.

### Architecture: mesh, gateways, and coverage zones

Bluetooth (and any single radio) only reaches so far. Meshenger grows its coverage zone by letting **every node relay encrypted traffic**:

```
[Phone A] ~~bluetooth~~ [Gateway 1] ~~bluetooth~~ [Gateway 2] ~~bluetooth~~ [Phone B]
                              |                        |
                         (amplifier /             (amplifier /
                          relay only)              relay only)
```

Three kinds of nodes are planned:

1. **The app** (this repo) — runs on any device: Windows, macOS, Linux, Android, iOS, or Chrome. Sends, receives, and can relay.
2. **Standalone gateways** — cheap dedicated boxes (Raspberry Pi or scratch‑built) that act purely as **signal amplifiers/relays**. They extend the mesh's reach: place a chain of gateways and the total coverage zone grows with each one. Gateways never need to be trusted, because they only ever handle ciphertext — without the recipient's private key there is nothing to read.
3. **Specialized devices ("mesh walkie‑talkie" phones)** — down the line, purpose‑built handsets running our own OS image (see MeshOS below) that are simultaneously a full messenger client *and* a gateway, so every device in the field automatically thickens the mesh.

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

#### Pi as a standalone gateway (roadmap)

The gateway profile of **MeshOS** (see above) targets the Pi first:

- Flash a headless image (Raspberry Pi OS Lite), boot, and the gateway daemon joins the mesh automatically — no screen, keyboard, or configuration needed.
- Gateways relay only ciphertext; they hold no identity and cannot read any traffic.
- Each gateway you place extends the total coverage zone of the mesh (Bluetooth hop by hop, or bridging across a building's Wi‑Fi).

The gateway daemon is not built yet; today the Pi participates like any other Linux client.

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
- **Peers never show “online” (Bluetooth)** — make sure Bluetooth is turned on on both machines and they are within range. The first discovery can take ~10–20 seconds. On macOS, approve the Bluetooth permission prompt on first run (re‑enable under **System Settings → Privacy & Security → Bluetooth** if declined).
- **Peers never show “online” (LAN)** — confirm both devices are on the same network/subnet, allow the app through the OS firewall (UDP 45654 inbound), and note that some guest/public Wi‑Fi networks block device‑to‑device traffic ("client isolation"). A phone hotspot is a reliable fallback.
- **macOS: network or Bluetooth blocked** — the app sandbox needs the network client/server and Bluetooth entitlements; they are already set in `macos/Runner/*.entitlements` in this repo. If you regenerate the macOS project with `flutter create .`, re‑add them.
