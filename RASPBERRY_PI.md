# Meshenger on a Raspberry Pi

A Raspberry Pi running Meshenger extends the mesh: put one on a windowsill, in a shed or halfway down the street, and messages hop through it to reach people you couldn't reach before. It only ever passes along encrypted messages it can't read.

There are two ways to set one up:

| | **Relay only** | **Relay you can also chat on** |
| --- | --- | --- |
| What it does | Sits quietly and passes messages along, day and night | The same, plus the full Meshenger app on a screen |
| Pi | Zero 2 W, 3, 4 or 5 | 4 or 5 with at least 4 GB of memory |
| Also needed | Power supply, microSD card (8 GB or more) | Screen, keyboard and mouse, microSD card (32 GB or more) |
| Setup time | About 15 minutes | About an hour, mostly waiting |
| Status | Tested | Experimental: the full app on Linux is new |

Older 32-bit boards (the original Zero and Zero W, Pi 1 and Pi 2) can't run it.

**Use a proper power supply**, like the official Raspberry Pi one. A weak phone charger or a computer's USB port makes the Bluetooth radio misbehave in confusing ways. If you ever see `Undervoltage detected!`, fix the power supply first.

---

## Option 1: Relay only

### 1. Prepare the memory card

1. On your computer, install [Raspberry Pi Imager](https://www.raspberrypi.com/software/) and open it.
2. **Choose Device**: your Pi model.
3. **Choose OS**: **Raspberry Pi OS (other) → Raspberry Pi OS Lite (64-bit)**.
4. **Choose Storage**: your microSD card.
5. When Imager offers to customise the settings, choose **Edit settings** and set a **username and password**. Remember the username. If you'd like to control the Pi from your computer instead of plugging in a keyboard and screen, also turn on **SSH** on the Services tab.
6. Write the card, put it in the Pi and power it on. The first boot takes a minute or two.

The relay itself only uses Bluetooth. The Pi only needs an internet connection (Ethernet, or the network settings in Imager) if you want to download the relay directly on it. Otherwise, use a USB stick as described in step 2.

### 2. Get the relay program

Log in on the Pi with the keyboard and screen, or from your computer with `ssh YOUR_USERNAME@raspberrypi.local`.

**If the Pi is online**, download it:

```bash
mkdir -p ~/meshenger && cd ~/meshenger
wget -O meshenger-relay https://github.com/George-Freedland/meshenger/releases/latest/download/meshenger-relay-linux-arm64
chmod +x meshenger-relay
```

**If it isn't**, download `meshenger-relay-linux-arm64` from the [releases page](https://github.com/George-Freedland/meshenger/releases/latest) on your computer and copy it onto a USB stick. Plug the stick into the Pi, then:

```bash
lsblk                                    # find the stick, usually sda1
sudo mkdir -p /mnt/usb && sudo mount /dev/sda1 /mnt/usb
mkdir -p ~/meshenger
cp /mnt/usb/meshenger-relay-linux-arm64 ~/meshenger/meshenger-relay
chmod +x ~/meshenger/meshenger-relay
sudo umount /mnt/usb
```

### 3. Try it

Pick a name. It's what everyone sees on their Mesh Map.

```bash
sudo rfkill unblock bluetooth
cd ~/meshenger
sudo ./meshenger-relay --name "Garden Relay"
```

You should see lines like these:

```
[12:00:01] Meshenger relay "Garden Relay"
[12:00:01] Address: qIBX9YZ2aJ93k0Ls…
[12:00:01] This node forwards encrypted envelopes it cannot read.
[12:00:02] BLE: advertising Meshenger service as "Garden Relay"
[12:00:02] BLE: scanning for Meshenger devices
[12:00:02] Relay running over Bluetooth. Ctrl-C to stop.
[12:00:15] BLE: peer online AbCdEf123456… (F4:5C:89:AA:BB:CC)
```

Open Meshenger on your phone and go to the **Mesh Map**. The relay shows up by name within a minute. Press **Ctrl+C** on the Pi to stop it.

### 4. Start it automatically

This makes the relay start every time the Pi powers on, and restart itself if anything goes wrong:

```bash
cd ~/meshenger
wget https://github.com/George-Freedland/meshenger/releases/latest/download/meshenger-relay.service
sudo cp meshenger-relay.service /etc/systemd/system/
sudo sed -i "s/REPLACE_ME/$USER/g" /etc/systemd/system/meshenger-relay.service
sudo sed -i 's/"Pi Gateway"/"Garden Relay"/' /etc/systemd/system/meshenger-relay.service
sudo systemctl daemon-reload
sudo systemctl enable --now meshenger-relay
```

The second `sed` line sets the name; change `Garden Relay` to yours. The service file is also in this repository at [`relay/pi/meshenger-relay.service`](relay/pi/meshenger-relay.service) if you're copying from a USB stick.

Useful commands:

```bash
systemctl status meshenger-relay      # is it running?
journalctl -u meshenger-relay -f      # watch it work (Ctrl+C to stop watching)
sudo systemctl restart meshenger-relay
```

You can now unplug the screen and keyboard. The relay keeps its identity in `~/meshenger/relay-identity.json`, so it keeps the same address and name after every reboot. Delete that file to give it a new one.

### 5. Check that it really relays

1. Put two devices with Meshenger near the Pi.
2. Quit Meshenger on device B, then send B a message from device A.
3. Wait until the relay's log shows it received the message (`journalctl -u meshenger-relay -f`), then quit Meshenger on A too.
4. Open Meshenger on B. The message arrives from the Pi.

### Updating

```bash
cd ~/meshenger
sudo systemctl stop meshenger-relay
wget -O meshenger-relay https://github.com/George-Freedland/meshenger/releases/latest/download/meshenger-relay-linux-arm64
chmod +x meshenger-relay
sudo systemctl start meshenger-relay
```

---

## Option 2: A relay you can also chat on

This runs the full Meshenger app on a Pi with a screen, alongside the relay from Option 1. You can chat from the Pi like from any computer, and the relay keeps passing messages along even when the app is closed.

You need both because the Linux version of the app can find other devices but can't be found by them yet: the Bluetooth library it uses on Linux can't advertise. The relay covers that. They're two separate devices on the Mesh Map: your profile, and the relay's name.

> **Experimental.** The relay is tested on a Pi. The full app on Linux is new, so expect rough edges and please [report problems](https://github.com/George-Freedland/meshenger/issues).

### 1. Prepare the memory card

Follow Option 1, step 1, but choose **Raspberry Pi OS (64-bit)**, the version with a desktop. Connect the screen, keyboard and mouse, and connect the Pi to the internet: building the app downloads its tools.

### 2. Set up the relay

Open **Terminal** on the Pi and follow Option 1, steps 2 to 4.

### 3. Install the tools to build the app

```bash
sudo apt update
sudo apt install -y git curl unzip xz-utils zip build-essential clang cmake ninja-build \
  pkg-config libgtk-3-dev libmpv-dev mpv libepoxy-dev libsecret-1-dev gnome-keyring \
  pulseaudio-utils ffmpeg
sudo usermod -aG bluetooth $USER
```

Then restart the Pi so the last line takes effect.

### 4. Install Flutter

Flutter is the toolkit Meshenger is built with. On a 64-bit Pi you install it with git, and it downloads the right tools for the Pi on first use:

```bash
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
flutter doctor
```

`flutter doctor` takes a few minutes the first time. It needs a ✓ next to **Linux toolchain**. It also complains about Android and Chrome, which you can ignore.

### 5. Build Meshenger

```bash
git clone https://github.com/George-Freedland/meshenger.git ~/meshenger-app
cd ~/meshenger-app
flutter build linux --release
```

The first build can take 10 to 30 minutes on a Pi.

### 6. Open it

```bash
~/meshenger-app/build/linux/arm64/release/bundle/meshenger
```

To add it to the Pi's menu (under **Internet**):

```bash
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/meshenger.desktop <<EOF
[Desktop Entry]
Name=Meshenger
Exec=$HOME/meshenger-app/build/linux/arm64/release/bundle/meshenger
Icon=$HOME/meshenger-app/assets/branding/icon.png
Type=Application
Categories=Network;Chat;
EOF
```

Create your profile like on any device. If the Pi asks you to choose a password for a new "keyring", pick one: that's where the app keeps its keys.

### Good to know

- **Relaying is on by default.** Settings → **Relay messages for the mesh** controls it.
- **No QR scanning on the Pi.** Add people from the **Mesh Map** (tap them), or paste their address in **Contacts → Add contact**.
- **Location:** the Pi can't tell where it is. Open the Mesh Map's globe and long-press to pin its spot.
- **Updating:** `cd ~/meshenger-app && git pull && flutter build linux --release`.

---

## Where to put a relay

- A relay only helps where it can hear at least two other devices. Good spots are a windowsill between two houses, a hallway between apartments, or a shed halfway down the street.
- One Bluetooth hop reaches about 10–50 m, less through walls. A line of relays can cover a whole street.
- Relays reach iPhones in the background too: an iPhone in range stays subscribed to the relay, so the relay can deliver a message even when Meshenger isn't on screen. If someone swipes Meshenger away completely, iPhone ends that until they open it again.

## Relay options

| Option | What it does |
| --- | --- |
| `--name "Shed"` | The name shown on everyone's Mesh Map |
| `--identity <path>` | Where the relay keeps its keys (default: `relay-identity.json` next to the program) |
| `--max-spool 512` | How many messages it carries at once (default 256; each expires after 48 hours) |
| `--adapter 1` | Use a second Bluetooth adapter, such as a USB dongle (`hci1`) |

To change options for the automatic start, edit the `ExecStart` line with `sudo nano /etc/systemd/system/meshenger-relay.service`, then run `sudo systemctl daemon-reload && sudo systemctl restart meshenger-relay`.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| `Bluetooth unavailable` | Run `sudo rfkill unblock bluetooth && sudo systemctl restart bluetooth`, then start the relay again |
| A permission error when starting | Start it with `sudo`, as above. The automatic start already runs it as the system administrator |
| `Undervoltage detected!` | The power supply is too weak. Use the official power supply for your Pi model, with its own cable |
| `Failed to register advertisement` or `bluetoothd refused advertising` | The relay fixes this itself: it retries, resets the adapter, and if that fails it programs the Bluetooth chip directly (`advertising via raw-HCI fallback`). If it keeps failing, run `sudo systemctl restart bluetooth`, check the power supply, and restart the relay |
| The relay never shows up on the Mesh Map | Make sure Bluetooth is on and you're within about 10 m. Tap the refresh button on the Mesh Map. It can take up to a minute |
| `cannot execute binary file` | You have a 32-bit system. Reinstall with the **64-bit** Raspberry Pi OS |

Still stuck? [Open an issue](https://github.com/George-Freedland/meshenger/issues) and include the output of `journalctl -u meshenger-relay -n 100`.

## For developers

The relay is a small pure-Dart program in [`relay/`](relay/). To build it yourself from any computer with the [Dart SDK](https://dart.dev/get-dart):

```bash
cd relay
dart pub get
dart compile exe bin/relay.dart --target-os linux --target-arch arm64 -o meshenger-relay
```

Or run it from source on the Pi: `dart pub get && sudo dart run bin/relay.dart --name "Shed"`. See [`relay/README.md`](relay/README.md).
