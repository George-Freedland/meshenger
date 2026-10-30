import 'package:flutter/material.dart';

import '../../core/services/messenger_service.dart';

/// Toolbar button that rescans the surroundings for nearby devices.
class RescanButton extends StatefulWidget {
  const RescanButton({super.key});

  @override
  State<RescanButton> createState() => _RescanButtonState();
}

class _RescanButtonState extends State<RescanButton> {
  bool _scanning = false;

  Future<void> _rescan() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _scanning = true);
    try {
      // Answers trickle in over the next seconds; keep the spinner up long
      // enough to say "looking".
      await Future.wait<void>([
        MessengerService.instance.rescan(),
        Future<void>.delayed(const Duration(seconds: 2)),
      ]);
      final error = MessengerService.instance.transportError;
      messenger.showSnackBar(SnackBar(
        content: Text(error != null
            ? 'Bluetooth unavailable: $error'
            : 'Rescanning — nearby devices appear as they answer'),
      ));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Rescan surroundings',
      onPressed: _scanning ? null : _rescan,
      icon: _scanning
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh),
    );
  }
}
