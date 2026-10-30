MESHENGER RASPBERRY PI GATEWAY — QUICK START
=============================================

What's on this stick (meshenger-pi/)
------------------------------------
  meshenger-relay                    READY-TO-RUN gateway program (64-bit Pi OS)
  meshenger-relay.service            optional: auto-start on boot
  README-PI.txt                      this file
  relay/                             source code (fallback path only)
  dartsdk-linux-arm64-release.zip    Dart SDK (fallback path only)
  pub-cache/                         offline packages (fallback path only)

FAST PATH (recommended) — no internet needed on the Pi
------------------------------------------------------
1. Plug this USB stick into the Pi. Log in, then find the stick:

     lsblk

   Look for a line like "sda1" whose size matches the stick.

2. Mount it and copy the program home:

     sudo mkdir -p /mnt/usb
     sudo mount /dev/sda1 /mnt/usb
     mkdir -p ~/meshenger
     cp /mnt/usb/meshenger-pi/meshenger-relay ~/meshenger/
     chmod +x ~/meshenger/meshenger-relay

3. Make sure Bluetooth is on:

     sudo rfkill unblock bluetooth
     sudo systemctl start bluetooth

4. Run the gateway (pick any name — it shows on everyone's Mesh Map):

     cd ~/meshenger
     sudo ./meshenger-relay --name "Pi Gateway"

   You should see lines like:

     Meshenger relay "Pi Gateway"
     Address: MSGR-...
     Relay running over Bluetooth. Ctrl-C to stop.

5. On your Mac / Windows / phone: open Meshenger -> Mesh Map.
   "Pi Gateway" appears within ~30-60 seconds.

VERIFY IT ACTUALLY RELAYS
-------------------------
- Run Meshenger on two devices near the Pi.
- QUIT the app on device B. Send it a message from device A.
- Watch the Pi's log: it spools the encrypted envelope.
- Reopen the app on device B -> the message arrives via the Pi.

START ON EVERY BOOT (optional)
------------------------------
     sudo cp /mnt/usb/meshenger-pi/meshenger-relay.service /etc/systemd/system/
     sudo sed -i "s/REPLACE_ME/$USER/g" /etc/systemd/system/meshenger-relay.service
     sudo systemctl daemon-reload
     sudo systemctl enable --now meshenger-relay

     journalctl -u meshenger-relay -f      # watch the live logs

FALLBACK PATH (only if the prebuilt binary won't run)
-----------------------------------------------------
Uses the SDK + source + offline packages; still no internet needed:

     cp -r /mnt/usb/meshenger-pi/relay ~/meshenger-src
     cp -r /mnt/usb/meshenger-pi/pub-cache ~/pub-cache-offline
     unzip /mnt/usb/meshenger-pi/dartsdk-linux-arm64-release.zip -d ~/dart
     export PATH="$HOME/dart/dart-sdk/bin:$PATH"
     export PUB_CACHE="$HOME/pub-cache-offline"
     cd ~/meshenger-src && dart pub get --offline
     sudo -E "$(command -v dart)" run bin/relay.dart --name "Pi Gateway"

IF YOU SEE "Undervoltage detected!"
-----------------------------------
Your power supply is too weak — this throttles the Pi, corrupts SD cards
over time, and destabilizes the Bluetooth radio. Use a proper
5V / 2.5A wall supply (official Pi PSU or a good 12W phone charger) with a
short, thick micro-USB cable. Do NOT power the Pi from a computer, TV, or
console USB port. Fix this before debugging anything else.

IF YOU SEE "Failed to register advertisement"
---------------------------------------------
BlueZ (the Linux Bluetooth daemon) refused to start the broadcast. The
relay heals itself in stages: it retries, power-cycles the adapter, drops
the broadcast name, and finally programs the radio DIRECTLY (raw HCI),
bypassing the daemon's broken advertising path — you'll see
"advertising via raw-HCI fallback" when that engages. It also keeps
retrying every 60 s forever, so a transient failure fixes itself.

If it stays failing across restarts:

     sudo systemctl restart bluetooth
     sleep 3
     cd ~/meshenger && sudo ./meshenger-relay --name "Pi Gateway"

Still failing? Collect these and compare/report:

     sudo bluetoothctl advertise on      # does the OS stack itself work?
     bluetoothctl show                   # look at the Advertising Features
     sudo journalctl -u bluetooth -n 30  # daemon-side error details
     dmesg | grep -iE 'blue|hci'         # controller/firmware errors

A weak power supply (see above) is a common root cause on Pi 3 boards.

TIPS
----
- The gateway's identity (its mesh address + keys) lives in
  relay-identity.json next to the binary. Delete it for a fresh address.
- Useful flags:  --max-spool 512   carry more messages
                 --adapter 1       use a USB Bluetooth dongle (hci1)
- Everything the Pi forwards is end-to-end encrypted. It cannot read any
  of it — it only sees opaque envelopes and delivery addresses.
