# Meshenger launch playbook

Follow this top to bottom. Every `- [ ]` is one action. Anything in `ALL_CAPS` is something you replace with your own value.

## The plan in one minute

- **Ship free downloads first, store listings second.** In week 1 you publish a Mac download, a Windows download and an Android APK on GitHub, plus an iPhone beta on TestFlight. Google Play, the Microsoft Store and the App Store follow in weeks 2–4, because each has a review or waiting period.
- **Yes, use TestFlight.** It's the only way to get Meshenger onto iPhones before App Store approval. A public link takes up to 10,000 testers, and "join the beta" is a good call to action.
- **Short videos are the engine; Reddit and Hacker News are the spark.** The core demo (two phones in airplane mode texting each other) is visual and surprising, which suits 15–25 second vertical videos. Post one a day for 30 days on TikTok, YouTube Shorts and Instagram Reels. Use Show HN and a few subreddits for the launch-day spike, and one long YouTube video for depth.
- **Lead with what bitchat doesn't do.** bitchat (Jack Dorsey's Bluetooth chat app) already owns "offline chat", with millions of installs. Your hook is the offline *internet*: personal websites that hop from phone to phone, laptops in the mesh, and $15 Raspberry Pi relays.
- **Win one place before the world.** A mesh needs density. 1,000 users scattered worldwide are 1,000 lonely apps. 50 users on one campus are a working network, and they generate your best videos.

### Where each version goes

| Platform | What people download | Where | What it costs you |
| --- | --- | --- | --- |
| Mac | `Meshenger-macOS.dmg`, signed and notarized (opens with no warning) | GitHub + your website | Apple Developer Program, $99/year |
| iPhone and iPad | TestFlight beta, then the App Store | TestFlight public link | Same $99 |
| Windows | `Meshenger-Windows-x64.zip` now, Microsoft Store next | GitHub, then Store | Free |
| Android | `Meshenger-Android.apk` now, Google Play after a 14-day test | GitHub, then Play | $25 once |
| Raspberry Pi relay | `meshenger-relay-linux-arm64` | GitHub | Free |
| Linux desktop | Build from source for now | README | Free |

Total to launch everywhere: **$124**. Optional later: Windows code signing for the zip (about $10/month, US/Canada individuals only) and a custom domain (about $12/year).

---

## Phase 0: Decisions (30 minutes)

- [x] **App ID: done.** It's `com.georgefreedland.meshenger` everywhere (step 1.2). It's permanent: app stores, signing keys and updates are tied to it forever.
- [ ] **Open source.** Recommended: make the GitHub repo **public** under **GPL-3.0**. For a privacy app, public code is what makes "end-to-end encrypted" believable. Hacker News and Reddit reward it, and GitHub stars become social proof. GPL means anyone can read, audit and improve it, but nobody can ship a closed-source clone. As the copyright owner, you can still publish to the App Store.
  - If you'd rather keep the code private, create a separate public repo `meshenger-releases` for downloads. Then change `REPO` in `docs/index.html` and skip the license step.
- [x] **Contact email: done.** `george.meshenger@gmail.com` is in the privacy policy, the terms, the website and the app's Report and Contact buttons (`lib/core/app_info.dart`). Use the same address in every store listing.
- [ ] **Name check.** Search "Meshenger" on the App Store, Google Play and Microsoft Store. If a store already has it, use `Meshenger: Offline Mesh Chat` as that store's listing name.

---

## Phase 1: Get the code release-ready (one afternoon)

### 1.1 Upgrade Flutter on both computers

Flutter 3.38 can't make Mac release builds with Xcode 27. It fails with `does not contain architectures "arm64 x86_64"` ([flutter#188346](https://github.com/flutter/flutter/issues/188346)). Stable releases from late July 2026 onward fix it.

- [x] **Mac: done.** It's on Flutter 3.47.9. Analysis, tests and universal Mac and iOS release builds all pass on it. The upgrade moved the Mac and iOS projects to Swift Package Manager for plugins. That's expected; commit those project changes along with everything else.
- [ ] **Windows:** in PowerShell, run the same version, then check it:
  ```powershell
  flutter upgrade
  flutter --version          # must say 3.47.9, the same as the Mac
  cd C:\path\to\meshenger
  flutter pub get; flutter analyze; flutter test
  ```
  If `analyze` or `test` fails, send me the output.
- [ ] For App Store screenshots later: Xcode → **Settings → Components** → get the **iOS 27 Simulator** (`flutter doctor` flags it as missing).

### 1.2 Set the app ID and name

- [x] **Done** with `tool/set_app_id.sh com.georgefreedland.meshenger "George Freedland"`. It updated Android, iOS, macOS, Windows, Linux and web. The app is **Meshenger** everywhere, and the Windows publisher and copyright are your name. The Mac and iOS release builds were checked with the new ID.
- [ ] **Expect a fresh start.** The new ID gives the app a new data folder on every machine, so your test identities won't appear. Their files stay on disk. Create new identities:
  - On the Mac.
  - On Windows, after `git pull`.
- [ ] Republish your creator page. Your new identity has a new public key, so it's a new site. Open the Home page editor and paste in `examples/creator_home.html`.

### 1.3 App icon

- [x] **Done.** It's the mesh "M", on every platform. The images are in `assets/branding/`:
  - `icon.png`: iOS, Windows and web.
  - `icon_android_foreground.png`: Android, shrunk so circular masks don't clip it.
  - `icon_macos.png`: Apple's rounded-square shape.
- To change it later, replace those files and run `dart run flutter_launcher_icons`.

### 1.4 License

- [x] **Done.** `LICENSE` is GPL-3.0. If you decide to keep the code private after all, delete `LICENSE` and the "free software under the GNU GPL v3" line in `TERMS.md`.

### 1.5 Privacy policy

- [x] **Done.** `PRIVACY.md` has your email. Read it once to make sure you're happy with it. Every store form asks for a privacy policy URL, so use this one. It works once the repo is public (1.8):
  `https://github.com/George-Freedland/meshenger/blob/main/PRIVACY.md`

### 1.6 Android signing key (once, then back it up)

Every Android update must be signed with the same key. **If you lose it, you can't update the app for anyone who installed it.**

- [ ] Your Mac doesn't have Android Studio yet. Install it and the Android SDK by following **README → Android → Setup**, then run `flutter doctor` until **Android toolchain** shows a ✓.
- [ ] Create the key, choosing a strong password when asked:
  ```bash
  "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool" -genkey -v \
    -keystore ~/meshenger-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
  ```
- [ ] Create `android/key.properties`. It's git-ignored, so it never gets committed:
  ```properties
  storePassword=YOUR_PASSWORD
  keyPassword=YOUR_PASSWORD
  keyAlias=upload
  storeFile=/Users/georgefreedland/meshenger-upload.jks
  ```
- [ ] Back up `~/meshenger-upload.jks` and the password in a password manager **and** on a USB stick.

Release builds now use this key automatically. Without `key.properties` they fall back to the debug key. This signing setup hasn't been compiled yet, because the Mac had no Android SDK. If the first `flutter build apk` fails, send me the error.

### 1.7 Safety features (required before the App Store and Google Play)

Both stores require apps with user-generated content (chats, Global posts, sites) to let users **block** people and **report** content. They also require **terms** saying abuse isn't tolerated, and a published **contact** address. Apple calls this guideline 1.2.

- [x] **Built.** Here's what's in the app:
  - **Terms at first launch.** `TERMS.md` is shown once per device, with zero tolerance for abuse, before anyone can create an identity.
  - **Block.** Available from a chat's menu, person details on the Mesh Map, and a site's or post's ⋮ menu. A blocked person's messages, calls and file offers are dropped before they're stored or notified, and their posts and site are hidden. Settings → **Blocked people** unblocks.
  - **Hide.** Any post or page from its ⋮ menu. Settings → **Show hidden posts again** brings them back.
  - **Report.** A person, post, page or site. It opens a pre-filled email to your contact address with the reason, the full public key and the post. It never includes chat messages. Reporting hides the post and offers to block, on by default. With no mail app, the report is copied to the clipboard instead.
  - **Contact, Terms and Privacy** links in Settings → Safety.
- [ ] Read **Handling reports** in Phase 5. `TERMS.md` promises reports are reviewed within 24 hours, so check that inbox daily.
- [ ] Try it once. Run the app on the Mac:
  - The terms screen appears first.
  - Agree, and you're at the login screen.
  - In Settings, the Safety section is there.
- [ ] Report a test post from your Windows identity on Global. Your mail app opens with the report filled in.

### 1.8 Make the repository public

- [ ] Check that no secret was ever committed. This should print **nothing**:
  ```bash
  git log --all --name-only --format='' | sort -u | grep -Ei '\.jks$|\.keystore$|key\.properties|\.p12$|\.p8$|\.mobileprovision$|relay-identity|\.env$'
  ```
- [ ] Then:
  - **Settings → General → Danger Zone → Change visibility → Public.**
  - **Settings → General → Features:** turn on **Issues** and **Discussions**.
  - **About (gear icon on the repo page):** set the website to `https://george-freedland.github.io/meshenger/` and add topics: `bluetooth`, `mesh-network`, `offline`, `p2p`, `messenger`, `privacy`, `flutter`, `raspberry-pi`.

### 1.9 Version numbers

`pubspec.yaml` has `version: 1.0.0+1`. Before every release, bump both parts. For example, `1.0.1+2`: `1.0.1` is what users see, and `+2` must go up on every store upload.

---

## Phase 2: Build the downloads (one day the first time)

Everything ends up in `build/dist/`, which isn't committed.

### 2.1 Mac: signed and notarized DMG

Unsigned Mac apps get blocked ("Apple could not verify…"), so this step is what makes Mac downloads usable.

One-time setup:

- [ ] Join the **Apple Developer Program** as an individual: <https://developer.apple.com/programs/enroll/> ($99/year, approval usually within 48 hours).
- [ ] Create a **Developer ID Application** certificate: Xcode → **Settings → Accounts** → your team → **Manage Certificates…** → **+** → **Developer ID Application**.
- [ ] Find your signing identity:
  ```bash
  security find-identity -v -p codesigning
  ```
  Copy the quoted text that looks like `Developer ID Application: George Freedland (AB12CD34EF)`. The part in brackets is your **Team ID**.
- [ ] Create an app-specific password: <https://account.apple.com> → **Sign-In and Security → App-Specific Passwords → +**, and name it `notarytool`.
- [ ] Store the notarization login in your keychain:
  ```bash
  xcrun notarytool store-credentials meshenger-notary \
    --apple-id YOUR_APPLE_ID_EMAIL --team-id YOUR_TEAM_ID --password YOUR_APP_SPECIFIC_PASSWORD
  ```

Every release:

- [ ] Build:
  ```bash
  export SIGN_IDENTITY="Developer ID Application: George Freedland (YOUR_TEAM_ID)"
  export NOTARY_PROFILE=meshenger-notary
  tool/release_macos.sh
  ```
  This takes 5–15 minutes, because Apple notarizes the app and then the DMG. It produces `build/dist/Meshenger-macOS.dmg`.
- [ ] Test on another Mac, or a second user account on yours: open the DMG, drag Meshenger to Applications and launch it. There should be **no warning**.
- [ ] If notarization fails, run `xcrun notarytool log SUBMISSION_ID --keychain-profile meshenger-notary` and send me the output. The unsigned build and DMG have been tested; signing with your real certificate hasn't been run yet.

### 2.2 Windows: zip

- [ ] On the Windows laptop, after `git pull`:
  ```powershell
  powershell -ExecutionPolicy Bypass -File tool\release_windows.ps1
  ```
  This produces `build\dist\Meshenger-Windows-x64.zip`. It includes the Visual C++ runtime, so it runs on PCs that don't have it installed.
- [ ] Test on a PC that has never had Flutter: extract the zip, then run `meshenger.exe`. Windows will say "Windows protected your PC". Click **More info → Run anyway**. That's expected for unsigned downloads. The Microsoft Store version in 3.5 removes it.

### 2.3 Android: APK and App Bundle

- [ ] On the Mac:
  ```bash
  flutter build apk --release --target-platform android-arm64
  mkdir -p build/dist && cp build/app/outputs/flutter-apk/app-release.apk build/dist/Meshenger-Android.apk
  flutter build appbundle --release   # for Google Play: build/app/outputs/bundle/release/app-release.aab
  ```
  The video player bundles its own decoders for each kind of phone CPU, so an APK with all of them would be huge. The download APK is the arm64 one, which runs on practically every phone from the last seven years. Google Play's App Bundle carries them all but gives each phone only its own.
- [ ] The patched Bluetooth plugin (`packages/bluetooth_low_energy_android`, which asks for a fast connection during transfers) and the video player haven't been compiled for Android yet, because the Mac had no Android SDK. If the first build fails, send me the error.
- [ ] Confirm the APK is signed with your key. It should print your name, not "Android Debug":
  ```bash
  "$(ls -d ~/Library/Android/sdk/build-tools/* | tail -1)/apksigner" verify --print-certs build/dist/Meshenger-Android.apk
  ```
- [ ] Test on a phone. If an older debug build is installed, uninstall it first, or Android says "App not installed".

### 2.4 iPhone: TestFlight

You need the Apple Developer Program membership from 2.1 (the same $99 covers iPhone), an iPhone and the Mac. The project is ready: the iOS release build compiles, the Bluetooth background modes, permission texts and encryption flag are in `Info.plist`, and `ios/Runner/PrivacyInfo.xcprivacy` declares the system calls the video player uses (App Store Connect rejects uploads without it).

- [ ] **Register the app.** In [App Store Connect](https://appstoreconnect.apple.com), go to **Apps → + → New App**. Choose iOS, name **Meshenger**, primary language English, bundle ID `com.georgefreedland.meshenger`, SKU `meshenger`. If the bundle ID isn't in the list, register it under [Identifiers](https://developer.apple.com/account/resources/identifiers/list) first (**+ → App IDs → App**, explicit ID, no extra capabilities).
- [ ] **Signing.** Open `ios/Runner.xcworkspace` in Xcode → **Runner** target → **Signing & Capabilities**. Set **Team** to your account and keep **Automatically manage signing** on.
- [ ] **Try it on your iPhone first.** Plug it in and tap **Trust**. When iOS asks, turn on **Settings → Privacy & Security → Developer Mode** and restart the phone. Then run `flutter run -d ios --release` and confirm it chats with your Mac over Bluetooth and plays a song before you involve Apple.
- [ ] **Bump the build number** in `pubspec.yaml`: every upload needs a higher number after the `+` (step 1.9). Build 2 (`1.0.0+2`) is uploaded, so the next one is `1.0.0+3`.
- [ ] Build:
  ```bash
  flutter build ipa --release        # produces build/ios/ipa/*.ipa
  ```
  If it can't find a signing certificate or profile, do the Signing step once in Xcode and run it again. If only the export step fails, run `open build/ios/archive/Runner.xcarchive`. Xcode's Organizer opens; click **Distribute App → App Store Connect → Upload** and skip Transporter.
- [ ] Upload. Quickest is from Terminal, using the Apple account signed in to Xcode. It skips the symbol upload, which only produces warnings for the video player's libraries:
  ```bash
  xcodebuild -exportArchive -archivePath build/ios/archive/Runner.xcarchive \
    -exportOptionsPlist tool/ios_upload_options.plist -exportPath build/ios/upload \
    -allowProvisioningUpdates
  ```
  It ends with `Upload succeeded`. Alternatively, drag the `.ipa` into Apple's **Transporter** app (free on the Mac App Store) and click **Deliver**. Processing takes 5–30 minutes, and Apple emails you when the build is ready, or if something is wrong with it.
- [ ] **Encryption.** Each processed build shows **Missing Compliance** in TestFlight. Click **Manage** and choose **Standard encryption algorithms instead of, or in addition to, using or accessing the encryption within Apple's operating system** (the app encrypts messages itself), then answer **No** for France. No documents are needed **unless you distribute in France**, which needs a French encryption declaration. Simplest: leave France out of availability until you've filed one. [Apple's guide](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/).
  - `Info.plist` deliberately has no `ITSAppUsesNonExemptEncryption` key. Setting it to true makes Apple reject the upload (ITMS-90592) unless it comes with the compliance code Apple issues for filed documentation, and false would be wrong for this app. Once Apple gives you a code, add both keys and the question stops appearing.
- [ ] **TestFlight → Internal Testing → +**: add yourself, install the **TestFlight** app on your iPhone and test.
- [ ] **TestFlight → External Testing → +**: create a group called "Public beta" and add the build. Fill in **Test Information**:
  - Feedback email: your contact email.
  - Privacy policy URL.
  - Beta description: "Meshenger lets phones text and share pages over Bluetooth with no internet."
  - Review notes: "No account is needed: tap Create New Identity and pick any password. Messaging needs two devices near each other with Bluetooth on. With one device you can browse Network → Global and build your own page. User content safety (guideline 1.2): users accept Terms of Use with zero tolerance for abuse at first launch. They can block people and report or hide posts, pages and sites from each item's ⋮ menu, and from chats and person details. Reports reach us by email and are reviewed within 24 hours. Confirmed abusive identities are blocked for all users in app updates. Contact details are in Settings → Safety. Location is optional and off by default: Settings → Location on the Mesh Map has two switches (approximate, about 1 km, or exact). It only places this device on other users' Mesh Map globe, device to device; it never reaches us or any server."
  - Submit. The first review usually takes about a day.
- [ ] Once it's approved, go to **External group → Testers → Create Public Link**, set the limit to 10,000 and copy the link. Paste it into `TESTFLIGHT_URL` in `docs/index.html`.
- [ ] **TestFlight builds expire after 90 days.** Upload a new build at least every 60 days.

### 2.5 Raspberry Pi relay

- [ ] Build the relay and copy its service file:
  ```bash
  cd relay && dart pub get
  dart compile exe bin/relay.dart --target-os linux --target-arch arm64 -o ../build/dist/meshenger-relay-linux-arm64
  cp pi/meshenger-relay.service ../build/dist/
  cd ..
  ```

### 2.6 Test before you publish

- [ ] Fresh install on Mac, Windows, Android and iPhone: create an identity and accept the permission prompts.
- [ ] Mac, Windows and a phone all chat with **Wi-Fi off**.
- [ ] Hop test: devices A and C out of range of each other, with B in the middle. A's message reaches C.
- [ ] Network: a Global post, a site, a page and a bookmark all work.
- [ ] The Pi relay shows up on the Mesh Map and forwards messages.
- [ ] **Transfer speed.** In a 1:1 chat, send a 2 MB file Mac → PC, then PC → Mac. The card shows the speed and time left while it runs. When it's done, the connection log (Messages → the receipt icon at the top) has a line like `FT: "song.mp3" complete … in 41 s at 49 KB/s`. Note both directions' numbers.
- [ ] **Songs stream.** Post an MP3 on Global. On the other device, tap play straight away: it plays while the bar fills, or says "Starts in 0:20" and starts by itself.
- [ ] **Videos play in the app.** Send an MP4 in a chat and post one on Global. Both play inside Meshenger (try full screen), without opening QuickTime, VLC or Media Player.
- [ ] **Mixed versions.** A device still on the previous build can chat with an updated one and receive files (more slowly).
- [ ] **Transfers survive drops.** Halfway through a big transfer, turn Bluetooth off on one device for 20 seconds, then back on. Both cards say "Paused at …", then it continues by itself from where it stopped. **Resume** on either card retries at once.
- [ ] **Save to the computer.** Long-press (or right-click) a received file, photo or song in a chat → **Save to this computer…**, and do the same from Storage. On a phone it's **Save or share…** (Save to Files, Save Image).

---

## Phase 3: Publish

### 3.1 GitHub release

The website's download buttons point at "latest release" links, so **asset names must match exactly**.

- [ ] Commit and push everything first. The release tag is created from what's on GitHub.
- [ ] Check the release notes in `tool/release_notes.md`. Edit them for each release.
- [ ] On the Mac:
  ```bash
  gh release create v1.0.0 --title "Meshenger 1.0" --notes-file tool/release_notes.md \
    build/dist/Meshenger-macOS.dmg build/dist/Meshenger-Android.apk \
    build/dist/meshenger-relay-linux-arm64 build/dist/meshenger-relay.service
  ```
- [ ] On Windows, after `winget install GitHub.cli` and `gh auth login`:
  ```powershell
  gh release upload v1.0.0 build\dist\Meshenger-Windows-x64.zip
  ```

### 3.2 Website (GitHub Pages, free)

- [ ] Once Apple approves the beta, set `TESTFLIGHT_URL` in `docs/index.html`, then commit and push. Until then the iPhone button says "Coming soon".
- [ ] Repo **Settings → Pages → Build and deployment**: source **Deploy from a branch**, branch **main**, folder **/docs** → **Save**.
- [ ] About a minute later the site is live at **https://george-freedland.github.io/meshenger/**. This is the link for every bio, video and post.

### 3.3 README header

- [x] **Done.** The top of `README.md` links to the download page. It goes live with Pages (3.2).
- [ ] Add your hero GIF under it once you've recorded one (4.2).

### 3.4 Google Play (start on day 1: it has a 14-day clock)

New personal accounts must run a **closed test with at least 12 testers for 14 days in a row** before they can publish.

- [ ] Create a developer account at <https://play.google.com/console/signup>: **Personal**, $25, ID verification, plus phone verification in the Play Console app.
- [ ] **Create app** → name Meshenger, App, Free.
- [ ] Before the first upload, go to **Test and release → App integrity → App signing**. If Play offers to use your own key, choose it and follow the on-screen export steps. Then GitHub APK installs and Play installs can update each other. If you skip this, people switching from the APK to Play must uninstall first and lose their data.
- [ ] **App content** forms:
  - Privacy policy: the URL from 1.5.
  - Ads: no.
  - App access: all features available without special access.
  - Content rating questionnaire: answer honestly. Users can interact with each other.
  - Target audience: 13+.
  - Data safety: the app sends nothing to you or any server. Read each question's help text for the case of messages sent between users.
- [ ] **Testing → Closed testing → Create track.** Upload `app-release.aab` and add testers using a Google Group. Send them the opt-in link. They must opt in **and install and open the app**, and stay opted in for 14 days.
- [ ] Recruit 15–20 testers, not 12: friends, family, classmates. Some will drop out. Ask them to actually message each other, because Google checks engagement.
- [ ] After 14 days, go to **Dashboard → Apply for production**. Approval usually takes up to 7 days.

### 3.5 Microsoft Store (free, and removes the Windows warning)

The Store signs your app itself, so Store installs show no SmartScreen warning and update automatically.

- [ ] Register at <https://storedeveloper.microsoft.com> → **Individual developer**. It's free and needs ID and selfie verification.
- [ ] In Partner Center: **Apps and games → New product → MSIX or PWA app** → reserve **Meshenger**.
- [ ] Open **Product identity** and copy **Package/Identity/Name** and **Package/Identity/Publisher** (it starts with `CN=`).
- [ ] `msix` is already a dev dependency, and `pubspec.yaml` already has an `msix_config` block. Replace its two placeholders with those values:
  ```yaml
  identity_name: PARTNER_CENTER_PACKAGE_IDENTITY_NAME       # e.g. 12345GeorgeFreedland.Meshenger
  publisher: PARTNER_CENTER_PACKAGE_IDENTITY_PUBLISHER      # e.g. CN=1A2B3C4D-…
  ```
  Its capabilities are `bluetooth,microphone,webcam` and nothing else, so the Store listing shows no internet access. Packaged Windows apps need the `bluetooth` capability declared, or Bluetooth silently does nothing.
- [ ] Every release, bump `msix_version` with the app version: `1.0.1.0` for `1.0.1`. The last number must stay 0 for the Store.
- [ ] Build the package on the Windows laptop:
  ```powershell
  dart run msix:create
  ```
  It builds the Windows release itself, bundles the video player's DLLs, and writes `build\windows\x64\runner\Release\meshenger.msix`.
- [ ] Before uploading, install it locally to check: double-click the `.msix` (Windows may ask to allow sideloading; Settings → System → For developers). Chat with the Mac once, since a packaged app runs with different permissions than the zip.
- [ ] Create a submission: free, category **Social**, age rating questionnaire, privacy policy URL, screenshots (1366×768 or larger) and description. Under **Packages**, upload the `.msix`. Under **Submission options → Restricted capabilities**, explain `runFullTrust`: "Desktop app built with Flutter; full trust is required for its native Bluetooth stack." Submit. Certification usually takes 1–3 business days.
- [ ] If `msix:create` errors, send me the message.

### 3.6 App Store

- [ ] In App Store Connect → your app → **App Store** tab, prepare version 1.0 and fill in:
  - Description, keywords, and the website as the support URL.
  - Privacy policy URL.
  - **App Privacy: Data Not Collected.** Nothing reaches you or any server. Optional location sharing goes only device to device, to other users' Mesh Maps, and never to you; say so in the review notes (below) so the reviewer isn't surprised by the location prompt.
  - Age rating questionnaire. Messaging and user content usually rate 13+ or higher.
  - iPhone 6.9" screenshots, and iPad 13" screenshots because the app runs on iPad. Simulator screenshots (**Cmd+S**) are fine.
- [ ] Select your TestFlight build and submit. Review usually takes 1–2 days.

### 3.7 Mac App Store (optional; the DMG keeps working alongside it)

The Mac app is already sandboxed with only the permissions it uses (Bluetooth, microphone, camera, files you pick), and its `Info.plist` has the app category and the encryption declaration that uploads require.

- [ ] In App Store Connect → your Meshenger app → **App Information**, add the **macOS** platform. Using the same bundle ID `com.georgefreedland.meshenger` on both makes it one purchase across iPhone, iPad and Mac.
- [ ] Certificates (one time): Xcode → **Settings → Accounts** → your team → **Manage Certificates… → +** → add **Apple Distribution** and **Mac Installer Distribution**.
- [ ] Open `macos/Runner.xcworkspace` in Xcode → **Runner** target → **Signing & Capabilities**: Team = your account, **Automatically manage signing** on. Xcode creates the Mac App Store profile. The sandbox and Bluetooth boxes are already ticked from the entitlements file.
- [ ] Build and upload:
  ```bash
  flutter build macos --release
  ```
  Then in Xcode: **Product → Archive** (scheme Runner, destination "Any Mac"). When the Organizer opens: **Distribute App → App Store Connect → Upload**. Xcode signs the player's libraries inside the app for you.
- [ ] In App Store Connect → **macOS App → version 1.0**: Mac screenshots (1280×800 or larger), description, privacy (**Data Not Collected**), the same encryption answer as iPhone, and the same review notes as TestFlight. Select the build and submit.

---

## Phase 4: The launch

### 4.1 Your message

- **Tagline:** The internet, without the internet.
- **One sentence:** Meshenger lets phones and laptops text, call and host websites over Bluetooth, with no Wi-Fi, no SIM and no servers; every device relays for the others.
- **Three proofs to show, not tell:**
  - Two phones in airplane mode texting each other.
  - A website that exists only on the phones around you.
  - A $15 Raspberry Pi extending the mesh down the street.
- **If someone says "isn't this bitchat?":** "bitchat is great for chat. Meshenger adds websites that travel between phones, Windows and Mac laptops, and Pi relays." Never trash them; their users are your users.

**Claims you can make:** no internet, no servers, no accounts; end-to-end encrypted (X25519 + AES-256-GCM, signed with Ed25519); relays only see ciphertext; open source (once public); works between phones and laptops.

**Claims you can't make (yet):**
- "Audited" or "military-grade."
- "Anonymous" or "untraceable": nicknames and public keys are visible nearby.
- "Safe for protests."
- "Unlimited range": it's 10–50 m per hop.
- "Works in the background forever": phones limit background Bluetooth.

One honest limitation in every long post buys you more trust than any feature.

### 4.2 Make these before launch day

- [ ] **Hero video (20 seconds):** the airplane-mode demo (script 1 below). It goes on the website, the README, X and every post.
- [ ] **Three GIFs:** a chat with airplane mode visible, the Mesh Map filling in, and publishing a page that loads on a second phone. Use them for the README and Reddit.
- [ ] **Store screenshots:** five per platform.
- [ ] **Ten short videos, filmed in advance**, so you can post daily without scrambling.

Recording tools:
- Mac: **Cmd+Shift+5**.
- iPhone: Control Center screen recording.
- Android: quick-settings screen recorder.
- Windows: **Win+Alt+R**.

Edit in **CapCut** (free): vertical 1080×1920 and auto-captions.

### 4.3 Short video scripts (TikTok, YouTube Shorts, Instagram Reels)

Rules for every video:
- Show **airplane mode being turned on** in the first two seconds. That's your proof.
- Big captions, because most people watch muted.
- Keep it 12–25 seconds and cut every pause.
- Film in real places, not at your desk.
- End with the name on screen, "free" and "link in bio".
- Post the same video on all three apps at the same time each day. Don't delete the flops.

| # | Hook (on-screen text, first second) | What you film | Last line |
| --- | --- | --- | --- |
| 1 | "Both phones are in airplane mode." | Swipe on airplane mode on both phones, Bluetooth back on, type "can you read this?", the other phone buzzes, zoom on the ✓✓ | "No Wi-Fi. No SIM. No servers. It's called Meshenger." |
| 2 | "This website doesn't exist on the internet." | Write three lines of HTML, publish, a friend's offline phone types your key and the page loads | "Your public key is your website." |
| 3 | "A $15 computer just extended my texts down the street." | Pi Zero on a windowsill, walk away until out of range, the message still arrives, the Mesh Map shows the Pi in between | "Every Pi makes the mesh bigger." |
| 4 | "How far can a text travel with no internet?" | Friends spaced along a street or campus, stopwatch, the message hops end to end | "5 phones. 200 meters. 8 seconds." (your real numbers) |
| 5 | "No Wi-Fi on this flight. Still texting." | Plane window, two phones across the aisle, message (Bluetooth in airplane mode is allowed on most airlines) | "Works anywhere there are people." |
| 6 | "My Windows laptop and my Mac are talking with Wi-Fi off." | Wi-Fi-off icons on both, each appears on the other's Mesh Map, chat | "Phones, laptops, even a Raspberry Pi." |
| 7 | "Zero bars at this festival. Our group chat still works." | The crowd, the Global page filling with posts from people nearby | "The more people, the further it reaches." |
| 8 | "I sent a disappearing photo with no internet." | View-once photo, the other person opens it, it burns on both phones | "End-to-end encrypted. Offline." |
| 9 | "Watch me vanish from his map." | Your dot on a friend's Mesh Map, tap Invisible, it disappears | "You can still send and receive." |
| 10 | "Day 1 of building an internet that works without the internet." | Build-in-public: one feature or test per day, face to camera with a screen recording | "Follow to see if it works." |
| 11 | "I just dropped a song to everyone in this room. No internet." | Post an MP3 on Global (the card shows its cover art), friends' phones in airplane mode tap play, the song downloads from your phone and plays | "Your mixtape, passed phone to phone." |

Also **reply to comments with videos**, like "does it work through walls?" or "what's the range?". Each test answers a real question and the algorithms favor replies.

### 4.4 The long YouTube video (week 2)

**Title:** "I Built an Internet That Works Without the Internet". **Thumbnail:** you holding two phones, airplane icon, big "NO INTERNET".

| Time | Section |
| --- | --- |
| 0:00 | Cold open: the most impressive hop test you filmed |
| 0:45 | The problem: dead zones, flights, festivals, outages |
| 2:00 | The demo: two phones, airplane mode |
| 3:30 | How it works: hops and encryption explained with a simple animation |
| 5:30 | The mesh web: your public key is your website |
| 7:00 | The big test: Pi relays across your neighborhood |
| 9:00 | What doesn't work yet (honesty builds trust) |
| 10:00 | How to get it, and how to help |

### 4.5 Reddit

How to post:
- Read each subreddit's rules first. Many limit self-promotion or require a flair.
- Post to **one subreddit per day**, with a title and body written for that community, never the same text twice.
- Use your own account, which has history, not a new one; Reddit filters new accounts.
- Reply to every comment for the first two hours.
- Never ask for upvotes.

| Subreddit | Your angle |
| --- | --- |
| r/SideProject | "I built an offline internet over Bluetooth": the story, a GIF and what you learned |
| r/FlutterDev | Technical: one Flutter codebase doing a Bluetooth mesh on five platforms, and what broke (Windows GATT, collisions, Xcode 27) |
| r/raspberry_pi | The Pi Zero 2 W relay build, with photos |
| r/opensource and r/coolgithubprojects | The code and license, once the repo is public |
| r/androidapps, r/macapps | The app itself; check the developer-post rules |
| r/preppers | Communication when networks are down; practical, no fear-mongering |
| r/privacy | Only if self-promotion is allowed: the threat model and the honest limits |
| r/meshtastic | Ask, don't advertise: "Bluetooth phone mesh vs LoRa: where does each win?" |

Post template:
> **Title:** I built a messenger that works with no internet: phones relay messages (and websites) to each other over Bluetooth
>
> [GIF]
>
> Two phones in airplane mode can text each other. With more phones around, messages hop between them until they arrive. Each person's public key is also their own website, so pages travel phone to phone. It runs on Mac, Windows, Android and iPhone, and a $15 Raspberry Pi works as a relay.
>
> Honest limits: it's 10–50 m per hop, phones limit Bluetooth in the background, and it hasn't been audited yet.
>
> Free and open source: [website link]. I'd love feedback, especially range tests.

### 4.6 Hacker News

- [ ] Post on a weekday morning, US Eastern time.
  - **Title:** `Show HN: Meshenger – text and host websites over a Bluetooth mesh, no internet`
  - **Link:** the GitHub repo.
- [ ] Immediately add the first comment: who you are, what it does, how it works (gossip, multi-hop store-and-forward, X25519 + AES-GCM), what's not done yet (no audit, background limits), and what feedback you want.
- [ ] Stay for the next 3–4 hours and answer every question calmly. Don't ask anyone to upvote; HN penalizes it.

### 4.7 Everything else

- **X, Bluesky, Threads, Mastodon:** a launch thread with the hero video, then daily build-in-public clips. Mastodon and Bluesky have big privacy and open-source crowds.
- **Product Hunt (week 3, on a Tuesday):** tagline "The internet, without the internet", the hero video, five gallery images and a maker comment telling the story.
- **Press and newsletters:** a short email with the hero video link to Hackaday's tips line (they love Pi and mesh projects), It's FOSS, Android Police, 9to5Mac and Lifehacker. Three sentences: what it is, why it's new (websites over a Bluetooth mesh), and a link.
- **Real-world stunts**, which make your best content and your first dense clusters: a "mesh day" on a campus, a concert or festival, the subway, a flight, a power outage, a hike, or a "how far can a message walk" challenge with Pi relays.

### 4.8 Launch calendar

| Day | What to do |
| --- | --- |
| −10 | Enroll in Apple Developer; create the Play Console and Microsoft accounts; Phase 0 |
| −9 | Phase 1: Flutter upgrade on Windows, new identities on both machines, Android Studio and key, make the repo public |
| −8 | Upload the AAB to Play closed testing and send the opt-in link to 15–20 testers. **The 14-day clock starts.** |
| −7 | Phase 2 builds and tests; TestFlight internal testing |
| −6 | Submit TestFlight external testing for review |
| −5 to −2 | Film the hero video, GIFs and 10 shorts; write posts; make the repo public; turn on Pages |
| −1 | Publish the v1.0.0 GitHub release; add the TestFlight link to the site; final check of every download link |
| **0** (Tue) | Show HN at 9 am ET; r/SideProject; short #1; X/Bluesky thread |
| 1 | r/FlutterDev; short #2 |
| 2 | r/raspberry_pi; short #3 |
| 3 | r/opensource and r/coolgithubprojects; short #4; email Hackaday and It's FOSS |
| 4 | r/androidapps or r/macapps; short #5 |
| 5–6 | Shorts #6–7; fix the top bugs and ship v1.0.1 |
| 6 | Apply for Google Play production (14 days after day −8) |
| 7 | Publish the long YouTube video; short #8 |
| 8–13 | Daily shorts; Microsoft Store submission; r/preppers |
| 14 | Product Hunt |
| 15–30 | Daily shorts (reply videos, stunts); weekly releases; App Store submission; weekly metrics review |

### 4.9 When something takes off

- Pin a comment with the website link right away, and update your bio.
- Post a follow-up within 24 hours answering the top question from the comments.
- Check GitHub Issues every few hours, and ship a fix release fast; a viral moment with a crash bug burns out quickly.
- Keep the same message. Thank people publicly.

### 4.10 Measure weekly

- Download counts per file:
  ```bash
  gh api repos/George-Freedland/meshenger/releases \
    --jq '.[] | .tag_name as $t | .assets[] | "\($t)  \(.name)  \(.download_count)"'
  ```
- Also track TestFlight testers, Play installs, Store acquisitions, GitHub stars, and views and profile visits per video.
- Each week, do more of the top three videos and drop what doesn't move downloads.

---

## Phase 5: After launch

- **Release often:**
  - Bump `version:` in `pubspec.yaml`.
  - Rebuild with the Phase 2 steps.
  - Run `gh release create v1.0.1 …` with the same file names. The website's download buttons update automatically.
- **TestFlight:** upload a new build at least every 60 days (builds expire at 90).
- **Support:** GitHub Issues for bugs, Discussions for questions. Start a Discord once you have about 100 active users.
- **Build next, to make it spread (ask me):**
  - QR codes that open the website for people who don't have the app yet.
  - An "Invite a friend" share button.
  - Identity backup and restore: today a lost device means a lost identity.
  - Always-on Android relaying (a foreground service).

### Handling reports

There's no server, so you can't delete anything from other people's phones. What you can do is block an identity for everyone in the next update. The terms promise a review within 24 hours, and Apple and Google expect you to keep that promise.

- [ ] Check the contact inbox every day. A report includes the reason, the reported identity's full public key, and the post or page text if it was about one.
- [ ] If it clearly breaks `TERMS.md` (illegal content, threats, hate, harassment, non-consensual sexual content, spam), add the key to `builtInBlocked` in `lib/core/services/safety_service.dart`:
  ```dart
  static const Set<String> builtInBlocked = <String>{
    'THE_FULL_PUBLIC_KEY', // 2026-11-02: threats on Global
  };
  ```
  Then ship a release. Everyone who updates stops seeing that identity's messages, posts and site. It doesn't appear in their "Blocked people" list, so nobody can unblock it.
- [ ] Reply to the reporter: "Thanks, confirmed. It's blocked for everyone in version X." If it isn't a violation, explain that they can keep the person blocked on their side.
- [ ] **Child sexual abuse material:** don't forward or keep the content. In the US, report it to NCMEC's CyberTipline (<https://report.cybertip.org>) as well as blocking the key.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Mac: "Apple could not verify Meshenger is free of malware" | The DMG wasn't signed and notarized. Rebuild with `SIGN_IDENTITY` and `NOTARY_PROFILE` set (2.1) |
| Mac build: `does not contain architectures "arm64 x86_64"` | Flutter is older than late July 2026. Upgrade (1.1) or use `MAC_ARCHS=arm64` |
| Windows: "Windows protected your PC" | Expected for the zip. Click More info → Run anyway. Store installs don't show it |
| Android: "App not installed" | A build signed with a different key is installed. Uninstall it first |
| iPhone: "This beta has expired" | The TestFlight build is over 90 days old. Upload a new one |
| Play: can't apply for production | You need 12+ testers opted in for 14 days in a row. Check the closed test's tester count |
| Mac/iPhone build suggests removing CocoaPods | Don't. The video player's libraries (media_kit) only come as CocoaPods, so `pod deintegrate` would break the build |
| Windows: first build stops while downloading mpv | The video player downloads its libmpv DLLs on the first Windows build, so the build PC needs internet once. Rerun `flutter build windows` |
| Microsoft Store: "package identity doesn't match" | `identity_name` or `publisher` in `msix_config` still has the placeholder, or a typo. Copy both again from Partner Center → Product identity |
| A file transfer crawls (a few KB/s) | One of the two devices runs an older build, which falls back to the slow format. Update both |
| Banner: "Bluetooth went quiet" (Windows) | The scan heard nothing for 90 s even after restarting itself. Tap **Retry**; if it comes back, quit and reopen Meshenger; restart the PC only if that doesn't help. The connection log says what happened |
| Windows log: `COM on the app's main thread had been shut down by another component; started it again` | The media player (libmpv) releases COM on the app's main thread each time a player closes. The Bluetooth plugin now holds spare references so that never reaches zero, and repairs it if it does. Seeing this line again means it got through anyway: send me the log |
| A transfer shows "Paused at …" | The link dropped. It continues by itself within seconds of the devices hearing each other again (the log says `FT: resuming …`); **Resume** on the card tries right away. Cancel and **Send again** start over |
| Log: `dropped N bytes of a packet … that broke off mid-way` | A packet was cut off by a link drop and thrown away instead of corrupting the next one. Harmless; the file transfer re-sends what was lost |
| iPhone: tapping Save Image in the share sheet crashes | `NSPhotoLibraryAddUsageDescription` is missing from `ios/Runner/Info.plist`. It's there now; rebuild |
| Upload fails: `Invalid Export Compliance Code … key value []` (ITMS-90592) | `Info.plist` sets `ITSAppUsesNonExemptEncryption` to true without the `ITSEncryptionExportComplianceCode` Apple issues for filed documentation. Remove the key (as the project now does) and answer the encryption questions per build in TestFlight |
| Upload warns `Upload Symbols Failed … did not include a dSYM for Avcodec.framework` (and other frameworks) | The video player's prebuilt libraries ship without debug symbols. Harmless: the upload still goes through. Untick **Upload your app's symbols** to hide the warnings |
| App Store Connect email `ITMS-91053: Missing API declaration` | A bundled library uses an API Apple wants a reason for. `ios/Runner/PrivacyInfo.xcprivacy` declares the ones the video player uses; send me the email if a new one appears |
