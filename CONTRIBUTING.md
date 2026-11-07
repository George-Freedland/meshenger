# Contributing to Meshenger

Thanks for helping. This guide covers building Meshenger from source, checking your changes, how the code is organized, and making release builds. For how the mesh works under the hood, read [ARCHITECTURE.md](ARCHITECTURE.md).

**Ways to help without writing code:** try it on real devices and [report bugs](https://github.com/George-Freedland/meshenger/issues) (with the connection log: Messages → the receipt icon → copy), share range and hop tests, set up a [Raspberry Pi relay](RASPBERRY_PI.md), or improve these docs.

## Build and run

1. Install [Flutter](https://docs.flutter.dev/get-started/install) (stable channel; development happens on Flutter 3.47) and run `flutter doctor`.
2. Get the code:
   ```bash
   git clone https://github.com/George-Freedland/meshenger.git
   cd meshenger
   flutter pub get
   ```
3. Follow the setup for your platform below, then run it, for example `flutter run -d macos`.

You need **two devices with Bluetooth** to try messaging. The iOS Simulator and Android emulators have no Bluetooth, so use real phones.

Keep every development machine on the same Flutter version. A few packages are pinned by the Flutter SDK itself, so machines on different versions rewrite `pubspec.lock` back and forth on every `flutter pub get`.

### macOS

1. Install [Xcode](https://developer.apple.com/xcode/), open it once to accept the license, and run `xcode-select --install`.
2. Install CocoaPods (`brew install cocoapods` or `sudo gem install cocoapods`). The video player's libraries only come as CocoaPods, so the project uses both CocoaPods and Swift Package Manager.
3. `flutter run -d macos`. Approve the Bluetooth prompt on first launch.

### iOS

Needs a Mac with Xcode and a real iPhone or iPad.

1. Open `ios/Runner.xcworkspace` in Xcode → **Runner** target → **Signing & Capabilities**, and choose your team. If you're not the project owner, also change the bundle ID (see [Your own app ID](#your-own-app-id)).
2. Connect the phone, tap **Trust**, and turn on **Settings → Privacy & Security → Developer Mode** when iOS asks.
3. `flutter run -d ios` (add `--release` to test real performance).

### Windows

1. Install [Visual Studio 2022](https://visualstudio.microsoft.com/) (Community is fine) with the **Desktop development with C++** workload, and [Git for Windows](https://git-scm.com/download/win).
2. `flutter run -d windows`. The first build downloads the video player's libmpv DLLs, so it needs an internet connection once.

### Android

1. Install [Android Studio](https://developer.android.com/studio) and, from its SDK Manager, the Android SDK and platform tools.
2. Run `flutter doctor --android-licenses` and accept them.
3. Connect a phone with USB debugging turned on, then `flutter run -d android`.

### Linux

1. Install the build tools and the libraries the plugins need. On Debian, Ubuntu or Raspberry Pi OS:
   ```bash
   sudo apt-get install -y build-essential clang cmake ninja-build pkg-config libgtk-3-dev \
     libmpv-dev mpv libepoxy-dev libsecret-1-dev gnome-keyring pulseaudio-utils ffmpeg
   ```
   For other distributions, see [Flutter's Linux setup](https://docs.flutter.dev/platform-integration/linux/setup) and install the equivalent packages.
2. `flutter run -d linux`.

On Linux the Bluetooth plugin is central-only: the app finds and messages nearby devices but can't be found itself. Run the [relay daemon](relay/) alongside to cover that. Camera QR scanning isn't available on Linux or Windows. Building on a Raspberry Pi is covered in [RASPBERRY_PI.md](RASPBERRY_PI.md#option-2-a-relay-you-can-also-chat-on).

### Web

`flutter run -d chrome` runs the interface, but browsers can't act as a Bluetooth peripheral, so there's no mesh: messages stay pending. Use any other platform for real use.

### Trying it out

1. Run the app on two devices and create an identity on each.
2. Add each other: tap your name on one device's home screen to show its QR code and address, then **Contacts → Add contact** on the other (scan, or paste the address). Or tap the other device on the **Mesh Map**.
3. Chat. To prove it's Bluetooth-only, turn on airplane mode with Bluetooth back on.
4. To test store and forward, quit the app on one device, send it messages (they show as pending), then reopen it: they arrive and flip to delivered.

The **connection log** (Messages → the receipt icon) shows every step of discovery and delivery, and is the first thing to check when two devices don't see each other.

## Before you open a pull request

```bash
dart format lib test tool relay/lib relay/bin relay/test
flutter analyze
flutter test
cd relay && dart analyze && dart test
```

- Anything that touches Bluetooth or the protocol needs testing on **at least two real devices**. Say which ones in the pull request.
- **Keep the protocol compatible.** Meshes mix versions, so new fields must be optional and old builds must keep working (see [ARCHITECTURE.md](ARCHITECTURE.md#compatibility)).
- **No internet.** Meshenger never talks to a server. Don't add analytics, crash reporting, update checks, remote config or anything else that uses the network.
- Keep pull requests focused, one change each.
- Contributions are licensed under the [GPL-3.0](LICENSE), like the rest of the project.
- Found a security problem? Please follow [SECURITY.md](SECURITY.md) instead of opening an issue.

## Project layout

| Path | What's there |
| --- | --- |
| `lib/core/transport/` | Bluetooth transport (`ble_transport_io.dart`), packet framing and chunking, envelope encoding and signatures |
| `lib/core/services/` | Identity, messaging and routing, file transfer, calls, gossip and the peer directory, location, safety, storage and settings |
| `lib/core/media/` | Song tags, progressive playback |
| `lib/core/models/`, `lib/core/ui/` | Data classes and shared widgets |
| `lib/features/` | Screens: the home screen, chats and calls, the built-in apps (Contacts, Camera, Storage, Voice Memos, Mesh Map, Network, Settings), onboarding |
| `lib/routing/` | Routes (`go_router`) |
| `relay/` | The headless relay daemon for Linux and Raspberry Pi (pure Dart, BlueZ) |
| `packages/` | Patched copies of the Bluetooth plugins, see below |
| `assets/` | App icons, alert sounds, and the globe's world map |
| `tool/` | Release and helper scripts, see below |
| `docs/` | The website, served by GitHub Pages |
| `examples/` | A sample home page for the Network app's page editor |
| `test/` | Unit and widget tests |

## Patched Bluetooth plugins

`packages/` holds modified copies of three platform plugins of [`bluetooth_low_energy`](https://pub.dev/packages/bluetooth_low_energy) 6.2.1, wired in through `dependency_overrides` in `pubspec.yaml`. If you update `bluetooth_low_energy`, carry these changes over or check whether upstream has fixed them first.

- **Windows** (`bluetooth_low_energy_windows`):
  - Remembers each device's address type from its advertisement and passes it when connecting. macOS and iOS use random addresses, which the stock plugin can't connect to.
  - Delivers every callback on the platform thread (`windows/ui_thread.h`). The stock plugin calls Flutter from WinRT thread-pool threads, which loses replies. It also keeps COM alive when the video player shuts it down on the main thread.
  - Restarts advertising whenever Windows stops it, which it does after the first incoming connection.
  - Doesn't reconnect to a device that's already connected, which would orphan the open push channel.
  - Tolerates services that refuse to be read (macOS answers "access denied" for its own).
  - Asks for fast connection parameters during transfers (needs the Windows 11 SDK; builds without it on older SDKs).
- **macOS and iOS** (`bluetooth_low_energy_darwin`): holds writes without response until CoreBluetooth has room (it silently drops them otherwise), delivers several writes that arrive together as separate writes, and asks for a low-latency connection while pushing a transfer.
- **Android** (`bluetooth_low_energy_android`): asks for a high-priority connection while a bulk transfer is streaming, and goes back to normal a few seconds after it stops.

## Scripts in `tool/`

| Script | What it does |
| --- | --- |
| `set_app_id.sh` | Sets the app ID, publisher and display name on every platform |
| `release_macos.sh` | Builds the Mac app and packages a DMG and zip, signed and notarized when configured |
| `release_windows.ps1` | Builds the Windows app and zips it with the Visual C++ runtime |
| `ios_upload_options.plist` | Export options for uploading iOS builds to App Store Connect |
| `release_notes.md` | Notes for the GitHub release |
| `ble_scan.py`, `windows_ble_check.ps1` | Check whether a computer's Bluetooth hears anything at all, with no Meshenger code involved |
| `build_world_geo.dart` | Rebuilds the globe's world map from Natural Earth data |

## Your own app ID

To publish your own build, give it your own app ID first. It's permanent once published, because stores and signing keys are tied to it:

```bash
tool/set_app_id.sh com.yourname.meshenger "Your Name"
```

Also set your Apple team ID in `tool/ios_upload_options.plist`, and the Microsoft Store identity in `msix_config` in `pubspec.yaml`.

## Release builds

Before each release, raise `version:` in `pubspec.yaml`, for example `1.0.1+4`. The number after `+` must go up with every store upload. For the Microsoft Store, also raise `msix_version` (its last number stays 0).

### Android

Every update must be signed with the same key, so create one once and back it up:

```bash
keytool -genkey -v -keystore ~/meshenger-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

(`keytool` comes with Android Studio, in `Android Studio.app/Contents/jbr/Contents/Home/bin` on a Mac.) Then create `android/key.properties`, which is git-ignored:

```properties
storePassword=YOUR_PASSWORD
keyPassword=YOUR_PASSWORD
keyAlias=upload
storeFile=/full/path/to/meshenger-upload.jks
```

Without it, release builds fall back to the debug key. Build:

```bash
flutter build apk --release --target-platform android-arm64   # the download APK
flutter build appbundle --release                             # for Google Play
```

The APK is arm64 only, because the video player bundles its own decoders for each CPU type; arm64 covers practically every phone from the last seven years.

### macOS

Unsigned builds are fine on your own Mac, but downloads must be signed with a **Developer ID Application** certificate and notarized, or macOS refuses to open them. One-time setup: create the certificate in Xcode (**Settings → Accounts → Manage Certificates → + → Developer ID Application**). Only the team's Account Holder can; if Xcode refuses anyway, make a certificate signing request with Keychain Access (**Certificate Assistant → Request a Certificate From a Certificate Authority**, saved to disk), upload it at [developer.apple.com](https://developer.apple.com/account/resources/certificates/add) as a Developer ID Application certificate, and double-click the download to install it in the **login** keychain. Then create an app-specific password at [account.apple.com](https://account.apple.com), and store it:

```bash
xcrun notarytool store-credentials meshenger-notary \
  --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password YOUR_APP_SPECIFIC_PASSWORD
```

Then:

```bash
security find-identity -v -p codesigning            # copy the "Developer ID Application: …" name
export SIGN_IDENTITY="Developer ID Application: Your Name (YOUR_TEAM_ID)"
export NOTARY_PROFILE=meshenger-notary
tool/release_macos.sh                               # → build/dist/Meshenger-macOS.dmg
```

`MAC_ARCHS=arm64` builds for Apple silicon only.

### Windows

```powershell
powershell -ExecutionPolicy Bypass -File tool\release_windows.ps1   # → build\dist\Meshenger-Windows-x64.zip
```

The zip isn't code-signed, so Windows shows "Windows protected your PC" the first time. For the Microsoft Store, put your Partner Center identity in `msix_config` and run `dart run msix:create`; the Store signs the package itself.

### iOS

```bash
flutter build ipa --release
xcodebuild -exportArchive -archivePath build/ios/archive/Runner.xcarchive \
  -exportOptionsPlist tool/ios_upload_options.plist -exportPath build/ios/upload \
  -allowProvisioningUpdates
```

That uploads to App Store Connect with the account signed in to Xcode. Alternatively, use Xcode's **Organizer → Distribute App**, or drag the `.ipa` into Apple's Transporter app.

**Export compliance:** the app does its own encryption, but `Info.plist` deliberately has no `ITSAppUsesNonExemptEncryption` key. Setting it to true without the compliance code Apple issues for filed documentation gets uploads rejected (ITMS-90592). Instead, each build shows **Missing Compliance** in TestFlight: choose **standard encryption algorithms**, then answer the France question. Distributing in France requires a French encryption declaration.

### Raspberry Pi relay

```bash
cd relay && dart pub get
dart compile exe bin/relay.dart --target-os linux --target-arch arm64 -o ../build/dist/meshenger-relay-linux-arm64
cp pi/meshenger-relay.service ../build/dist/
```

### GitHub release

The website's download buttons link to the latest release's files by name, so keep these names: `Meshenger-macOS.dmg`, `Meshenger-Windows-x64.zip`, `Meshenger-Android.apk`, `meshenger-relay-linux-arm64` and `meshenger-relay.service`.

```bash
gh release create v1.0.1 --title "Meshenger 1.0.1" --notes-file tool/release_notes.md build/dist/*
```

## Troubleshooting builds

| Symptom | Fix |
| --- | --- |
| "No supported devices connected" | Run `flutter devices` and pick one with `-d <id>`, or finish the platform setup above |
| Build errors after upgrading Flutter | `flutter clean`, then `flutter pub get`, then build again |
| Windows: `error C2338 … <experimental/coroutine> … STL1011` | Newer Visual Studio versions removed headers the Windows Bluetooth plugin uses. `windows/CMakeLists.txt` defines `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` to restore them; re-add it if you regenerate the project with `flutter create .` |
| Windows: first build stops while downloading mpv | The build needs internet once to fetch libmpv. Run it again |
| macOS: Bluetooth never starts | The sandbox needs the Bluetooth entitlement in `macos/Runner/*.entitlements`. Re-add it if you regenerate the project |
| Mac build: `does not contain architectures "arm64 x86_64"` | Flutter is older than late July 2026 and can't build universal apps with Xcode 27. Upgrade, or use `MAC_ARCHS=arm64` |
| A Mac or iPhone build suggests removing CocoaPods | Don't: the video player's libraries only come as CocoaPods |
| Upload warns `Upload Symbols Failed … Avcodec.framework` | The video player's prebuilt libraries ship without debug symbols. Harmless |
| App Store Connect email `ITMS-91053: Missing API declaration` | A library uses an API Apple wants a reason for. Declare it in `ios/Runner/PrivacyInfo.xcprivacy` |
| Android: "App not installed" | A build signed with a different key is installed. Uninstall it first |
| Windows and Mac never see each other | Remove any old Bluetooth pairing between them (Meshenger never pairs, and a stale bond breaks connections), then press refresh on the Mesh Map. The connection log shows which step fails |
| A file transfer crawls at a few KB/s | One device runs an older build, which falls back to the slow format. Update both |
