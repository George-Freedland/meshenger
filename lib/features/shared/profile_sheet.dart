import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/services/identity_service.dart';
import '../../core/services/messenger_service.dart';
import '../../core/ui/avatars.dart';
import 'contact_actions.dart';
import 'rescan_button.dart';

/// "Me" card: who I am on the mesh (avatar, nickname, public key, QR),
/// how many devices are in range, and the invisible switch.
Future<void> showProfileSheet(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const _ProfileDialog(),
    );

class _ProfileDialog extends StatefulWidget {
  const _ProfileDialog();

  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  String? _address;
  String? _qrPayload;
  bool _showQr = false;
  bool _invisible = MessengerService.instance.isInvisible;
  bool _switching = false;
  Set<String> _inRange = MessengerService.instance.visiblePeers;
  StreamSubscription<Set<String>>? _peersSub;

  @override
  void initState() {
    super.initState();
    _peersSub = MessengerService.instance.onPeersChanged.listen((peers) {
      if (mounted) setState(() => _inRange = peers);
    });
    _load();
  }

  @override
  void dispose() {
    _peersSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final address = await IdentityService.instance.getPublicAddressBase64();
    final payload = address == null ? null : await myContactQrPayload(address);
    if (!mounted) return;
    setState(() {
      _address = address;
      _qrPayload = payload;
    });
  }

  Future<void> _copyAddress() async {
    final address = _address;
    if (address == null) return;
    await Clipboard.setData(ClipboardData(text: address));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied public key')),
    );
  }

  Future<void> _setInvisible(bool value) async {
    setState(() {
      _invisible = value;
      _switching = true;
    });
    await MessengerService.instance.setInvisible(value);
    if (!mounted) return;
    setState(() {
      _switching = false;
      _inRange = MessengerService.instance.visiblePeers;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final identity = IdentityService.instance.active;
    final nickname = identity?.nickname ?? '';
    final address = _address;
    final count = _inRange.length;
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  presetAvatar(identity?.avatarId ?? 0, size: 56),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          nickname.isEmpty ? 'No nickname' : nickname,
                          style: theme.textTheme.titleLarge,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          _invisible
                              ? 'Invisible on the mesh'
                              : 'Visible on the mesh',
                          style:
                              theme.textTheme.bodySmall?.copyWith(color: muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text('Public key', style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        address ?? '…',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy public key',
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: address == null ? null : _copyAddress,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: Icon(_showQr ? Icons.expand_less : Icons.qr_code),
                label: Text(_showQr ? 'Hide QR code' : 'Show QR code'),
                onPressed: _qrPayload == null
                    ? null
                    : () => setState(() => _showQr = !_showQr),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                alignment: Alignment.topCenter,
                child: _showQr && _qrPayload != null
                    ? Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Column(
                          children: [
                            QrImageView(
                              data: _qrPayload!,
                              size: 220,
                              backgroundColor: Colors.white,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Scan to add me as a contact',
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: muted),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.bluetooth_searching),
                title: Text(count == 0
                    ? 'No devices in range'
                    : '$count ${count == 1 ? 'device' : 'devices'} in range'),
                subtitle:
                    const Text('Reachable directly over Bluetooth right now'),
                trailing: const RescanButton(),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: Icon(
                  _invisible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                title: const Text('Invisible'),
                subtitle: Text(
                  _invisible
                      ? 'You don\'t appear on anyone\'s mesh map and your '
                          'presence isn\'t announced. You can still see '
                          'others and send and receive messages.'
                      : 'Nearby devices can see you on their mesh map.',
                ),
                value: _invisible,
                onChanged: _switching ? null : _setInvisible,
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
