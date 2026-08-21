import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/services/messenger_service.dart';
import '../../core/services/transport_settings.dart';

/// Persistent transport-health banner.
///
/// Transport startup failures used to be stored silently and only surface
/// when the user happened to toggle transports — the mesh map just looked
/// empty. This banner puts the problem (and the fix) where users actually
/// look:
/// - red with a Retry button when the transport failed to start (Bluetooth
///   off, permission denied, …);
/// - amber when running degraded (central-only Bluetooth: can discover
///   others but is not discoverable itself);
/// - hidden when everything is healthy.
class TransportStatusBanner extends StatefulWidget {
  const TransportStatusBanner({super.key});

  @override
  State<TransportStatusBanner> createState() => _TransportStatusBannerState();
}

class _TransportStatusBannerState extends State<TransportStatusBanner> {
  StreamSubscription<TransportMode>? _sub;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _sub = MessengerService.instance.onTransportChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _retry() async {
    setState(() => _retrying = true);
    await MessengerService.instance.restartTransport();
    if (mounted) setState(() => _retrying = false);
  }

  @override
  Widget build(BuildContext context) {
    final service = MessengerService.instance;
    final error = service.transportError;
    final warning = service.transportWarning;
    if (error == null && warning == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final isError = error != null;
    final background = isError
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.tertiaryContainer;
    final foreground = isError
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onTertiaryContainer;
    final bluetooth = service.mode == TransportMode.bluetooth;
    final icon = isError
        ? (bluetooth ? Icons.bluetooth_disabled : Icons.wifi_off)
        : Icons.info_outline;
    final title = isError
        ? (bluetooth
            ? 'Bluetooth transport not running'
            : 'LAN transport not running')
        : 'Limited Bluetooth mode';

    return Material(
      color: background,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: foreground, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(color: foreground),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    error ?? warning!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: foreground.withValues(alpha: 0.9),
                    ),
                  ),
                ],
              ),
            ),
            if (isError) ...[
              const SizedBox(width: 8),
              _retrying
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : TextButton(
                      onPressed: _retry,
                      style: TextButton.styleFrom(foregroundColor: foreground),
                      child: const Text('Retry'),
                    ),
            ],
          ],
        ),
      ),
    );
  }
}
