// Meshenger relay daemon: a headless mesh gateway.
//
// Advertises and scans over Bluetooth LE exactly like the phone app, so it
// slots invisibly into the mesh. It stores and forwards end-to-end
// encrypted envelopes it CANNOT read (only the final recipient holds the
// private key).
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
//
// Bluetooth requires BlueZ, so the relay only runs on Linux.

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

  if (!Platform.isLinux) {
    log('Bluetooth needs BlueZ (Linux) — nothing to relay over. Exiting.');
    exitCode = 1;
    return;
  }

  final ble = BleTransport(
    identity: identity,
    localName: name,
    adapterIndex: adapterIndex,
    log: log,
  );
  try {
    await ble.start();
  } catch (e) {
    log('Bluetooth unavailable: $e');
    log('Exiting. (If this is a permission error, run as root or add your '
        'user to the "bluetooth" group.)');
    exitCode = 1;
    return;
  }

  final core = RelayCore(
    identity: identity,
    name: name,
    maxSpool: maxSpool,
    transports: [ble],
  );
  await core.start();

  log('Relay running over Bluetooth. Ctrl-C to stop.');

  Timer.periodic(const Duration(minutes: 5), (_) {
    log('Status: ${core.stats}');
  });

  ProcessSignal.sigint.watch().listen((_) async {
    log('Shutting down…');
    await core.stop();
    exit(0);
  });
}
