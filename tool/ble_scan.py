"""Checks whether this computer's Bluetooth hears nearby devices at all, with
no Meshenger code involved. Works on Windows, macOS and Linux.

    python -m pip install bleak
    python tool/ble_scan.py            # 15 s active scan
    python tool/ble_scan.py 30 passive

Keep Meshenger open on the other device. If this hears nothing at all, the
problem is the OS or its Bluetooth driver, not Meshenger.
"""

import asyncio
import sys

from bleak import BleakScanner

MESHENGER_SERVICE = "4d455348-454e-4745-5242-4c4530303031"


async def main(seconds: int, mode: str) -> None:
    seen = {}

    def on_advertisement(device, adv):
        entry = seen.setdefault(
            device.address, {"heard": 0, "rssi": -127, "name": "", "meshenger": False}
        )
        entry["heard"] += 1
        entry["rssi"] = max(entry["rssi"], adv.rssi)
        if adv.local_name:
            entry["name"] = adv.local_name
        uuids = [u.lower() for u in adv.service_uuids]
        if MESHENGER_SERVICE in uuids or adv.local_name == "MSH":
            entry["meshenger"] = True

    print(f"Listening for Bluetooth LE advertisements for {seconds} s ({mode} scan)...")
    async with BleakScanner(on_advertisement, scanning_mode=mode):
        await asyncio.sleep(seconds)

    total = sum(e["heard"] for e in seen.values())
    print(f"Heard {total} advertisements from {len(seen)} devices.")
    for address, e in sorted(seen.items(), key=lambda kv: -kv[1]["rssi"])[:20]:
        tag = "  <- Meshenger" if e["meshenger"] else ""
        print(f"  {address}  {e['rssi']:4} dBm  heard {e['heard']:3}x  {e['name']}{tag}")

    print()
    if total == 0:
        print("Bluetooth heard nothing at all, with no app involved: the problem is "
              "the OS or its Bluetooth driver, not Meshenger.")
        if sys.platform == "win32":
            print("On Windows, use Start > Power > Restart (not Shut down: with Fast "
                  "Startup on, Shut down doesn't reset the Bluetooth chip), then run "
                  "this again.")
    elif not any(e["meshenger"] for e in seen.values()):
        print("Bluetooth works, but no Meshenger device was heard. Is Meshenger open "
              "and unlocked on the other device?")
    else:
        print("Bluetooth works and a Meshenger device is in range.")


if __name__ == "__main__":
    asyncio.run(main(
        int(sys.argv[1]) if len(sys.argv) > 1 else 15,
        sys.argv[2] if len(sys.argv) > 2 else "active",
    ))
