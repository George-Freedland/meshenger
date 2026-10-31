import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/safety_service.dart';
import '../network/network_common.dart';
import 'safety_actions.dart';

/// Copies a full public address to the clipboard and confirms it.
Future<void> copyFullAddress(BuildContext context, String address) async {
  await Clipboard.setData(ClipboardData(text: address));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Copied full public address')),
  );
}

/// A shortened address with a copy icon; tapping copies the whole key.
class CopyableAddress extends StatelessWidget {
  const CopyableAddress(this.address, {super.key, this.style});

  final String address;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Tooltip(
      message: 'Copy full public address',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => copyFullAddress(context, address),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  shortAddress(address),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style ??
                      theme.textTheme.bodySmall?.copyWith(
                        color: muted,
                        fontFamily: 'monospace',
                      ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.copy, size: 14, color: muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Who someone is on the mesh: their name and full public address (shown
/// whole, selectable, one tap to copy), with shortcuts to message them or
/// visit their site in the Network browser.
Future<void> showPeerInfoSheet(
  BuildContext context, {
  required String address,
  required String name,
  bool showMessage = true,
}) async {
  var copied = false;
  final blocked = await SafetyService.instance.isBlocked(address);
  if (!context.mounted) return;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      void openRoute(String route) {
        Navigator.pop(dialogContext);
        context.push(route);
      }

      return AlertDialog(
        title: Row(
          children: [
            InitialAvatar(name: name, seed: address, radius: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Public address', style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  address,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ),
              const SizedBox(height: 10),
              // A snackbar would sit dimmed behind the dialog barrier.
              StatefulBuilder(
                builder: (context, setState) => FilledButton.tonalIcon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: address));
                    setState(() => copied = true);
                  },
                  icon: Icon(copied ? Icons.check : Icons.copy, size: 18),
                  label: Text(copied ? 'Copied' : 'Copy address'),
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    style: blocked
                        ? null
                        : TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.error),
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      blocked
                          ? unblockPerson(context, address: address, name: name)
                          : confirmBlock(context, address: address, name: name);
                    },
                    icon: const Icon(Icons.block, size: 18),
                    label: Text(blocked ? 'Unblock' : 'Block'),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      showReportDialog(context, address: address, name: name);
                    },
                    icon: const Icon(Icons.flag_outlined, size: 18),
                    label: const Text('Report'),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => openRoute(
                '/app/network?url=${Uri.encodeComponent(address)}'),
            icon: const Icon(Icons.public, size: 18),
            label: const Text('Visit site'),
          ),
          if (showMessage)
            TextButton.icon(
              onPressed: () =>
                  openRoute('/chat?peer=${Uri.encodeComponent(address)}'),
              icon: const Icon(Icons.chat_bubble_outline, size: 18),
              label: const Text('Message'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
