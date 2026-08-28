// Meshenger relay daemon: a headless mesh gateway.
//
// Bluetooth-first: advertises and scans exactly like the phone app, so it
// slots invisibly into the BLE mesh. It stores and forwards end-to-end
// encrypted envelopes it CANNOT read (only the final recipient holds the
// private key) and bridges between links — Bluetooth on one side, LAN on
// the other — so two Bluetooth islands connect across a house.
//
// Run on a Raspberry Pi (or anything with the Dart SDK + BlueZ):
//   cd relay && dart pub get && sudo dart run bin/relay.dart --name "Shed"
// Or compile a native binary:
//   dart compile exe bin/relay.dart -o meshenger-relay
//
// Options:
//   --name <label>       Public name shown on peers' Mesh Maps (default: Relay)
//   --identity <path>    Where the relay keypair persists
//                        (default: relay-identity.json next to the binary)
//   --max-spool <n>      Max envelopes carried at once (default 256)
//   --adapter <n>        Bluetooth adapter index (default 0 = hci0)
//   --no-ble             Disable the Bluetooth link
//   --no-lan             Disable the LAN link
//
// Bluetooth requires BlueZ (Linux). Elsewhere (e.g. macOS for development)
// the relay runs LAN-only.

import 'dart:async';
import 'dart:io';

import 'package:meshenger_relay/meshenger_relay.dart';

void main(List<String> args) {
  // A planted gateway must never die from a transient radio/socket error.
  runZonedGuarded(() => _run(args), (error, stack) {
    stdout.writeln('Recovered from error: $error');
  });
}

String? _argValue(List<String> args, String flag) {
  final idx = args.indexOf(flag);
  if (idx < 0 || idx + 1 >= args.length) return null;
  return args[idx + 1];
}

Future<void> _run(List<String> args) async {
  final name = _argValue(args, '--name') ?? 'Relay';
  final maxSpool = int.tryParse(_argValue(args, '--max-spool') ?? '') ?? 256;
  final adapterIndex = int.tryParse(_argValue(args, '--adapter') ?? '') ?? 0;
  final wantBle = !args.contains('--no-ble');
  final wantLan = !args.contains('--no-lan');
  final identityPath = _argValue(args, '--identity') ??
      '${File(Platform.script.toFilePath()).parent.path}/relay-identity.json';

  final identity = await RelayIdentity.loadOrCreate(identityPath);

  void log(String message) {
    final now = DateTime.now().toIso8601String().substring(11, 19);
    stdout.writeln('[$now] $message');
  }

  log('Meshenger relay "$name"');
  log('Address: ${identity.address}');
  log('This node forwards encrypted envelopes it cannot read.');

  final transports = <RelayTransport>[];

  if (wantBle) {
    if (Platform.isLinux) {
      final ble = BleTransport(
        identity: identity,
        localName: name,
        adapterIndex: adapterIndex,
        log: log,
      );
      try {
        await ble.start();
        transports.add(ble);
      } catch (e) {
        log('Bluetooth unavailable: $e');
        log('Continuing without Bluetooth. (If this is a permission error, '
            'run as root or add your user to the "bluetooth" group.)');
      }
    } else {
      log('Bluetooth link needs BlueZ (Linux); running without it here.');
    }
  }

  if (wantLan) {
    final lan = LanTransport(identity: identity, log: log);
    try {
      await lan.start();
      transports.add(lan);
    } catch (e) {
      log('LAN unavailable: $e');
    }
  }

  if (transports.isEmpty) {
    log('No links available — nothing to relay over. Exiting.');
    exitCode = 1;
    return;
  }

  final core = RelayCore(
    identity: identity,
    name: name,
    maxSpool: maxSpool,
    transports: transports,
  );
  await core.start();

  log('Relay running with ${transports.map((t) => t.name).join(" + ")}. '
      'Ctrl-C to stop.');

  Timer.periodic(const Duration(minutes: 5), (_) {
    log('Status: ${core.stats}');
  });

  ProcessSignal.sigint.watch().listen((_) async {
    log('Shutting down…');
    await core.stop();
    exit(0);
  });
}
