MESHENGER RASPBERRY PI RELAY: OFFLINE QUICK START
=================================================

The full guide, including running the app on a Pi with a screen:
https://github.com/George-Freedland/meshenger/blob/main/RASPBERRY_PI.md

Put these on a USB stick:
  meshenger-relay-linux-arm64      the relay (from the GitHub releases page)
  meshenger-relay.service          optional: start it on every boot
  README-PI.txt                    this file

The Pi needs 64-bit Raspberry Pi OS (Lite is fine) and a proper power supply.


1. COPY THE RELAY TO THE PI
---------------------------
Plug the stick into the Pi, log in, and find the stick:

     lsblk

Look for a line like "sda1" whose size matches the stick. Then:

     sudo mkdir -p /mnt/usb
     sudo mount /dev/sda1 /mnt/usb
     mkdir -p ~/meshenger
     cp /mnt/usb/meshenger-relay-linux-arm64 ~/meshenger/meshenger-relay
     chmod +x ~/meshenger/meshenger-relay


2. RUN IT
---------
Pick any name. It shows on everyone's Mesh Map.

     sudo rfkill unblock bluetooth
     cd ~/meshenger
     sudo ./meshenger-relay --name "Garden Relay"

You should see:

     Meshenger relay "Garden Relay"
     Address: qIBX9YZ2aJ93k0Ls...
     Relay running over Bluetooth. Ctrl-C to stop.

Open Meshenger on a phone or computer -> Mesh Map. The relay appears
within about a minute.


3. START IT ON EVERY BOOT (optional)
------------------------------------
     sudo cp /mnt/usb/meshenger-relay.service /etc/systemd/system/
     sudo sed -i "s/REPLACE_ME/$USER/g" /etc/systemd/system/meshenger-relay.service
     sudo sed -i 's/"Pi Gateway"/"Garden Relay"/' /etc/systemd/system/meshenger-relay.service
     sudo systemctl daemon-reload
     sudo systemctl enable --now meshenger-relay

     journalctl -u meshenger-relay -f      # watch it work


IF YOU SEE "Undervoltage detected!"
-----------------------------------
The power supply is too weak. That throttles the Pi, wears out the
memory card and makes the Bluetooth radio unreliable. Use the official
power supply for your Pi model. Don't power it from a computer or TV.
Fix this before anything else.


IF YOU SEE "Failed to register advertisement"
---------------------------------------------
BlueZ (the Linux Bluetooth service) refused to broadcast. The relay
heals itself in stages: it retries, resets the adapter, drops the
broadcast name, and finally programs the radio directly ("advertising
via raw-HCI fallback"). It keeps retrying every 60 seconds, so a
passing failure fixes itself. If it keeps failing:

     sudo systemctl restart bluetooth
     sleep 3
     cd ~/meshenger && sudo ./meshenger-relay --name "Garden Relay"

To report it, include the output of:

     bluetoothctl show
     sudo journalctl -u bluetooth -n 30
     dmesg | grep -iE 'blue|hci'


GOOD TO KNOW
------------
- The relay keeps its identity in relay-identity.json next to the
  program. Delete it for a new address.
- --max-spool 512 carries more messages; --adapter 1 uses a USB
  Bluetooth dongle (hci1).
- Everything the relay carries is end-to-end encrypted. It can't read
  any of it.
