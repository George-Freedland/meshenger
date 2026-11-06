# Meshenger relay

A headless Meshenger node for Linux: a Raspberry Pi, an old laptop, anything with Bluetooth and BlueZ. It speaks the same Bluetooth protocol as the app, so phones and computers see it as just another device in the mesh.

It stores and forwards end-to-end encrypted envelopes it can't read, re-floods gossip so devices on either side learn about each other, pushes waiting envelopes to devices subscribed to its outbox (that's how it reaches iPhones in the background), carries the neighborhood's Network posts, and passes file-transfer chunks straight through without storing them. Its only key signs its own announcements.

**Setting one up on a Pi:** see [RASPBERRY_PI.md](../RASPBERRY_PI.md).

## Run from source

Needs the [Dart SDK](https://dart.dev/get-dart) (no Flutter) and Linux with BlueZ:

```bash
dart pub get
sudo dart run bin/relay.dart --name "Shed"
```

`sudo` is needed to register a GATT service with BlueZ over D-Bus. Adding your user to the `bluetooth` group also works.

## Build a binary

The binary bundles the Dart runtime, so the target needs nothing installed. Dart cross-compiles from any computer:

```bash
dart compile exe bin/relay.dart --target-os linux --target-arch arm64 -o meshenger-relay   # 64-bit Pi
dart compile exe bin/relay.dart -o meshenger-relay                                       # this machine
```

## Options

| Option | Meaning |
| --- | --- |
| `--name <label>` | Public name on everyone's Mesh Map (default `Relay`) |
| `--identity <path>` | Where the keypair is kept (default `relay-identity.json` next to the binary) |
| `--max-spool <n>` | Envelopes carried at once (default 256; each expires after 48 hours) |
| `--adapter <n>` | Bluetooth adapter index (default 0, `hci0`) |

## Layout

| Path | What's there |
| --- | --- |
| `bin/relay.dart` | Command line, logging and startup |
| `lib/src/core.dart` | Spool, dedup, gossip, forwarding and push decisions |
| `lib/src/ble.dart` | BlueZ: GATT service (announce, inbox, outbox), advertising with its fallbacks, scanning, connections |
| `lib/src/identity.dart` | The relay's Ed25519 keypair |
| `lib/src/transport.dart` | The interface `core.dart` uses to talk to a radio |
| `pi/` | systemd service file and an offline quick start for a USB stick |
| `test/` | Store-and-forward, dedup, gossip and advertising-payload tests (`dart test`) |
